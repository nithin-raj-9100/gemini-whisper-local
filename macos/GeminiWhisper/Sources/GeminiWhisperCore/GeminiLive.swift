import Foundation

public let GEMINI_LIVE_ENDPOINT =
    "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
public let GEMINI_LIVE_MODEL = "models/gemini-3.5-transcribe-live"

private let CONNECT_TIMEOUT_MS: UInt64 = 15_000
private let FAST_FINISH_GRACE_MS: UInt64 = 500
private let HARD_FINISH_TIMEOUT_MS: UInt64 = 1_200
/// Last-resort local limit. DictationSession rotates to a fresh Live session
/// well before this, at a pause, so a long dictation never reaches it.
private let SESSION_TIMEOUT_MS: UInt64 = 9 * 60 * 1000
/// Audio held while (re)connecting. DictationSession records every frame
/// independently, so overflowing this degrades Live but never loses audio.
private let MAX_BUFFERED_AUDIO_BYTES = 16_000 * 2 * 30
private let RACE_WINDOW_MS: Double = 800
private let MAX_RECONNECT_ATTEMPTS = 5
/// Exponential reconnect backoff: 200, 400, 800, 1600, 3200 ms.
private let RECONNECT_BASE_DELAY_MS: UInt64 = 200
private let RECONNECT_MAX_DELAY_MS: UInt64 = 3_200
/// How long a reconnect waits for the network path to come back.
private let NETWORK_WAIT_MS: UInt64 = 30_000
/// An identical final this soon after the previous one is a server resend.
private let RESEND_WINDOW_MS: Double = 2_000

public protocol LiveTranscriber: AnyObject, Sendable {
    func connect() async throws
    func sendAudio(_ chunk: Data) throws
    func finish() throws
    func close()
}

public struct GeminiLiveOptions {
    public var apiKey: String
    public var config: TranscriptionConfig
    public var emit: (ServerEvent) -> Void
    public var webSocketFactory: GeminiWebSocketFactory?
    /// nil uses the system path monitor (NWPathMonitor on macOS).
    public var network: (any NetworkPathMonitoring)?

    public init(
        apiKey: String,
        config: TranscriptionConfig,
        emit: @escaping (ServerEvent) -> Void,
        webSocketFactory: GeminiWebSocketFactory? = nil,
        network: (any NetworkPathMonitoring)? = nil
    ) {
        self.apiKey = apiKey
        self.config = config
        self.emit = emit
        self.webSocketFactory = webSocketFactory
        self.network = network
    }
}

public func buildGeminiSetup(_ config: TranscriptionConfig) -> [String: Any] {
    var setup: [String: Any] = [
        "model": GEMINI_LIVE_MODEL,
        "generationConfig": ["responseModalities": ["TEXT"]],
        "inputAudioTranscription": [
            "languageCodes": config.languageCodes,
            "customVocabulary": config.customVocabulary,
            "mode": config.mode.rawValue.uppercased(),
        ],
    ]

    if config.vad == .manual {
        setup["realtimeInputConfig"] = [
            "automaticActivityDetection": ["disabled": true],
        ]
    } else {
        setup["realtimeInputConfig"] = [
            "automaticActivityDetection": [
                "disabled": false,
                "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                "prefixPaddingMs": config.vadPrefixPaddingMs,
                "silenceDurationMs": config.vadSilenceDurationMs,
            ],
        ]
    }

    return ["setup": setup]
}

/// Gemini statuses that a reconnect or retry cannot fix.
let NON_RETRYABLE_GEMINI_STATUSES: Set<String> = [
    "INVALID_ARGUMENT", "PERMISSION_DENIED", "UNAUTHENTICATED", "NOT_FOUND", "FAILED_PRECONDITION",
]

/// True when an error or close reason says the API key itself was rejected.
/// Retrying, reconnecting, or falling back to another endpoint with the same key
/// cannot succeed, so callers should fail fast instead.
public func isAuthenticationFailure(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return [
        "api key not valid", "api_key_invalid", "invalid api key", "api key expired",
        "permission_denied", "permission denied", "unauthenticated",
    ].contains { lowered.contains($0) }
}

