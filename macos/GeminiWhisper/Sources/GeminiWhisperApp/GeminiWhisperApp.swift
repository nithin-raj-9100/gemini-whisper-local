import AppKit
import GeminiWhisperCore
import SwiftUI

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let settings = AppSettings()
    let permissions = PermissionsMonitor()
    let hud = FloatingHUDController()
    let controller: DictationController
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {
        controller = DictationController(settings: settings, hud: hud, permissions: permissions)
        hud.onShow = { HotkeyMonitor.shared.registerEscapeHotKey() }
        hud.onHide = { HotkeyMonitor.shared.unregisterEscapeHotKey() }
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        let env = settings.environment
        if let url = env.envFileURL {
            AppLog.line("Loaded environment from \(url.path)")
            if env.envFileIsBundled {
                AppLog.line("This app bundle contains a .env from an older build. Rebuild with scripts/build-app.sh to remove it; the key now lives in the Keychain.")
            }
        } else {
            AppLog.line("No .env found; using the process environment and Keychain.")
        }
        if env.migratedToKeychain {
            AppLog.line("Saved the .env Gemini API key to the Keychain. It can now be removed from .env.")
        }
        AppLog.line(env.hasAPIKey ? "Gemini API key loaded from \(env.apiKeySource.rawValue)." : "Gemini API key is not configured.")
        AppLog.line("Running from \(PasteController.runningIdentity)")
        AppLog.line("Bundle \(PasteController.bundleURL.path)")
        AppLog.line("Log file \(AppLog.fileURL.path)")
        AppLog.line("AXIsProcessTrusted=\(PasteController.hasPasteAutomationPermission())")
        if !PasteController.isAppBundle {
            AppLog.line(
                "Not launched as GeminiWhisper.app. Paste Cmd+V is posted by this process; use `open macos/GeminiWhisper.app` so Accessibility applies to the signed app bundle."
            )
        }

        if settings.openAtLogin {
            try? LoginItemController.setEnabled(true)
        }
        UserNotify.prepare()

        HotkeyMonitor.shared.onPrepare = { [weak controller] in controller?.prepareHotkeyCapture() }
        HotkeyMonitor.shared.onDiscardPreparation = { [weak controller] in controller?.discardHotkeyCapture() }
        HotkeyMonitor.shared.onHoldStart = { [weak controller] in controller?.beginHeldDictation() }
        HotkeyMonitor.shared.onHoldEnd = { [weak controller] in controller?.finishHeldDictation() }
        HotkeyMonitor.shared.onHoldCancel = { [weak controller] in controller?.cancelHeldDictation() }
        HotkeyMonitor.shared.onToggle = { [weak controller] in
            controller?.toggle()
        }
        HotkeyMonitor.shared.onCancel = { [weak controller] in
            controller?.cancel()
        }
        HotkeyMonitor.shared.onEventTapChanged = { [weak permissions] in
            permissions?.refresh()
        }
        controller.applySettings()
        HotkeyMonitor.shared.start()
        controller.prepareCapture()
        observeSleepAndWake()
        Task {
            await permissions.requestMicrophone()
            permissions.promptAccessibility()
            permissions.startPolling()
        }
    }

    /// Closing the lid mid-dictation must not paste into whatever is focused after
    /// wake; the dictation is kept in history instead. After wake, the audio
    /// graph, the keyboard event tap, and permissions are re-validated.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                AppLog.line("System will sleep.")
                self?.controller.interrupt(reason: "sleep")
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                AppLog.line("System woke; re-validating audio input, event tap, and permissions.")
                guard let self else { return }
                self.controller.capture.markNeedsRebuild()
                HotkeyMonitor.shared.revalidate()
                self.permissions.refresh()
            }
        })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct GeminiWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(AppRuntime.shared.settings)
                .environment(AppRuntime.shared.controller)
                .environment(AppRuntime.shared.permissions)
        }
    }
}

private struct MenuBarLabel: View {
    var body: some View {
        let controller = AppRuntime.shared.controller
        let symbol: String = {
            if controller.phase == .listening { return "mic.fill" }
            if !controller.lastError.isEmpty { return "exclamationmark.bubble" }
            return "mic"
        }()
        Image(systemName: symbol)
    }
}

private struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let controller = AppRuntime.shared.controller
        Text("Gemini Whisper — \(controller.statusTitle)")
        if !controller.interimPreview.isEmpty {
            Text(controller.interimPreview)
                .lineLimit(3)
        } else if !controller.lastTranscript.isEmpty {
            Text(controller.lastTranscript)
                .lineLimit(3)
        }
        Divider()
        Button(controller.phase == .idle ? "Start dictation" : controller.phase == .listening ? "Stop dictation" : "Finalizing…") {
            controller.toggle()
        }
        .disabled(controller.phase == .finalizing)
        Button("Cancel") {
            controller.cancel()
        }
        .disabled(controller.phase == .idle)
        Divider()
        Button("Copy Last Transcript") {
            controller.copyLastTranscript()
        }
        .disabled(controller.history.lastText == nil)
        Button("Paste Last Transcript") {
            Task { await controller.pasteLastTranscript() }
        }
        .disabled(controller.history.lastText == nil || controller.phase != .idle)
        Button(controller.isRecovering ? "Retrying…" : "Retry Last Dictation from Audio") {
            Task { await controller.retryLastDictation() }
        }
        .disabled(controller.history.lastRecording == nil || controller.phase != .idle || controller.isRecovering)
        if !controller.history.entries.isEmpty {
            Menu("Recent Transcripts") {
                ForEach(controller.history.entries) { entry in
                    Button(historyLabel(entry)) {
                        controller.copyHistoryEntry(entry.id)
                    }
                    .disabled(entry.text.isEmpty)
                }
            }
        }
        Divider()
        Button("Audio Check") {
            Task { await controller.runAudioCheck() }
        }
        .disabled(controller.phase != .idle)
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Gemini Whisper") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func historyLabel(_ entry: TranscriptHistoryEntry) -> String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        let text = entry.text.isEmpty ? "(no text)" : entry.text.replacingOccurrences(of: "\n", with: " ")
        let clipped = text.count > 48 ? String(text.prefix(47)) + "…" : text
        return "\(time) · \(entry.outcome.rawValue) · \(clipped)"
    }
}
