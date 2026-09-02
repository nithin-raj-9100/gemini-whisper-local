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
    private var session: CoreDictationBox?
    private var targetApplication: String?
    private var cancelled = false
    private var didComplete = false
    private var finalSegments: [String] = []
    private var latestInterim: String = ""
    private var polishedText: String = ""
    private var polishedInput: String = ""
    private var completion: CheckedContinuation<Void, Error>?
    private var stopRequestedAt: UInt64 = 0
    private var sessionGeneration = 0

    init(settings: AppSettings, hud: FloatingHUDController, permissions: PermissionsMonitor) {
        self.settings = settings
        self.hud = hud
        self.permissions = permissions
        capture.setPCMHandler { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.isStreamingAudio else { return }
                do {
                    try self.session?.sendAudio(data)
                } catch {
                    self.handleAudioSendFailure(AppLog.redact(error.localizedDescription))
                }
            }
        }
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
        switch phase {
        case .idle:
            startMicrophoneDictation()
        case .listening:
            beginStop()
        case .finalizing:
            break
        }
    }

    func cancel() {
        guard phase != .idle else { return }
        AppLog.line("Dictation cancelled (Escape).")
        cancelled = true
        isStreamingAudio = false
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
        lastAudioCheck = await capture.audioCheck()
    }

    private func startMicrophoneDictation() {
        guard let apiKey = requireAPIKey() else { return }
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

        do {
            capture.applyPreferredDevice(uniqueID: settings.audioDevice)
            try capture.prepare()
            try capture.start()
        } catch {
            failStart(error.localizedDescription)
            return
        }

        startSession(apiKey: apiKey)
    }

    private func startSession(apiKey: String) {
        let generation = sessionGeneration + 1
        sessionGeneration = generation
        do {
            let config = try CoreConfigFactory.make(settings: settings)
            let box = CoreDictationBox(
                apiKey: apiKey,
                config: config,
                intelligenceModel: settings.environment.intelligenceModel
            ) { [weak self] event in
                Task { @MainActor in
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
        hud.setState("polishing")
        SoundPlayer.play(.pop)
        AppLog.line("Option: stopping and polishing dictation.")
        let tailNs = UInt64(max(0, settings.stopTailMs)) * 1_000_000
        let generation = sessionGeneration
        Task {
            if tailNs > 0 {
                try? await Task.sleep(nanoseconds: tailNs)
            }
            guard self.sessionGeneration == generation, !self.cancelled else { return }
            self.isStreamingAudio = false
            self.capture.pause()
            do {
                try self.session?.flush()
                try self.session?.stop()
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
        case .final:
            if !event.text.isEmpty {
                finalSegments.append(event.text)
            }
            latestInterim = ""
            hud.updateText(draftText())
            interimPreview = draftText()
        case .polished:
            polishedText = event.text
            let rawDraft = (finalSegments + [latestInterim])
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawDraft.isEmpty {
                polishedInput = rawDraft
            }
            lastPolishLatencyMs = event.latencyMs
            lastSpeculative = event.speculative
            if phase == .listening {
                hud.updateText(draftText())
                interimPreview = draftText()
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
        let buffered = draftText()
        if !buffered.isEmpty {
            AppLog.line("Microphone stream failed with buffered text present; inserting transcript.")
            Task {
                await self.insertResult()
            }
            return
        }
        interimPreview = ""
        handleFailure("\(detail) No text was inserted; start dictation again.", code: code)
    }

    private func insertResult() async {
        isStreamingAudio = false
        hud.hide()
        let text = polishedText.isEmpty ? draftText() : polishedText
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
            SoundPlayer.play(pasted ? .glass : .pop)
            let stopToPasteMs = stopRequestedAt > 0
                ? Int((timeIntervalSinceAbsoluteTime(stopRequestedAt) * 1_000).rounded())
                : 0
            AppLog.line(
                "\(pasted ? "Inserted" : "Copied") \(text.count) characters in \(stopToPasteMs) ms after stop " +
                    "(Flash-Lite \(lastPolishLatencyMs) ms, \(lastSpeculative ? "overlapped" : "after final"))."
            )
            stopRequestedAt = 0
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
        finalSegments = []
        latestInterim = ""
        polishedText = ""
        polishedInput = ""
        lastPolishLatencyMs = 0
        lastSpeculative = false
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
        let rawDraft = (finalSegments + [latestInterim])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !polishedText.isEmpty else {
            return rawDraft
        }

        // Gapless Compositor:
        // 1. If rawDraft matches polishedInput, show polishedText directly.
        if transcriptsCompatible(polishedInput, rawDraft) {
            return polishedText
        }

        // 2. If rawDraft has newly arrived text (unpolished final segments or active interim),
        // extract whatever trailing extension was NOT yet polished and append it seamlessly.
        // Completed words NEVER vanish or flicker!
        if !polishedInput.isEmpty,
           let trailing = extractTrailingExtension(prefix: polishedInput, full: rawDraft),
           !trailing.isEmpty
        {
            return joinUniqueTranscript(polishedText, trailing)
        }

        // 3. If there is an active interim stream not yet part of the polished text, append it.
        if !latestInterim.isEmpty && !polishedText.contains(latestInterim) {
            return (polishedText + "\n" + latestInterim).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return polishedText
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