/// Protobuf Duration JSON ("12.5s") or a bare number of seconds.
func parseDurationMilliseconds(_ value: Any?) -> Int {
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
        return Double(number).map { Int(($0 * 1000).rounded()) } ?? 0
    }
    if let number = value as? NSNumber { return Int((number.doubleValue * 1000).rounded()) }
    if let object = jsonObject(value) {
        let seconds = (object["seconds"] as? NSNumber)?.doubleValue ?? 0
        let nanos = (object["nanos"] as? NSNumber)?.doubleValue ?? 0
        return Int((seconds * 1000 + nanos / 1_000_000).rounded())
    }
    return 0
}

public func parseGeminiMessage(_ value: Any) -> [ServerEvent] {
    guard let object = jsonObject(value) else { return [] }
    var events: [ServerEvent] = []

    if object["setupComplete"] != nil {
        events.append(.ready)
    }

    if let errorObject = jsonObject(object["error"]) {
        let rawMessage = errorObject["message"] as? String ?? ""
        let message = rawMessage.isEmpty ? "Gemini Live returned an error." : rawMessage
        let code: String
        if let status = errorObject["status"] as? String, !status.isEmpty {
            code = status
        } else if let number = errorObject["code"] {
            code = "gemini_\(number)"
        } else {
            code = "gemini_error"
        }
        let permanent = NON_RETRYABLE_GEMINI_STATUSES.contains(code) || isAuthenticationFailure(message)
        events.append(.error(code: code, message: redactApiKeys(message), retryable: !permanent))
        return events
    }

    if let goAway = jsonObject(object["goAway"]) {
        events.append(.goAway(timeLeftMs: parseDurationMilliseconds(goAway["timeLeft"])))
    }

    guard let content = jsonObject(object["serverContent"]) else { return events }

    if let interim = jsonObject(content["interimInputTranscription"]),
       let text = interim["text"] as? String, !text.isEmpty
    {
        events.append(.interim(text: text))
    }
    if let final = jsonObject(content["inputTranscription"]),
       let text = final["text"] as? String, !text.isEmpty
    {
        events.append(.final(text: text))
    }
    if content["turnComplete"] as? Bool == true {
        events.append(.complete)
    }
    return events
}

/// Gemini Live client. Socket callbacks, timer tasks, and caller methods may run on
/// different threads, so every entry point runs under one recursive lock. Events
/// are queued while the lock is held and delivered, in order, only after it is
/// released: the consumer may take its own lock and call back in without
/// deadlocking against a socket callback.
public final class GeminiLiveTranscriber: LiveTranscriber, @unchecked Sendable {
    private enum State {
        case idle, connecting, ready, finishing, closed
    }

    private let options: GeminiLiveOptions
    private let lock = NSRecursiveLock()
    private var depth = 0
    private var outbox: [ServerEvent] = []
    private var emitting = false
    private var socket: (any GeminiWebSocket)?
    private var state: State = .idle
    private var queuedAudio: [Data] = []
    private var queuedBytes = 0
    private var localEndpoint = LocalSpeechEndpoint()
    private var hybridEndPending = false
    private var audioSequence = 0
    private var hybridEndSequence = 0
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var failureReported = false
    private var completeEmitted = false
    private var reconnectAttempts = 0
    private var finishRequested = false
    private var lastAudioSentAt: Double = 0
    private var lastTurnCompleteAt: Double = 0
    private var latestInterim = ""
    private var interimAccumulator = InterimTranscriptAccumulator()
    private var lastFinal = ""
    private var lastFinalAt: Double = 0
    /// Speech-energy audio sent since the last final. A final that repeats earlier
    /// text is only treated as new speech when enough new audio could carry it.
    private var voicedMsSinceFinal = 0
    private var hasTranscript = false
    private var connectTimeoutTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    public init(options: GeminiLiveOptions) {
        self.options = options
    }

