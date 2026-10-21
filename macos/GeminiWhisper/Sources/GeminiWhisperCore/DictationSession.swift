import Foundation

/// When to hand over to a fresh Live session during a long dictation. Gemini
/// limits connection lifetime, so the session rotates at a natural pause after
/// `rotateAfter`, and unconditionally at `forceAfter`. The retiring session is
/// finished gracefully, so words spoken just before the handover still arrive.
public struct LiveRotationPolicy: Sendable {
    public var rotateAfter: TimeInterval
    public var forceAfter: TimeInterval
    /// Rotate immediately once a goAway leaves less than this much time.
    public var goAwayMargin: TimeInterval
    /// Silence that counts as a pause for rotation.
    public var pauseMilliseconds: Int
    /// How long stop waits for a retiring session to deliver its last words.
    public var retireTimeout: TimeInterval

    public init(rotateAfter: TimeInterval = 7 * 60, forceAfter: TimeInterval = 8.5 * 60,
                goAwayMargin: TimeInterval = 3, pauseMilliseconds: Int = 600, retireTimeout: TimeInterval = 2.5) {
        self.rotateAfter = rotateAfter
        self.forceAfter = max(rotateAfter, forceAfter)
        self.goAwayMargin = goAwayMargin
        self.pauseMilliseconds = pauseMilliseconds
        self.retireTimeout = retireTimeout
    }
}

/// When the recorded audio is transcribed again instead of trusting Live.
public struct BatchFallbackPolicy: Sendable {
    /// Live returned nothing although at least this much speech was captured.
    public var minimumVoicedMsWhenEmpty: Int
    /// Re-transcribe after a Live reconnect when the recording is at most this long.
    public var maximumAudioMsAfterReconnect: Int
    /// Live returned fewer words than this per second of speech...
    public var sparseWordsPerVoicedSecond: Double
    /// ...over at least this much speech.
    public var sparseMinimumVoicedMs: Int

    public init(minimumVoicedMsWhenEmpty: Int = 300, maximumAudioMsAfterReconnect: Int = 10 * 60 * 1000,
                sparseWordsPerVoicedSecond: Double = 0.6, sparseMinimumVoicedMs: Int = 8_000) {
        self.minimumVoicedMsWhenEmpty = minimumVoicedMsWhenEmpty
        self.maximumAudioMsAfterReconnect = maximumAudioMsAfterReconnect
        self.sparseWordsPerVoicedSecond = sparseWordsPerVoicedSecond
        self.sparseMinimumVoicedMs = sparseMinimumVoicedMs
    }
}

/// How long stop waits for the final polish before inserting the raw text.
/// Scales with length because a long dictation legitimately takes longer.
public struct PolishDeadlinePolicy: Sendable {
    public var base: TimeInterval
    public var perWord: TimeInterval
    public var maximum: TimeInterval

    public init(base: TimeInterval = 2.5, perWord: TimeInterval = 0.015, maximum: TimeInterval = 8) {
        self.base = base
        self.perWord = perWord
        self.maximum = max(base, maximum)
    }

