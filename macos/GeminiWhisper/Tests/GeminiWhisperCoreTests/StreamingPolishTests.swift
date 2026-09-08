import Foundation
import Testing

@testable import GeminiWhisperCore

private struct StreamingIntelligence: TranscriptIntelligence {
    let chunks: [String]

    func polish(_ transcript: String) async throws -> IntelligenceResult {
        IntelligenceResult(text: chunks.last ?? transcript, model: "test", latencyMs: 1)
    }

    func revise(_ transcript: String, previousInput: String?, previousOutput: String?) async throws -> IntelligenceResult {
        try await polish(transcript)
    }

    func reviseStreaming(_ transcript: String, previousInput: String?, previousOutput: String?,
                         onPartial: @escaping @Sendable (String) -> Void) async throws -> IntelligenceResult {
        for chunk in chunks { onPartial(chunk) }
        return try await polish(transcript)
    }
}

@Suite("streaming polish")
struct StreamingPolishTests {
    private func frame(_ text: String, finishReason: String? = nil, thoughts: Int? = nil) -> String {
        var candidate: [String: Any] = ["content": ["parts": [["text": text]]]]
        if let finishReason { candidate["finishReason"] = finishReason }
        var payload: [String: Any] = ["candidates": [candidate]]
        if let thoughts { payload["usageMetadata"] = ["thoughtsTokenCount": thoughts] }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return "data: " + String(decoding: data, as: UTF8.self) + "\n"
    }

    @Test func concatenatesDeltasAcrossFrames() {
        var accumulator = GeminiSSEAccumulator()
        #expect(accumulator.accept(Data(frame("Hello").utf8)) == "Hello")
        #expect(accumulator.accept(Data(frame(", world").utf8)) == ", world")
        #expect(accumulator.text == "Hello, world")
    }

    @Test func reassemblesFramesSplitAcrossChunkBoundaries() {
        let whole = frame("Split me")
        let cut = whole.index(whole.startIndex, offsetBy: 12)
        var accumulator = GeminiSSEAccumulator()
        // A frame arriving in two TCP reads must not be parsed twice or dropped.
        #expect(accumulator.accept(Data(String(whole[whole.startIndex..<cut]).utf8)) == "")
        #expect(accumulator.accept(Data(String(whole[cut...]).utf8)) == "Split me")
        #expect(accumulator.text == "Split me")
    }

    @Test func ignoresKeepAlivesBlankLinesAndDoneSentinel() {
        var accumulator = GeminiSSEAccumulator()
        accumulator.accept(Data(": keep-alive\n\n".utf8))
        accumulator.accept(Data("data: [DONE]\n".utf8))
        accumulator.accept(Data("event: message\n".utf8))
        #expect(accumulator.text.isEmpty)
    }

    @Test func surfacesTruncationAndThinkingTokens() {
        var accumulator = GeminiSSEAccumulator()
        accumulator.accept(Data(frame("cut off", finishReason: "MAX_TOKENS", thoughts: 42).utf8))
        #expect(accumulator.finishReason == "MAX_TOKENS")
        // thinkingBudget 0 should keep this at 0 in production; the parser must
        // still report a non-zero value so a regression is visible.
        #expect(accumulator.thoughtsTokens == 42)
    }

    @Test func flushesAFinalFrameWithoutATrailingNewline() {
        var accumulator = GeminiSSEAccumulator()
        let unterminated = String(frame("last").dropLast())
        #expect(accumulator.accept(Data(unterminated.utf8)) == "")
        #expect(accumulator.finish() == "last")
        #expect(accumulator.text == "last")
    }

    @Test func partialsArePreviewOnlyAndTheFinalTextIsWhatCompletes() async throws {
        let log = EventLog()
        let session = DictationSession(apiKey: "test-only", emit: { log.append($0) },
            transcriberFactory: { _, emit in FakeTranscriber(emit: emit) },
            intelligence: StreamingIntelligence(chunks: ["Test", "Testing", "Testing done."]),
            backgroundPolicy: .init(maximumJobs: 0))
        try await session.start()
        try session.sendAudio(Data(count: 3200))
        try session.stop()
        for _ in 0..<1000 {
            if log.snapshot().last?.typeName == "complete" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let progress = log.snapshot().compactMap { event -> String? in
            if case .polishProgress(let text) = event { return text }; return nil
        }
        #expect(progress == ["Test", "Testing", "Testing done."])
        // Only the completed text may be emitted as polished; a partial must not.
        let polished = log.snapshot().compactMap { event -> String? in
            if case .polished(let text, _, _, _, _) = event { return text }; return nil
        }
        #expect(polished == ["Testing done."])
        session.close()
    }

    @Test func malformedJsonIsSkippedWithoutCorruptingLaterFrames() {
        var accumulator = GeminiSSEAccumulator()
        accumulator.accept(Data("data: {not json\n".utf8))
        accumulator.accept(Data(frame("recovered").utf8))
        #expect(accumulator.text == "recovered")
    }
}