    public convenience init(
        apiKey: String,
        config: TranscriptionConfig,
        emit: @escaping (ServerEvent) -> Void,
        webSocketFactory: GeminiWebSocketFactory? = nil,
        network: (any NetworkPathMonitoring)? = nil
    ) {
        self.init(options: GeminiLiveOptions(
            apiKey: apiKey,
            config: config,
            emit: emit,
            webSocketFactory: webSocketFactory,
            network: network
        ))
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            perform {
                guard state == .idle else {
                    continuation.resume(throwing: TranscriptionError("Session already started."))
                    return
                }
                state = .connecting
                connectContinuation = continuation
                openSocket()
            }
        }
    }

    public func sendAudio(_ chunk: Data) throws {
        try validatePcmChunk(chunk)
        try perform {
            if state == .finishing || state == .closed {
                return
            }
            if state != .ready {
                try queueAudio(chunk)
                return
            }

            // A URLSession transport failure can change the wrapper state before its
            // close delegate callback arrives. Buffer this frame and start recovery
            // here as well; otherwise every microphone frame is rejected during that
            // callback gap and the UI appears to keep listening with a frozen draft.
            guard socket?.readyState == .open else {
                try queueAudio(chunk)
                recoverUnavailableSocket()
                if state == .closed {
                    throw TranscriptionError("Gemini Live connection could not be restored.")
                }
                return
            }
            lastAudioSentAt = nowMilliseconds()
            try sendAudioFrame(chunk)
        }
    }

    public func finish() throws {
        try perform {
            if state == .connecting {
                finishRequested = true
                return
            }
            if state == .finishing {
                return
            }
            if state == .closed {
                if emitBufferedComplete(
                    code: "gemini_connection_closed",
                    message: "Gemini Live closed before stop; using buffered transcript."
                ) {
                    return
                }
                throw TranscriptionError("The transcription session is not ready.")
            }
            guard state == .ready else {
                throw TranscriptionError("The transcription session is not ready.")
            }
            state = .finishing
            emit(.speechEnd)
            // Nothing pending: the server already turned everything after the last
            // audio frame (or no audio was sent). Complete locally instead of a
            // network round trip. Applies to manual push-to-talk too: an
            // activityEnd acknowledging already-finalized audio buys nothing.
            if !hybridEndPending && (lastAudioSentAt == 0 || lastTurnCompleteAt - lastAudioSentAt > RACE_WINDOW_MS)
            {
                emitComplete()
                closeLocked()
                return
            }
            // audioStreamEnd is the only signal documented to bypass the server-side
            // silence wait. Manual VAD also needs activityEnd to close its segment,
            // and that path is known to hang without a following audioStreamEnd.
            if !hybridEndPending {
                if options.config.vad == .manual {
                    try sendJSON(["realtimeInput": ["activityEnd": [String: Any]()]])
                }
                try sendJSON(["realtimeInput": ["audioStreamEnd": true]])
            }
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(FAST_FINISH_GRACE_MS))
                guard !Task.isCancelled, let self else { return }
                let stillFinishing = self.perform { () -> Bool in
                    self.handleFastFinishGrace()
                    return self.state == .finishing
                }
                guard stillFinishing else { return }
                try? await Task.sleep(for: .milliseconds(HARD_FINISH_TIMEOUT_MS - FAST_FINISH_GRACE_MS))
                guard !Task.isCancelled else { return }
                self.perform { self.handleHardFinishTimeout() }
            }
        }
    }

    public func close() {
        perform { closeLocked() }
    }

    // MARK: - Locking

    /// Runs `body` under the lock. When the outermost call on this thread returns,
    /// queued events are delivered without the lock held.
    private func perform<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        depth += 1
        defer {
            depth -= 1
            let outermost = depth == 0
            lock.unlock()
            if outermost { drainOutbox() }
        }
        return try body()
    }

    /// Queue an event. Callers hold the lock.
    private func emit(_ event: ServerEvent) {
        outbox.append(event)
    }

    /// Delivers queued events in order from one thread at a time. A thread that
    /// finds another already delivering leaves its events for that thread.
    private func drainOutbox() {
        while true {
            lock.lock()
            if emitting || outbox.isEmpty {
                lock.unlock()
                return
            }
            emitting = true
            let batch = outbox
            outbox.removeAll()
            lock.unlock()
            for event in batch { options.emit(event) }
            lock.lock()
            emitting = false
            lock.unlock()
        }
    }

    private var networkAvailable: Bool {
        (options.network ?? defaultNetworkPathMonitor()).isSatisfied
    }

    // MARK: - Socket lifecycle (lock held)

    private func closeLocked() {
        if state == .closed { return }
        state = .closed
        clearTimers()
        if let socket, socket.readyState == .open || socket.readyState == .connecting {
            socket.close(code: 1000, reason: "local session ended")
        }
    }

    private func openSocket() {
        hybridEndPending = false
        localEndpoint = LocalSpeechEndpoint()
        let encodedKey =
            options.apiKey.addingPercentEncoding(withAllowedCharacters: encodeURIComponentAllowed) ?? options.apiKey
        let url = URL(string: "\(GEMINI_LIVE_ENDPOINT)?key=\(encodedKey)")!
        let factory = options.webSocketFactory ?? defaultGeminiWebSocketFactory
        let socket = factory(url)
        self.socket = socket

        socket.onOpen = { [weak self, weak socket] in
            guard let self, let socket else { return }
            self.perform {
                guard socket === self.socket, self.state != .closed else { return }
                try? self.sendJSON(buildGeminiSetup(self.options.config))
            }
        }
        socket.onMessage = { [weak self, weak socket] text in
            guard let self, let socket else { return }
            self.perform {
                guard socket === self.socket else { return }
                self.onMessage(text)
            }
        }
        socket.onError = { [weak self, weak socket] in
            guard let self, let socket else { return }
            self.perform {
                guard socket === self.socket else { return }
                self.recoverUnavailableSocket()
            }
        }
        socket.onClose = { [weak self, weak socket] code, reason in
            guard let self, let socket else { return }
            self.perform {
                guard socket === self.socket else { return }
                self.handleClose(code: code, reason: reason)
            }
        }

        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(CONNECT_TIMEOUT_MS))
            guard !Task.isCancelled, let self else { return }
            self.perform { self.closeSocketIfStillConnecting() }
        }
    }

    private func handleClose(code: Int, reason: String) {
        let wasExpected = state == .closed
        let wasFinishing = state == .finishing || finishRequested
        let permanent = code == 1008 || isAuthenticationFailure(reason)
        clearTimers()
        socket = nil

        if !wasExpected, !wasFinishing, !permanent, reconnectAttempts < MAX_RECONNECT_ATTEMPTS {
            let delay = min(RECONNECT_MAX_DELAY_MS, RECONNECT_BASE_DELAY_MS << UInt64(reconnectAttempts))
            reconnectAttempts += 1
            commitInterimFallback()
            state = .connecting
            emit(.connecting)
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                // A dead interface would fail every attempt instantly. Wait for a
                // route instead of spending the attempts.
                var waited: UInt64 = 0
                while !Task.isCancelled, waited < NETWORK_WAIT_MS, self?.networkAvailable == false {
                    try? await Task.sleep(for: .milliseconds(250))
                    waited += 250
                }
                guard !Task.isCancelled, let self else { return }
                self.perform {
                    if self.state == .connecting {
                        self.openSocket()
                    }
                }
            }
            return
        }

        state = .closed
        if wasExpected || completeEmitted || failureReported {
            return
        }

        let recovered = commitInterimFallback()
        let detail = sanitizeCloseReason(reason)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        if wasFinishing, hasTranscript || recovered {
            emit(.warning(
                code: "gemini_connection_closed",
                message: "Gemini Live closed the session (code \(code))\(suffix); using buffered transcript."
            ))
            emitComplete()
            return
        }
        if hasTranscript || recovered {
            // Keep the buffered transcript for Option-stop. Do not complete while still listening.
            emit(.warning(
                code: "gemini_connection_closed",
                message: "Gemini Live closed the session (code \(code))\(suffix); dictation will use the buffered transcript when you stop."
            ))
            return
        }
        fail(
            code: "gemini_connection_closed",
            message: "Gemini Live closed the session (code \(code))\(suffix).",
            retryable: !permanent
        )
    }

    private func onMessage(_ text: String) {
        if state == .closed { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            fail(code: "invalid_gemini_message", message: "Gemini returned an unreadable message.", retryable: true)
            closeLocked()
            return
        }

        for event in parseGeminiMessage(parsed) {
            if state == .closed { break }
            if event.typeName == "ready" {
                onReady()
                emit(event)
                emit(.speechStart)
                continue
            }
            if case .error(let code, let message, let retryable) = event {
                if state == .finishing, emitBufferedComplete(code: code, message: "\(message) Using buffered transcript.") {
                    continue
                }
                fail(code: code, message: message, retryable: retryable)
                closeLocked()
                continue
            }
            if event.typeName == "complete" {
                commitInterimFallback()
                lastTurnCompleteAt = nowMilliseconds()
                let acknowledgedHybridEnd = hybridEndPending
                hybridEndPending = false
                if options.config.vad == .hybrid {
                    lastFinal = ""
                    emit(.turnBoundary)
                }
                if state == .finishing {
                    if acknowledgedHybridEnd, audioSequence > hybridEndSequence {
                        // An older pause finished while Stop was draining newer PCM.
                        // Only a subsequent acknowledgment may complete that newer audio.
                        try? sendJSON(["realtimeInput": ["audioStreamEnd": true]])
                    } else {
                        emitComplete()
                        closeLocked()
                    }
                }
                continue
            }
            if case .interim(let text) = event {
                let merged = interimAccumulator.accept(text)
                latestInterim = merged
                emit(.interim(text: merged))
                continue
            }
            if case .final(let text) = event {
                let accumulated = interimAccumulator.text
                let fullText = isRevisionReplacement(last: accumulated, incoming: text)
                    ? text : joinUniqueTranscript(accumulated, text)
                interimAccumulator.reset()
                latestInterim = ""
                // Drop server resends of text already delivered: without this,
                // Session/Controller append a second copy of the same chunk. A
                // repeat backed by new speech audio is kept: it was said again.
                if isResend(fullText) {
                    hasTranscript = true
                    if state == .finishing, !hybridEndPending {
                        emitComplete()
                        closeLocked()
                    }
                    continue
                }
                recordFinal(fullText)
                emit(.final(text: fullText))
                if state == .finishing, !hybridEndPending {
                    emitComplete()
                    closeLocked()
                }
                continue
            }
            // goAway and anything else pass through for the session to act on.
            emit(event)
        }
    }

    private func onReady() {
        guard state == .connecting else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        state = .ready
        reconnectAttempts = 0
        connectContinuation?.resume()
        connectContinuation = nil

        if options.config.vad == .manual {
            try? sendJSON(["realtimeInput": ["activityStart": [String: Any]()]])
        }
        for chunk in queuedAudio {
            try? sendAudioFrame(chunk)
        }
        if !queuedAudio.isEmpty {
            lastAudioSentAt = nowMilliseconds()
        }
        queuedAudio = []
        queuedBytes = 0

        sessionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(SESSION_TIMEOUT_MS))
            guard !Task.isCancelled, let self else { return }
            self.perform {
                self.emit(.error(
                    code: "session_limit",
                    message: "The local session reached its nine-minute safety limit.",
                    retryable: true
                ))
                self.closeLocked()
            }
        }

        if finishRequested {
            finishRequested = false
            try? finish()
        }
    }

    private func sendAudioFrame(_ chunk: Data) throws {
        try sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": chunk.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000",
                ],
            ],
        ])
        audioSequence += 1
        if pcmRootMeanSquare(chunk) >= PCM_VOICED_RMS_THRESHOLD {
            voicedMsSinceFinal += chunk.count / PCM_BYTES_PER_MILLISECOND
        }
        if options.config.vad == .hybrid, state == .ready,
           localEndpoint.accept(chunk), !hybridEndPending {
            try sendJSON(["realtimeInput": ["audioStreamEnd": true]])
            hybridEndPending = true
            hybridEndSequence = audioSequence
        }
    }

    private func queueAudio(_ chunk: Data) throws {
        if queuedBytes + chunk.count > MAX_BUFFERED_AUDIO_BYTES {
            throw TranscriptionError("Audio queue exceeded 30 seconds while Gemini was reconnecting.")
        }
        queuedAudio.append(chunk)
        queuedBytes += chunk.count
    }

    private func recoverUnavailableSocket() {
        guard state != .closed, state != .finishing, let failedSocket = socket else { return }

        // Detach first. URLSession and test sockets may synchronously invoke their
        // close callback; its identity guard will then ignore this already-handled
        // transport so reconnect attempts are counted exactly once.
        socket = nil
        handleClose(code: 1006, reason: "transport error")
        if failedSocket.readyState != .closed {
            failedSocket.close(code: 1001, reason: "reconnecting")
        }
    }

    private func sendJSON(_ message: [String: Any]) throws {
        guard let socket, socket.readyState == .open else {
            throw TranscriptionError("Gemini Live socket is not open.")
        }
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionError("Gemini Live socket is not open.")
        }
        socket.send(text)
    }

    private func recordFinal(_ text: String) {
        lastFinal = text
        lastFinalAt = nowMilliseconds()
        voicedMsSinceFinal = 0
        hasTranscript = true
    }

    /// A final that repeats the previous one is a server resend unless enough new
    /// speech audio arrived to have said it again.
    private func isResend(_ text: String) -> Bool {
        let normNew = normalizeTranscript(text)
        let normLast = normalizeTranscript(lastFinal)
        guard !normNew.isEmpty, !normLast.isEmpty else { return false }
        let freshSpeech = newSpeechLikely(voicedMs: voicedMsSinceFinal, incoming: text)
        if normNew == normLast {
            return nowMilliseconds() - lastFinalAt < RESEND_WINDOW_MS || !freshSpeech
        }
        return !freshSpeech && normalizedTranscriptContains(haystack: lastFinal, needle: text)
    }

    @discardableResult
    private func commitInterimFallback() -> Bool {
        let text = latestInterim.trimmingCharacters(in: .whitespacesAndNewlines)
        interimAccumulator.reset()
        latestInterim = ""
        // Echo guard: never promote interim the session already holds as a
        // final (exact or contained) unless new speech audio backs it. Otherwise
        // the fallback + the real final land as two copies of the same words on stop.
        if text.isEmpty { return false }
        let normText = normalizeTranscript(text)
        let normLast = normalizeTranscript(lastFinal)
        let freshSpeech = newSpeechLikely(voicedMs: voicedMsSinceFinal, incoming: text)
        if !freshSpeech, normText == normLast || normalizedTranscriptContains(haystack: lastFinal, needle: text) {
            return false
        }
        recordFinal(text)
        emit(.final(text: text))
        return true
    }

    private func fail(code: String, message: String, retryable: Bool) {
        if failureReported || completeEmitted { return }
        failureReported = true
        let error = TranscriptionError(message)
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        emit(.error(code: code, message: message, retryable: retryable))
    }

    private func emitComplete() {
        if completeEmitted { return }
        completeEmitted = true
        emit(.complete)
    }

    @discardableResult
    private func emitBufferedComplete(code: String, message: String) -> Bool {
        if completeEmitted { return true }
        let recovered = commitInterimFallback()
        guard hasTranscript || recovered else { return false }
        if state != .finishing, state != .closed {
            emit(.speechEnd)
        }
        emit(.warning(code: code, message: message))
        emitComplete()
        closeLocked()
        return true
    }

    private func handleFastFinishGrace() {
        guard state == .finishing, !completeEmitted else { return }
        // An interim is not an acknowledgment that the server processed the last audio.
        emit(.warning(code: "finalization_wait", message: "Still waiting for final audio acknowledgment."))
    }

    private func handleHardFinishTimeout() {
        guard state == .finishing, !completeEmitted else { return }
        let lateInterim = commitInterimFallback()
        if hasTranscript {
            emit(.warning(
                code: "finalization_ack_timeout",
                message: lateInterim
                    ? "Gemini did not acknowledge finalization; using its latest buffered transcript."
                    : "Gemini did not acknowledge finalization; using the transcript already received."
            ))
            emitComplete()
            closeLocked()
            return
        }
        fail(
            code: "final_transcript_timeout",
            message: "Gemini did not finalize the transcript in time.",
            retryable: true
        )
        closeLocked()
    }

    private func closeSocketIfStillConnecting() {
        guard state == .connecting, let socket else { return }
        socket.close(code: 1000, reason: "connect timeout")
    }

    private func clearTimers() {
        connectTimeoutTask?.cancel()
        finishTimeoutTask?.cancel()
        sessionTimeoutTask?.cancel()
        reconnectTask?.cancel()
        connectTimeoutTask = nil
        finishTimeoutTask = nil
        sessionTimeoutTask = nil
        reconnectTask = nil
    }
}

