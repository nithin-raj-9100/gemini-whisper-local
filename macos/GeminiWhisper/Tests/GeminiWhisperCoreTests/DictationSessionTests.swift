import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("dictation session")
struct DictationSessionTests {
    @Test func polishesTheAccumulatedFinalTranscriptBeforeCompleting() async throws {
        let events = try await runSession(
            config: .default,
            speculativeIntelligence: false,
            intelligence: ClosureIntelligence { transcript in
                #expect(transcript == "Testing.")
                return IntelligenceResult(text: "1. Milk\n2. Vegetables", model: "test-flash-lite", latencyMs: 3)
            }
        )

        #expect(events.last(where: { $0.typeName == "polished" }) == .polished(
            text: "1. Milk\n2. Vegetables",
            model: "test-flash-lite",
            latencyMs: 3,
            speculative: nil, source: "Testing."
        ))
        #expect(events.last?.typeName == "complete")
    }

    @Test func skipsIntelligenceWhenPolishingIsDisabled() async throws {
        nonisolated(unsafe) var polishCalls = 0
        var config = TranscriptionConfig.default
        config.polish = false
        let events = try await runSession(
            config: config,
            intelligence: ClosureIntelligence { _ in
                polishCalls += 1
                return IntelligenceResult(text: "unexpected", model: "test-flash-lite", latencyMs: 1)
            }
        )
        #expect(polishCalls == 0)
        #expect(!events.contains { $0.typeName == "polished" })
    }

    @Test func shortStopUsesOneFinalCallWithoutExtraSpeculation() async throws {
        nonisolated(unsafe) var polishCalls = 0
        let events = try await runSession(
            config: .default,
            speculativeIntelligence: true,
            customize: { $0.interimText = "Testing." },
            intelligence: ClosureIntelligence { transcript in
                polishCalls += 1
                #expect(transcript.lowercased().replacingOccurrences(of: ".", with: "") == "testing")
                try await Task.sleep(for: .milliseconds(20))
                return IntelligenceResult(text: "Testing.", model: "test-flash-lite", latencyMs: 20)
            }
        )
        #expect(polishCalls == 1)
        #expect(events.contains { event in
            if case .polished(_, _, _, let speculative, _) = event {
                return speculative == nil
            }
            return false
        })
    }

    @Test func polishesInterimMidSpeechBeforeStop() async throws {
        nonisolated(unsafe) var inputs: [String] = []
        _ = try await runSession(
            config: .default,
            speculativeIntelligence: true,
            customize: { fake in
                fake.interimText = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron"
            },
            intelligence: ClosureIntelligence { transcript in
                inputs.append(transcript)
                try await Task.sleep(for: .milliseconds(20))
                return IntelligenceResult(text: transcript, model: "test-flash-lite", latencyMs: 20)
            }
        )
        // Interim (15 words) polishes during speech; the final still gets its
        // own pass since it differs. No change when interim is tiny.
        #expect(inputs.count == 2)
        #expect(inputs[0].contains("alpha"))
        #expect(inputs[1] == "Testing.")
    }

    @Test func abortsSpeculativePolishWhenTheFinalTranscriptIsIncompatible() async throws {
        nonisolated(unsafe) var inputs: [String] = []
        _ = try await runSession(
            config: .default,
            speculativeIntelligence: true,
            customize: { fake in
                fake.interimText = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
                fake.finalText = "completely different words that should not reuse"
            },
            intelligence: ClosureIntelligence { transcript in
                inputs.append(transcript)
                try await Task.sleep(for: .milliseconds(10))
                return IntelligenceResult(text: transcript, model: "test-flash-lite", latencyMs: 10)
            }
        )
        #expect(inputs.contains { $0.contains("completely different") })
        #expect(!transcriptsCompatible(
            "alpha beta gamma delta epsilon zeta eta theta iota kappa",
            "completely different words that should not reuse"
        ))
    }

    @Test func emitsWarningAndCompletesWithRawTranscriptWhenPolishFails() async throws {
        let events = try await runSession(
            config: .default,
            speculativeIntelligence: false,
            intelligence: ClosureIntelligence { _ in
                throw TranscriptionError("Flash-Lite AIzaSySecretKey exploded")
            }
        )
        #expect(!events.contains { $0.typeName == "polished" })
        #expect(events.contains { event in
            if case .warning(let code, let message) = event {
                return code == "intelligence_failed" && message.contains("[redacted]") && !message.contains("AIza")
            }
            return false
        })
        #expect(events.contains(.final(text: "Testing.")))
        #expect(events.last?.typeName == "complete")
    }

    @Test func speculativeReuseRequiresExactSourceIncludingPunctuationAndCase() {
        #expect(!transcriptsCompatible("Testing.", "testing"))
        #expect(transcriptsCompatible("Testing.", "Testing."))
        #expect(!transcriptsCompatible(
            "one two three four five six seven eight nine ten",
            "one two three four five six seven eight nine tens"
        ))
        #expect(!transcriptsCompatible(
            "one two three four five six seven eight nine ten",
            "one two three four five six seven eight nine ten eleven"
        ))
        #expect(!transcriptsCompatible("one two three", "alpha beta gamma"))
        #expect(!transcriptsCompatible("", "hello"))
    }

    @Test func extractTrailingExtensionFindsAppendedWordsWhenPrefixMatches() {        let prefix = "I am using my own application to prompt this"
        let full = "I am using my own application to prompt this very prompt in you"
        let extensionWords = extractTrailingExtension(prefix: prefix, full: full)
        #expect(extensionWords == "very prompt in you")

        #expect(extractTrailingExtension(prefix: "completely different text", full: full) == nil)
        #expect(extractTrailingExtension(prefix: full, full: prefix) == nil)
    }

    @Test func cumulativeFinalReplacesAllCoveredSegments() {
        let first = "First sentence was spoken earlier."
        let second = "Then I added another sentence."
        let cumulative = first + " " + second + " Here is the ending."
        #expect(appendDedupedFinalSegment([first, second], cumulative) == [cumulative])
        #expect(appendDedupedFinalSegment(["Keep this introduction.", first, second], cumulative)
            == ["Keep this introduction.", cumulative])
    }

    @Test func interimPreviewDoesNotRepeatFinalizedWords() {
        let first = "First sentence was spoken earlier."
        let second = "Then I added another sentence."
        #expect(transcriptDraft(finalSegments: [first], latestInterim: first) == first)
        let cumulative = first + " " + second + " Here is the ending."
        #expect(transcriptDraft(finalSegments: [first, second], latestInterim: cumulative) == cumulative)
        #expect(transcriptDraft(finalSegments: [first], latestInterim: second) == first + "\n" + second)
    }

    @Test func newTurnAndSpokenRepetitionArePreserved() {
        let repeated = "Please try again."
        #expect(transcriptDraft(finalSegments: [repeated], latestInterim: repeated, startsNewTurn: true)
            == repeated + "\n" + repeated)
        #expect(transcriptDraft(finalSegments: [], latestInterim: "Very very useful. Please try again. Please try again.")
            == "Very very useful. Please try again. Please try again.")
    }

    @Test func resendMatchingRequiresWholeWords() {
        #expect(!normalizedTranscriptContains(haystack: "We discussed catering", needle: "cat"))
        #expect(appendDedupedFinalSegment(["We discussed catering"], "cat") == ["We discussed catering", "cat"])
    }

    @Test func dedupedFinalSegmentsDropResendsAndMergeExtensions() {
        #expect(appendDedupedFinalSegment(["hello world"], "hello world") == ["hello world"])
        #expect(appendDedupedFinalSegment(["hello world"], "Hello, WORLD!") == ["hello world"])
        #expect(appendDedupedFinalSegment(["hello"], "hello world") == ["hello world"])
        #expect(appendDedupedFinalSegment(["one"], "two") == ["one", "two"])
        #expect(appendDedupedFinalSegment(["one", "two three"], "two three four") == ["one", "two three four"])
        #expect(appendDedupedFinalSegment(
            ["here is the the maid speech i am speaking"],
            "here is the speech i am speaking"
        ) == ["here is the speech i am speaking"])
        #expect(appendDedupedFinalSegment(
            ["did you run some tests"],
            "did you write some tests"
        ) == ["did you write some tests"])
        #expect(appendDedupedFinalSegment(["i like apples"], "i like oranges and bananas") == [
            "i like apples", "i like oranges and bananas",
        ])
        #expect(appendDedupedFinalSegment([], "") == [])
        #expect(normalizedTranscriptContains(haystack: "Please do not edit!", needle: "please do not edit"))
        #expect(!normalizedTranscriptContains(haystack: "hello", needle: "hello world"))
    }

    @Test func ignoresMidSessionCompleteAndKeepsAcceptingAudioUntilStop() async throws {
        let log = EventLog()
        nonisolated(unsafe) var fake: FakeTranscriber?
        let session = DictationSession(
            apiKey: "test-only",
            config: {
                var config = TranscriptionConfig.default
                config.polish = false
                return config
            }(),
            emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let created = FakeTranscriber(emit: emit)
                created.emitOnAudio = .complete
                fake = created
                return created
            },
            intelligence: nil,
            speculativeIntelligence: false
        )

        try await session.start()
        try session.sendAudio(Data(count: 3200))
        try session.sendAudio(Data(count: 3200))
        #expect(fake?.audioBytes == 6400)
        #expect(!log.snapshot().contains { $0.typeName == "complete" })

        try session.stop()
        await log.waitForComplete()
        #expect(fake?.finishCalled == true)
        #expect(log.snapshot().last?.typeName == "complete")
    }

    @Test func stopAfterLiveFinishErrorStillCompletesWithLatestInterim() async throws {
        let log = EventLog()
        let session = DictationSession(
            apiKey: "test-only",
            config: {
                var config = TranscriptionConfig.default
                config.polish = false
                return config
            }(),
            emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let fake = FakeTranscriber(emit: emit)
                fake.finishError = TranscriptionError("The transcription session is not ready.")
                return fake
            },
            intelligence: nil,
            speculativeIntelligence: false
        )

        try await session.start()
        try session.sendAudio(Data(count: 3200))
        try session.stop()
        await log.waitForComplete()

        let events = log.snapshot()
        #expect(events.contains(.interim(text: "testing")))
        #expect(events.contains { event in
            if case .warning(let code, _) = event { return code == "live_finish_failed" }
            return false
        })
        #expect(!events.contains { $0.typeName == "error" })
        #expect(events.last?.typeName == "complete")
    }

    @Test func cancelIgnoresLateCompleteButStopWithTextStillInserts() async throws {
        let log = EventLog()
        nonisolated(unsafe) var fake: FakeTranscriber?
        let session = DictationSession(
            apiKey: "test-only",
            config: {
                var config = TranscriptionConfig.default
                config.polish = false
                return config
            }(),
            emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let created = FakeTranscriber(emit: emit)
                fake = created
                return created
            },
            intelligence: nil,
            speculativeIntelligence: false
        )

        try await session.start()
        try session.sendAudio(Data(count: 3200))
        session.cancel()
        fake?.emitLate(.final(text: "late words"))
        fake?.emitLate(.complete)
        try await Task.sleep(for: .milliseconds(50))

        let events = log.snapshot()
        #expect(events.contains(.cancelled))
        #expect(!events.contains(.final(text: "late words")))
        #expect(events.filter { $0.typeName == "complete" }.isEmpty)
    }
}

private func runSession(
    config: TranscriptionConfig,
    speculativeIntelligence: Bool = true,
    customize: ((FakeTranscriber) -> Void)? = nil,
    intelligence: ClosureIntelligence
) async throws -> [ServerEvent] {
    let log = EventLog()
    let session = DictationSession(
        apiKey: "test-only",
        config: config,
        emit: { log.append($0) },
        transcriberFactory: { _, emit in
            let fake = FakeTranscriber(emit: emit)
            customize?(fake)
            return fake
        },
        intelligence: intelligence,
        speculativeIntelligence: speculativeIntelligence
    )

    try await session.start()
    try session.sendAudio(Data(count: 3200))
    await Task.yield()
    try session.stop()

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await log.waitForComplete()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw TranscriptionError("Dictation session test timed out.")
        }
        try await group.next()
        group.cancelAll()
    }
    return log.snapshot()
}
