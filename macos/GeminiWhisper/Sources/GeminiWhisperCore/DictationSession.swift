import Foundation

public final class DictationSession: @unchecked Sendable {
    public struct Options {
        public var apiKey: String
        public var config: TranscriptionConfig
        public var emit: (ServerEvent) -> Void
        public var transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)?
        public var intelligence: (any TranscriptIntelligence)?
        public var speculativeIntelligence: Bool
        public var backgroundPolicy: BackgroundPolishPolicy
        public var webSocketFactory: GeminiWebSocketFactory?

        public init(
            apiKey: String,
            config: TranscriptionConfig = .default,
            emit: @escaping (ServerEvent) -> Void,
            transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)? = nil,
            intelligence: (any TranscriptIntelligence)? = nil,
            speculativeIntelligence: Bool = true,
            webSocketFactory: GeminiWebSocketFactory? = nil,
            backgroundPolicy: BackgroundPolishPolicy = .init()
        ) {
            self.apiKey = apiKey
            self.config = config
            self.emit = emit
            self.transcriberFactory = transcriberFactory
            self.intelligence = intelligence
            self.speculativeIntelligence = speculativeIntelligence
            self.webSocketFactory = webSocketFactory
            self.backgroundPolicy = backgroundPolicy
        }
    }

    private enum State {
        case idle, connecting, ready, finishing, closed
    }

    private var stateName: String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .finishing: return "finishing"
        case .closed: return "closed"
        }
    }

    private let lock = NSRecursiveLock()
    private var revision = 0
    private var lastRevisionText = ""
    private var stopPrepared = false
    private var scheduler: BackgroundPolishScheduler
    private let sessionID = UUID().uuidString
    private var stopBeganAt: TimeInterval?
    private var audioEndedAt: TimeInterval?
    private var liveEndedAt: TimeInterval?
    private var liveFallback = false
    private var finalJobs = 0
    private var stabilityTask: Task<Void, Never>?
    private var revisionChangedAt = ProcessInfo.processInfo.systemUptime
    private var completedCandidate: (input: String, result: IntelligenceResult)?
    private let options: Options
    private var session: (any LiveTranscriber)?
    private var earlyAudio: [Data] = []
    private var finalSegments: [String] = []
    private var latestInterim = ""
    private var startsNewTurn = false
    private var polishEnabled: Bool
    private var state: State = .idle
    private var speculativePolish: SpeculativePolish?
    private var completeTask: Task<Void, Never>?
    private var resolvedIntelligence: (any TranscriptIntelligence)?
    private var didResolveIntelligence = false
    private var discarded = false
    // Per-session polish telemetry: how many background calls fired, finished,
    // or were cancelled before producing output. Surfaced via log-only
    // warnings so the next slow run shows volume, not just final latency.
    private var polishStarts = 0
    private var polishCompletions = 0
    private var polishCancels = 0

    private struct SpeculativePolish {
        var id: UUID
        var input: String
        var revision: Int
        var task: Task<Result<IntelligenceResult, Error>, Never>
    }

    public init(options: Options) {
        self.options = options
        self.scheduler = BackgroundPolishScheduler(policy: options.backgroundPolicy)
        self.polishEnabled = options.config.polish
    }

    public convenience init(
        apiKey: String,
        config: TranscriptionConfig = .default,
        emit: @escaping (ServerEvent) -> Void,
        transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)? = nil,
        intelligence: (any TranscriptIntelligence)? = nil,
        speculativeIntelligence: Bool = true,
        webSocketFactory: GeminiWebSocketFactory? = nil,
        backgroundPolicy: BackgroundPolishPolicy = .init()
    ) {
        self.init(options: Options(
            apiKey: apiKey,
            config: config,
            emit: emit,
            transcriberFactory: transcriberFactory,
            intelligence: intelligence,
            speculativeIntelligence: speculativeIntelligence,
            webSocketFactory: webSocketFactory,
            backgroundPolicy: backgroundPolicy
        ))
    }

    public var draft: String {
        lock.withLock { transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim, startsNewTurn: startsNewTurn) }
    }

    private func prepareSession() throws -> (any LiveTranscriber)? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else {
            throw ProtocolError(code: "already_started", message: "This connection already has a session.")
        }
        discarded = false
        polishEnabled = options.config.polish
        state = .connecting
        options.emit(.connecting)

        let emit: (ServerEvent) -> Void = { [weak self] event in
            self?.handle(event)
        }
        if let factory = options.transcriberFactory {
            session = factory(options.config, emit)
        } else {
            session = GeminiLiveTranscriber(
                apiKey: options.apiKey,
                config: options.config,
                emit: emit,
                webSocketFactory: options.webSocketFactory
            )
        }
        for block in earlyAudio { try session?.sendAudio(block) }
        earlyAudio.removeAll()
        return session
    }

    public func start() async throws {
        let live = try prepareSession()
        do {
            try await live?.connect()
        } catch {
            // Connection failures are reported through the event stream.
        }
    }

    public func sendAudio(_ chunk: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if session == nil, state == .idle {
            try validatePcmChunk(chunk)
            guard earlyAudio.reduce(0, { $0 + $1.count }) + chunk.count <= 320_000 else {
                throw TranscriptionError("Audio startup buffer exceeded 10 seconds.")
            }
            earlyAudio.append(chunk)
            return
        }
        try session?.sendAudio(chunk)
    }

    public func stop() throws {
        lock.lock()
        defer { lock.unlock() }
        stopBeganAt = stopBeganAt ?? ProcessInfo.processInfo.systemUptime
        audioEndedAt = ProcessInfo.processInfo.systemUptime
        stopPrepared = true
        stabilityTask?.cancel()
        if discarded {
            throw ProtocolError(code: "not_ready", message: "There is no ready transcription to stop.")
        }
        if state == .finishing {
            return
        }
        if state == .closed {
            if !draft.isEmpty {
                state = .finishing
                completeWithBufferedTranscript(code: "live_finish_failed", message: "The live session ended; inserting the buffered transcript.")
                return
            }
            throw ProtocolError(code: "not_ready", message: "There is no ready transcription to stop.")
        }
        guard state == .ready || state == .connecting else {
            throw ProtocolError(code: "not_ready", message: "There is no ready transcription to stop.")
        }
        stabilityTask?.cancel()
        state = .finishing
        do {
            try session?.finish()
        } catch {
            if !draft.isEmpty {
                completeWithBufferedTranscript(
                    code: "live_finish_failed",
                    message: redactApiKeys((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                )
                return
            }
            throw error
        }
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        discarded = true
        stabilityTask?.cancel()
        earlyAudio.removeAll()
        completeTask?.cancel()
        completeTask = nil
        session?.close()
        session = nil
        state = .closed
        cancelSpeculative()
        options.emit(.cancelled)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        discarded = true
        stabilityTask?.cancel()
        earlyAudio.removeAll()
        completeTask?.cancel()
        cancelSpeculative()
        state = .closed
        session?.close()
        session = nil
    }

    /// Cancel the in-flight background polish, counting it: a cancelled call
    /// still executes server-side and burns quota, so cancellations are a
    /// first-class telemetry signal, not a free undo.
    private func cancelSpeculative() {
        if speculativePolish != nil {
            polishCancels += 1
        }
        speculativePolish?.task.cancel()
        speculativePolish = nil
    }

    private var intelligence: (any TranscriptIntelligence)? {
        if !polishEnabled { return nil }
        if didResolveIntelligence { return resolvedIntelligence }
        didResolveIntelligence = true
        if let intelligence = options.intelligence {
            resolvedIntelligence = intelligence
        } else if !options.apiKey.isEmpty {
            resolvedIntelligence = createTranscriptIntelligence(apiKey: options.apiKey)
        }
        return resolvedIntelligence
    }

    private func handle(_ event: ServerEvent) {
        lock.lock()
        defer { lock.unlock() }
        if discarded { return }
        switch event {
        case .connecting:
            if state != .finishing { state = .connecting }
            options.emit(event)
        case .ready:
            if state != .finishing { state = .ready }
            options.emit(event)
        case .interim(let text):
            latestInterim = text
            updateRevision()
            scheduleBackgroundPolish()
            options.emit(event)
        case .turnBoundary:
            startsNewTurn = true
            options.emit(event)
        case .final(let text):
            latestInterim = ""
            let merged = startsNewTurn ? finalSegments + [text] : appendDedupedFinalSegment(finalSegments, text)
            startsNewTurn = false
            finalSegments = merged
            updateRevision()
            scheduleBackgroundPolish()
            options.emit(event)
        case .complete:
            // Only the user stop path completes dictation. Mid-session Live turnComplete
            // must not polish/paste while the Option toggle is still listening.
            // Tripwires: a dropped/duplicate complete is otherwise invisible and
            // the HUD sits on "Polishing..." until Escape.
            guard state == .finishing else {
                options.emit(.warning(code: "complete_ignored", message: "Live complete arrived while session state=\(stateName); ignoring."))
                return
            }
            if completeTask != nil {
                options.emit(.warning(code: "complete_deduped", message: "Duplicate Live complete ignored."))
                return
            }
            liveEndedAt = ProcessInfo.processInfo.systemUptime
            completeTask = Task { [weak self] in
                await self?.finishWithIntelligence()
            }
        case .cancelled:
            discarded = true
            state = .closed
            options.emit(event)
        case .error(let code, let message, _):
            if !draft.isEmpty, state == .finishing {
                completeWithBufferedTranscript(code: code, message: message)
                return
            }
            state = .closed
            options.emit(event)
        case .warning(let code, _):
            if code == "finalization_ack_timeout" || code == "gemini_connection_closed" { liveFallback = true }
            options.emit(event)
        default:
            options.emit(event)
        }
    }

    private func completeWithBufferedTranscript(code: String, message: String) {
        if discarded || completeTask != nil { return }
        liveFallback = true
        liveEndedAt = ProcessInfo.processInfo.systemUptime
        options.emit(.warning(code: code, message: message))
        completeTask = Task { [weak self] in
            await self?.finishWithIntelligence()
        }
    }

    /// Freeze background admission at the stop gesture; reserve new work for the final input.
    public func prepareToStop(at time: TimeInterval? = nil) {
        lock.withLock {
            guard !discarded, state == .ready || state == .connecting else { return }
            stopPrepared = true
            stopBeganAt = stopBeganAt ?? time ?? ProcessInfo.processInfo.systemUptime
            stabilityTask?.cancel()
            startStopEdgeSpeculation()
        }
    }

    /// The stop gesture is followed by the audio tail and Live finalization, during
    /// which the transcript usually does not change. Polishing the stop-edge draft
    /// there converts that wait into a head start: if the final input matches, the
    /// call is awaited instead of started; if late words arrive, it still becomes
    /// the previous-candidate context for revise() rather than being wasted.
    private func startStopEdgeSpeculation() {
        guard let intelligence, !discarded, options.speculativeIntelligence,
              polishEnabled, speculativePolish == nil else { return }
        let input = draft
        guard !input.isEmpty, completedCandidate?.input != input,
              scheduler.admitsStopEdge(input) else { return }
        scheduler.started(input, now: ProcessInfo.processInfo.systemUptime)
        let id = UUID()
        let sourceRevision = revision
        polishStarts += 1
        options.emit(.warning(code: "polish_start", message: "session=\(sessionID) kind=stop_edge revision=\(sourceRevision) backgroundJobs=\(scheduler.jobs)"))
        let task = Task<Result<IntelligenceResult, Error>, Never> { [weak self] in
            let result: Result<IntelligenceResult, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await intelligence.polishBackground(input))
            } catch { result = .failure(error) }
            self?.speculationFinished(id: id, input: input, revision: sourceRevision, result: result)
            return result
        }
        speculativePolish = SpeculativePolish(id: id, input: input, revision: sourceRevision, task: task)
    }

    private func updateRevision() {
        let text = draft
        if text != lastRevisionText {
            revision += 1
            lastRevisionText = text
            revisionChangedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private func scheduleBackgroundPolish() {
        stabilityTask?.cancel()
        stabilityTask = nil
        guard !discarded, !stopPrepared, state == .ready, options.speculativeIntelligence,
              polishEnabled, speculativePolish == nil else { return }
        let input = draft
        if completedCandidate?.input == input { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let delay = scheduler.delay(for: input, stableFor: now - revisionChangedAt, now: now) else { return }
        if delay <= 0 {
            startSpeculativePolish()
        } else {
            stabilityTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.lock.withLock { self?.scheduleBackgroundPolish() }
            }
        }
    }

    private func startSpeculativePolish() {
        guard let intelligence, !discarded, !stopPrepared, state == .ready,
              options.speculativeIntelligence, speculativePolish == nil else { return }
        let input = draft
        let now = ProcessInfo.processInfo.systemUptime
        guard let delay = scheduler.delay(for: input, stableFor: now - revisionChangedAt, now: now), delay <= 0 else { return }
        scheduler.started(input, now: now)
        let id = UUID()
        let sourceRevision = revision
        polishStarts += 1
        options.emit(.warning(code: "polish_start", message: "session=\(sessionID) kind=background revision=\(sourceRevision) backgroundJobs=\(scheduler.jobs)"))
        let task = Task<Result<IntelligenceResult, Error>, Never> { [weak self] in
            let result: Result<IntelligenceResult, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await intelligence.polishBackground(input))
            } catch { result = .failure(error) }
            self?.speculationFinished(id: id, input: input, revision: sourceRevision, result: result)
            return result
        }
        speculativePolish = SpeculativePolish(id: id, input: input, revision: sourceRevision, task: task)
    }

    private func speculationFinished(id: UUID, input: String, revision: Int, result: Result<IntelligenceResult, Error>) {
        lock.withLock {
            guard !discarded, speculativePolish?.id == id else { return }
            speculativePolish = nil
            switch result {
            case .success(let value):
                completedCandidate = (input, value)
                polishCompletions += 1
                options.emit(.warning(code: "polish_call", message: "polish kind=background revision=\(revision) ms=\(value.latencyMs) thoughts=\(value.thoughtsTokens) sessStarts=\(polishStarts) sessDone=\(polishCompletions)"))
                // Carry the actual source, never relabel old work with the newest draft.
                if input == draft {
                    options.emit(.polished(text: value.text, model: value.model, latencyMs: value.latencyMs, speculative: true, source: input))
                }
                // A completion schedules accumulated changes even if no more interims arrive.
                scheduleBackgroundPolish()
            case .failure(let error):
                let status = (error as? IntelligenceHTTPError)?.status
                scheduler.failed(input, now: ProcessInfo.processInfo.systemUptime, rateLimited: status == 429)
                options.emit(.warning(code: "polish_call", message: "session=\(sessionID) kind=background revision=\(revision) failed status=\(status.map(String.init) ?? "transport_or_output") backgroundDisabled=\(scheduler.throttled)"))
                scheduleBackgroundPolish()
            }
        }
    }

    private func finishWithIntelligence() async {
        // This task owns final editing. No polling, stale grace waits, or fragment joins.
        while true {
            let work: (String, (any TranscriptIntelligence)?, SpeculativePolish?, (input: String, result: IntelligenceResult)?)? = lock.withLock {
                guard !discarded else { return nil }
                state = .finishing
                let input = draft
                let matching = speculativePolish.flatMap { $0.input == input ? $0 : nil }
                if speculativePolish != nil, matching == nil { cancelSpeculative() }
                return (input, intelligence, matching, completedCandidate)
            }
            guard let (input, intelligence, pending, candidate) = work else { return }
            // Announce the settled raw transcript before blocking on polish, so a
            // consumer can insert it now and repair in place when polish lands.
            if intelligence != nil, !input.isEmpty {
                lock.withLock {
                    guard !discarded else { return }
                    let ready = candidate?.input == input
                    if !ready { options.emit(.provisional(text: input)) }
                }
            }
            var result: IntelligenceResult?
            var reused = false
            var outcome = "raw_disabled"
            var failure: Error?
            if let intelligence, !input.isEmpty {
                do {
                    if let candidate, candidate.input == input {
                        result = candidate.result
                        reused = true
                        outcome = "reused_ready"
                    } else if let pending {
                        result = try await pending.task.value.get()
                        reused = true
                        outcome = "reused_inflight"
                    } else {
                        lock.withLock { polishStarts += 1; finalJobs += 1 }
                        outcome = "fresh"
                        let sessionRef = self
                        result = try await intelligence.reviseStreaming(
                            input, previousInput: candidate?.input, previousOutput: candidate?.result.text
                        ) { partial in
                            sessionRef.lock.withLock {
                                guard !sessionRef.discarded else { return }
                                sessionRef.options.emit(.polishProgress(text: partial))
                            }
                        }
                    }
                } catch { failure = error; outcome = "raw_failure" }
            }
            let done = lock.withLock {
                guard !discarded else { return true }
                // A late recognition correction reopens editing before a single paste.
                guard input == draft else { return false }
                if let result {
                    if !reused { polishCompletions += 1 }
                    options.emit(.warning(code: "polish_call", message: "polish kind=\(reused ? "reused" : "final") revision=\(revision) chars=\(input.count) ms=\(result.latencyMs) thoughts=\(result.thoughtsTokens) attempts=\(result.attempts) statuses=\(result.statuses) sessStarts=\(polishStarts) sessDone=\(polishCompletions) sessCancelled=\(polishCancels)"))
                    completedCandidate = (input, result)
                    options.emit(.polished(text: result.text, model: result.model, latencyMs: result.latencyMs, speculative: reused ? true : nil, source: input))
                } else if let failure {
                    options.emit(.warning(code: "intelligence_failed", message: redactApiKeys(failure.localizedDescription)))
                }
                let endedAt = ProcessInfo.processInfo.systemUptime
                let began = stopBeganAt ?? endedAt
                let audio = audioEndedAt ?? began
                let live = liveEndedAt ?? audio
                options.emit(.timing(DictationTiming(sessionID: sessionID, readyAt: endedAt,
                    captureMs: milliseconds(audio - began), liveMs: milliseconds(live - audio),
                    polishWaitMs: milliseconds(endedAt - live), outcome: outcome,
                    backgroundJobs: scheduler.jobs, finalJobs: finalJobs, liveFallback: liveFallback)))
                state = .closed
                options.emit(.complete)
                return true
            }
            if done { return }
        }
    }

}

