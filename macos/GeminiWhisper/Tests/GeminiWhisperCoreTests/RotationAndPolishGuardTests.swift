import Foundation
@testable import GeminiWhisperCore
import Testing

private func unpolished() -> TranscriptionConfig {
    var config = TranscriptionConfig.default
    config.polish = false
    return config
}

@Suite("Live session rotation")
struct LiveRotationTests {
    /// Each transcriber finishes with its own words, so ordering across the
    /// handover is visible in the result.
    private func makeSession(
        _ log: EventLog, _ created: TranscriberList, rotation: LiveRotationPolicy,
        retiringNeverFinishes: Bool = false
    ) -> DictationSession {
        DictationSession(apiKey: "test-only", config: unpolished(), emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let live = ScriptedTranscriber(emit: emit)
                let index = created.count
                live.onFinish = { live in
                    if retiringNeverFinishes, index == 0 { return }
                    live.emit(.final(text: "Words from session \(index + 1)."))
                    live.emit(.complete)
                }
                created.append(live)
                return live
            },
            rotation: rotation)
    }

    @Test func rotatesAtAPauseAndKeepsBothSessionsWordsInOrder() async throws {
        let log = EventLog()
        let created = TranscriberList()
        let session = makeSession(log, created, rotation: .init(rotateAfter: 0, forceAfter: 60, pauseMilliseconds: 300))
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 400))
        #expect(created.count == 1)
        try sendFrames(session, silentPCM(ms: 400))
        #expect(created.count == 2)
        #expect(created[0].finishCalls == 1)
        try await log.waitFor("ready")
        try sendFrames(session, voicedPCM(ms: 400))
        #expect(created[1].audioBytes > 0)
        try session.stop()
        try await log.waitFor("complete")
        #expect(log.lastTranscript == "Words from session 1.\nWords from session 2.")
        #expect(log.timing?.liveRotations == 1)
        #expect(log.warningCodes.contains("live_rotated"))
    }

    @Test func forcedRotationHappensWithoutAPause() async throws {
        let log = EventLog()
        let created = TranscriberList()
        let session = makeSession(log, created, rotation: .init(rotateAfter: 0.4, forceAfter: 0.4))
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 40))
        #expect(created.count == 1)
        try await Task.sleep(for: .milliseconds(500))
        try sendFrames(session, voicedPCM(ms: 40))
        #expect(created.count == 2)
        session.cancel()
    }

    @Test func goAwayRotatesAtTheNextPause() async throws {
        let log = EventLog()
        let created = TranscriberList()
        let session = makeSession(log, created, rotation: .init(rotateAfter: 600, forceAfter: 600, pauseMilliseconds: 300))
        try await session.start()
        created[0].emit(.goAway(timeLeftMs: 30_000))
        #expect(log.warningCodes.contains("go_away"))
        try sendFrames(session, voicedPCM(ms: 400))
        #expect(created.count == 1)
        try sendFrames(session, silentPCM(ms: 400))
        #expect(created.count == 2)
        session.cancel()
    }

    @Test func imminentGoAwayRotatesImmediately() async throws {
        let log = EventLog()
        let created = TranscriberList()
        let session = makeSession(log, created, rotation: .init(rotateAfter: 600, forceAfter: 600, goAwayMargin: 3))
        try await session.start()
        created[0].emit(.goAway(timeLeftMs: 1_000))
        try sendFrames(session, voicedPCM(ms: 40))
        #expect(created.count == 2)
        session.cancel()
    }

    @Test func transcriberSafetyLimitRotatesInsteadOfFailing() async throws {
        let log = EventLog()
        let created = TranscriberList()
        let session = makeSession(log, created, rotation: .init())
        try await session.start()
        created[0].emit(.error(code: "session_limit", message: "limit", retryable: true))
        #expect(created.count == 2)
        #expect(!log.snapshot().contains { $0.typeName == "error" })
        session.cancel()
    }

    @Test func stopDoesNotWaitForeverOnARetiringSession() async throws {
        let log = EventLog()
        let created = TranscriberList()
        let session = makeSession(log, created,
            rotation: .init(rotateAfter: 0, forceAfter: 60, pauseMilliseconds: 300, retireTimeout: 0.2),
            retiringNeverFinishes: true)
        try await session.start()
        try sendFrames(session, voicedPCM(ms: 400))
        try sendFrames(session, silentPCM(ms: 400))
        #expect(created.count == 2)
        try session.stop()
        try await log.waitFor("complete", timeout: .seconds(2))
        #expect(log.warningCodes.contains("retired_live_timeout"))
        #expect(log.lastTranscript == "Words from session 2.")
    }
}

