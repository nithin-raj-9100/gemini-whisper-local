import AppKit
import Foundation
import GeminiWhisperCore
import Observation

@MainActor
@Observable
final class DictationController {
    enum Phase: String {
        case idle
        case listening
        case finalizing
    }

    private(set) var phase: Phase = .idle
    var lastError: String = ""
    var lastTranscript: String = ""
    var lastPolishLatencyMs: Int = 0
    var lastSpeculative: Bool = false
    var lastAudioCheck: AudioCheckResult?
    var interimPreview: String = ""

    let settings: AppSettings
    let permissions: PermissionsMonitor
    let hud: FloatingHUDController
    let capture = MicrophoneCapture()

    private var isStreamingAudio = false
    private var lastVoicedUptime: TimeInterval = 0
    private var audioStream: PCMDeliveryStream?
    private var preCapture = false
    private var heldGestureActive = false
    private var heldGestureStartedSession = false
    private var session: CoreDictationBox?
    private var targetApplication: String?
    private var cancelled = false
    private var didComplete = false
    private var finalSegments: [String] = []
    private var startsNewTurn = false
    private var latestInterim: String = ""
    private var polishedText: String = ""
    private var polishedInput: String = ""
    private var completion: CheckedContinuation<Void, Error>?
    private var stopRequestedAt: UInt64 = 0
    private var stopRequestedUptime: TimeInterval = 0
    private var pipelineTiming: DictationTiming?
    /// Key-down time of the tap that triggered this session (felt-latency anchor).
    private var togglePressedAt: UInt64 = 0
    private var sessionGeneration = 0
    /// Background polishes that completed while speaking (speculative receipts
    /// this session). Logged on the Inserted line: spec>0 proves post work overlapped speech.
    private var speculativeHits = 0

    init(settings: AppSettings, hud: FloatingHUDController, permissions: PermissionsMonitor) {
        self.settings = settings
        self.hud = hud
        self.permissions = permissions
    }

    var statusTitle: String {
        switch phase {
        case .idle: return lastError.isEmpty ? "Idle" : "Error"
        case .listening: return "Listening"
        case .finalizing: return "Finalizing"
        }
    }

    func prepareCapture() {
        do {
            capture.applyPreferredDevice(uniqueID: settings.audioDevice)
            try capture.prepare()
        } catch {
            lastError = error.localizedDescription
            AppLog.line("Microphone prepare failed: \(error.localizedDescription)")
        }
    }

    func toggle() {
        togglePressedAt = HotkeyMonitor.shared.lastTapDownTime
        switch phase {
        case .idle:
            startMicrophoneDictation()
        case .listening:
            beginStop()
        case .finalizing:
            // Swallowed by design (stop already in flight), but say so: a
            // silent keypress reads as a dead hotkey in the logs and the HUD.
            AppLog.line("Toggle ignored; still finalizing.")
            hud.nudge()
        }
    }

    func beginHeldDictation() {
        let wasIdle = phase == .idle
        if wasIdle { startMicrophoneDictation() }
        guard phase == .listening else { return }
        heldGestureActive = true
        heldGestureStartedSession = wasIdle
    }

    func finishHeldDictation() {
        guard heldGestureActive else { return }
        heldGestureActive = false
        heldGestureStartedSession = false
        togglePressedAt = HotkeyMonitor.shared.lastTapDownTime
        if phase == .listening { beginStop() }
    }

    func cancelHeldDictation() {
        let shouldCancel = heldGestureActive && heldGestureStartedSession
        heldGestureActive = false
        heldGestureStartedSession = false
        if shouldCancel { cancel() }
        else { discardHotkeyCapture() }
    }

    func cancel() {
        heldGestureActive = false
        heldGestureStartedSession = false
        discardHotkeyCapture()
        guard phase != .idle else { return }
        AppLog.line("Dictation cancelled (Escape).")
        cancelled = true
        isStreamingAudio = false
        audioStream?.discard()
        sessionGeneration += 1
        finishWait(with: nil)
        capture.pause()
        session?.cancel()
        session?.close()
        session = nil
        hud.hide()
        phase = .idle
        targetApplication = nil
        SoundPlayer.play(.pop)
    }

    func runAudioCheck() async {
        guard phase == .idle else {
            lastAudioCheck = AudioCheckResult(
                source: "AVAudioEngine",
                bytes: 0,
                rms: 0,
                peak: 0,
                error: "Dictation is active."
            )
            return
        }
        discardHotkeyCapture()
        lastAudioCheck = await capture.audioCheck()
    }

