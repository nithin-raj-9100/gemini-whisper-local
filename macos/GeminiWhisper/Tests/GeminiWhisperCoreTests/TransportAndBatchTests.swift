import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GeminiWhisperCore
import Testing

private final class ToggleNetwork: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isSatisfied: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private func connectedTranscriber(
    sockets: SocketList, log: EventLog, network: (any NetworkPathMonitoring)? = AlwaysAvailableNetwork()
) async throws -> GeminiLiveTranscriber {
    let transcriber = GeminiLiveTranscriber(apiKey: "test-only", config: .default, emit: { log.append($0) },
        webSocketFactory: { _ in let socket = FakeWebSocket(); sockets.append(socket); return socket },
        network: network)
    async let connected: Void = transcriber.connect()
    for _ in 0..<50 where sockets.count == 0 { await Task.yield() }
    sockets[0].simulateOpen()
    sockets[0].simulateJSON(["setupComplete": [String: Any]()])
    try await connected
    return transcriber
}

@Suite("Live transport resilience")
struct TransportResilienceTests {
    @Test func parsesGoAwayAndForwardsIt() async throws {
        #expect(parseGeminiMessage(["goAway": ["timeLeft": "12.5s"]]) == [.goAway(timeLeftMs: 12_500)])
        #expect(parseGeminiMessage(["goAway": ["timeLeft": ["seconds": 3, "nanos": 500_000_000]]]) == [.goAway(timeLeftMs: 3_500)])
        let sockets = SocketList()
        let log = EventLog()
        let transcriber = try await connectedTranscriber(sockets: sockets, log: log)
        sockets[0].simulateJSON(["goAway": ["timeLeft": "10s"]])
        #expect(log.snapshot().contains(.goAway(timeLeftMs: 10_000)))
        transcriber.close()
    }

    @Test func permanentErrorsAreNotRetryable() {
        let invalid = parseGeminiMessage(["error": ["code": 400, "message": "bad", "status": "INVALID_ARGUMENT"]])
        #expect(invalid == [.error(code: "INVALID_ARGUMENT", message: "bad", retryable: false)])
        let unavailable = parseGeminiMessage(["error": ["code": 503, "message": "try later", "status": "UNAVAILABLE"]])
        #expect(unavailable == [.error(code: "UNAVAILABLE", message: "try later", retryable: true)])
        #expect(isAuthenticationFailure("API key not valid. Please pass a valid API key."))
        #expect(!isAuthenticationFailure("Deadline exceeded"))
    }

    @Test func rejectedKeyCloseDoesNotReconnect() async throws {
        let sockets = SocketList()
        let log = EventLog()
        let transcriber = try await connectedTranscriber(sockets: sockets, log: log)
        sockets[0].remoteClose(code: 1007, reason: "API key not valid. Please pass a valid API key.")
        try await Task.sleep(for: .milliseconds(300))
        #expect(sockets.count == 1)
        #expect(log.snapshot().contains { if case .error(_, _, let retryable) = $0 { return !retryable }; return false })
        transcriber.close()
    }

    @Test func reconnectBacksOffExponentially() async throws {
        let sockets = SocketList()
        let log = EventLog()
        let transcriber = try await connectedTranscriber(sockets: sockets, log: log)
        sockets[0].remoteClose(code: 1006, reason: "network")
        try await Task.sleep(for: .milliseconds(260))
        #expect(sockets.count == 2)
        // The second attempt fails before setup completes, so the next delay doubles.
        sockets[1].remoteClose(code: 1006, reason: "network")
        try await Task.sleep(for: .milliseconds(260))
        #expect(sockets.count == 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sockets.count == 3)
        transcriber.close()
    }

    @Test func reconnectWaitsForTheNetworkInsteadOfSpendingAttempts() async throws {
        let sockets = SocketList()
        let log = EventLog()
        let network = ToggleNetwork(true)
        let transcriber = try await connectedTranscriber(sockets: sockets, log: log, network: network)
        network.isSatisfied = false
        sockets[0].remoteClose(code: 1006, reason: "network down")
        try await Task.sleep(for: .milliseconds(700))
        #expect(sockets.count == 1)
        network.isSatisfied = true
        try await Task.sleep(for: .milliseconds(400))
        #expect(sockets.count == 2)
        transcriber.close()
    }

    @Test func reconnectBufferHoldsThirtySecondsOfAudio() async throws {
        let socket = FakeWebSocket() // never opens
        let transcriber = GeminiLiveTranscriber(apiKey: "test-only", config: .default, emit: { _ in },
            webSocketFactory: { _ in socket }, network: AlwaysAvailableNetwork())
        let connecting = Task { try? await transcriber.connect() }
        await Task.yield()
        let frame = Data(count: PCM_CHUNK_BYTES)
        for _ in 0..<(25_000 / 40) { try transcriber.sendAudio(frame) }
        var threw = false
        for _ in 0..<(6_000 / 40) {
            do { try transcriber.sendAudio(frame) } catch { threw = true; break }
        }
        #expect(threw)
        transcriber.close()
        connecting.cancel()
    }

