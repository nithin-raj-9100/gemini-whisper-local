import Foundation
@testable import GeminiWhisperCore
import Testing

/// A Live failure must never lose a dictation: the session keeps recording and
/// recovers the transcript from the audio at stop.
@Suite("session recovery")
struct SessionRecoveryTests {
    private func unpolished() -> TranscriptionConfig {
        var config = TranscriptionConfig.default
        config.polish = false
        return config
    }

    @Test func liveErrorWhileListeningDegradesAndBatchRecoversAtStop() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in "Everything I said, recovered." }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                live.onAudio = { live, _ in
                    if live.audioBytes > 3 * PCM_CHUNK_BYTES {
                        live.emit(.error(code: "UNAVAILABLE", message: "backend unavailable", retryable: true))
                    }
                }
                return live
            },
            batchTranscriber: batch)
        try await session.start()
        // Transport failure is absorbed: audio keeps being accepted and recorded.
        try sendFrames(session, voicedPCM(ms: 2_000))
        #expect(log.warningCodes.contains("live_degraded"))
        #expect(!log.snapshot().contains { $0.typeName == "error" })
        try session.stop()
        try await log.waitFor("complete")

        #expect(batch.calls.count == 1)
        #expect(batch.calls.first?.durationMs == 2_000)
        #expect(log.lastTranscript == "Everything I said, recovered.")
        #expect(log.timing?.transcriptSource == "batch")
        #expect(log.timing?.batchReason == "live_failed")
    }

    @Test func transcriberSendFailureNeverThrowsToTheCaller() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in "Recovered after overflow." }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                live.onAudio = { _, _ in throw TranscriptionError("Audio queue exceeded 30 seconds.") }
                return live
            },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 400))
        try session.stop()
        try await log.waitFor("complete")
        #expect(session.recordedAudio.durationMs == 400)
        #expect(log.lastTranscript == "Recovered after overflow.")
    }

    @Test func emptyLiveResultWithSpeechIsRecoveredFromAudio() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in "Words Live never returned." }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in ScriptedTranscriber(emit: emit) },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 1_000))
        try session.stop()
        try await log.waitFor("complete")
        #expect(log.timing?.batchReason == "live_empty")
        #expect(log.lastTranscript == "Words Live never returned.")
    }

    @Test func reconnectDuringDictationTriggersRecoveryFromAudio() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in "Complete sentence including the words lost in the drop." }
        nonisolated(unsafe) var live: ScriptedTranscriber!
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                live = ScriptedTranscriber(emit: emit)
                live.onFinish = { live in
                    live.emit(.final(text: "Complete sentence the drop."))
                    live.emit(.complete)
                }
                return live
            },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 600))
        // GeminiLiveTranscriber reports `.connecting` only when it reconnects.
        live.emit(.connecting)
        live.emit(.ready)
        try sendFrames(session, voicedPCM(ms: 600))
        try session.stop()
        try await log.waitFor("complete")
        #expect(log.timing?.batchReason == "live_reconnected")
        #expect(log.timing?.liveReconnects == 1)
        #expect(log.lastTranscript == "Complete sentence including the words lost in the drop.")
    }

    @Test func implausiblySparseLiveTranscriptIsRecovered() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in String(repeating: "word ", count: 30) }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                live.onFinish = { live in
                    live.emit(.final(text: "Only three words."))
                    live.emit(.complete)
                }
                return live
            },
            batchTranscriber: batch,
            batchPolicy: .init(sparseWordsPerVoicedSecond: 1, sparseMinimumVoicedMs: 4_000))
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 5_000))
        try session.stop()
        try await log.waitFor("complete")
        #expect(log.timing?.batchReason == "live_sparse")
        #expect(log.lastTranscript?.hasPrefix("word word") == true)
    }

    @Test func healthyLiveDoesNotCallBatch() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in "should not be used" }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in FakeTranscriber(emit: emit) },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 400))
        try session.stop()
        try await log.waitFor("complete")
        #expect(batch.calls.isEmpty)
        #expect(log.timing?.transcriptSource == "live")
        #expect(log.lastTranscript == "Testing.")
    }

    @Test func failedRecoveryWithNothingBufferedReportsAndKeepsAudio() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in throw IntelligenceHTTPError(status: 503) }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in ScriptedTranscriber(emit: emit) },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 800))
        try session.stop()
        try await log.waitFor("error")
        #expect(log.snapshot().contains { if case .error(let code, _, let retryable) = $0 { return code == "transcription_failed" && retryable }; return false })
        #expect(!log.snapshot().contains { $0.typeName == "complete" })
        #expect(session.recordedAudio.durationMs == 800)
    }

    @Test func failedRecoveryFallsBackToTheBufferedLiveText() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in throw IntelligenceHTTPError(status: 503) }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                live.onAudio = { live, _ in
                    if live.audioBytes == PCM_CHUNK_BYTES { live.emit(.final(text: "Buffered before the failure.")) }
                    if live.audioBytes == 2 * PCM_CHUNK_BYTES {
                        live.emit(.error(code: "gemini_connection_closed", message: "closed", retryable: true))
                    }
                }
                return live
            },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 400))
        try session.stop()
        try await log.waitFor("complete")
        #expect(log.warningCodes.contains("batch_failed"))
        #expect(log.lastTranscript == "Buffered before the failure.")
    }

    @Test func rejectedApiKeyFailsFastInsteadOfRecording() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in "unused" }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                live.onAudio = { live, _ in
                    live.emit(.error(code: "gemini_connection_closed", message: "API key not valid. Please pass a valid API key.", retryable: false))
                }
                return live
            },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 80))
        #expect(log.snapshot().contains { if case .error(_, _, let retryable) = $0 { return !retryable }; return false })
        #expect(!log.warningCodes.contains("live_degraded"))
    }

    @Test func withoutBatchRecoveryTheLiveErrorIsStillReported() async throws {
        let log = EventLog()
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                live.onFinish = { live in
                    live.emit(.error(code: "final_transcript_timeout", message: "Gemini did not finalize the transcript in time.", retryable: true))
                }
                return live
            })
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 400))
        try session.stop()
        try await log.waitFor("error")
        #expect(log.snapshot().contains { if case .error(let code, _, _) = $0 { return code == "final_transcript_timeout" }; return false })
    }

    @Test func silenceCompletesEmptyWithoutCallingBatch() async throws {
        let log = EventLog()
        let batch = FakeBatchTranscriber { _ in "hallucination" }
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in ScriptedTranscriber(emit: emit) },
            batchTranscriber: batch)
        try await session.start()
        try sendFrames(session, silentPCM(ms: 1_000))
        try session.stop()
        try await log.waitFor("complete")
        #expect(batch.calls.isEmpty)
        #expect(log.timing?.transcriptSource == "none")
        #expect(log.timing?.voicedMs == 0)
        #expect(log.timing?.audioMs == 1_000)
    }

    @Test func transcriptEventCarriesTheAuthoritativeDraft() async throws {
        let log = EventLog()
        let session = DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                live.onAudio = { live, _ in
                    live.emit(.interim(text: "hello wor"))
                    live.emit(.final(text: "Hello world."))
                }
                return live
            })
        try await session.start()
        try session.sendAudio(voicedPCM(ms: 40))
        let transcripts = log.snapshot().compactMap { if case .transcript(let text) = $0 { return text }; return nil }
        #expect(transcripts == ["hello wor", "Hello world."])
        session.cancel()
    }
}

