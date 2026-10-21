import AppKit
import Foundation
import GeminiWhisperCore
import Observation

/// App-side owner of dictation: connects the Core `DictationCoordinator` (which
/// holds the whole lifecycle and is tested in Core) to the microphone, the HUD,
/// sounds, notifications, and the pasteboard.
@MainActor
@Observable
final class DictationController {
    typealias Phase = DictationCoordinator.Phase

    var lastAudioCheck: AudioCheckResult?

    let settings: AppSettings
    let permissions: PermissionsMonitor
    let hud: FloatingHUDController
    let capture: MicrophoneCapture
    let coordinator: DictationCoordinator

    init(settings: AppSettings, hud: FloatingHUDController, permissions: PermissionsMonitor) {
        self.settings = settings
        self.hud = hud
        self.permissions = permissions
        let microphone = MicrophoneCapture()
        capture = microphone
        coordinator = DictationCoordinator(
            capture: CaptureAdapter(capture: microphone, settings: settings),
            inserter: PasteController.shared,
            feedback: AppFeedback(hud: hud),
            makeSession: { emit in try DictationController.makeSession(settings: settings, emit: emit) },
            recover: { audio in try await DictationController.recover(audio, settings: settings) },
            log: { AppLog.line($0) }
        )
        applySettings()
    }

    var phase: Phase { coordinator.phase }
    var statusTitle: String { coordinator.statusTitle }
    var lastError: String { coordinator.lastError }
    var lastTranscript: String { coordinator.lastTranscript }
    var interimPreview: String { coordinator.interimPreview }
    var history: TranscriptHistory { coordinator.history }
    var isRecovering: Bool { coordinator.isRecovering }

    /// Push settings that may change between dictations.
    func applySettings() {
        coordinator.stopTailMs = settings.stopTailMs
        coordinator.optimisticPaste = settings.optimisticPaste && settings.polish && settings.mode != .verbatim
        HotkeyMonitor.shared.hotkey = settings.hotkey
    }

    func prepareCapture() {
        do {
            capture.applyPreferredDevice(uniqueID: settings.audioDevice)
            try capture.prepare()
        } catch {
            AppLog.line("Microphone prepare failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Gestures

    func toggle() { coordinator.toggle(pressedAt: HotkeyMonitor.shared.lastTapDownUptime) }
    func beginHeldDictation() { coordinator.beginHeldDictation(pressedAt: HotkeyMonitor.shared.lastTapDownUptime) }
    func finishHeldDictation() { coordinator.finishHeldDictation(pressedAt: HotkeyMonitor.shared.lastTapDownUptime) }
    func cancelHeldDictation() { coordinator.cancelHeldDictation() }
    func cancel() { coordinator.cancel() }
    func prepareHotkeyCapture() { coordinator.prepareHotkeyCapture() }
    func discardHotkeyCapture() { coordinator.discardHotkeyCapture() }
    func interrupt(reason: String) { coordinator.interrupt(reason: reason) }

    // MARK: - Recovery

    func copyLastTranscript() { coordinator.copyLastTranscript() }
    func pasteLastTranscript() async { await coordinator.pasteLastTranscript() }
    func retryLastDictation() async { await coordinator.retryLastDictation() }
    func copyHistoryEntry(_ id: UUID) { coordinator.copyHistoryEntry(id) }

    func runAudioCheck() async {
        guard phase == .idle else {
            lastAudioCheck = AudioCheckResult(source: capture.currentDeviceName, bytes: 0, rms: 0, peak: 0,
                                              error: "Dictation is active.")
            return
        }
        discardHotkeyCapture()
        capture.applyPreferredDevice(uniqueID: settings.audioDevice)
        lastAudioCheck = await capture.audioCheck()
    }

    // MARK: - Session wiring

    private struct SetupError: LocalizedError {
        var errorDescription: String?
    }

    private static func makeSession(settings: AppSettings, emit: @escaping (ServerEvent) -> Void) throws -> DictationSession {
        let apiKey = settings.apiKey
        guard !apiKey.isEmpty else {
            throw SetupError(errorDescription: "Add your Gemini API key in Gemini Whisper Settings to start dictating.")
        }
        let config = try CoreConfigFactory.make(settings: settings)
        let env = settings.environment
        let intelligence: (any TranscriptIntelligence)? = config.polish
            ? createTranscriptIntelligence(apiKey: apiKey, model: env.intelligenceModel, patchEditing: env.patchEditingOverride ?? true)
            : nil
        return DictationSession(
            apiKey: apiKey,
            config: config,
            emit: emit,
            intelligence: intelligence,
            speculativeIntelligence: true,
            batchTranscriber: createBatchTranscriber(apiKey: apiKey, model: env.batchModel),
            polishDeadline: settings.polishDeadline
        )
    }

    private static func recover(_ audio: RecordedAudio, settings: AppSettings) async throws -> String {
        let apiKey = settings.apiKey
        guard !apiKey.isEmpty else {
            throw SetupError(errorDescription: "Add your Gemini API key in Gemini Whisper Settings.")
        }
        let config = try CoreConfigFactory.make(settings: settings)
        let env = settings.environment
        let intelligence: (any TranscriptIntelligence)? = config.polish
            ? createTranscriptIntelligence(apiKey: apiKey, model: env.intelligenceModel, patchEditing: false)
            : nil
        return try await recoverTranscript(
            from: audio,
            config: config,
            batch: createBatchTranscriber(apiKey: apiKey, model: env.batchModel),
            intelligence: intelligence
        )
    }
}

/// `MicrophoneCapture` as the coordinator's audio source.
@MainActor
final class CaptureAdapter: AudioCapturing {
    private let capture: MicrophoneCapture
    private let settings: AppSettings

    init(capture: MicrophoneCapture, settings: AppSettings) {
        self.capture = capture
        self.settings = settings
    }

    var deviceName: String { capture.currentDeviceName }

    func startCapture(_ handler: @escaping @Sendable (Data) -> Void) throws {
        capture.setPCMHandler(handler)
        capture.applyPreferredDevice(uniqueID: settings.audioDevice)
        try capture.prepare()
        try capture.start()
    }

    func pauseCapture() {
        capture.pause()
    }
}

/// HUD, sounds, and notifications for the coordinator.
@MainActor
final class AppFeedback: DictationFeedback {
    private let hud: FloatingHUDController

    init(hud: FloatingHUDController) {
        self.hud = hud
    }

    func showListening() {
        hud.show()
        hud.setState("listening")
    }

    func hide() { hud.hide() }
    func showText(_ text: String) { hud.updateText(text) }
    func showStatus(_ text: String) { hud.updateStatus(text) }
    func showFinalizing() { hud.setState("polishing") }
    func showError(_ message: String) { hud.showError(message) }
    func nudge() { hud.nudge() }
    func setLevel(_ rms: Double) { hud.setLevel(rms) }

    func play(_ cue: DictationCue) {
        switch cue {
        case .start: SoundPlayer.play(.tink)
        case .stop, .copied: SoundPlayer.play(.pop)
        case .inserted: SoundPlayer.play(.glass)
        case .error: SoundPlayer.play(.basso)
        }
    }

    func notify(_ message: String) {
        UserNotify.show(message)
    }
}
