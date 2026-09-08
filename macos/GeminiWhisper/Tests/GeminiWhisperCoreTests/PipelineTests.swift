import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("revision and audio pipeline")
struct PipelineTests {
    @Test func turnBoundariesPreserveSeparateRepeatedSpeech() async throws {
        nonisolated(unsafe) var live: FakeTranscriber!
        var config = TranscriptionConfig.default
        config.polish = false
        let session = DictationSession(apiKey: "test-only", config: config, emit: { _ in },
            transcriberFactory: { _, emit in live = FakeTranscriber(emit: emit); return live })
        try await session.start()
        live.emitLate(.final(text: "Keep this sentence."))
        live.emitLate(.turnBoundary)
        live.emitLate(.final(text: "Keep this sentence."))
        #expect(session.draft == "Keep this sentence.\nKeep this sentence.")
        session.cancel()
    }

    @Test func completionPicksUpAccumulatedChangesWithoutAnotherInterim() async throws {
        let probe = PolishProbe()
        nonisolated(unsafe) var live: FakeTranscriber!
        let session = DictationSession(apiKey: "test-only", emit: { _ in },
            transcriberFactory: { _, emit in live = FakeTranscriber(emit: emit); return live }, intelligence: probe, backgroundPolicy: .init(minimumInterval: 0.01, minimumNewWords: 8))
        try await session.start()
        let first = "one two three four five six seven eight nine ten eleven twelve"
        let second = first + " thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone"
        live.emitLate(.interim(text: first))
        try await probe.waitForCalls(1)
        live.emitLate(.interim(text: second))
        await probe.finish(0, text: first)
        try await probe.waitForCalls(2)
        #expect(await probe.inputs == [first, second])
        session.cancel()
        await probe.finish(1, text: second)
    }

    @Test func shortStableUtterancePolishesBeforeStop() async throws {
        let probe = PolishProbe()
        nonisolated(unsafe) var live: FakeTranscriber!
        let session = DictationSession(apiKey: "test-only", emit: { _ in },
            transcriberFactory: { _, emit in live = FakeTranscriber(emit: emit); return live }, intelligence: probe)
        try await session.start()
        live.emitLate(.interim(text: "Please keep the last word."))
        try await probe.waitForCalls(1)
        #expect(!live.finishCalled)
        session.cancel()
        await probe.finish(0, text: "Please keep the last word.")
    }

