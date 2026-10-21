import Foundation
@testable import GeminiWhisperCore
import Testing

// MARK: - Fakes

@MainActor
final class FakeCapture: AudioCapturing {
    var deviceName = "Fake Mic"
    var startCount = 0
    var pauseCount = 0
    var failStart = false
    private(set) var handler: (@Sendable (Data) -> Void)?

    func startCapture(_ handler: @escaping @Sendable (Data) -> Void) throws {
        if failStart { throw TranscriptionError("Microphone unavailable.") }
        startCount += 1
        self.handler = handler
    }

    func pauseCapture() {
        pauseCount += 1
        handler = nil
    }

    /// Delivers `pcm` the way the audio tap does, in 40 ms blocks.
    func speak(_ pcm: Data) {
        var offset = 0
        while offset < pcm.count {
            let end = min(pcm.count, offset + PCM_CHUNK_BYTES)
            handler?(pcm.subdata(in: offset..<end))
            offset = end
        }
    }
}

@MainActor
final class FakeInserter: TextInserting {
    var target: InsertionTarget? = InsertionTarget(processIdentifier: 42, bundleIdentifier: "com.example.editor", name: "Editor")
    var inserted: [String] = []
    var copied: [String] = []
    var replacements: [(String, String)] = []
    var replaceResult = true
    var failInsert = false
    var reportNotInserted = false
    var watching = false
    private var inputHandler: (@MainActor @Sendable () -> Void)?

    func currentTarget() -> InsertionTarget? { target }

    func insert(_ text: String, expected: InsertionTarget?,
                onNotInserted: @escaping @MainActor @Sendable (String) -> Void) async throws -> InsertionReport {
        if failInsert { throw TranscriptionError("Accessibility is off.") }
        inserted.append(text)
        if reportNotInserted { onNotInserted(text) }
        return .pasted
    }

    func replaceInserted(_ inserted: String, with replacement: String, target: InsertionTarget?) async throws -> Bool {
        replacements.append((inserted, replacement))
        return replaceResult
    }

    func copy(_ text: String) throws { copied.append(text) }

    func startUserInputWatch(_ onInput: @escaping @MainActor @Sendable () -> Void) {
        watching = true
        inputHandler = onInput
    }

    func stopUserInputWatch() {
        watching = false
        inputHandler = nil
    }

    func simulateUserTyping() { inputHandler?() }
}

@MainActor
final class FakeFeedback: DictationFeedback {
    var statuses: [String] = []
    var errors: [String] = []
    var notifications: [String] = []
    var cues: [DictationCue] = []
    var texts: [String] = []
    var visible = false

    func showListening() { visible = true }
    func hide() { visible = false }
    func showText(_ text: String) { texts.append(text) }
    func showStatus(_ text: String) { statuses.append(text) }
    func showFinalizing() {}
    func showError(_ message: String) { errors.append(message) }
    func nudge() {}
    func setLevel(_ rms: Double) {}
    func play(_ cue: DictationCue) { cues.append(cue) }
    func notify(_ message: String) { notifications.append(message) }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
    func outcome(_ result: String) -> String? { all.last { $0.hasPrefix("outcome ") && $0.contains("result=\(result) ") } }
}

/// Builds sessions on scripted transcribers so each test controls what Live does.
@MainActor
final class Harness {
    let capture = FakeCapture()
    let inserter = FakeInserter()
    let feedback = FakeFeedback()
    let logs = LogLines()
    let transcribers = TranscriberList()
    var configure: (ScriptedTranscriber, Int) -> Void = { live, _ in
        live.onAudio = { live, _ in
            if live.audioBytes == PCM_CHUNK_BYTES { live.emit(.interim(text: "hello")) }
        }
        live.onFinish = { live in
            live.emit(.final(text: "Hello world."))
            live.emit(.complete)
        }
    }
    var batch: FakeBatchTranscriber?
    var polish = false
    var intelligence: (any TranscriptIntelligence)?
    var missingKey = false
    lazy var coordinator: DictationCoordinator = makeCoordinator()

    var policy = DictationCoordinatorPolicy(finalizeTimeout: 2, silentInputCheckAfter: 0.2, userInputWatchDelay: 0.01)

