import Foundation

public let GEMINI_LIVE_ENDPOINT =
    "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
public let GEMINI_LIVE_MODEL = "models/gemini-3.5-transcribe-live"

private let CONNECT_TIMEOUT_MS: UInt64 = 15_000
private let FAST_FINISH_GRACE_MS: UInt64 = 1_200
private let HARD_FINISH_TIMEOUT_MS: UInt64 = 3_500
private let SESSION_TIMEOUT_MS: UInt64 = 9 * 60 * 1000
private let MAX_BUFFERED_AUDIO_BYTES = 16_000 * 2 * 10
private let RACE_WINDOW_MS: Double = 800
private let MAX_RECONNECT_ATTEMPTS = 2
private let RECONNECT_DELAY_MS: UInt64 = 200

public protocol LiveTranscriber: AnyObject {
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

    public init(
        apiKey: String,
        config: TranscriptionConfig,
        emit: @escaping (ServerEvent) -> Void,
        webSocketFactory: GeminiWebSocketFactory? = nil
    ) {
        self.apiKey = apiKey
        self.config = config
        self.emit = emit
        self.webSocketFactory = webSocketFactory
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
        events.append(.error(code: code, message: redactApiKeys(message), retryable: true))
        return events
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

public final class GeminiLiveTranscriber: LiveTranscriber, @unchecked Sendable {
    private enum State {
        case idle, connecting, ready, finishing, closed
    }

    private let options: GeminiLiveOptions
    private var socket: (any GeminiWebSocket)?
    private var state: State = .idle
    private var queuedAudio: [Data] = []
    private var queuedBytes = 0
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var failureReported = false
    private var completeEmitted = false
    private var reconnectAttempts = 0
    private var finishRequested = false
    private var lastAudioSentAt: Double = 0
    private var lastTurnCompleteAt: Double = 0
    private var latestInterim = ""
    private var lastFinal = ""
    private var hasTranscript = false
    private var fastFinishGraceElapsed = false
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
        webSocketFactory: GeminiWebSocketFactory? = nil
    ) {
        self.init(options: GeminiLiveOptions(
            apiKey: apiKey,
            config: config,
            emit: emit,
            webSocketFactory: webSocketFactory
        ))
    }

    public func connect() async throws {
        guard state == .idle else {
            throw TranscriptionError("Session already started.")
        }
        state = .connecting
        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            openSocket()
        }
    }

    public func sendAudio(_ chunk: Data) throws {
        try validatePcmChunk(chunk)
        if state == .finishing || state == .closed {
            throw TranscriptionError("Cannot send audio after the session is finishing.")
        }
        if state != .ready {
            if queuedBytes + chunk.count > MAX_BUFFERED_AUDIO_BYTES {
                throw TranscriptionError("Audio queue exceeded 10 seconds while Gemini was connecting.")
            }
            queuedAudio.append(chunk)
            queuedBytes += chunk.count
            return
        }
        lastAudioSentAt = nowMilliseconds()
        try sendAudioFrame(chunk)
    }