    @Test func hybridPauseSendsAllAudioAndOldAcknowledgmentCannotFinishNewSpeech() async throws {
        let socket = FakeWebSocket()
        let log = EventLog()
        var config = TranscriptionConfig.default
        config.vad = .hybrid
        let live = GeminiLiveTranscriber(apiKey: "test-only", config: config,
            emit: { log.append($0) }, webSocketFactory: { _ in socket })
        async let connected: Void = live.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        let speech = Data(repeating: 32, count: 3200)
        try live.sendAudio(speech)
        for _ in 0..<6 { try live.sendAudio(Data(count: 3200)) }
        #expect(socket.sent.filter { $0.contains("audioStreamEnd") }.count == 1)
        let audioMessages = socket.sent.compactMap { text -> [String: Any]? in
            let message = jsonObject(text) as? [String: Any]
            return (message?["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        }
        #expect(audioMessages.count == 7)
        #expect(audioMessages.compactMap { $0["data"] as? String }.compactMap { Data(base64Encoded: $0) }.reduce(0) { $0 + $1.count } == 7 * 3200)
        try live.sendAudio(speech)
        try live.finish()
        socket.simulateJSON(["serverContent": ["inputTranscription": ["text": "First sentence."]]])
        #expect(!log.snapshot().contains { $0.typeName == "complete" })
        socket.simulateJSON(["serverContent": ["turnComplete": true]])
        #expect(!log.snapshot().contains { $0.typeName == "complete" })
        #expect(socket.sent.filter { $0.contains("audioStreamEnd") }.count == 2)
        socket.simulateJSON(["serverContent": ["inputTranscription": ["text": "Last words."]]])
        #expect(log.snapshot().contains(.final(text: "Last words.")))
        #expect(log.snapshot().last?.typeName == "complete")
    }

    @Test func liveFinalReplacesACorrectedNumberInsteadOfConcatenatingBoth() async throws {
        let socket = FakeWebSocket()
        let log = EventLog()
        let live = GeminiLiveTranscriber(apiKey: "test-only", config: .default,
            emit: { log.append($0) }, webSocketFactory: { _ in socket })
        async let connected: Void = live.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        try live.sendAudio(Data(count: 3200))
        socket.simulateJSON(["serverContent": ["interimInputTranscription": ["text": "Set the timeout to fifteen seconds for all of these requests."]]])
        try live.finish()
        let final = "Set the timeout to fifty seconds for all of these requests."
        socket.simulateJSON(["serverContent": ["inputTranscription": ["text": final]]])
        #expect(log.snapshot().contains(.final(text: final)))
    }

    @Test func bufferedAudioDrainsInOrderIncludingPartialLastFrame() async {
        let queue = DispatchQueue(label: "test.audio.delivery")
        let stream = PCMDeliveryStream(queue: queue)
        let delivered = Blocks()
        stream.append(Data(repeating: 1, count: 3200))
        #expect(delivered.snapshot().isEmpty)
        stream.commit { delivered.append($0) }
        stream.append(Data(repeating: 2, count: 442))
        let boundary = await stream.drain()
        stream.append(Data(count: 100))
        let blocks = delivered.snapshot()
        #expect(boundary == 1821)
        #expect(blocks.map(\.sequence) == [0, 1])
        #expect(blocks.map(\.firstSample) == [0, 1600])
        #expect(blocks.map { $0.pcm.count } == [3200, 442])
    }

    @Test func unconfirmedHotkeyAudioIsNeverDelivered() async {
        let stream = PCMDeliveryStream(queue: DispatchQueue(label: "test.discard"))
        let delivered = Blocks()
        stream.append(Data(count: 3200))
        stream.discard()
        stream.commit { delivered.append($0) }
        _ = await stream.drain()
        #expect(delivered.snapshot().isEmpty)
    }

    @Test func correctedFinalStartsImmediatelyWithoutWaitingForStalePolish() async throws {
        let probe = PolishProbe()
        let log = EventLog()
        let fake = FakeTranscriber(emit: { _ in })
        nonisolated(unsafe) var live = fake
        let session = DictationSession(apiKey: "test-only", emit: { log.append($0) },
            transcriberFactory: { _, emit in
                live = FakeTranscriber(emit: emit)
                return live
            }, intelligence: probe)
        try await session.start()
        let initial = "please set the timeout for all of the following requests to fifteen seconds"
        let final = "please set the timeout for all of the following requests to fifty seconds"
        live.emitLate(.interim(text: initial))
        try await probe.waitForCalls(1)
        live.finalText = final
        try session.stop()
        // The first request is still blocked. Final editing must not depend on it.
        try await probe.waitForCalls(2)
        #expect(await probe.inputs == [initial, final])
        await probe.finish(1, text: "Set the timeout to 50 seconds.")
        try await waitUntilComplete(log)
        await probe.finish(0, text: "Set the timeout to 15 seconds.")
        #expect(log.snapshot().contains(.polished(text: "Set the timeout to 50 seconds.", model: "probe", latencyMs: 1, speculative: nil, source: final)))
        #expect(!log.snapshot().contains { event in
            if case .polished(let text, _, _, _, _) = event { return text.contains("15 seconds") }
            return false
        })
        session.close()
    }

    @Test func matchingPolishIsAwaitedOnceAndCarriesItsActualSource() async throws {
        let probe = PolishProbe()
        let log = EventLog()
        nonisolated(unsafe) var live: FakeTranscriber!
        let session = DictationSession(apiKey: "test-only", emit: { log.append($0) },
            transcriberFactory: { _, emit in live = FakeTranscriber(emit: emit); return live }, intelligence: probe)
        try await session.start()
        live.interimText = "Please do not edit anything."
        live.finalText = live.interimText
        try session.sendAudio(Data(count: 3200))
        try await probe.waitForCalls(1)
        session.prepareToStop()
        try session.stop()
        #expect(!log.snapshot().contains { $0.typeName == "complete" })
        await probe.finish(0, text: "Please do not edit anything.")
        try await waitUntilComplete(log)
        #expect(await probe.inputs.count == 1)
        #expect(!transcriptsCompatible(live.finalText, "Please do edit anything."))
        session.close()
    }

    @Test func audioArrivingBeforeAsyncConnectIsRetained() async throws {
        nonisolated(unsafe) var live: FakeTranscriber!
        let session = DictationSession(apiKey: "test-only", emit: { _ in },
            transcriberFactory: { _, emit in live = FakeTranscriber(emit: emit); return live }, speculativeIntelligence: false)
        try session.sendAudio(Data(count: 3200))
        try await session.start()
        #expect(live.audioBytes == 3200)
        session.cancel()
    }

    @Test func editsValidateRevisionAndSpanIdentityAndPreserveUnicode() throws {
        let document = TranscriptEditDocument("Hello दुनिया.", revision: "r1")
        let valid = Data(#"{"revision":"r1","edits":[{"id":"s0","text":"Hello दुनिया!"},{"id":"s1","text":" Last words."}]}"#.utf8)
        #expect(try document.applying(valid) == "Hello दुनिया! Last words.")
        for invalid in [
            #"{"revision":"r0","edits":[]}"#,
            #"{"revision":"r1","edits":[{"id":"s9","text":"lost"}]}"#,
            #"{"revision":"r1","edits":[{"id":"s0","text":"a"},{"id":"s0","text":"b"}]}"#,
            #"{"revision":"r1","edits":[{"id":"s0","text":""}]}"#,
        ] {
            #expect(throws: (any Error).self) { try document.applying(Data(invalid.utf8)) }
        }
    }
}

private final class Blocks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PCMDeliveryStream.Block] = []
    func append(_ block: PCMDeliveryStream.Block) { lock.withLock { values.append(block) } }
    func snapshot() -> [PCMDeliveryStream.Block] { lock.withLock { values } }
}

private actor PolishProbe: TranscriptIntelligence {
    var inputs: [String] = []
    private var continuations: [Int: CheckedContinuation<IntelligenceResult, Never>] = [:]
    func polish(_ text: String) async throws -> IntelligenceResult {
        let index = inputs.count
        inputs.append(text)
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, text: String) {
        continuations.removeValue(forKey: index)?.resume(returning: IntelligenceResult(text: text, model: "probe", latencyMs: 1))
    }
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<1000 {
            if inputs.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw TranscriptionError("Expected polish call did not start.")
    }
}

private func waitUntilComplete(_ log: EventLog) async throws {
    for _ in 0..<1000 {
        if log.snapshot().contains(where: { $0.typeName == "complete" }) { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw TranscriptionError("Session did not complete.")
}