    private func makeCoordinator() -> DictationCoordinator {
        DictationCoordinator(
            capture: capture,
            inserter: inserter,
            feedback: feedback,
            makeSession: { [unowned self] emit in
                if self.missingKey { throw TranscriptionError("Add a Gemini API key in Settings.") }
                var config = TranscriptionConfig.default
                config.polish = self.polish
                let transcribers = self.transcribers
                let configure = self.configure
                return DictationSession(apiKey: "test-only", config: config, emit: emit,
                    transcriberFactory: { _, emit in
                        let live = ScriptedTranscriber(emit: emit)
                        configure(live, transcribers.count)
                        transcribers.append(live)
                        return live
                    },
                    intelligence: self.intelligence,
                    speculativeIntelligence: false,
                    batchTranscriber: self.batch,
                    polishDeadline: .init(base: 1, perWord: 0, maximum: 1))
            },
            recover: { [unowned self] audio in
                guard let batch = self.batch else { throw TranscriptionError("no batch") }
                return try await batch.transcribe(audio, hints: .init()).text
            },
            policy: policy,
            log: { [logs] in logs.append($0) }
        )
    }

    func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(3)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met in time")
        throw TranscriptionError("timeout")
    }

    /// Tap, speak, tap again, and wait for the dictation to end.
    func dictate(_ pcm: Data) async throws {
        coordinator.toggle()
        try await waitUntil { self.transcribers.count > 0 }
        capture.speak(pcm)
        try await Task.sleep(for: .milliseconds(30))
        coordinator.toggle()
        try await waitUntil { self.coordinator.phase == .idle }
    }
}

// MARK: - Tests

@Suite("dictation coordinator")
@MainActor
struct CoordinatorTests {
    @Test func tapSpeakTapInsertsAndRecordsTheOutcome() async throws {
        let harness = Harness()
        harness.coordinator.stopTailMs = 0
        try await harness.dictate(voicedPCM(ms: 400))
        #expect(harness.inserter.inserted == ["Hello world."])
        #expect(harness.coordinator.lastTranscript == "Hello world.")
        #expect(harness.coordinator.history.entries.first?.outcome == .inserted)
        #expect(harness.coordinator.history.entries.first?.audio?.durationMs == 400)
        let outcome = try #require(harness.logs.outcome("inserted"))
        #expect(outcome.contains("chars=12") && outcome.contains("source=live") && outcome.contains("audio_ms=400"))
        #expect(harness.feedback.cues == [.start, .stop, .inserted])
    }