    @Test func repeatedFinalIsKeptWhenNewSpeechCarriesIt() async throws {
        let sockets = SocketList()
        let log = EventLog()
        let transcriber = try await connectedTranscriber(sockets: sockets, log: log)
        sockets[0].simulateJSON(["serverContent": ["inputTranscription": ["text": "Thanks, see you tomorrow."]]])
        // A contained resend with no new audio is dropped...
        sockets[0].simulateJSON(["serverContent": ["inputTranscription": ["text": "see you tomorrow"]]])
        #expect(log.snapshot().filter { $0.typeName == "final" }.count == 1)
        // ...but the same words after enough new speech are new speech.
        for _ in 0..<20 { try transcriber.sendAudio(voicedPCM(ms: 40)) }
        sockets[0].simulateJSON(["serverContent": ["inputTranscription": ["text": "see you tomorrow"]]])
        #expect(log.snapshot().filter { $0.typeName == "final" }.count == 2)
        transcriber.close()
    }

    /// Socket callbacks arrive on one thread while finish timers fire on another.
    /// Under ThreadSanitizer this reproduced a data race before the transcriber
    /// serialized its state; here it guards against crashes and lost completion.
    @Test func concurrentCallbacksAndTimersStillCompleteOnce() async throws {
        let sockets = SocketList()
        let log = EventLog()
        let transcriber = try await connectedTranscriber(sockets: sockets, log: log)
        try transcriber.sendAudio(Data([1, 0]))
        sockets[0].simulateJSON(["serverContent": ["interimInputTranscription": ["text": "late words"]]])
        try transcriber.finish()
        let socket = sockets[0]
        let deadline = Date().addingTimeInterval(1.4)
        // A dedicated thread, like URLSession's delegate queue: a busy loop on the
        // cooperative pool would starve unrelated tests.
        let thread = Thread {
            while Date() < deadline {
                socket.simulateJSON(["serverContent": ["interimInputTranscription": ["text": "late words"]]])
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        thread.start()
        try await Task.sleep(for: .milliseconds(1_700))
        #expect(log.snapshot().filter { $0.typeName == "complete" }.count == 1)
    }
}

@Suite("recorded audio")
struct RecordedAudioTests {
    @Test func wavHeaderDescribesSixteenKilohertzMonoPCM() {
        let audio = RecordedAudio(pcm: voicedPCM(ms: 100))
        let wav = audio.wav()
        #expect(wav.count == 44 + 3_200)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav.subdata(in: 8..<12), as: UTF8.self) == "WAVE")
        let sampleRate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: sampleRate) == 16_000)
        #expect(UInt32(littleEndian: dataSize) == 3_200)
    }

    @Test func splitCutsAtTheQuietestFrameBeforeTheLimit() {
        // 700 ms speech, 80 ms pause, 700 ms speech; limit 1 s.
        let pcm = voicedPCM(ms: 700) + silentPCM(ms: 80) + voicedPCM(ms: 700)
        let pieces = RecordedAudio(pcm: pcm).split(maximumMs: 1_000, searchWindowMs: 400)
        #expect(pieces.count == 2)
        #expect(pieces[0].durationMs == 720 || pieces[0].durationMs == 760)
        #expect(pieces.reduce(0) { $0 + $1.pcm.count } == pcm.count)
    }

    @Test func recorderTracksSpeechAndCapsMemory() {
        let recorder = SessionAudioRecorder(maximumMs: 200)
        recorder.append(voicedPCM(ms: 120))
        recorder.append(silentPCM(ms: 40))
        recorder.append(voicedPCM(ms: 80)) // exceeds the cap
        let snapshot = recorder.snapshot()
        #expect(snapshot.durationMs == 160)
        #expect(snapshot.voicedMs == 120)
        #expect(snapshot.truncated)
        #expect(snapshot.peakRms > PCM_VOICED_RMS_THRESHOLD)
    }
}