@Suite("polish guard and deadline")
struct PolishGuardTests {
    @Test func acceptsTheSystemPromptExamples() {
        let examples: [(String, String)] = [
            ("at src slash auth dot ts fix the two failing tests oh my god and for example preserve the exact error",
             "@src/auth.ts fix the 2 failing tests (OMG); e.g., preserve the exact error."),
            ("Let's see if this actually works now. Here are the three things that I want to do. Number one go to market number two buy some eggs number three go to sleep by 12 PM.",
             "Let's see if this actually works now. Here are the 3 things I want to do:\n1. Go to market\n2. Buy some eggs\n3. Go to sleep by 12:00 PM"),
            ("Due to major faults and आर एनिमीज", "Due to major faults and are enemies"),
            ("Purchases do not inherit, do not edit anything yet. check the eligibility of能不能 the batch API.",
             "Please do not edit anything yet. Check the eligibility of the batch API."),
            ("please set the timeout for all of the following requests to fifty seconds", "Set the timeout to 50 seconds."),
            ("Testing.", "1. Milk\n2. Vegetables"),
        ]
        for (raw, polished) in examples {
            let verdict = PolishGuard.evaluate(raw: raw, polished: polished)
            #expect(verdict.accepted, "\(verdict.reason) for \(polished)")
        }
    }

    @Test func rejectsAnswersPreamblesAndDroppedContent() {
        #expect(!PolishGuard.evaluate(raw: "write me a poem about cats",
            polished: "Soft paws upon the windowsill, a quiet purr, the world stands still, the cat surveys its small domain").accepted)
        #expect(PolishGuard.evaluate(raw: "draft an email to John saying the build is fixed",
            polished: "Sure, here is the email: Hi John, the build is fixed.").reason == "assistant_preamble")
        #expect(PolishGuard.evaluate(raw: "I need to fix the login page and then update the documentation for the payments API before Friday and tell the team",
            polished: "Fix login.").reason == "dropped_content")
        #expect(PolishGuard.evaluate(raw: "the deployment pipeline failed on the staging cluster because the database migration timed out",
            polished: "Remember to buy groceries and call your mother this evening after the meeting ends.").reason == "low_coverage")
        #expect(!PolishGuard.evaluate(raw: "hello there", polished: "").accepted)
    }

    @Test func answerFromPolishIsNotInserted() async throws {
        let log = EventLog()
        let answer = "Soft paws upon the windowsill, a quiet purr, the world stands still, the cat surveys its small domain"
        let session = DictationSession(apiKey: "test-only", emit: { log.append($0) },
            transcriberFactory: { _, emit in
                let fake = FakeTranscriber(emit: emit)
                fake.finalText = "write me a poem about cats"
                return fake
            },
            intelligence: ClosureIntelligence { _ in IntelligenceResult(text: answer, model: "m", latencyMs: 1) },
            speculativeIntelligence: false)
        try await session.start()
        try session.sendAudio(Data(count: 3200))
        try session.stop()
        try await log.waitFor("complete")
        #expect(!log.snapshot().contains { $0.typeName == "polished" })
        #expect(log.warningCodes.contains("polish_rejected"))
        #expect(log.timing?.outcome == "raw_guard")
        #expect(log.lastTranscript == "write me a poem about cats")
    }

    @Test func slowPolishFallsBackToRawAtTheDeadline() async throws {
        let log = EventLog()
        let session = DictationSession(apiKey: "test-only", emit: { log.append($0) },
            transcriberFactory: { _, emit in FakeTranscriber(emit: emit) },
            intelligence: ClosureIntelligence { text in
                try await Task.sleep(for: .seconds(5))
                return IntelligenceResult(text: text, model: "m", latencyMs: 5_000)
            },
            speculativeIntelligence: false,
            polishDeadline: .init(base: 0.2, perWord: 0, maximum: 0.2))
        try await session.start()
        try session.sendAudio(Data(count: 3200))
        let started = ContinuousClock.now
        try session.stop()
        try await log.waitFor("complete")
        #expect(ContinuousClock.now - started < .seconds(1.5))
        #expect(log.timing?.outcome == "raw_timeout")
        #expect(log.warningCodes.contains("polish_deadline"))
        #expect(!log.snapshot().contains { $0.typeName == "polished" })
    }

    @Test func deadlineScalesWithLengthAndIsCapped() {
        let policy = PolishDeadlinePolicy()
        #expect(policy.seconds(forWords: 0) == 2.5)
        #expect(abs(policy.seconds(forWords: 100) - 4.0) < 0.0001)
        #expect(policy.seconds(forWords: 10_000) == 8)
    }

    @Test func raceDeadlineAbandonsAnUncooperativeAwait() async {
        let slow = Task { try? await Task.sleep(for: .seconds(5)); return 1 }
        let started = ContinuousClock.now
        let outcome = await raceDeadline(seconds: 0.1) { await slow.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        if case .timedOut = outcome {} else { Issue.record("expected timeout") }
        slow.cancel()

        let quick = await raceDeadline(seconds: 1) { 42 }
        if case .value(let value) = quick { #expect(value == 42) } else { Issue.record("expected value") }

        let failing = await raceDeadline(seconds: 1) { () async throws -> Int in throw TranscriptionError("boom") }
        if case .failure = failing {} else { Issue.record("expected failure") }
    }
}