    @Test func liveFailureMidDictationStillInsertsTheRecoveredText() async throws {
        let harness = Harness()
        harness.coordinator.stopTailMs = 0
        harness.batch = FakeBatchTranscriber { _ in "Every word, recovered from audio." }
        harness.configure = { live, _ in
            live.onAudio = { live, _ in
                if live.audioBytes == 2 * PCM_CHUNK_BYTES {
                    live.emit(.error(code: "UNAVAILABLE", message: "socket dropped", retryable: true))
                }
            }
        }
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count > 0 }
        harness.capture.speak(voicedPCM(ms: 600))
        // The status is shown while listening; stop only once it has arrived.
        try await harness.waitUntil { harness.feedback.statuses.contains { $0.contains("still recording") } }
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.coordinator.phase == .idle }
        #expect(harness.inserter.inserted == ["Every word, recovered from audio."])
        #expect(harness.feedback.statuses.contains("Recovering transcript from audio…"))
        let outcome = try #require(harness.logs.outcome("inserted"))
        #expect(outcome.contains("source=batch") && outcome.contains("batch=live_failed"))
    }

    @Test func fatalErrorWhileListeningCopiesThePartialTranscriptAndKeepsAudio() async throws {
        let harness = Harness()
        harness.configure = { live, _ in
            live.onAudio = { live, _ in
                if live.audioBytes == PCM_CHUNK_BYTES { live.emit(.final(text: "Partial words.")) }
                if live.audioBytes == 3 * PCM_CHUNK_BYTES {
                    live.emit(.error(code: "PERMISSION_DENIED", message: "API key not valid.", retryable: false))
                }
            }
        }
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count > 0 }
        harness.capture.speak(voicedPCM(ms: 400))
        try await harness.waitUntil { harness.coordinator.phase == .idle }
        #expect(harness.inserter.copied == ["Partial words."])
        #expect(harness.feedback.errors.last?.contains("rejected the API key") == true)
        let entry = try #require(harness.coordinator.history.entries.first)
        #expect(entry.text == "Partial words.")
        #expect(entry.audio?.isEmpty == false)
        #expect(harness.logs.outcome("copied")?.contains("code=PERMISSION_DENIED") == true)
    }

    /// Finding #19: a finalize timer from an earlier dictation must not end a later one.
    @Test func staleFinalizeTimerCannotCutTheNextDictationShort() async throws {
        let harness = Harness()
        harness.policy = DictationCoordinatorPolicy(finalizeTimeout: 1.2, silentInputCheckAfter: 5)
        harness.coordinator.stopTailMs = 0
        harness.configure = { live, index in
            live.onFinish = { live in
                if index == 0 {
                    live.emit(.final(text: "First dictation."))
                    live.emit(.complete)
                    return
                }
                // The second dictation needs 0.9 s to finalize.
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    live.emit(.final(text: "Second dictation, slow to finalize."))
                    live.emit(.complete)
                }
            }
        }
        // First dictation: its wait arms a 1.2 s timer before the completion
        // event is delivered.
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count == 1 }
        harness.capture.speak(voicedPCM(ms: 80))
        try await Task.sleep(for: .milliseconds(20))
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.coordinator.phase == .idle }
        // Second dictation stops about 0.5 s later and finalizes at about 1.45 s;
        // the first timer fires at about 1.2 s, while this one is still waiting.
        try await Task.sleep(for: .milliseconds(300))
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count == 2 }
        harness.capture.speak(voicedPCM(ms: 80))
        try await Task.sleep(for: .milliseconds(200))
        harness.coordinator.toggle()
        try await harness.waitUntil({ harness.coordinator.phase == .idle }, timeout: .seconds(4))
        #expect(harness.inserter.inserted == ["First dictation.", "Second dictation, slow to finalize."])
        #expect(!harness.logs.all.contains { $0.contains("Finalization failed with buffered transcript") })
        #expect(!harness.logs.all.contains { $0.contains("finalize_timeout") })
    }

    @Test func escapeKeepsTheDictationInHistory() async throws {
        let harness = Harness()
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count > 0 }
        harness.capture.speak(voicedPCM(ms: 200))
        try await harness.waitUntil { harness.feedback.texts.last == "hello" }
        harness.coordinator.cancel()
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.inserter.inserted.isEmpty)
        let entry = try #require(harness.coordinator.history.entries.first)
        #expect(entry.outcome == .cancelled)
        #expect(entry.text == "hello")
        harness.coordinator.copyLastTranscript()
        #expect(harness.inserter.copied == ["hello"])
        await harness.coordinator.pasteLastTranscript()
        #expect(harness.inserter.inserted == ["hello"])
    }

    @Test func retryLastDictationTranscribesTheSavedAudio() async throws {
        let harness = Harness()
        harness.coordinator.stopTailMs = 0
        harness.configure = { live, _ in
            live.onFinish = { live in
                live.emit(.error(code: "final_transcript_timeout", message: "Gemini did not finalize.", retryable: true))
            }
        }
        try await harness.dictate(voicedPCM(ms: 400))
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.coordinator.history.lastRecording != nil)
        harness.batch = FakeBatchTranscriber { audio in "Recovered \(audio.durationMs) ms." }
        await harness.coordinator.retryLastDictation()
        #expect(harness.inserter.inserted == ["Recovered 400 ms."])
        #expect(harness.coordinator.history.entries.first?.detail == "Retried from audio")
    }

    @Test func unconfirmedPasteIsReportedAndRecorded() async throws {
        let harness = Harness()
        harness.coordinator.stopTailMs = 0
        harness.inserter.reportNotInserted = true
        try await harness.dictate(voicedPCM(ms: 200))
        #expect(harness.coordinator.history.entries.first?.outcome == .pasteUnconfirmed)
        #expect(harness.feedback.notifications.last?.contains("press ⌘V") == true)
        #expect(harness.logs.all.contains { $0.contains("result=paste_unconfirmed") })
    }

    @Test func pasteFailureFallsBackToTheClipboard() async throws {
        let harness = Harness()
        harness.coordinator.stopTailMs = 0
        harness.inserter.failInsert = true
        try await harness.dictate(voicedPCM(ms: 200))
        #expect(harness.inserter.copied == ["Hello world."])
        #expect(harness.coordinator.history.entries.first?.outcome == .copied)
        #expect(harness.logs.outcome("copied")?.contains("code=paste_failed") == true)
    }

    @Test func silenceIsReportedAsNoSpeechFromTheDevice() async throws {
        let harness = Harness()
        harness.coordinator.stopTailMs = 0
        harness.configure = { live, _ in }
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count > 0 }
        harness.capture.speak(silentPCM(ms: 400))
        try await harness.waitUntil { harness.feedback.statuses.contains { $0.contains("No signal from Fake Mic") } }
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.coordinator.phase == .idle }
        #expect(harness.coordinator.lastError.contains("No speech detected from Fake Mic"))
        #expect(harness.logs.outcome("empty")?.contains("code=no_speech") == true)
    }

    @Test func sleepInterruptsWithoutPastingAndKeepsTheRecording() async throws {
        let harness = Harness()
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count > 0 }
        harness.capture.speak(voicedPCM(ms: 200))
        try await harness.waitUntil { harness.feedback.texts.last == "hello" }
        harness.coordinator.interrupt(reason: "sleep")
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.coordinator.history.entries.first?.outcome == .interrupted)
        #expect(harness.coordinator.history.lastRecording?.audio?.durationMs == 200)
    }

    @Test func keyDownPreconnectsAndADiscardedGestureClosesTheSession() async throws {
        let harness = Harness()
        harness.coordinator.prepareHotkeyCapture()
        try await harness.waitUntil { harness.transcribers.count == 1 }
        #expect(harness.capture.startCount == 1)
        harness.coordinator.discardHotkeyCapture()
        #expect(harness.transcribers[0].closed)
        #expect(harness.coordinator.phase == .idle)

        // A confirmed tap adopts the pre-connected session instead of opening another.
        harness.coordinator.prepareHotkeyCapture()
        try await harness.waitUntil { harness.transcribers.count == 2 }
        harness.capture.speak(voicedPCM(ms: 80))
        harness.coordinator.toggle()
        #expect(harness.transcribers.count == 2)
        try await harness.waitUntil { harness.transcribers[1].audioBytes == 80 * PCM_BYTES_PER_MILLISECOND }
        harness.coordinator.cancel()
    }

    @Test func missingKeyFailsToStartWithAClearMessage() async throws {
        let harness = Harness()
        harness.missingKey = true
        harness.coordinator.toggle()
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.coordinator.lastError == "Add a Gemini API key in Settings.")
        #expect(harness.capture.pauseCount >= 1)
    }

    @Test func optimisticInsertIsRepairedInPlace() async throws {
        let harness = Harness()
        harness.polish = true
        harness.intelligence = ClosureIntelligence { text in
            try await Task.sleep(for: .milliseconds(150))
            return IntelligenceResult(text: "Hello, world!", model: "m", latencyMs: 150)
        }
        harness.coordinator.stopTailMs = 0
        harness.coordinator.optimisticPaste = true
        try await harness.dictate(voicedPCM(ms: 200))
        #expect(harness.inserter.inserted == ["Hello world."])
        #expect(harness.inserter.replacements.count == 1)
        #expect(harness.inserter.replacements.first?.0 == "Hello world.")
        #expect(harness.inserter.replacements.first?.1 == "Hello, world!")
    }

    @Test func userInputAfterOptimisticInsertSkipsTheRepair() async throws {
        let harness = Harness()
        harness.polish = true
        harness.intelligence = ClosureIntelligence { _ in
            try await Task.sleep(for: .milliseconds(300))
            return IntelligenceResult(text: "Hello, world!", model: "m", latencyMs: 300)
        }
        harness.coordinator.stopTailMs = 0
        harness.coordinator.optimisticPaste = true
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.transcribers.count > 0 }
        harness.capture.speak(voicedPCM(ms: 200))
        try await Task.sleep(for: .milliseconds(30))
        harness.coordinator.toggle()
        try await harness.waitUntil { harness.inserter.watching }
        harness.inserter.simulateUserTyping()
        try await harness.waitUntil { harness.coordinator.phase == .idle }
        #expect(harness.inserter.inserted == ["Hello world."])
        #expect(harness.inserter.replacements.isEmpty)
        #expect(harness.logs.all.contains { $0.contains("Repair skipped") })
    }

    @Test func historyKeepsAudioOnlyForTheMostRecentEntries() {
        var history = TranscriptHistory(capacity: 4, audioCapacity: 2)
        for index in 0..<6 {
            history.record(TranscriptHistoryEntry(text: "t\(index)", targetName: nil, outcome: .inserted,
                audio: RecordedAudio(pcm: voicedPCM(ms: 40))))
        }
        #expect(history.entries.map(\.text) == ["t5", "t4", "t3", "t2"])
        #expect(history.entries.map { $0.audio != nil } == [true, true, false, false])
        #expect(history.lastText == "t5")
    }
}