    /// Key-down captures locally; a tap or sustained hold commits buffered audio.
    func prepareHotkeyCapture() {
        guard phase == .idle, !preCapture else { return }
        let stream = PCMDeliveryStream()
        audioStream = stream
        capture.setPCMHandler { stream.append($0) }
        do {
            capture.applyPreferredDevice(uniqueID: settings.audioDevice)
            try capture.prepare()
            try capture.start()
            preCapture = true
        } catch {
            stream.discard()
            audioStream = nil
        }
    }

    func discardHotkeyCapture() {
        guard preCapture, phase == .idle else { return }
        capture.pause()
        audioStream?.discard()
        audioStream = nil
        preCapture = false
    }

    private func startMicrophoneDictation() {
        guard let apiKey = requireAPIKey() else { discardHotkeyCapture(); return }
        cancelled = false
        resetTranscriptState()
        targetApplication = PasteController.frontmostApplication()
        hud.show()
        hud.setState("listening")
        SoundPlayer.play(.tink)
        phase = .listening
        isStreamingAudio = true
        lastError = ""
        AppLog.line("Option: starting dictation.")

        if !preCapture {
            let stream = PCMDeliveryStream()
            audioStream = stream
            capture.setPCMHandler { stream.append($0) }
            do {
                capture.applyPreferredDevice(uniqueID: settings.audioDevice)
                try capture.prepare()
                try capture.start()
            } catch { failStart(error.localizedDescription); return }
        }
        preCapture = false
        startSession(apiKey: apiKey)
        let generation = sessionGeneration
        lastVoicedUptime = ProcessInfo.processInfo.systemUptime
        audioStream?.commit { [weak self] block in
            guard let self, self.sessionGeneration == generation, !self.cancelled else { return }
            if pcmRootMeanSquare(block.pcm) >= PCM_VOICED_RMS_THRESHOLD {
                self.lastVoicedUptime = ProcessInfo.processInfo.systemUptime
            }
            do { try self.session?.sendAudio(block.pcm) }
            catch { self.handleAudioSendFailure(AppLog.redact(error.localizedDescription)) }
        }
    }

    private func startSession(apiKey: String) {
        let generation = sessionGeneration + 1
        sessionGeneration = generation
        do {
            let config = try CoreConfigFactory.make(settings: settings)
            let box = CoreDictationBox(
                apiKey: apiKey,
                config: config,
                intelligenceModel: settings.environment.intelligenceModel,
                patchEditing: settings.environment.patchEditing
            ) { [weak self] event in
                DispatchQueue.main.async {
                    self?.handle(event, generation: generation)
                }
            }
            session = box
            Task {
                do {
                    try await box.connect()
                } catch {
                    if self.sessionGeneration == generation, !self.cancelled {
                        self.failStart(AppLog.redact(error.localizedDescription))
                    }
                }
            }
        } catch {
            failStart(error.localizedDescription)
        }
    }

    private func beginStop() {
        guard phase == .listening else { return }
        phase = .finalizing
        stopRequestedAt = mach_absolute_time()
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        hud.setState("polishing")
        SoundPlayer.play(.pop)
        AppLog.line("Option: stopping and polishing dictation.")
        session?.prepareToStop(at: stopRequestedUptime)
        // The tail exists to catch words still in flight at key-release. Silence
        // already observed since the last voiced frame counts against it, so a
        // release after a natural pause pays nothing.
        let tailMs = max(0, settings.stopTailMs)
        let silentMs = Int(max(0, stopRequestedUptime - lastVoicedUptime) * 1000)
        let tailNs = UInt64(max(0, tailMs - silentMs)) * 1_000_000
        let generation = sessionGeneration
        Task {
            if tailNs > 0 {
                try? await Task.sleep(nanoseconds: tailNs)
            }
            guard self.sessionGeneration == generation, !self.cancelled else { return }
            self.capture.pause()
            let boundary = await self.audioStream?.drain() ?? 0
            guard self.sessionGeneration == generation, !self.cancelled else { return }
            self.isStreamingAudio = false
            AppLog.line("Audio drained through sample \(boundary), \(Int(timeIntervalSinceAbsoluteTime(self.stopRequestedAt) * 1000)) ms after stop (tail \(tailNs / 1_000_000) of \(tailMs) ms, \(silentMs) ms already silent).")
            do {
                try self.session?.flush()
                try self.session?.stop()
                self.hud.updateStatus("Waiting for transcript…")
            } catch {
                AppLog.line("Stop failed: \(error.localizedDescription)")
                if !self.draftText().isEmpty {
                    await self.insertResult()
                } else {
                    self.handleFailure(AppLog.redact(error.localizedDescription), code: "stop_failed")
                }
                return
            }
            do {
                try await self.waitForCompletion()
                guard !self.cancelled else { return }
                self.hud.updateStatus("Pasting…")
                await self.insertResult()
            } catch {
                guard !self.cancelled else { return }
                if !self.draftText().isEmpty || !self.polishedText.isEmpty {
                    AppLog.line("Finalization failed with buffered transcript; inserting anyway.")
                    await self.insertResult()
                } else {
                    self.handleFailure(AppLog.redact(error.localizedDescription), code: "finalize_failed")
                }
            }
        }
    }

