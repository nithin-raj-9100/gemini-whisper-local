import AppKit
import SwiftUI

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let settings = AppSettings()
    let permissions = PermissionsMonitor()
    let hud = FloatingHUDController()
    let controller: DictationController

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
        } else {
            AppLog.line("No project .env found; using process environment.")
        }
        AppLog.line(env.hasAPIKey ? "Gemini API key loaded." : "Gemini API key is not configured.")
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

        HotkeyMonitor.shared.onToggle = { [weak controller] in
            controller?.toggle()
        }
        HotkeyMonitor.shared.onCancel = { [weak controller] in
            controller?.cancel()
        }
        HotkeyMonitor.shared.start()
        controller.prepareCapture()
        Task {
            await permissions.requestMicrophone()
            permissions.promptAccessibility()
        }
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
        Button("Audio Check") {
            Task { await controller.runAudioCheck() }
        }
        .disabled(controller.phase != .idle)
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            if #available(macOS 14.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
        .keyboardShortcut(",")
        Button("Quit Gemini Whisper") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