/// Merging must keep genuinely repeated or parallel speech.
@Suite("speech-preserving merge")
struct SpeechPreservingMergeTests {
    @Test func repeatedPhraseAfterOtherSpeechIsKept() {
        #expect(appendDedupedFinalSegment(["Yes.", "Then we can ship on Monday."], "Yes.")
            == ["Yes.", "Then we can ship on Monday.", "Yes."])
    }

    @Test func immediateResendWithoutNewSpeechIsDropped() {
        #expect(appendDedupedFinalSegment(["Thanks."], "Thanks.") == ["Thanks."])
        #expect(appendDedupedFinalSegment(["one two", "three four"], "two three") == ["one two", "three four"])
    }

    @Test func parallelSentenceBackedByNewSpeechIsKept() {
        let first = "Please send the report to John by Friday."
        let second = "Please send the invoice to John by Friday."
        #expect(appendDedupedFinalSegment([first], second, newSpeechLikely: true) == [first, second])
        // Without audio evidence it is still treated as a recognition revision.
        #expect(appendDedupedFinalSegment([first], second) == [second])
    }

    @Test func newSpeechNeedsEnoughVoicedAudioForItsWords() {
        #expect(!newSpeechLikely(voicedMs: 300, incoming: "Yes."))
        #expect(newSpeechLikely(voicedMs: 400, incoming: "Yes."))
        #expect(!newSpeechLikely(voicedMs: 1_000, incoming: "Please send the invoice to John by Friday."))
        #expect(newSpeechLikely(voicedMs: 1_200, incoming: "Please send the invoice to John by Friday."))
    }

    @Test func sessionKeepsAParallelSentenceSpokenAfterThePrevious() async throws {
        let log = EventLog()
        var config = TranscriptionConfig.default
        config.polish = false
        nonisolated(unsafe) var live: ScriptedTranscriber!
        let session = DictationSession(apiKey: "test-only", config: config, emit: { log.append($0) },
            transcriberFactory: { _, emit in live = ScriptedTranscriber(emit: emit); return live })
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 2_000))
        live.emit(.final(text: "Please send the report to John by Friday."))
        try sendFrames(session, voicedPCM(ms: 2_000))
        live.emit(.final(text: "Please send the invoice to John by Friday."))
        #expect(session.draft == "Please send the report to John by Friday.\nPlease send the invoice to John by Friday.")
        session.cancel()
    }

    @Test func sessionStillReplacesARevisionWithoutNewSpeech() async throws {
        var config = TranscriptionConfig.default
        config.polish = false
        nonisolated(unsafe) var live: ScriptedTranscriber!
        let session = DictationSession(apiKey: "test-only", config: config, emit: { _ in },
            transcriberFactory: { _, emit in live = ScriptedTranscriber(emit: emit); return live })
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 2_000))
        live.emit(.final(text: "did you run some tests"))
        live.emit(.final(text: "did you write some tests"))
        #expect(session.draft == "did you write some tests")
        session.cancel()
    }
}