private let encodeURIComponentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

private func jsonObject(_ value: Any?) -> [String: Any]? {
    guard let value else { return nil }
    if let object = value as? [String: Any] {
        return object
    }
    if let object = value as? NSDictionary {
        var result: [String: Any] = [:]
        for (key, nested) in object {
            if let key = key as? String {
                result[key] = nested
            }
        }
        return result
    }
    return nil
}

private func sanitizeCloseReason(_ reason: String) -> String {
    redactApiKeys(reason)
}

private func normalizeTranscript(_ text: String) -> String {
    let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return collapsed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Holds already completed interim windows separately from the one hypothesis
/// Gemini is still revising. This prevents a revised active tail from being
/// appended repeatedly and fabricating duplicate paragraphs.
struct InterimTranscriptAccumulator {
    private var committed = ""
    private var active = ""

    var text: String {
        joinUniqueTranscript(committed, active)
    }

    mutating func accept(_ update: String) -> String {
        let incoming = update.trimmingCharacters(in: .whitespacesAndNewlines)
        if incoming.isEmpty { return text }
        if active.isEmpty {
            active = incoming
            return text
        }

        if let reconciled = reconcileHypothesis(active, incoming) {
            active = reconciled
            return text
        }

        // When incoming cannot be reconciled as an edit or extension of active,
        // active represents preceding speech and must be committed so earlier words
        // are never lost when a new sentence or window begins.
        committed = joinUniqueTranscript(committed, active)
        active = incoming
        return text
    }

    mutating func reset() {
        committed = ""
        active = ""
    }
}

/// Returns a single revised active hypothesis when two updates are related, or
/// nil when the incoming text begins a genuinely new window.
private func reconcileHypothesis(_ previous: String, _ update: String) -> String? {
    let oldWords = transcriptWords(previous)
    let newWords = transcriptWords(update)
    if oldWords.isEmpty || newWords.isEmpty { return update }
    if oldWords == newWords { return update }

    let commonPrefix = zip(oldWords, newWords).prefix { $0.0 == $0.1 }.count
    if newWords.count >= oldWords.count {
        if commonPrefix >= 2 || commonPrefix * 2 >= oldWords.count {
            return update
        }
    } else {
        if abs(oldWords.count - newWords.count) <= 3 && commonPrefix >= 2 {
            return update
        }
    }

    // A sliding update can restart from words already present inside the active
    // hypothesis. Keep the untouched prefix and replace only its tail.
    if newWords.count >= 2 {
        for index in oldWords.indices where index + 1 < oldWords.count {
            if oldWords[index] == newWords[0], oldWords[index + 1] == newWords[1] {
                let prefix = originalWords(previous).prefix(index).joined(separator: " ")
                return joinUniqueTranscript(prefix, update)
            }
        }
    }

    // Or it can continue from the end of the current active hypothesis.
    let maximumOverlap = min(oldWords.count, newWords.count)
    if maximumOverlap >= 2 {
        for count in stride(from: maximumOverlap, through: 2, by: -1) {
            if oldWords.suffix(count).elementsEqual(newWords.prefix(count)) {
                return joinUniqueTranscript(previous, updateWords(update, dropping: count))
            }
        }
    }
    return nil
}

private func transcriptWords(_ text: String) -> [String] {
    text.split(whereSeparator: { $0.isWhitespace }).map { token in
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }.filter { !$0.isEmpty }
}

private func originalWords(_ text: String) -> [Substring] {
    text.split(whereSeparator: { $0.isWhitespace })
}

private func updateWords(_ text: String, dropping count: Int) -> String {
    text.split(whereSeparator: { $0.isWhitespace })
        .dropFirst(count)
        .joined(separator: " ")
}

public func joinUniqueTranscript(_ left: String, _ right: String) -> String {
    let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
    if lhs.isEmpty { return rhs }
    if rhs.isEmpty { return lhs }

    let normalizedLeft = normalizeTranscript(lhs)
    let normalizedRight = normalizeTranscript(rhs)
    if normalizedLeft.contains(normalizedRight) { return lhs }
    if normalizedRight.contains(normalizedLeft) { return rhs }

    let leftWords = transcriptWords(lhs)
    let rightWords = transcriptWords(rhs)
    let maximumOverlap = min(leftWords.count, rightWords.count)
    if maximumOverlap >= 2 {
        for count in stride(from: maximumOverlap, through: 2, by: -1) {
            if leftWords.suffix(count).elementsEqual(rightWords.prefix(count)) {
                return lhs + " " + updateWords(rhs, dropping: count)
            }
        }
    }
    return lhs + " " + rhs
}