public func transcriptDraft(finalSegments: [String], latestInterim: String, startsNewTurn: Bool = false) -> String {
    // A hypothesis can resend or extend finalized text. Use the same merge for
    // the preview and the final result, unless the protocol marked a new turn.
    let segments = startsNewTurn ? finalSegments + [latestInterim]
        : appendDedupedFinalSegment(finalSegments, latestInterim)
    return segments
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

public func transcriptsCompatible(_ draft: String, _ final: String) -> Bool {
    !draft.isEmpty && draft == final
}

private func recognitionHypothesesSimilar(_ draft: String, _ final: String) -> Bool {
    let left = normalizeForComparison(draft)
    let right = normalizeForComparison(final)
    if left.isEmpty || right.isEmpty { return false }
    if left == right { return true }
    let leftWords = left.split(separator: " ").map(String.init)
    let rightWords = right.split(separator: " ").map(String.init)
    // If the final transcript has different word count (e.g. newly arrived end words),
    // speculative polish based on the draft cannot contain them. Never reuse in that case.
    if leftWords.count != rightWords.count { return false }
    let length = leftWords.count
    var matching = 0
    for index in 0..<length {
        if leftWords[index] == rightWords[index] {
            matching += 1
        }
    }
    return Double(matching) / Double(length) >= 0.9
}

public func extractTrailingExtension(prefix: String, full: String) -> String? {
    let left = normalizeForComparison(prefix)
    let right = normalizeForComparison(full)
    if left.isEmpty || right.isEmpty { return nil }
    let prefixWords = left.split(separator: " ").map(String.init)
    let fullWords = right.split(separator: " ").map(String.init)
    guard !prefixWords.isEmpty, fullWords.count > prefixWords.count else { return nil }
    let commonPrefix = zip(prefixWords, fullWords).prefix { $0.0 == $0.1 }.count
    if commonPrefix == prefixWords.count {
        let originalWords = full.split(separator: " ").map(String.init)
        if originalWords.count > commonPrefix {
            return originalWords.dropFirst(commonPrefix).joined(separator: " ")
        }
    }
    return nil
}

/// Normalized substring check (case/punctuation-insensitive). Used to detect
/// duplicate resends without comparing raw formatting.
public func normalizedTranscriptContains(haystack: String, needle: String) -> Bool {
    let hay = normalizeForComparison(haystack)
    let ndl = normalizeForComparison(needle)
    if hay.isEmpty || ndl.isEmpty { return false }
    if hay == ndl { return true }
    return (" " + hay + " ").contains(" " + ndl + " ")
}

/// Merge a newly arrived final chunk without duplicating text the session
/// already holds. Drops exact resends / interim-fallback echoes, and replaces
/// the last segment when the incoming chunk extends it (fallback then real
/// final), instead of keeping prefix + extension as two paragraphs.
public func appendDedupedFinalSegment(_ segments: [String], _ text: String) -> [String] {
    let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if incoming.isEmpty { return segments }
    let draft = segments.filter { !$0.isEmpty }.joined(separator: "\n")
    if normalizedTranscriptContains(haystack: draft, needle: incoming) {
        return segments
    }
    // A cumulative final can cover several previously delivered windows.
    // Replace all covered trailing segments, not only the last one.
    for index in segments.indices {
        let suffix = segments[index...].joined(separator: "\n")
        if normalizedTranscriptContains(haystack: incoming, needle: suffix) {
            return Array(segments[..<index]) + [incoming]
        }
    }
    if let last = segments.last,
       !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       isRevisionReplacement(last: last, incoming: incoming)
    {
        // Live self-correction (e.g. "the the maid" -> "the"): same sentence
        // re-recognized with different words. Replace instead of keeping the
        // garbled hypothesis plus its correction as two paragraphs.
        var merged = segments
        merged[merged.count - 1] = incoming
        return merged
    }
    var merged = segments
    merged.append(incoming)
    return merged
}

/// Same sentence re-recognized with different words (STT self-correction),
/// as opposed to genuinely new speech. Exact resends are handled by
/// containment checks; this catches same-length rewordings and
/// prefix/suffix-anchored revisions of different lengths.
public func isRevisionReplacement(last: String, incoming: String) -> Bool {
    if recognitionHypothesesSimilar(last, incoming) { return true }
    let old = normalizeForComparison(last).split(separator: " ").map(String.init)
    let new = normalizeForComparison(incoming).split(separator: " ").map(String.init)
    if old.isEmpty || new.isEmpty { return false }
    var prefix = 0
    while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(old.count - prefix, new.count - prefix),
          old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
    {
        suffix += 1
    }
    if prefix >= 2, suffix >= 2,
       prefix + suffix >= Int((Double(min(old.count, new.count)) * 0.6).rounded(.up))
    {
        return true
    }
    return false
}

private func normalizeForComparison(_ text: String) -> String {
    let lowered = text.lowercased()
    let pattern = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")
    let range = NSRange(lowered.startIndex..., in: lowered)
    let replaced = pattern.stringByReplacingMatches(in: lowered, range: range, withTemplate: " ")
    return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func milliseconds(_ seconds: TimeInterval) -> Int { Int((max(0, seconds) * 1000).rounded()) }