    public func seconds(forWords words: Int) -> TimeInterval {
        min(maximum, base + perWord * Double(words))
    }
}

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
        /// Recovers the transcript from recorded audio. nil disables recovery;
        /// it is never created implicitly, so tests cannot reach the network.
        public var batchTranscriber: (any BatchTranscriber)?
        public var batchPolicy: BatchFallbackPolicy
        public var rotation: LiveRotationPolicy
        public var polishDeadline: PolishDeadlinePolicy
        public var network: (any NetworkPathMonitoring)?

        public init(
            apiKey: String,
            config: TranscriptionConfig = .default,
            emit: @escaping (ServerEvent) -> Void,
            transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)? = nil,
            intelligence: (any TranscriptIntelligence)? = nil,
            speculativeIntelligence: Bool = true,
            webSocketFactory: GeminiWebSocketFactory? = nil,
            backgroundPolicy: BackgroundPolishPolicy = .init(),
            batchTranscriber: (any BatchTranscriber)? = nil,
            batchPolicy: BatchFallbackPolicy = .init(),
            rotation: LiveRotationPolicy = .init(),
            polishDeadline: PolishDeadlinePolicy = .init(),
            network: (any NetworkPathMonitoring)? = nil
        ) {
            self.apiKey = apiKey
            self.config = config
            self.emit = emit
            self.transcriberFactory = transcriberFactory
            self.intelligence = intelligence
            self.speculativeIntelligence = speculativeIntelligence
            self.webSocketFactory = webSocketFactory
            self.backgroundPolicy = backgroundPolicy
            self.batchTranscriber = batchTranscriber
            self.batchPolicy = batchPolicy
            self.rotation = rotation
            self.polishDeadline = polishDeadline
            self.network = network
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
    private var lastEmittedTranscript = ""
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
    private let recorder = SessionAudioRecorder()
    private var earlyAudio: [Data] = []
    private var earlyAudioBytes = 0
    private var polishEnabled: Bool
    private var state: State = .idle
    private var speculativePolish: SpeculativePolish?
    private var completeTask: Task<Void, Never>?
    private var retireDeadlineTask: Task<Void, Never>?
    private var resolvedIntelligence: (any TranscriptIntelligence)?
    private var didResolveIntelligence = false
    private var discarded = false
    // Per-session polish telemetry: how many background calls fired, finished,
    // or were cancelled before producing output. Surfaced via log-only
    // warnings so the next slow run shows volume, not just final latency.
    private var polishStarts = 0
    private var polishCompletions = 0
    private var polishCancels = 0

    // Live connection generations. Each rotation starts a new transcriber and a
    // new transcript generation; retiring transcribers finish in the background.
    private var live: (any LiveTranscriber)?
    private var liveGeneration = 0
    private var generations = [GenerationTranscript()]
    private var retiring: [Int: any LiveTranscriber] = [:]
    private var liveReadyAt: TimeInterval?
    private var liveEverReady = false
    private var liveCompleted = false
    /// Set once Live can no longer be trusted for this dictation. Audio keeps
    /// recording and is transcribed from the recording at stop.
    private var liveDegraded: String?
    private var reconnects = 0
    private var rotations = 0
    private var goAwayDeadline: TimeInterval?
    private var pauseDetector: LocalSpeechEndpoint
    private var transcriptSource = "live"
    private var batchReason = ""
    /// Most recent Live failure, reported if nothing else can be recovered.
    private var lastLiveError: (code: String, message: String)?

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
        self.pauseDetector = LocalSpeechEndpoint(silenceMilliseconds: options.rotation.pauseMilliseconds)
    }

    public convenience init(
        apiKey: String,
        config: TranscriptionConfig = .default,
        emit: @escaping (ServerEvent) -> Void,
        transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)? = nil,
        intelligence: (any TranscriptIntelligence)? = nil,
        speculativeIntelligence: Bool = true,
        webSocketFactory: GeminiWebSocketFactory? = nil,
        backgroundPolicy: BackgroundPolishPolicy = .init(),
        batchTranscriber: (any BatchTranscriber)? = nil,
        batchPolicy: BatchFallbackPolicy = .init(),
        rotation: LiveRotationPolicy = .init(),
        polishDeadline: PolishDeadlinePolicy = .init(),
        network: (any NetworkPathMonitoring)? = nil
    ) {
        self.init(options: Options(
            apiKey: apiKey,
            config: config,
            emit: emit,
            transcriberFactory: transcriberFactory,
            intelligence: intelligence,
            speculativeIntelligence: speculativeIntelligence,
            webSocketFactory: webSocketFactory,
            backgroundPolicy: backgroundPolicy,
            batchTranscriber: batchTranscriber,
            batchPolicy: batchPolicy,
            rotation: rotation,
            polishDeadline: polishDeadline,
            network: network
        ))
    }

    public var draft: String {
        lock.withLock { joinedDraft(generations) }
    }

    /// Everything captured so far. Kept by the caller so a failed or cancelled
    /// dictation can be transcribed again later.
    public var recordedAudio: RecordedAudio {
        recorder.snapshot()
    }

    private func makeTranscriber(generation: Int) -> any LiveTranscriber {
        let emit: (ServerEvent) -> Void = { [weak self] event in
            self?.handle(event, generation: generation)
        }
        if let factory = options.transcriberFactory {
            return factory(options.config, emit)
        }
        return GeminiLiveTranscriber(
            apiKey: options.apiKey,
            config: options.config,
            emit: emit,
            webSocketFactory: options.webSocketFactory,
            network: options.network
        )
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

        let transcriber = makeTranscriber(generation: liveGeneration)
        live = transcriber
        for block in earlyAudio {
            if pcmRootMeanSquare(block) >= PCM_VOICED_RMS_THRESHOLD {
                generations[liveGeneration].voicedMsSinceFinal += block.count / PCM_BYTES_PER_MILLISECOND
            }
            do { try transcriber.sendAudio(block) } catch {
                degradeLive(code: "live_send_failed", message: describe(error))
                break
            }
        }
        earlyAudio.removeAll()
        earlyAudioBytes = 0
        return transcriber
    }

    public func start() async throws {
        let live = try prepareSession()
        do {
            try await live?.connect()
        } catch {
            // Connection failures are reported through the event stream.
        }
    }

    /// Records the chunk and forwards it to Live. Transport failures never
    /// throw: Live is marked degraded and the recording is transcribed at stop.
    public func sendAudio(_ chunk: Data) throws {
        try validatePcmChunk(chunk)
        lock.lock()
        defer { lock.unlock() }
        if discarded || state == .finishing || state == .closed { return }
        let rms = recorder.append(chunk)
        if live == nil, state == .idle {
            // Before start(): hold up to 10 seconds for Live; the recorder keeps all of it.
            if earlyAudioBytes + chunk.count <= 320_000 {
                earlyAudio.append(chunk)
                earlyAudioBytes += chunk.count
            } else if liveDegraded == nil {
                liveDegraded = "startup_buffer"
            }
            return
        }
        if rms >= PCM_VOICED_RMS_THRESHOLD {
            generations[liveGeneration].voicedMsSinceFinal += chunk.count / PCM_BYTES_PER_MILLISECOND
        }
        guard liveDegraded == nil, let live else { return }
        do {
            try live.sendAudio(chunk)
        } catch {
            degradeLive(code: "live_send_failed", message: describe(error))
            return
        }
        considerRotation(after: chunk)
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
            // Live failed fatally earlier. Finish with whatever exists; recovery
            // decides between the buffered text and the recording.
            guard !joinedDraft(generations).isEmpty || recorder.snapshot().voicedMs > 0 else {
                throw ProtocolError(code: "not_ready", message: "There is no ready transcription to stop.")
            }
            state = .finishing
            liveFallback = true
            liveCompleted = true
            options.emit(.warning(code: "live_finish_failed", message: "The live session ended; finishing from buffered text and audio."))
            maybeFinish()
            return
        }
        guard state == .ready || state == .connecting else {
            throw ProtocolError(code: "not_ready", message: "There is no ready transcription to stop.")
        }
        state = .finishing
        scheduleRetireDeadline()
        guard liveDegraded == nil, let live else {
            liveCompleted = true
            liveFallback = true
            maybeFinish()
            return
        }
        do {
            try live.finish()
        } catch {
            liveFallback = true
            liveCompleted = true
            options.emit(.warning(code: "live_finish_failed", message: describe(error)))
            maybeFinish()
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
        closeAllTranscribers()
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
        closeAllTranscribers()
    }

    private func closeAllTranscribers() {
        retireDeadlineTask?.cancel()
        live?.close()
        live = nil
        for transcriber in retiring.values { transcriber.close() }
        retiring.removeAll()
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

    // MARK: - Live events

    private func handle(_ event: ServerEvent, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        if discarded { return }
        guard generation == liveGeneration else {
            handleRetiring(event, generation: generation)
            return
        }
        switch event {
        case .connecting:
            // The transcriber only reports connecting when it reconnects. Audio
            // in flight on the dropped socket is lost to Live: note it so stop
            // can transcribe the recording instead.
            if liveEverReady { reconnects += 1 }
            if state != .finishing { state = .connecting }
            options.emit(event)
        case .ready:
            liveEverReady = true
            liveReadyAt = ProcessInfo.processInfo.systemUptime
            if state != .finishing { state = .ready }
            options.emit(event)
        case .interim(let text):
            generations[generation].latestInterim = text
            options.emit(event)
            transcriptChanged()
            scheduleBackgroundPolish()
        case .turnBoundary:
            generations[generation].startsNewTurn = true
            options.emit(event)
        case .final(let text):
            generations[generation].acceptFinal(text)
            options.emit(event)
            transcriptChanged()
            scheduleBackgroundPolish()
        case .goAway(let timeLeftMs):
            goAwayDeadline = ProcessInfo.processInfo.systemUptime + Double(timeLeftMs) / 1000
            options.emit(.warning(code: "go_away", message: "Gemini will close this Live session in \(timeLeftMs) ms; rotating at the next pause."))
        case .complete:
            // Only the user stop path completes dictation. Mid-session Live turnComplete
            // must not polish/paste while the Option toggle is still listening.
            // Tripwires: a dropped/duplicate complete is otherwise invisible and
            // the HUD sits on "Polishing..." until Escape.
            guard state == .finishing else {
                options.emit(.warning(code: "complete_ignored", message: "Live complete arrived while session state=\(stateName); ignoring."))
                return
            }
            if liveCompleted || completeTask != nil {
                options.emit(.warning(code: "complete_deduped", message: "Duplicate Live complete ignored."))
                return
            }
            liveCompleted = true
            maybeFinish()
        case .cancelled:
            discarded = true
            state = .closed
            options.emit(event)
        case .error(let code, let message, let retryable):
            handleLiveError(code: code, message: message, retryable: retryable)
        case .warning(let code, _):
            if code == "finalization_ack_timeout" || code == "gemini_connection_closed" { liveFallback = true }
            options.emit(event)
        default:
            options.emit(event)
        }
    }

    /// A retiring transcriber is finishing the audio it already received. Its
    /// words land in its own generation; its end only matters for stop.
    private func handleRetiring(_ event: ServerEvent, generation: Int) {
        guard generations.indices.contains(generation) else { return }
        switch event {
        case .interim(let text):
            generations[generation].latestInterim = text
            transcriptChanged()
        case .final(let text):
            generations[generation].acceptFinal(text)
            transcriptChanged()
            scheduleBackgroundPolish()
        case .turnBoundary:
            generations[generation].startsNewTurn = true
        case .complete, .cancelled:
            retiring.removeValue(forKey: generation)?.close()
            maybeFinish()
        case .error(let code, let message, _):
            retiring.removeValue(forKey: generation)?.close()
            options.emit(.warning(code: "retired_live_failed", message: "\(code): \(message)"))
            maybeFinish()
        case .warning:
            options.emit(event)
        default:
            break
        }
    }

    private func handleLiveError(code: String, message: String, retryable: Bool) {
        if code == "session_limit", state != .finishing, live != nil {
            // The transcriber's own safety limit fired before a pause allowed a
            // rotation. Hand over now; the old session still flushes its audio.
            rotateLive(reason: "session_limit")
            return
        }
        lastLiveError = (code, message)
        if state == .finishing {
            liveFallback = true
            liveCompleted = true
            if joinedDraft(generations).isEmpty && liveDegraded == nil {
                liveDegraded = code
            }
            options.emit(.warning(code: code, message: message))
            maybeFinish()
            return
        }
        if isAuthenticationFailure(message) || code == "PERMISSION_DENIED" || code == "UNAUTHENTICATED" {
            // The key itself was rejected; every fallback would use the same key.
            state = .closed
            closeAllTranscribers()
            options.emit(.error(code: code, message: message, retryable: false))
            return
        }
        degradeLive(code: code, message: message)
    }

    private func degradeLive(code: String, message: String) {
        guard liveDegraded == nil else { return }
        liveDegraded = code
        lastLiveError = lastLiveError ?? (code, message)
        liveFallback = true
        live?.close()
        live = nil
        options.emit(.warning(
            code: "live_degraded",
            message: "Gemini Live stopped (\(code)): \(redactApiKeys(message)) Recording continues and will be transcribed when you stop."
        ))
    }

    // MARK: - Rotation

    private func considerRotation(after chunk: Data) {
        guard state == .ready, liveDegraded == nil, live != nil, let readyAt = liveReadyAt else { return }
        let paused = pauseDetector.accept(chunk)
        let now = ProcessInfo.processInfo.systemUptime
        let age = now - readyAt
        let policy = options.rotation
        if age >= policy.forceAfter {
            rotateLive(reason: "age")
        } else if let deadline = goAwayDeadline, now >= deadline - policy.goAwayMargin {
            rotateLive(reason: "go_away")
        } else if paused, age >= policy.rotateAfter || goAwayDeadline != nil {
            rotateLive(reason: goAwayDeadline != nil ? "go_away_pause" : "pause")
        }
    }

    private func rotateLive(reason: String) {
        guard let old = live else { return }
        let oldGeneration = liveGeneration
        rotations += 1
        liveGeneration += 1
        generations.append(GenerationTranscript())
        goAwayDeadline = nil
        liveReadyAt = nil
        pauseDetector = LocalSpeechEndpoint(silenceMilliseconds: options.rotation.pauseMilliseconds)
        retiring[oldGeneration] = old
        let fresh = makeTranscriber(generation: liveGeneration)
        live = fresh
        state = .connecting
        options.emit(.warning(code: "live_rotated", message: "reason=\(reason) rotations=\(rotations)"))
        do {
            try old.finish()
        } catch {
            retiring.removeValue(forKey: oldGeneration)?.close()
        }
        Task {
            try? await fresh.connect()
        }
    }

    /// Stop must not wait forever on a retiring session that never acknowledges.
    private func scheduleRetireDeadline() {
        guard !retiring.isEmpty else { return }
        let timeout = Int(options.rotation.retireTimeout * 1000)
        retireDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(timeout))
            guard !Task.isCancelled, let self else { return }
            self.lock.withLock {
                guard !self.retiring.isEmpty else { return }
                for transcriber in self.retiring.values { transcriber.close() }
                self.retiring.removeAll()
                self.options.emit(.warning(code: "retired_live_timeout", message: "A rotated Live session did not finish in time."))
                self.maybeFinish()
            }
        }
    }

    // MARK: - Completion

    private func maybeFinish() {
        guard state == .finishing, !discarded, completeTask == nil, liveCompleted, retiring.isEmpty else { return }
        retireDeadlineTask?.cancel()
        liveEndedAt = ProcessInfo.processInfo.systemUptime
        completeTask = Task { [weak self] in
            await self?.finishWithIntelligence()
        }
    }

    private func transcriptChanged() {
        updateRevision()
        let text = joinedDraft(generations)
        if text != lastEmittedTranscript {
            lastEmittedTranscript = text
            options.emit(.transcript(text: text))
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
                let verdict = PolishGuard.evaluate(raw: input, polished: value.text)
                guard verdict.accepted else {
                    scheduler.failed(input, now: ProcessInfo.processInfo.systemUptime, rateLimited: false)
                    options.emit(.warning(code: "polish_rejected", message: "kind=background reason=\(verdict.reason) ratio=\(String(format: "%.2f", verdict.lengthRatio)) coverage=\(String(format: "%.2f", verdict.coverage))"))
                    scheduleBackgroundPolish()
                    return
                }
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

    // MARK: - Batch recovery

    private func batchReason(draft: String, audio: RecordedAudio) -> String? {
        let policy = options.batchPolicy
        if liveDegraded != nil { return "live_failed" }
        if draft.isEmpty {
            return audio.voicedMs >= policy.minimumVoicedMsWhenEmpty ? "live_empty" : nil
        }
        if reconnects > 0, audio.durationMs <= policy.maximumAudioMsAfterReconnect { return "live_reconnected" }
        if audio.voicedMs >= policy.sparseMinimumVoicedMs {
            let expected = Double(audio.voicedMs) / 1000 * policy.sparseWordsPerVoicedSecond
            if Double(transcriptWordCount(draft)) < expected { return "live_sparse" }
        }
        return nil
    }

    /// Replaces the Live transcript with a transcription of the recording when
    /// Live failed, reconnected, came back empty, or is implausibly short.
    /// Returns false when nothing usable exists and the failure was reported.
    private func recoverFromRecordingIfNeeded() async -> Bool {
        let work: (BatchTranscriber, RecordedAudio)? = lock.withLock {
            guard !discarded, let batch = options.batchTranscriber else { return nil }
            let audio = recorder.snapshot()
            guard let reason = batchReason(draft: joinedDraft(generations), audio: audio) else { return nil }
            batchReason = reason
            options.emit(.warning(code: "batch_start", message: "reason=\(reason) audio_ms=\(audio.durationMs) voiced_ms=\(audio.voicedMs) reconnects=\(reconnects)"))
            return (batch, audio)
        }
        guard let (batch, audio) = work else { return true }
        let hints = BatchTranscriptionHints(config: options.config)
        let outcome: Result<BatchTranscriptionResult, Error>
        do {
            outcome = .success(try await batch.transcribe(audio, hints: hints))
        } catch {
            outcome = .failure(error)
        }
        return lock.withLock {
            guard !discarded else { return false }
            switch outcome {
            case .success(let result):
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                options.emit(.warning(code: "batch_done", message: "chars=\(text.count) ms=\(result.latencyMs) chunks=\(result.chunks) attempts=\(result.attempts)"))
                if !text.isEmpty {
                    generations = [GenerationTranscript(segments: [text])]
                    transcriptSource = "batch"
                    transcriptChanged()
                }
                return true
            case .failure(let error):
                options.emit(.warning(code: "batch_failed", message: describe(error)))
                if !joinedDraft(generations).isEmpty { return true }
                state = .closed
                options.emit(.error(
                    code: "transcription_failed",
                    message: "Gemini could not transcribe this dictation: \(describe(error)) The audio was kept; use Retry Last Dictation.",
                    retryable: true
                ))
                return false
            }
        }
    }

    private func finishWithIntelligence() async {
        guard await recoverFromRecordingIfNeeded() else { return }
        // Nothing was recovered and Live reported why: surface that instead of
        // completing with an unexplained empty transcript.
        let unrecoverable: Bool = lock.withLock {
            guard !discarded, joinedDraft(generations).isEmpty, let error = lastLiveError else { return false }
            state = .closed
            options.emit(.error(code: error.code, message: error.message, retryable: true))
            return true
        }
        if unrecoverable { return }
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
            var outcome = input.isEmpty ? "empty" : "raw_disabled"
            if let intelligence, !input.isEmpty {
                let deadline = options.polishDeadline.seconds(forWords: transcriptWordCount(input))
                let polishOutcome: DeadlineOutcome<(IntelligenceResult, Bool, String)>
                if let candidate, candidate.input == input {
                    polishOutcome = .value((candidate.result, true, "reused_ready"))
                } else if let pending {
                    let task = pending.task
                    polishOutcome = await raceDeadline(seconds: deadline) {
                        (try await task.value.get(), true, "reused_inflight")
                    }
                } else {
                    lock.withLock { polishStarts += 1; finalJobs += 1 }
                    let sessionRef = self
                    let previousInput = candidate?.input
                    let previousOutput = candidate?.result.text
                    polishOutcome = await raceDeadline(seconds: deadline) {
                        let revised = try await intelligence.reviseStreaming(
                            input, previousInput: previousInput, previousOutput: previousOutput
                        ) { partial in
                            sessionRef.lock.withLock {
                                guard !sessionRef.discarded else { return }
                                sessionRef.options.emit(.polishProgress(text: partial))
                            }
                        }
                        return (revised, false, "fresh")
                    }
                }
                switch polishOutcome {
                case .value(let (value, wasReused, label)):
                    let verdict = PolishGuard.evaluate(raw: input, polished: value.text)
                    if verdict.accepted {
                        result = value
                        reused = wasReused
                        outcome = label
                    } else {
                        outcome = "raw_guard"
                        lock.withLock {
                            options.emit(.warning(code: "polish_rejected", message: "kind=final reason=\(verdict.reason) ratio=\(String(format: "%.2f", verdict.lengthRatio)) coverage=\(String(format: "%.2f", verdict.coverage))"))
                        }
                    }
                case .failure(let error):
                    outcome = "raw_failure"
                    lock.withLock {
                        guard !discarded else { return }
                        options.emit(.warning(code: "intelligence_failed", message: describe(error)))
                    }
                case .timedOut:
                    outcome = "raw_timeout"
                    lock.withLock {
                        guard !discarded else { return }
                        if pending != nil { cancelSpeculative() }
                        options.emit(.warning(code: "polish_deadline", message: "Polish exceeded \(Int(deadline * 1000)) ms; inserting the raw transcript."))
                    }
                }
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
                }
                let endedAt = ProcessInfo.processInfo.systemUptime
                let began = stopBeganAt ?? endedAt
                let audioEnd = audioEndedAt ?? began
                let liveEnd = liveEndedAt ?? audioEnd
                let audio = recorder.snapshot()
                var timing = DictationTiming(sessionID: sessionID, readyAt: endedAt,
                    captureMs: milliseconds(audioEnd - began), liveMs: milliseconds(liveEnd - audioEnd),
                    polishWaitMs: milliseconds(endedAt - liveEnd), outcome: outcome,
                    backgroundJobs: scheduler.jobs, finalJobs: finalJobs, liveFallback: liveFallback)
                timing.audioMs = audio.durationMs
                timing.voicedMs = audio.voicedMs
                timing.transcriptSource = input.isEmpty ? "none" : transcriptSource
                timing.batchReason = batchReason
                timing.liveReconnects = reconnects
                timing.liveRotations = rotations
                options.emit(.timing(timing))
                state = .closed
                options.emit(.complete)
                return true
            }
            if done { return }
        }
    }
}

private func describe(_ error: Error) -> String {
    redactApiKeys((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
}

private func milliseconds(_ seconds: TimeInterval) -> Int { Int((max(0, seconds) * 1000).rounded()) }