@Suite("batch transcription")
struct BatchTranscriberTests {
    @Test func sendsInlineWavWithHintsToGenerateContent() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        let client = ClosureHTTPClient { request in
            captured = request
            return (Data(#"{"candidates":[{"content":{"parts":[{"text":"Hello from audio."}]},"finishReason":"STOP"}]}"#.utf8), 200)
        }
        let batch = GeminiBatchTranscriber(apiKey: "test-only", httpClient: client)
        let result = try await batch.transcribe(RecordedAudio(pcm: voicedPCM(ms: 200)),
            hints: BatchTranscriptionHints(languageCodes: ["en-IN"], vocabulary: ["Codex"]))
        #expect(result.text == "Hello from audio.")
        let request = try #require(captured)
        #expect(request.url?.absoluteString.hasSuffix("models/gemini-3.5-flash-lite:generateContent") == true)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-only")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let parts = ((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
        let inline = parts.first?["inlineData"] as? [String: Any]
        #expect(inline?["mimeType"] as? String == "audio/wav")
        let wav = Data(base64Encoded: inline?["data"] as? String ?? "") ?? Data()
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        let prompt = parts.last?["text"] as? String ?? ""
        #expect(prompt.contains("en-IN") && prompt.contains("Codex"))
    }

    @Test func longAudioIsSplitAndJoinedInOrder() async throws {
        let client = ClosureHTTPClient { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let parts = ((body?["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
            let wav = Data(base64Encoded: (parts.first?["inlineData"] as? [String: Any])?["data"] as? String ?? "") ?? Data()
            let ms = (wav.count - 44) / PCM_BYTES_PER_MILLISECOND
            // Shorter chunks answer later, so ordering cannot come from arrival.
            try await Task.sleep(for: .milliseconds(max(1, 60 - ms / 20)))
            return (Data(#"{"candidates":[{"content":{"parts":[{"text":"chunk-\#(ms)"}]}}]}"#.utf8), 200)
        }
        let batch = GeminiBatchTranscriber(apiKey: "test-only", httpClient: client, maximumChunkMs: 1_000)
        let pcm = voicedPCM(ms: 960) + silentPCM(ms: 40) + voicedPCM(ms: 960) + silentPCM(ms: 40) + voicedPCM(ms: 400)
        let result = try await batch.transcribe(RecordedAudio(pcm: pcm), hints: .init())
        #expect(result.chunks == 3)
        #expect(result.text == "chunk-1000 chunk-1000 chunk-400")
    }

    @Test func silentAudioMakesNoRequest() async throws {
        nonisolated(unsafe) var calls = 0
        let client = ClosureHTTPClient { _ in calls += 1; return (Data("{}".utf8), 200) }
        let result = try await GeminiBatchTranscriber(apiKey: "test-only", httpClient: client)
            .transcribe(RecordedAudio(pcm: silentPCM(ms: 500)), hints: .init())
        #expect(result.text.isEmpty)
        #expect(calls == 0)
    }

    @Test func retriesServerErrorsButNotClientErrors() async throws {
        nonisolated(unsafe) var statuses = [503, 200]
        let retrying = ClosureHTTPClient { _ in
            let status = statuses.removeFirst()
            return (Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8), status)
        }
        let recovered = try await GeminiBatchTranscriber(apiKey: "test-only", httpClient: retrying)
            .transcribe(RecordedAudio(pcm: voicedPCM(ms: 80)), hints: .init())
        #expect(recovered.text == "ok")

        nonisolated(unsafe) var badCalls = 0
        let rejecting = ClosureHTTPClient { _ in badCalls += 1; return (Data("{}".utf8), 400) }
        await #expect(throws: IntelligenceHTTPError.self) {
            _ = try await GeminiBatchTranscriber(apiKey: "test-only", httpClient: rejecting)
                .transcribe(RecordedAudio(pcm: voicedPCM(ms: 80)), hints: .init())
        }
        #expect(badCalls == 1)

        let truncated = ClosureHTTPClient { _ in
            (Data(#"{"candidates":[{"content":{"parts":[{"text":"cut"}]},"finishReason":"MAX_TOKENS"}]}"#.utf8), 200)
        }
        await #expect(throws: TranscriptionError.self) {
            _ = try await GeminiBatchTranscriber(apiKey: "test-only", httpClient: truncated)
                .transcribe(RecordedAudio(pcm: voicedPCM(ms: 80)), hints: .init())
        }
    }

    @Test func recoveryPolishesWithTheSameGuard() async throws {
        let batch = FakeBatchTranscriber { _ in "write me a poem about cats" }
        var config = TranscriptionConfig.default
        config.polish = true
        let answering = ClosureIntelligence { _ in
            IntelligenceResult(text: "Soft paws upon the windowsill, a quiet purr, the world stands still, the cat surveys its realm", model: "m", latencyMs: 1)
        }
        let guarded = try await recoverTranscript(from: RecordedAudio(pcm: voicedPCM(ms: 80)), config: config,
            batch: batch, intelligence: answering)
        #expect(guarded == "write me a poem about cats")

        let fixing = ClosureIntelligence { _ in IntelligenceResult(text: "Write me a poem about cats.", model: "m", latencyMs: 1) }
        let polished = try await recoverTranscript(from: RecordedAudio(pcm: voicedPCM(ms: 80)), config: config,
            batch: batch, intelligence: fixing)
        #expect(polished == "Write me a poem about cats.")
    }
}