    public func finish() throws {
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
        options.emit(.speechEnd)
        if options.config.vad != .manual,
           lastAudioSentAt == 0 || lastTurnCompleteAt - lastAudioSentAt > RACE_WINDOW_MS
        {
            emitComplete()
            close()
            return
        }
        let realtimeInput: [String: Any] =
            options.config.vad == .manual
                ? ["activityEnd": [String: Any]()]
                : ["audioStreamEnd": true]
        try sendJSON(["realtimeInput": realtimeInput])
        finishTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(FAST_FINISH_GRACE_MS))
            guard !Task.isCancelled else { return }
            self?.handleFastFinishGrace()
            guard self?.state == .finishing else { return }
            try? await Task.sleep(for: .milliseconds(HARD_FINISH_TIMEOUT_MS - FAST_FINISH_GRACE_MS))
            guard !Task.isCancelled else { return }
            self?.handleHardFinishTimeout()
        }
    }

    public func close() {
        if state == .closed { return }
        state = .closed
        clearTimers()
        if let socket, socket.readyState == .open || socket.readyState == .connecting {
            socket.close(code: 1000, reason: "local session ended")
        }
    }

    private func openSocket() {
        let encodedKey =
            options.apiKey.addingPercentEncoding(withAllowedCharacters: encodeURIComponentAllowed) ?? options.apiKey
        let url = URL(string: "\(GEMINI_LIVE_ENDPOINT)?key=\(encodedKey)")!
        let factory = options.webSocketFactory ?? defaultGeminiWebSocketFactory
        let socket = factory(url)
        self.socket = socket

        socket.onOpen = { [weak self, weak socket] in
            guard let self, let socket, socket === self.socket, self.state != .closed else { return }
            try? self.sendJSON(buildGeminiSetup(self.options.config))
        }
        socket.onMessage = { [weak self, weak socket] text in
            guard let self, let socket, socket === self.socket else { return }
            self.onMessage(text)
        }
        socket.onError = { [weak self, weak socket] in
            guard let self, let socket, socket === self.socket else { return }
            if socket.readyState != .closed {
                socket.close(code: 1006, reason: "")
            }
        }
        socket.onClose = { [weak self, weak socket] code, reason in
            guard let self, let socket, socket === self.socket else { return }
            self.handleClose(code: code, reason: reason)
        }

        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(CONNECT_TIMEOUT_MS))
            guard !Task.isCancelled else { return }
            self?.closeSocketIfStillConnecting()
        }
    }

    private func handleClose(code: Int, reason: String) {
        let wasExpected = state == .closed
        let wasFinishing = state == .finishing || finishRequested
        clearTimers()
        socket = nil

        if !wasExpected, !wasFinishing, code != 1008, reconnectAttempts < MAX_RECONNECT_ATTEMPTS {
            reconnectAttempts += 1
            state = .connecting
            options.emit(.connecting)
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(RECONNECT_DELAY_MS))
                guard !Task.isCancelled else { return }
                if self?.state == .connecting {
                    self?.openSocket()
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
            options.emit(.warning(
                code: "gemini_connection_closed",
                message: "Gemini Live closed the session (code \(code))\(suffix); using buffered transcript."
            ))
            emitComplete()
            return
        }
        if hasTranscript || recovered {
            // Keep the buffered transcript for Option-stop. Do not complete while still listening.
            options.emit(.warning(
                code: "gemini_connection_closed",
                message: "Gemini Live closed the session (code \(code))\(suffix); dictation will use the buffered transcript when you stop."
            ))
            return
        }
        fail(
            code: "gemini_connection_closed",
            message: "Gemini Live closed the session (code \(code))\(suffix).",
            retryable: code != 1008
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
            close()
            return
        }

        for event in parseGeminiMessage(parsed) {
            if event.typeName == "ready" {
                onReady()
                options.emit(event)
                options.emit(.speechStart)
                continue
            }
            if case .error(let code, let message, let retryable) = event {
                if state == .finishing, emitBufferedComplete(code: code, message: "\(message) Using buffered transcript.") {
                    continue
                }
                fail(code: code, message: message, retryable: retryable)
                close()
                continue
            }
            if event.typeName == "complete" {
                commitInterimFallback()
                lastTurnCompleteAt = nowMilliseconds()
                // Mid-session turnComplete is a VAD turn, not dictation complete.
                if state == .finishing {
                    emitComplete()
                    close()
                }
                continue
            }
            if case .interim(let text) = event {
                latestInterim = text
            }
            if case .final(let text) = event {
                latestInterim = ""
                lastFinal = text
                hasTranscript = true
            }
            options.emit(event)
            if case .interim = event,
               state == .finishing,
               fastFinishGraceElapsed,
               commitInterimFallback()
            {
                options.emit(.warning(
                    code: "finalization_ack_timeout",
                    message: "Gemini did not acknowledge finalization; using its latest buffered transcript."
                ))
                emitComplete()
                close()
                continue
            }
            if case .final = event, state == .finishing {
                emitComplete()
                close()
            }
        }
    }

    private func onReady() {
        guard state == .connecting else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        state = .ready
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
            guard !Task.isCancelled else { return }
            self?.options.emit(.error(
                code: "session_limit",
                message: "The local session reached its nine-minute safety limit.",
                retryable: true
            ))
            self?.close()
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

    @discardableResult
    private func commitInterimFallback() -> Bool {
        let text = latestInterim.trimmingCharacters(in: .whitespacesAndNewlines)
        latestInterim = ""
        if text.isEmpty || normalizeTranscript(text) == normalizeTranscript(lastFinal) {
            return false
        }
        lastFinal = text
        hasTranscript = true
        options.emit(.final(text: text))
        return true
    }

    private func fail(code: String, message: String, retryable: Bool) {
        if failureReported || completeEmitted { return }
        failureReported = true
        let error = TranscriptionError(message)
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        options.emit(.error(code: code, message: message, retryable: retryable))
    }

    private func emitComplete() {
        if completeEmitted { return }
        completeEmitted = true
        options.emit(.complete)
    }

    @discardableResult
    private func emitBufferedComplete(code: String, message: String) -> Bool {
        if completeEmitted { return true }
        let recovered = commitInterimFallback()
        guard hasTranscript || recovered else { return false }
        if state != .finishing, state != .closed {
            options.emit(.speechEnd)
        }
        options.emit(.warning(code: code, message: message))
        emitComplete()
        close()
        return true
    }

    private func handleFastFinishGrace() {
        guard state == .finishing, !completeEmitted else { return }
        let recoveredInterim = commitInterimFallback()
        if hasTranscript {
            options.emit(.warning(
                code: "finalization_ack_timeout",
                message: recoveredInterim
                    ? "Gemini did not acknowledge finalization; using its latest buffered transcript."
                    : "Gemini did not acknowledge finalization; using the transcript already received."
            ))
            emitComplete()
            close()
            return
        }
        fastFinishGraceElapsed = true
    }

    private func handleHardFinishTimeout() {
        guard state == .finishing, !completeEmitted else { return }
        let lateInterim = commitInterimFallback()
        if hasTranscript {
            options.emit(.warning(
                code: "finalization_ack_timeout",
                message: lateInterim
                    ? "Gemini did not acknowledge finalization; using its latest buffered transcript."
                    : "Gemini did not acknowledge finalization; using the transcript already received."
            ))
            emitComplete()
            close()
            return
        }
        fail(
            code: "final_transcript_timeout",
            message: "Gemini did not finalize the transcript in time.",
            retryable: true
        )
        close()
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
