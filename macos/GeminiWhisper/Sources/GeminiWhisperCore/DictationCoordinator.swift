import Foundation
import Observation

/// The app a dictation started in, identified by process rather than display name.
public struct InsertionTarget: Sendable, Equatable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String?
    public var name: String

    public init(processIdentifier: Int32, bundleIdentifier: String?, name: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

public enum InsertionReport: Sendable, Equatable {
    /// The paste shortcut was posted into the focused app.
    case pasted
    /// The text was left on the clipboard instead, for the stated reason.
    case copied(reason: String)
}

/// Delivers text into other apps. Implemented with the pasteboard and
/// Accessibility on macOS; faked in tests.
@MainActor
public protocol TextInserting: AnyObject {
    func currentTarget() -> InsertionTarget?
    /// Paste `text` into the focused app. When the inserter later finds the paste
    /// did not land, it leaves the text on the clipboard and calls `onNotInserted`.
    func insert(_ text: String, expected: InsertionTarget?,
                onNotInserted: @escaping @MainActor @Sendable (String) -> Void) async throws -> InsertionReport
    /// Replace text this app just inserted. Returns false when the inserted text
    /// cannot be verified in place; the caller then leaves it untouched.
    func replaceInserted(_ inserted: String, with replacement: String, target: InsertionTarget?) async throws -> Bool
    func copy(_ text: String) throws
    /// Report the first real keyboard or mouse input in any app.
    func startUserInputWatch(_ onInput: @escaping @MainActor @Sendable () -> Void)
    func stopUserInputWatch()
}

/// Microphone capture delivering 16 kHz PCM16 mono.
@MainActor
public protocol AudioCapturing: AnyObject {
    var deviceName: String { get }
    /// Begin delivering PCM to `handler`, which may run on any thread.
    func startCapture(_ handler: @escaping @Sendable (Data) -> Void) throws
    /// Stop delivering. Returns after any in-flight block has been handed off.
    func pauseCapture()
}

public enum DictationCue: Sendable, Equatable {
    case start, stop, inserted, copied, error
}

/// HUD, sounds, and notifications.
@MainActor
public protocol DictationFeedback: AnyObject {
    func showListening()
    func hide()
    func showText(_ text: String)
    func showStatus(_ text: String)
    func showFinalizing()
    /// Shows the message briefly, then hides.
    func showError(_ message: String)
    func nudge()
    func setLevel(_ rms: Double)
    func play(_ cue: DictationCue)
    func notify(_ message: String)
}

/// Builds the session for one dictation. Throws a readable error when the app
/// cannot start one (for example, no API key).
public typealias DictationSessionFactory = @MainActor (@escaping (ServerEvent) -> Void) throws -> DictationSession

/// Transcribes saved audio for "Retry Last Dictation".
public typealias RecordingRecovery = @MainActor (RecordedAudio) async throws -> String

public struct DictationCoordinatorPolicy: Sendable {
    /// Wait for Live to finalize after stop.
    public var finalizeTimeout: TimeInterval
    /// Wait once recovery from the recording has started.
    public var recoveryTimeout: TimeInterval
    /// When to check whether the microphone delivers any signal at all.
    public var silentInputCheckAfter: TimeInterval
    /// Peak RMS below this for the whole check window means digital silence.
    public var silentInputPeakRms: Double
    /// Speech below this is reported as "no speech" rather than "no transcript".
    public var minimumVoicedMsForSpeech: Int
    /// Delay before watching for user input after an optimistic paste, so our own
    /// synthetic Cmd+V does not count.
    public var userInputWatchDelay: TimeInterval

    public init(finalizeTimeout: TimeInterval = 25, recoveryTimeout: TimeInterval = 120,
                silentInputCheckAfter: TimeInterval = 2.5, silentInputPeakRms: Double = 0.0005,
                minimumVoicedMsForSpeech: Int = 300, userInputWatchDelay: TimeInterval = 0.15) {
        self.finalizeTimeout = finalizeTimeout
        self.recoveryTimeout = recoveryTimeout
        self.silentInputCheckAfter = silentInputCheckAfter
        self.silentInputPeakRms = silentInputPeakRms
        self.minimumVoicedMsForSpeech = minimumVoicedMsForSpeech
        self.userInputWatchDelay = userInputWatchDelay
    }
}

/// Owns one dictation at a time: hotkey gestures, capture, the Gemini session,
/// finalization, delivery, and history. Platform work goes through the protocols
/// above, so the whole lifecycle runs in tests.
@MainActor
@Observable
public final class DictationCoordinator {
    public enum Phase: String, Sendable {
        case idle, listening, finalizing
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastError = ""
    public private(set) var lastTranscript = ""
    public private(set) var interimPreview = ""
    public private(set) var lastPolishLatencyMs = 0
    public private(set) var history = TranscriptHistory()
    public private(set) var isRecovering = false

    /// Settings the app may change between dictations.
    public var stopTailMs = 400
    public var optimisticPaste = false

    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let inserter: any TextInserting
    @ObservationIgnored private let feedback: any DictationFeedback
    @ObservationIgnored private let makeSession: DictationSessionFactory
    @ObservationIgnored private let recover: RecordingRecovery?
    @ObservationIgnored private let policy: DictationCoordinatorPolicy
    @ObservationIgnored private let log: (String) -> Void

    @ObservationIgnored private var nextGeneration = 0
    @ObservationIgnored private var activeGeneration = -1
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var chunker = PcmChunker()
    @ObservationIgnored private var audioStream: PCMDeliveryStream?
    @ObservationIgnored private var preCapture = false
    @ObservationIgnored private var prepared: (generation: Int, session: DictationSession)?
    @ObservationIgnored private var preparedEvents: [ServerEvent] = []
    @ObservationIgnored private var heldGestureActive = false
    @ObservationIgnored private var heldGestureStartedSession = false
    @ObservationIgnored private var target: InsertionTarget?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var didComplete = false
    @ObservationIgnored private var rawDraft = ""
    @ObservationIgnored private var polishedText = ""
    @ObservationIgnored private var polishedInput = ""
    @ObservationIgnored private var pipelineTiming: DictationTiming?
    @ObservationIgnored private var completion: (token: UUID, continuation: CheckedContinuation<Void, Error>)?
    @ObservationIgnored private var lastVoicedUptime: TimeInterval = 0
    @ObservationIgnored private var captureStartedUptime: TimeInterval = 0
    @ObservationIgnored private var peakRms = 0.0
    @ObservationIgnored private var levelFrame = 0
    @ObservationIgnored private var stopRequestedUptime: TimeInterval = 0
    @ObservationIgnored private var pressedUptime: TimeInterval = 0
    @ObservationIgnored private var speculativeHits = 0
    /// Text already inserted while polish was still running, plus where it went.
    @ObservationIgnored private var optimisticInsert: (text: String, target: InsertionTarget?)?
    @ObservationIgnored private var repairAborted = false
    @ObservationIgnored private var lastLiveWarning = ""

    public init(
        capture: any AudioCapturing,
        inserter: any TextInserting,
        feedback: any DictationFeedback,
        makeSession: @escaping DictationSessionFactory,
        recover: RecordingRecovery? = nil,
        policy: DictationCoordinatorPolicy = .init(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.capture = capture
        self.inserter = inserter
        self.feedback = feedback
        self.makeSession = makeSession
        self.recover = recover
        self.policy = policy
        self.log = log
    }

    public var statusTitle: String {
        switch phase {
        case .idle: return lastError.isEmpty ? "Idle" : "Error"
        case .listening: return "Listening"
        case .finalizing: return "Finalizing"
        }
    }

    // MARK: - Gestures

    /// Tap: start, or stop and insert. `pressedAt` is the key-down uptime, for felt latency.
    public func toggle(pressedAt: TimeInterval = 0) {
        pressedUptime = pressedAt
        switch phase {
        case .idle:
            startDictation()
        case .listening:
            beginStop()
        case .finalizing:
            // Swallowed by design (stop already in flight), but say so: a
            // silent keypress reads as a dead hotkey in the logs and the HUD.
            log("Toggle ignored; still finalizing.")
            feedback.nudge()
        }
    }

    public func beginHeldDictation(pressedAt: TimeInterval = 0) {
        let wasIdle = phase == .idle
        pressedUptime = pressedAt
        if wasIdle { startDictation() }
        guard phase == .listening else { return }
        heldGestureActive = true
        heldGestureStartedSession = wasIdle
    }

    public func finishHeldDictation(pressedAt: TimeInterval = 0) {
        guard heldGestureActive else { return }
        heldGestureActive = false
        heldGestureStartedSession = false
        pressedUptime = pressedAt
        if phase == .listening { beginStop() }
    }

    public func cancelHeldDictation() {
        let shouldCancel = heldGestureActive && heldGestureStartedSession
        heldGestureActive = false
        heldGestureStartedSession = false
        if shouldCancel { cancel() } else { discardHotkeyCapture() }
    }

    /// Escape. Whatever was said stays in history, so a stray Escape is recoverable.
    public func cancel() {
        heldGestureActive = false
        heldGestureStartedSession = false
        discardHotkeyCapture()
        guard phase != .idle else { return }
        log("Dictation cancelled (Escape).")
        abandon(outcome: .cancelled, detail: "Escape")
        feedback.play(.stop)
    }

    /// The Mac is going to sleep: keep what exists in history instead of pasting
    /// into whatever is focused after wake.
    public func interrupt(reason: String) {
        discardHotkeyCapture()
        guard phase != .idle else { return }
        log("Dictation interrupted (\(reason)).")
        abandon(outcome: .interrupted, detail: reason)
        feedback.notify("Dictation stopped (\(reason)). Use Paste Last Transcript or Retry Last Dictation to recover it.")
    }

    private func abandon(outcome: TranscriptHistoryEntry.Outcome, detail: String) {
        cancelled = true
        // An optimistic insert already typed into the target is not ours to retract.
        optimisticInsert = nil
        endRepairWatch()
        audioStream?.discard()
        audioStream = nil
        let generation = activeGeneration
        activeGeneration = -1
        finishWait(with: nil)
        capture.pauseCapture()
        let text = draftText()
        let audio = session?.recordedAudio
        session?.cancel()
        session?.close()
        session = nil
        feedback.hide()
        phase = .idle
        if !text.isEmpty || audio?.voicedMs ?? 0 > 0 {
            history.record(TranscriptHistoryEntry(text: text, targetName: target?.name, outcome: outcome, detail: detail, audio: audio))
        }
        logOutcome(generation: generation, result: outcome.rawValue, code: detail, text: text, audio: audio)
        target = nil
    }

    // MARK: - Hotkey pre-capture and pre-connect

    /// Key-down: capture locally and start connecting, so a confirmed tap or hold
    /// loses neither its first words nor the connection setup time.
    public func prepareHotkeyCapture() {
        guard phase == .idle, !preCapture else { return }
        let stream = PCMDeliveryStream()
        audioStream = stream
        do {
            try capture.startCapture { stream.append($0) }
            preCapture = true
        } catch {
            stream.discard()
            audioStream = nil
            return
        }
        preconnect()
    }

    /// Key used as a modifier, or released without a gesture.
    public func discardHotkeyCapture() {
        guard preCapture, phase == .idle else { return }
        capture.pauseCapture()
        audioStream?.discard()
        audioStream = nil
        preCapture = false
        if let prepared {
            prepared.session.close()
            self.prepared = nil
            preparedEvents.removeAll()
        }
    }

    private func preconnect() {
        guard prepared == nil else { return }
        nextGeneration += 1
        let generation = nextGeneration
        guard let session = try? makeSession({ [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(event, generation: generation) }
            }
        }) else { return }
        prepared = (generation, session)
        preparedEvents.removeAll()
        Task { try? await session.start() }
    }

    // MARK: - Start

    private func startDictation() {
        cancelled = false
        resetTranscriptState()
        target = inserter.currentTarget()
        feedback.showListening()
        feedback.play(.start)
        phase = .listening
        log("Starting dictation.")

        if !preCapture {
            let stream = PCMDeliveryStream()
            audioStream = stream
            do {
                try capture.startCapture { stream.append($0) }
            } catch {
                failStart(error.localizedDescription)
                return
            }
        }
        preCapture = false

        let generation: Int
        if let prepared {
            generation = prepared.generation
            session = prepared.session
            self.prepared = nil
            activeGeneration = generation
            let replay = preparedEvents
            preparedEvents.removeAll()
            for event in replay { handle(event) }
            guard phase == .listening else { return }
        } else {
            nextGeneration += 1
            generation = nextGeneration
            do {
                let created = try makeSession({ [weak self] event in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.receive(event, generation: generation) }
                    }
                })
                session = created
                activeGeneration = generation
                Task { try? await created.start() }
            } catch {
                failStart(redactApiKeys((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                return
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        lastVoicedUptime = now
        captureStartedUptime = now
        audioStream?.commit { [weak self] block in
            MainActor.assumeIsolated { self?.deliverAudio(block.pcm, generation: generation) }
        }
        scheduleSilentInputCheck(generation: generation)
    }

    private func deliverAudio(_ pcm: Data, generation: Int) {
        guard activeGeneration == generation, !cancelled, phase != .idle, let session else { return }
        let rms = pcmRootMeanSquare(pcm)
        peakRms = max(peakRms, rms)
        if rms >= PCM_VOICED_RMS_THRESHOLD {
            lastVoicedUptime = ProcessInfo.processInfo.systemUptime
        }
        levelFrame += 1
        if levelFrame % 2 == 0 { feedback.setLevel(rms) }
        for frame in chunker.push(pcm) {
            do { try session.sendAudio(frame) } catch {
                log("Audio frame rejected: \(redactApiKeys(error.localizedDescription))")
            }
        }
    }

    /// A muted or wrong input delivers digital silence; say so while the user can
    /// still fix it instead of after a failed dictation.
    private func scheduleSilentInputCheck(generation: Int) {
        let delay = policy.silentInputCheckAfter
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, self.activeGeneration == generation, self.phase == .listening else { return }
            guard self.peakRms < self.policy.silentInputPeakRms else { return }
            self.log("No microphone signal from \(self.capture.deviceName) after \(Int(delay * 1000)) ms (peak RMS \(self.peakRms)).")
            self.feedback.showStatus("No signal from \(self.capture.deviceName) — check the microphone")
        }
    }

    // MARK: - Stop

    private func beginStop() {
        guard phase == .listening, let session else { return }
        phase = .finalizing
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        feedback.showFinalizing()
        feedback.play(.stop)
        log("Stopping and finalizing dictation.")
        session.prepareToStop(at: stopRequestedUptime)
        // The tail exists to catch words still in flight at key-release. Silence
        // already observed since the last voiced frame counts against it, so a
        // release after a natural pause pays nothing.
        let tailMs = max(0, stopTailMs)
        let silentMs = Int(max(0, stopRequestedUptime - lastVoicedUptime) * 1000)
        let waitMs = max(0, tailMs - silentMs)
        let generation = activeGeneration
        Task {
            if waitMs > 0 {
                try? await Task.sleep(for: .milliseconds(waitMs))
            }
            guard self.activeGeneration == generation, !self.cancelled else { return }
            self.capture.pauseCapture()
            let boundary = await self.audioStream?.drain() ?? 0
            guard self.activeGeneration == generation, !self.cancelled, let session = self.session else { return }
            self.log("Audio drained through sample \(boundary), \(self.millisecondsSince(self.stopRequestedUptime)) ms after stop (tail \(waitMs) of \(tailMs) ms, \(silentMs) ms already silent).")
            do {
                if let tail = self.chunker.flush(), !tail.isEmpty {
                    try session.sendAudio(tail)
                }
                try session.stop()
                self.feedback.showStatus("Waiting for transcript…")
            } catch {
                self.log("Stop failed: \(redactApiKeys(error.localizedDescription))")
                if !self.draftText().isEmpty {
                    await self.insertResult(generation: generation)
                } else {
                    self.handleFailure(redactApiKeys(error.localizedDescription), code: "stop_failed")
                }
                return
            }
            do {
                try await self.waitForCompletion(generation: generation)
                guard self.activeGeneration == generation, !self.cancelled else { return }
                await self.insertResult(generation: generation)
            } catch {
                guard self.activeGeneration == generation, !self.cancelled else { return }
                if !self.draftText().isEmpty || !self.polishedText.isEmpty {
                    self.log("Finalization failed with buffered transcript; inserting anyway.")
                    await self.insertResult(generation: generation)
                } else {
                    self.handleFailure(redactApiKeys(error.localizedDescription), code: (error as? CoordinatorError)?.code ?? "finalize_failed")
                }
            }
        }
    }

    // MARK: - Session events

    private func receive(_ event: ServerEvent, generation: Int) {
        if generation == activeGeneration {
            handle(event)
        } else if generation == prepared?.generation {
            // The pre-connected session reports before the gesture is confirmed.
            preparedEvents.append(event)
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .transcript(let text):
            rawDraft = text
            if phase == .listening { showDraft() }
        case .polished(let text, _, let latencyMs, let speculative, let source):
            polishedText = text
            polishedInput = source
            lastPolishLatencyMs = latencyMs
            // Only while listening: the final reuse emit after stop is also
            // speculative-flagged but proves nothing about speak-time overlap.
            if speculative == true, phase == .listening { speculativeHits += 1 }
            if phase == .listening { showDraft() }
        case .provisional(let text):
            handleProvisional(text)
        case .polishProgress(let text):
            // Preview only: never feeds draftText(), so a partial stream can
            // never be the text that gets pasted.
            guard phase == .finalizing, !text.isEmpty else { return }
            feedback.showText(text)
            feedback.showStatus("Polishing…")
        case .timing(let timing):
            pipelineTiming = timing
            if timing.outcome.hasPrefix("raw_") {
                polishedText = ""
                polishedInput = ""
                lastPolishLatencyMs = 0
            }
        case .complete, .cancelled:
            didComplete = true
            finishWait(with: nil)
        case .error(let code, let message, let retryable):
            let detail = message.isEmpty ? code : "\(code): \(message)"
            if phase == .listening {
                // DictationSession absorbs transport failures; an error while
                // listening means it cannot continue (for example, a rejected key).
                handleFailure(detail, code: code)
            } else {
                finishWait(with: CoordinatorError(code: code, message: detail, retryable: retryable))
            }
        case .warning(let code, let message):
            log("\(code): \(message)")
            switch code {
            case "live_degraded":
                lastLiveWarning = code
                if phase == .listening { feedback.showStatus("Connection lost — still recording; will transcribe when you stop") }
            case "batch_start":
                feedback.showStatus("Recovering transcript from audio…")
                extendWait(by: policy.recoveryTimeout)
            default:
                break
            }
        case .connecting:
            log("Gemini Live connecting; microphone audio is buffering.")
            if phase == .listening, !rawDraft.isEmpty { feedback.showStatus("Reconnecting…") }
        case .ready:
            log("Gemini Live ready.")
            if phase == .listening, lastLiveWarning.isEmpty { feedback.showStatus("Listening…") }
        default:
            break
        }
    }

    private func showDraft() {
        let text = draftText()
        interimPreview = text
        feedback.showText(text)
    }

    // MARK: - Optimistic insert and repair

    /// Raw transcript settled while polish is still running. Insert it now so the
    /// user sees text at raw-mode latency; insertResult() repairs it in place when
    /// the polished version lands. Opt-in: the repair only proceeds when the
    /// inserter can verify the inserted text is still there, untouched.
    private func handleProvisional(_ text: String) {
        guard optimisticPaste, phase == .finalizing, optimisticInsert == nil, !cancelled, !text.isEmpty else { return }
        let expected = target
        let generation = activeGeneration
        optimisticInsert = (text, expected)
        repairAborted = false
        Task {
            guard self.activeGeneration == generation, !self.cancelled else { return }
            do {
                let report = try await self.inserter.insert(text, expected: expected) { [weak self] _ in
                    // The raw text never landed, so there is nothing to repair.
                    self?.optimisticInsert = nil
                }
                guard report == .pasted else {
                    self.optimisticInsert = nil
                    return
                }
                self.log("Optimistic insert of \(text.count) characters in \(self.millisecondsSince(self.stopRequestedUptime)) ms after stop; awaiting polish.")
                self.feedback.showStatus("Polishing inserted text…")
                self.beginRepairWatch()
            } catch {
                self.optimisticInsert = nil
                self.log("Optimistic insert failed: \(redactApiKeys(error.localizedDescription)); falling back to a single paste.")
            }
        }
    }

    /// Any real keystroke or click after the optimistic insert invalidates the
    /// text the repair depends on. Start watching only after our own synthetic
    /// Cmd+V has flushed, so it does not abort on itself.
    private func beginRepairWatch() {
        endRepairWatch()
        let delay = policy.userInputWatchDelay
        Task {
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard self.optimisticInsert != nil, !self.repairAborted else { return }
            self.inserter.startUserInputWatch { [weak self] in
                guard let self, !self.repairAborted else { return }
                self.repairAborted = true
                self.log("Repair aborted; the user typed or clicked after the optimistic insert.")
            }
        }
    }

    private func endRepairWatch() {
        inserter.stopUserInputWatch()
    }

    // MARK: - Delivery

    private func insertResult(generation: Int) async {
        let text = draftText()
        let timing = pipelineTiming
        let stopTime = stopRequestedUptime
        let usedPolish = !polishedText.isEmpty && transcriptsCompatible(polishedInput, rawDraft)
        let audio = session?.recordedAudio
        capture.pauseCapture()
        audioStream?.discard()
        audioStream = nil
        session?.close()
        session = nil
        activeGeneration = -1
        phase = .idle
        let expected = target
        target = nil
        lastTranscript = text
        interimPreview = ""
        feedback.hide()

        guard !text.isEmpty else {
            let voiced = timing?.voicedMs ?? audio?.voicedMs ?? 0
            let message = voiced < policy.minimumVoicedMsForSpeech
                ? "No speech detected from \(capture.deviceName). Check the input device, or run Audio Check."
                : "No transcript was returned. Use Retry Last Dictation to transcribe the audio again."
            lastError = message
            feedback.play(.error)
            feedback.notify(message)
            log("Dictation completed without text (voiced \(voiced) ms).")
            history.record(TranscriptHistoryEntry(text: "", targetName: expected?.name, outcome: .empty,
                detail: message, audio: voiced > 0 ? audio : nil))
            logOutcome(generation: generation, result: "empty", code: voiced < policy.minimumVoicedMsForSpeech ? "no_speech" : "no_transcript",
                       text: text, audio: audio)
            return
        }

        let entryID = history.record(TranscriptHistoryEntry(text: text, targetName: expected?.name, outcome: .inserted, audio: audio))
        do {
            let report = try await deliver(text, expected: expected, entryID: entryID, generation: generation)
            let stopToPasteMs = stopTime > 0 ? millisecondsSince(stopTime) : 0
            let pressToPaste = pressedUptime > 0 ? " (\(millisecondsSince(pressedUptime)) ms after press)" : ""
            let outcome = usedPolish
                ? (timing?.outcome ?? "polished_unverified")
                : (timing?.outcome.hasPrefix("raw_") == true ? timing!.outcome : "raw_fallback")
            let pasted = report == .pasted
            log("\(pasted ? "Inserted" : "Copied") \(text.count) characters in \(stopToPasteMs) ms after stop\(pressToPaste) outcome=\(outcome).")
            if let timing {
                let deliveryMs = Int((max(0, ProcessInfo.processInfo.systemUptime - timing.readyAt) * 1000).rounded())
                log("latency session=\(timing.sessionID) capture_ms=\(timing.captureMs) live_ms=\(timing.liveMs) polish_wait_ms=\(timing.polishWaitMs) delivery_ms=\(deliveryMs) total_ms=\(stopToPasteMs) outcome=\(outcome) background_jobs=\(timing.backgroundJobs) final_jobs=\(timing.finalJobs) live_fallback=\(timing.liveFallback) pasted=\(pasted)")
            }
            if case .copied(let reason) = report {
                history.update(entryID, outcome: .copied, detail: reason)
                feedback.play(.copied)
                feedback.notify("Copied \(text.count) characters to the clipboard (\(reason)). Press ⌘V to paste.")
                logOutcome(generation: generation, result: "copied", code: reason, text: text, audio: audio, stopToPasteMs: stopToPasteMs)
            } else {
                feedback.play(.inserted)
                logOutcome(generation: generation, result: "inserted", code: outcome, text: text, audio: audio, stopToPasteMs: stopToPasteMs)
            }
        } catch {
            feedback.play(.error)
            let detail = redactApiKeys(error.localizedDescription)
            do {
                try inserter.copy(text)
                lastError = "Paste failed; copied \(text.count) characters instead. \(detail)"
                history.update(entryID, outcome: .copied, detail: detail)
                logOutcome(generation: generation, result: "copied", code: "paste_failed", text: text, audio: audio)
            } catch {
                lastError = detail
                history.update(entryID, outcome: .failed, detail: detail)
                logOutcome(generation: generation, result: "failed", code: "paste_and_copy_failed", text: text, audio: audio)
            }
            feedback.notify(lastError)
            log("Paste failed (\(detail)).")
        }
    }

    /// When text was already inserted optimistically, replace just that text in
    /// place instead of pasting a second copy; when polish did not change it,
    /// nothing needs to happen at all.
    private func deliver(_ text: String, expected: InsertionTarget?, entryID: UUID, generation: Int) async throws -> InsertionReport {
        guard let pending = optimisticInsert else {
            return try await inserter.insert(text, expected: expected) { [weak self] text in
                self?.pasteDidNotLand(text, entryID: entryID, generation: generation)
            }
        }
        optimisticInsert = nil
        endRepairWatch()
        if pending.text == text {
            log("Repair unnecessary; polish matched the optimistic insert.")
            return .pasted
        }
        if repairAborted {
            log("Repair skipped; optimistic text left in place to avoid corrupting user edits.")
            return .pasted
        }
        do {
            if try await inserter.replaceInserted(pending.text, with: text, target: pending.target) {
                return .pasted
            }
            log("Repair declined; the inserted text could not be verified, so it was left in place.")
        } catch {
            // The optimistic text is already correct-enough raw output. Never
            // paste a second copy on top of it just because the repair failed.
            log("Repair failed: \(redactApiKeys(error.localizedDescription)); optimistic text left in place.")
        }
        return .pasted
    }

    private func pasteDidNotLand(_ text: String, entryID: UUID, generation: Int) {
        history.update(entryID, outcome: .pasteUnconfirmed, detail: "The focused app did not change after Cmd+V.")
        log("outcome_update session=\(generation) result=paste_unconfirmed chars=\(text.count)")
        feedback.play(.copied)
        feedback.notify("The paste didn't appear to land. The transcript is on the clipboard: press ⌘V.")
    }

    // MARK: - Recovery actions

    public func copyLastTranscript() {
        guard let text = history.lastText else { return }
        do {
            try inserter.copy(text)
            feedback.play(.copied)
        } catch {
            lastError = redactApiKeys(error.localizedDescription)
        }
    }

    public func pasteLastTranscript() async {
        guard phase == .idle, let text = history.lastText else { return }
        _ = try? await inserter.insert(text, expected: nil) { [weak self] _ in
            self?.feedback.notify("The paste didn't appear to land. The transcript is on the clipboard: press ⌘V.")
        }
    }

    public func copyHistoryEntry(_ id: UUID) {
        guard let text = history.entry(id)?.text, !text.isEmpty else { return }
        try? inserter.copy(text)
        feedback.play(.copied)
    }

    /// Transcribe the most recent saved recording again and insert the result.
    public func retryLastDictation() async {
        guard phase == .idle, !isRecovering, let recover, let entry = history.lastRecording, let audio = entry.audio else { return }
        isRecovering = true
        defer { isRecovering = false }
        feedback.showListening()
        feedback.showFinalizing()
        feedback.showStatus("Transcribing the saved recording…")
        let destination = inserter.currentTarget()
        do {
            let text = try await recover(audio).trimmingCharacters(in: .whitespacesAndNewlines)
            feedback.hide()
            guard !text.isEmpty else {
                feedback.showError("The saved recording contains no speech.")
                return
            }
            lastTranscript = text
            lastError = ""
            let entryID = history.record(TranscriptHistoryEntry(text: text, targetName: destination?.name, outcome: .inserted,
                detail: "Retried from audio", audio: audio))
            let report = try await inserter.insert(text, expected: destination) { [weak self] text in
                self?.pasteDidNotLand(text, entryID: entryID, generation: -1)
            }
            if case .copied(let reason) = report { history.update(entryID, outcome: .copied, detail: reason) }
            feedback.play(report == .pasted ? .inserted : .copied)
            log("outcome session=retry result=\(report == .pasted ? "inserted" : "copied") chars=\(text.count) audio_ms=\(audio.durationMs)")
        } catch {
            let detail = redactApiKeys(error.localizedDescription)
            lastError = "Retry failed: \(detail)"
            feedback.showError(lastError)
            feedback.notify(lastError)
            log("outcome session=retry result=failed code=\(detail)")
        }
    }

    // MARK: - Failure

    private func handleFailure(_ detail: String, code: String) {
        optimisticInsert = nil
        endRepairWatch()
        capture.pauseCapture()
        audioStream?.discard()
        audioStream = nil
        let text = draftText()
        let audio = session?.recordedAudio
        session?.close()
        session = nil
        let generation = activeGeneration
        activeGeneration = -1
        phase = .idle
        let targetName = target?.name
        target = nil
        interimPreview = ""
        // Whatever was transcribed before the failure is the user's text: put it
        // where they can paste it rather than discarding it.
        var copied = false
        if !text.isEmpty { copied = (try? inserter.copy(text)) != nil }
        let message = copied
            ? "\(detail) The partial transcript (\(text.count) characters) was copied to the clipboard."
            : "\(detail) The recording was kept; use Retry Last Dictation."
        lastError = code.isEmpty ? message : "\(code): \(message)"
        lastTranscript = text
        history.record(TranscriptHistoryEntry(text: text, targetName: targetName, outcome: copied ? .copied : .failed,
            detail: lastError, audio: audio))
        feedback.play(.error)
        feedback.showError(friendlyFailure(detail: detail, code: code))
        feedback.notify(friendlyFailure(detail: detail, code: code) + (copied ? " Partial transcript copied." : ""))
        log(lastError)
        logOutcome(generation: generation, result: copied ? "copied" : "failed", code: code, text: text, audio: audio)
    }

    private func failStart(_ message: String, code: String = "start_failed") {
        capture.pauseCapture()
        audioStream?.discard()
        audioStream = nil
        session?.close()
        session = nil
        let generation = activeGeneration
        activeGeneration = -1
        phase = .idle
        target = nil
        lastError = message
        feedback.play(.error)
        feedback.showError(message)
        feedback.notify(message)
        log("Dictation could not start: \(message)")
        logOutcome(generation: generation, result: "failed", code: code, text: "", audio: nil)
    }

    private func friendlyFailure(detail: String, code: String) -> String {
        if detail.contains("exceeded your current quota") {
            return "Gemini quota is temporarily unavailable. Try again after the quota resets."
        }
        if isAuthenticationFailure(detail) {
            return "Gemini rejected the API key. Update it in Settings."
        }
        let clipped = detail.count > 140 ? String(detail.prefix(137)) + "…" : detail
        return code.isEmpty ? "Dictation failed. \(clipped)" : "Dictation failed (\(code)). \(clipped)"
    }

    // MARK: - Completion wait

    private struct CoordinatorError: Error, LocalizedError {
        var code: String
        var message: String
        var retryable: Bool
        var errorDescription: String? { message }
    }

    /// Each wait owns a token; its timeout can only end that wait. A timer left
    /// over from an earlier dictation never cuts a later one short.
    private func waitForCompletion(generation: Int) async throws {
        if didComplete { return }
        let token = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if didComplete {
                continuation.resume()
                return
            }
            if let existing = completion {
                existing.continuation.resume(throwing: CancellationError())
            }
            completion = (token, continuation)
            armTimeout(token: token, seconds: policy.finalizeTimeout)
        }
    }

    private func armTimeout(token: UUID, seconds: TimeInterval) {
        Task {
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard self.completion?.token == token else { return }
            self.finishWait(with: CoordinatorError(
                code: "finalize_timeout",
                message: "Timed out waiting for Gemini to finalize the transcript.",
                retryable: true
            ))
        }
    }

    /// Recovery from the recording legitimately takes longer than Live finalization.
    private func extendWait(by seconds: TimeInterval) {
        guard let current = completion else { return }
        let token = UUID()
        completion = (token, current.continuation)
        armTimeout(token: token, seconds: seconds)
    }

    private func finishWait(with error: Error?) {
        guard let current = completion else { return }
        completion = nil
        if let error {
            current.continuation.resume(throwing: error)
        } else {
            current.continuation.resume()
        }
    }

    // MARK: - Helpers

    private func resetTranscriptState() {
        pipelineTiming = nil
        rawDraft = ""
        polishedText = ""
        polishedInput = ""
        lastPolishLatencyMs = 0
        speculativeHits = 0
        interimPreview = ""
        lastError = ""
        lastLiveWarning = ""
        didComplete = false
        chunker = PcmChunker()
        peakRms = 0
        levelFrame = 0
        stopRequestedUptime = 0
    }

    private func draftText() -> String {
        guard !polishedText.isEmpty else { return rawDraft }
        return transcriptsCompatible(polishedInput, rawDraft) ? polishedText : rawDraft
    }

    private func millisecondsSince(_ uptime: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - uptime) * 1000).rounded())
    }

    /// One line per dictation, so reliability is measurable from the log alone.
    private func logOutcome(generation: Int, result: String, code: String, text: String,
                            audio: RecordedAudio?, stopToPasteMs: Int? = nil) {
        let timing = pipelineTiming
        var fields = [
            "session=\(generation)",
            "result=\(result)",
            "code=\(code.isEmpty ? "none" : code.replacingOccurrences(of: " ", with: "_"))",
            "chars=\(text.count)",
            "source=\(timing?.transcriptSource ?? "none")",
            "batch=\(timing?.batchReason.isEmpty == false ? timing!.batchReason : "none")",
            "audio_ms=\(audio?.durationMs ?? 0)",
            "voiced_ms=\(audio?.voicedMs ?? 0)",
            "reconnects=\(timing?.liveReconnects ?? 0)",
            "rotations=\(timing?.liveRotations ?? 0)",
        ]
        if let stopToPasteMs { fields.append("stop_to_paste_ms=\(stopToPasteMs)") }
        log("outcome " + fields.joined(separator: " "))
    }
}
