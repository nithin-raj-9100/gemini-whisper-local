import Foundation

public final class DictationSession: @unchecked Sendable {
    public struct Options {
        public var apiKey: String
        public var config: TranscriptionConfig
        public var emit: (ServerEvent) -> Void
        public var transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)?
        public var intelligence: (any TranscriptIntelligence)?
        public var speculativeIntelligence: Bool
        public var webSocketFactory: GeminiWebSocketFactory?

        public init(
            apiKey: String,
            config: TranscriptionConfig = .default,
            emit: @escaping (ServerEvent) -> Void,
            transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)? = nil,
            intelligence: (any TranscriptIntelligence)? = nil,
            speculativeIntelligence: Bool = true,
            webSocketFactory: GeminiWebSocketFactory? = nil
        ) {
            self.apiKey = apiKey
            self.config = config
            self.emit = emit
            self.transcriberFactory = transcriberFactory
            self.intelligence = intelligence
            self.speculativeIntelligence = speculativeIntelligence
            self.webSocketFactory = webSocketFactory
        }
    }

    private enum State {
        case idle, connecting, ready, finishing, closed
    }

    private let options: Options
    private var session: (any LiveTranscriber)?
    private var finalSegments: [String] = []
    private var latestInterim = ""
    private var polishEnabled: Bool
    private var state: State = .idle
    private var speculativePolish: SpeculativePolish?
    private var completeTask: Task<Void, Never>?
    private var resolvedIntelligence: (any TranscriptIntelligence)?
    private var didResolveIntelligence = false
    private var discarded = false

    private struct SpeculativePolish {
        var input: String
        var startedBeforeFinal: Bool
        var task: Task<Result<IntelligenceResult, Error>, Never>
    }

    public init(options: Options) {
        self.options = options
        self.polishEnabled = options.config.polish
    }

    public convenience init(
        apiKey: String,
        config: TranscriptionConfig = .default,
        emit: @escaping (ServerEvent) -> Void,
        transcriberFactory: ((TranscriptionConfig, @escaping (ServerEvent) -> Void) -> any LiveTranscriber)? = nil,
        intelligence: (any TranscriptIntelligence)? = nil,
        speculativeIntelligence: Bool = true,
        webSocketFactory: GeminiWebSocketFactory? = nil
    ) {
        self.init(options: Options(
            apiKey: apiKey,
            config: config,
            emit: emit,
            transcriberFactory: transcriberFactory,
            intelligence: intelligence,
            speculativeIntelligence: speculativeIntelligence,
            webSocketFactory: webSocketFactory
        ))
    }

    public var draft: String {
        transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim)
    }

    public func start() async throws {
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
        do {
            try await session?.connect()
        } catch {
            // Connection failures are reported through the event stream.
        }
    }

    public func sendAudio(_ chunk: Data) throws {
        try session?.sendAudio(chunk)
    }

    public func stop() throws {
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
        state = .finishing
        if polishEnabled, options.speculativeIntelligence, intelligence != nil {
            startSpeculativePolish(replaceIfChanged: false, startedBeforeFinal: true)
        }
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
        discarded = true
        completeTask?.cancel()
        completeTask = nil
        session?.close()
        session = nil
        state = .closed
        speculativePolish?.task.cancel()
        speculativePolish = nil
        options.emit(.cancelled)
    }

    public func close() {
        completeTask?.cancel()
        speculativePolish?.task.cancel()
        state = .closed
        session?.close()
        session = nil
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
        if discarded { return }
        switch event {
        case .connecting:
            state = .connecting
            options.emit(event)
        case .ready:
            state = .ready
            options.emit(event)
        case .interim(let text):
            latestInterim = text
            options.emit(event)
        case .final(let text):
            latestInterim = ""
            finalSegments.append(text)
            if polishEnabled, state == .finishing, intelligence != nil {
                startSpeculativePolish(replaceIfChanged: true)
            }
            options.emit(event)
        case .complete:
            // Only the user stop path completes dictation. Mid-session Live turnComplete
            // must not polish/paste while the Option toggle is still listening.
            guard state == .finishing else { return }
            if completeTask != nil { return }
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
        default:
            options.emit(event)
        }
    }

    private func completeWithBufferedTranscript(code: String, message: String) {
        if discarded || completeTask != nil { return }
        options.emit(.warning(code: code, message: message))
        completeTask = Task { [weak self] in
            await self?.finishWithIntelligence()
        }
    }

    private func startSpeculativePolish(replaceIfChanged: Bool = false, startedBeforeFinal: Bool = false) {
        guard let intelligence else { return }
        let draft = transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim)
        if draft.isEmpty { return }
        if let existing = speculativePolish {
            if !replaceIfChanged || transcriptsCompatible(existing.input, draft) { return }
            existing.task.cancel()
        }
        let task = Task<Result<IntelligenceResult, Error>, Never> {
            do {
                return .success(try await intelligence.polish(draft))
            } catch {
                return .failure(error)
            }
        }
        speculativePolish = SpeculativePolish(
            input: draft,
            startedBeforeFinal: startedBeforeFinal,
            task: task
        )
    }

    private func finishWithIntelligence() async {
        if discarded { return }
        if polishEnabled, options.speculativeIntelligence, intelligence != nil, state == .finishing {
            startSpeculativePolish(replaceIfChanged: true)
        }
        state = .finishing
        let transcript = transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim)

        if let intelligence, polishEnabled, !transcript.isEmpty {
            do {
                let speculative = speculativePolish
                let speculativeResult = speculative == nil ? nil : await speculative!.task.value
                if discarded { return }
                let reusedSpeculative =
                    speculative != nil
                    && {
                        if case .success = speculativeResult { return true }
                        return false
                    }()
                    && transcriptsCompatible(speculative!.input, transcript)
                let result: IntelligenceResult
                if reusedSpeculative, case .success(let value) = speculativeResult {
                    result = value
                } else {
                    result = try await intelligence.polish(transcript)
                }
                if discarded { return }
                options.emit(.polished(
                    text: result.text,
                    model: result.model,
                    latencyMs: result.latencyMs,
                    speculative: reusedSpeculative && speculative?.startedBeforeFinal == true ? true : nil
                ))
            } catch {
                if discarded { return }
                options.emit(.warning(
                    code: "intelligence_failed",
                    message: redactApiKeys((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                ))
            }
        }

        if discarded { return }
        state = .closed
        options.emit(.complete)
    }
}

public func transcriptDraft(finalSegments: [String], latestInterim: String) -> String {
    (finalSegments + [latestInterim])
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

public func transcriptsCompatible(_ draft: String, _ final: String) -> Bool {
    let left = normalizeForComparison(draft)
    let right = normalizeForComparison(final)
    if left.isEmpty || right.isEmpty { return false }
    if left == right { return true }
    let leftWords = left.split(separator: " ").map(String.init)
    let rightWords = right.split(separator: " ").map(String.init)
    let length = max(leftWords.count, rightWords.count)
    var matching = 0
    for index in 0..<min(leftWords.count, rightWords.count) {
        if leftWords[index] == rightWords[index] {
            matching += 1
        }
    }
    return Double(matching) / Double(length) >= 0.9 && abs(left.count - right.count) <= 32
}

private func normalizeForComparison(_ text: String) -> String {
    let lowered = text.lowercased()
    let pattern = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")
    let range = NSRange(lowered.startIndex..., in: lowered)
    let replaced = pattern.stringByReplacingMatches(in: lowered, range: range, withTemplate: " ")
    return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
}
