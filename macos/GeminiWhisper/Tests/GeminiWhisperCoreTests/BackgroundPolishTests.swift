import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("bounded background polishing")
struct BackgroundPolishTests {
    private let sentence = "one two three four five six seven eight nine ten eleven twelve"

    @Test func rapidRevisionsCannotExceedIntervalOrSessionBudget() {
        var scheduler = BackgroundPolishScheduler()
        var admitted: [Double] = []
        for tick in 0..<340 {
            let time = Double(tick) / 10
            let input = String(repeating: "word ", count: 12 + tick)
            if let delay = scheduler.delay(for: input, stableFor: 1, now: time), delay == 0 {
                scheduler.started(input, now: time)
                admitted.append(time)
            }
        }
        #expect(admitted.count == 6)
        #expect(zip(admitted, admitted.dropFirst()).allSatisfy { $1 - $0 >= 4 })
    }

    @Test func stabilityDoesNotBypassContentGateOrRetryFailedInput() {
        var scheduler = BackgroundPolishScheduler()
        scheduler.started(sentence, now: 0)
        #expect(scheduler.delay(for: sentence + " thirteen", stableFor: 100, now: 100) == nil)
        #expect(scheduler.delay(for: sentence + " next whole sentence here.", stableFor: 1, now: 4) == 0)
        scheduler.failed(sentence, now: 4, rateLimited: false)
        #expect(scheduler.delay(for: sentence, stableFor: 100, now: 100) == nil)
        #expect(scheduler.delay(for: sentence + " next whole sentence here.", stableFor: 1, now: 5) == 9)
    }

    @Test func rateLimitDisablesBackgroundForRestOfSession() {
        var scheduler = BackgroundPolishScheduler()
        scheduler.started(sentence, now: 0)
        scheduler.failed(sentence, now: 1, rateLimited: true)
        #expect(scheduler.delay(for: sentence + sentence, stableFor: 100, now: 100) == nil)
    }

    @Test func backgroundHTTPDoesNotRetryRateLimitsOrTransportFailures() async throws {
        for status in [429, 503, -1] {
            let counter = CallCounter()
            let intelligence = GeminiTranscriptIntelligence(apiKey: "test-only", httpClient: ClosureHTTPClient { _ in
                counter.increment()
                if status == -1 { throw URLError(.networkConnectionLost) }
                return (Data("{}".utf8), status)
            })
            do {
                _ = try await intelligence.polishBackground(sentence)
                Issue.record("Expected background failure")
            } catch {
                if status != -1 { #expect((error as? IntelligenceHTTPError)?.status == status) }
            }
            #expect(counter.value == 1)
        }
    }

    @Test func exhaustedBackgroundBudgetDoesNotBlockFinalCallAndTiming() async throws {
        let log = EventLog()
        let counter = CallCounter()
        let session = DictationSession(apiKey: "test-only", emit: { log.append($0) },
            transcriberFactory: { _, emit in FakeTranscriber(emit: emit) },
            intelligence: ClosureIntelligence { input in
                counter.increment()
                return IntelligenceResult(text: input, model: "test", latencyMs: 1)
            }, backgroundPolicy: .init(maximumJobs: 0))
        try await session.start()
        try session.sendAudio(Data(count: 3200))
        session.prepareToStop()
        try session.stop()
        for _ in 0..<1000 {
            if log.snapshot().last?.typeName == "complete" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(counter.value == 1)
        let timing = log.snapshot().compactMap { event -> DictationTiming? in
            if case .timing(let value) = event { return value }; return nil
        }.last
        #expect(timing?.outcome == "fresh")
        #expect(timing?.backgroundJobs == 0)
        #expect(timing?.finalJobs == 1)
        #expect(log.snapshot().last?.typeName == "complete")
        session.close()
    }

    @Test func failedFinalReportsRawInsteadOfOldPolishTiming() async throws {
        let log = EventLog()
        let session = DictationSession(apiKey: "test-only", emit: { log.append($0) },
            transcriberFactory: { _, emit in FakeTranscriber(emit: emit) },
            intelligence: ClosureIntelligence { _ in throw IntelligenceHTTPError(status: 429) },
            backgroundPolicy: .init(maximumJobs: 0))
        try await session.start()
        try session.sendAudio(Data(count: 3200))
        try session.stop()
        for _ in 0..<1000 {
            if log.snapshot().last?.typeName == "complete" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(log.snapshot().contains { if case .timing(let value) = $0 { return value.outcome == "raw_failure" }; return false })
        #expect(!log.snapshot().contains { $0.typeName == "polished" })
        session.close()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