    private func handle(_ event: AppTranscriptEvent, generation: Int) {
        guard generation == sessionGeneration else { return }
        switch event.kind {
        case .interim:
            latestInterim = event.text
            if phase == .listening {
                hud.updateText(draftText())
                interimPreview = draftText()
            }
        case .turnBoundary:
            startsNewTurn = true
        case .final:
            let merged = startsNewTurn ? finalSegments + [event.text] : appendDedupedFinalSegment(finalSegments, event.text)
            startsNewTurn = false
            finalSegments = merged
            latestInterim = ""
            hud.updateText(draftText())
            interimPreview = draftText()
        case .polished:
            polishedText = event.text
            polishedInput = event.source
            lastPolishLatencyMs = event.latencyMs
            lastSpeculative = event.speculative
            // Only while listening: the final reuse emit after stop is also
            // speculative-flagged but proves nothing about speak-time overlap.
            if event.speculative, phase == .listening {
                speculativeHits += 1
            }
            if phase == .listening {
                hud.updateText(draftText())
                interimPreview = draftText()
            }
        case .timing:
            pipelineTiming = event.timing
            if event.timing?.outcome.hasPrefix("raw_") == true {
                polishedText = ""
                polishedInput = ""
                lastPolishLatencyMs = 0
                lastSpeculative = false
            }
        case .complete:
            didComplete = true
            finishWait(with: nil)
        case .cancelled:
            didComplete = true
            finishWait(with: nil)
        case .error:
            let message = event.message.isEmpty ? event.code : "\(event.code): \(event.message)"
            if phase == .listening {
                handleAudioSendFailure(message, code: event.code)
            } else {
                finishWait(with: NSError(domain: "GeminiWhisper", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message,
                ]))
            }
        case .warning:
            AppLog.line("\(event.code): \(event.message)")
        case .connecting:
            AppLog.line("Gemini Live reconnecting; microphone audio is buffering.")
        case .ready:
            AppLog.line("Gemini Live ready.")
        default:
            break
        }
    }

    private func handleAudioSendFailure(_ detail: String, code: String = "audio_stream_failed") {
        guard phase == .listening else { return }
        isStreamingAudio = false
        AppLog.line("Microphone stream failed: \(detail)")
        interimPreview = draftText()
        handleFailure("\(detail) No text was inserted; start dictation again.", code: code)
    }

    private func insertResult() async {
        isStreamingAudio = false
        hud.hide()
        let text = draftText()
        let timing = pipelineTiming
        let stopTime = stopRequestedUptime
        let stopMachTime = stopRequestedAt
        let pressTime = togglePressedAt
        let usedPolish = !polishedText.isEmpty && transcriptsCompatible(polishedInput, transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim, startsNewTurn: startsNewTurn))
        capture.pause()
        audioStream?.discard()
        session?.close()
        session = nil
        phase = .idle
        let expected = targetApplication
        targetApplication = nil
        lastTranscript = text
        interimPreview = ""
        guard !text.isEmpty else {
            SoundPlayer.play(.basso)
            lastError = "No transcript was returned. Please try again."
            UserNotify.show(lastError)
            AppLog.line("Dictation completed without text.")
            return
        }
        do {
            let pasted = try await PasteController.pasteIntoFocusedApplication(text, expectedApplication: expected)
            let postedAt = ProcessInfo.processInfo.systemUptime
            let stopToPasteMs = stopTime > 0 ? Int(((postedAt - stopTime) * 1000).rounded()) : 0
            let pressToPaste = pressTime > 0
                ? " (\(Int((timeIntervalSinceAbsoluteTime(pressTime) * 1_000).rounded())) ms after press)" : ""
            let outcome = usedPolish ? (timing?.outcome ?? "polished_unverified") : (timing?.outcome.hasPrefix("raw_") == true ? timing!.outcome : "raw_fallback")
            AppLog.line("\(pasted ? "Inserted" : "Copied") \(text.count) characters in \(stopToPasteMs) ms after stop\(pressToPaste) outcome=\(outcome).")
            if let timing {
                let deliveryMs = Int((max(0, postedAt - timing.readyAt) * 1000).rounded())
                AppLog.line("latency session=\(timing.sessionID) capture_ms=\(timing.captureMs) live_ms=\(timing.liveMs) polish_wait_ms=\(timing.polishWaitMs) delivery_ms=\(deliveryMs) total_ms=\(stopToPasteMs) outcome=\(outcome) background_jobs=\(timing.backgroundJobs) final_jobs=\(timing.finalJobs) live_fallback=\(timing.liveFallback) pasted=\(pasted)")
            }
            if stopRequestedAt == stopMachTime { stopRequestedAt = 0 }
            SoundPlayer.play(pasted ? .glass : .pop)

        } catch {
            SoundPlayer.play(.basso)
            do {
                try PasteController.copyText(text)
                lastError = "Paste failed; copied \(text.count) characters instead. \(error.localizedDescription)"
                UserNotify.show(lastError)
                AppLog.line(
                    "Paste failed trusted=\(PasteController.hasPasteAutomationPermission()) " +
                        "executable=\(PasteController.runningIdentity) (\(error.localizedDescription)); " +
                        "copied \(text.count) characters instead."
                )
            } catch {
                lastError = error.localizedDescription
                UserNotify.show(lastError)
                AppLog.line("Paste and copy failed: \(AppLog.redact(error.localizedDescription))")
            }
        }
    }

    private func handleFailure(_ detail: String, code: String = "") {
        isStreamingAudio = false
        hud.setState("error")
        hud.hide()
        capture.pause()
        audioStream?.discard()
        session?.close()
        session = nil
        phase = .idle
        targetApplication = nil
        lastError = code.isEmpty ? detail : "\(code): \(detail)"
        SoundPlayer.play(.basso)
        UserNotify.dictationFailure(detail: detail, code: code)
        AppLog.line(lastError)
    }

    private func failStart(_ message: String, code: String = "") {
        isStreamingAudio = false
        capture.pause()
        audioStream?.discard()
        session?.close()
        session = nil
        phase = .idle
        hud.setState("error")
        hud.hide()
        lastError = code.isEmpty ? message : "\(code): \(message)"
        SoundPlayer.play(.basso)
        UserNotify.dictationFailure(detail: message, code: code)
        AppLog.line(lastError)
    }

    private func requireAPIKey() -> String? {
        let key = settings.environment.apiKey
        guard !key.isEmpty else {
            lastError = "Set GEMINI_API_KEY in the project .env before starting a transcription."
            SoundPlayer.play(.basso)
            UserNotify.show(lastError)
            AppLog.line("Gemini API key is not configured.")
            return nil
        }
        return key
    }

    private func resetTranscriptState() {
        pipelineTiming = nil
        finalSegments = []
        startsNewTurn = false
        latestInterim = ""
        polishedText = ""
        polishedInput = ""
        lastPolishLatencyMs = 0
        lastSpeculative = false
        speculativeHits = 0
        togglePressedAt = 0
        interimPreview = ""
        lastError = ""
        didComplete = false
    }

    private func waitForCompletion() async throws {
        if didComplete { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if didComplete {
                continuation.resume()
                return
            }
            if let existing = completion {
                existing.resume(throwing: CancellationError())
            }
            completion = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if self.completion != nil {
                    self.finishWait(with: DictationTimeout())
                }
            }
        }
    }

    private struct DictationTimeout: Error, LocalizedError {
        var errorDescription: String? { "Timed out waiting for Gemini to finalize the transcript." }
    }

    private func draftText() -> String {
        let rawDraft = transcriptDraft(finalSegments: finalSegments, latestInterim: latestInterim, startsNewTurn: startsNewTurn)

        guard !polishedText.isEmpty else {
            return rawDraft
        }

        return transcriptsCompatible(polishedInput, rawDraft) ? polishedText : rawDraft
    }

    private func finishWait(with error: Error?) {
        guard let continuation = completion else { return }
        completion = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
