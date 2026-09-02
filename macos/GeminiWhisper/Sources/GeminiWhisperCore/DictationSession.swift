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
        var output: String?
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
            if polishEnabled, options.speculativeIntelligence, intelligence != nil {
                startSpeculativePolish(replaceIfChanged: true, startedBeforeFinal: true)
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
        guard let intelligence, polishEnabled, options.speculativeIntelligence else { return }
        let draft = transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim)
        if draft.isEmpty { return }
        if let existing = speculativePolish {
            if transcriptsCompatible(existing.input, draft) { return }
            // If the existing task is still in flight and we haven't received an output yet,
            // don't cancel it on regular speech updates so its output can be reused as a prefix.
            if !replaceIfChanged && existing.output == nil {
                return
            }
        }

        let prefixPolish: (input: String, output: String)? = {
            if let existing = speculativePolish, let out = existing.output {
                if let tail = extractTrailingExtension(prefix: existing.input, full: draft), !tail.isEmpty {
                    return (existing.input, out)
                }
            }
            return nil
        }()

        let targetToPolish: String
        let basePrefix: String?
        if let prefixPolish, let tail = extractTrailingExtension(prefix: prefixPolish.input, full: draft), tail.split(separator: " ").count <= 35 {
            targetToPolish = tail
            basePrefix = prefixPolish.output
        } else {
            targetToPolish = draft
            basePrefix = nil
            speculativePolish?.task.cancel()
        }

        let task = Task<Result<IntelligenceResult, Error>, Never> { [weak self] in
            do {
                let polishedResult = try await intelligence.polish(targetToPolish)
                guard let self, !self.discarded else {
                    return .success(polishedResult)
                }
                let fullText = basePrefix != nil ? joinUniqueTranscript(basePrefix!, polishedResult.text) : polishedResult.text
                let combinedResult = IntelligenceResult(
                    text: fullText,
                    model: polishedResult.model,
                    latencyMs: polishedResult.latencyMs
                )
                self.speculativePolish?.output = fullText
                self.options.emit(.polished(
                    text: fullText,
                    model: combinedResult.model,
                    latencyMs: combinedResult.latencyMs,
                    speculative: true
                ))
                return .success(combinedResult)
            } catch {
                return .failure(error)
            }
        }

        speculativePolish = SpeculativePolish(
            input: draft,
            output: basePrefix,
            startedBeforeFinal: startedBeforeFinal,
            task: task
        )
    }

    private func finishWithIntelligence() async {
        if discarded { return }
        state = .finishing
        let transcript = transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim)

        if let intelligence, polishEnabled, !transcript.isEmpty {
            do {
                let speculative = speculativePolish
                let speculativeResult = speculative == nil ? nil : await speculative!.task.value
                if discarded { return }

                let result: IntelligenceResult
                if let speculative,
                   let out = speculative.output,
                   transcriptsCompatible(speculative.input, transcript),
                   !out.isEmpty
                {
                    result = IntelligenceResult(text: out, model: GEMINI_INTELLIGENCE_MODEL, latencyMs: 0)
                } else if case .success(let value) = speculativeResult,
                          speculative != nil,
                          transcriptsCompatible(speculative!.input, transcript)
                {
                    result = value
                } else if let speculative,
                          let baseText = (speculative.output ?? (try? speculativeResult?.get().text)),
                          let trailingTail = extractTrailingExtension(prefix: speculative.input, full: transcript),
                          !trailingTail.isEmpty,
                          trailingTail.split(separator: " ").count <= 35
                {
                    // Parallel pipelining: If the prefix of the transcript was already polished
                    // in the background while the user was speaking, polish only the newly added tail!
                    let polishedTail = try await intelligence.polish(trailingTail)
                    let combined = joinUniqueTranscript(baseText, polishedTail.text)
                    result = IntelligenceResult(
                        text: combined,
                        model: polishedTail.model,
                        latencyMs: polishedTail.latencyMs
                    )
                } else {
                    result = try await intelligence.polish(transcript)
                }
                if discarded { return }
                let wasSpeculative = (speculative != nil && (transcriptsCompatible(speculative!.input, transcript) || extractTrailingExtension(prefix: speculative!.input, full: transcript) != nil)) && speculative?.startedBeforeFinal == true
                options.emit(.polished(
                    text: result.text,
                    model: result.model,
                    latencyMs: result.latencyMs,
                    speculative: wasSpeculative ? true : nil
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
    if Double(commonPrefix) / Double(prefixWords.count) >= 0.9 {
        let originalWords = full.split(separator: " ").map(String.init)
        if originalWords.count > commonPrefix {
            return originalWords.dropFirst(commonPrefix).joined(separator: " ")
        }
    }
    return nil
}

private func normalizeForComparison(_ text: String) -> String {
    let lowered = text.lowercased()
    let pattern = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")
    let range = NSRange(lowered.startIndex..., in: lowered)
    let replaced = pattern.stringByReplacingMatches(in: lowered, range: range, withTemplate: " ")
    return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
}
