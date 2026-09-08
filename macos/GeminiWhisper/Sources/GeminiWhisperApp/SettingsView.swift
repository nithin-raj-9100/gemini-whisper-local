import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @Environment(PermissionsMonitor.self) private var permissions

    @State private var devices: [AudioDeviceList.Device] = []
    @State private var loginItemError = ""

    var body: some View {
        Form {
            Section("Transcription") {
                TextField("Language (BCP-47)", text: Bindable(settings).language)
                TextField("Vocabulary (comma-separated)", text: Bindable(settings).vocabularyText, axis: .vertical)
                    .lineLimit(2...4)
                Picker("Mode", selection: Bindable(settings).mode) {
                    ForEach(AppTranscriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Polish with Flash-Lite", isOn: Bindable(settings).polish)
                    .disabled(settings.mode == .verbatim)
                Toggle("Insert immediately, polish in place", isOn: Bindable(settings).optimisticPaste)
                    .disabled(settings.mode == .verbatim || !settings.polish)
                Text("Pastes the raw transcript the moment it settles, then reselects and replaces it once polish lands, so text appears at verbatim speed with polished output. The replacement is skipped if you type or click first, leaving the raw text. Turn off if you dictate into editors that auto-indent or auto-complete while you wait.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("VAD", selection: Bindable(settings).vad) {
                    ForEach(AppVadMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Manual keeps pauses in one dictation. Automatic uses the server silence duration. Hybrid also finalizes during locally detected pauses; dictation continues until you press Stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("VAD prefix padding (ms)", value: Bindable(settings).vadPrefixPaddingMs, format: .number)
                TextField("VAD silence duration (ms)", value: Bindable(settings).vadSilenceDurationMs, format: .number)
                Picker("Audio device", selection: Bindable(settings).audioDevice) {
                    Text("System default").tag(AppSettings.systemDefaultDeviceID)
                    ForEach(devices) { device in
                        Text("\(device.name)\(device.isDefault ? " (default)" : "")")
                            .tag(device.uniqueID)
                    }
                }
            }

            Section("Diagnostics") {
                LabeledContent("Stop tail") {
                    Text("\(settings.stopTailMs) ms")
                }
                LabeledContent("Environment file") {
                    Text(settings.environment.envFileURL?.path ?? "not found")
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("API key") {
                    Text(settings.environment.hasAPIKey ? "loaded" : "missing")
                }
                Button("Audio check (1s RMS / peak)") {
                    Task { await controller.runAudioCheck() }
                }
                .disabled(controller.phase != .idle)
                if let check = controller.lastAudioCheck {
                    LabeledContent("Source") { Text(check.source) }
                    LabeledContent("Bytes") { Text("\(check.bytes)") }
                    LabeledContent("RMS") { Text("\(check.rms)") }
                    LabeledContent("Peak") { Text("\(check.peak)") }
                    if !check.error.isEmpty {
                        Text(check.error)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    Text(permissions.microphoneGranted ? "granted" : permissions.microphoneStatus.label)
                }
                LabeledContent("Accessibility") {
                    Text(permissions.accessibilityTrusted ? "trusted" : "not trusted")
                }
                LabeledContent("Keyboard event tap") {
                    if permissions.eventTapInstalled {
                        Text("installed")
                    } else {
                        Text("failed")
                            .foregroundStyle(.orange)
                    }
                }
                if !permissions.eventTapFailureMessage.isEmpty {
                    Text(permissions.eventTapFailureMessage)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                LabeledContent("Paste") {
                    Text(permissions.accessibilityTrusted ? "Cmd+V from this process" : "needs Accessibility")
                }
                LabeledContent("This process") {
                    Text(PasteController.runningIdentity)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                LabeledContent("App bundle") {
                    Text(PasteController.bundleURL.path)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                LabeledContent("Paste log") {
                    Text(AppLog.fileURL.path)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Button("Request microphone access") {
                    Task { await permissions.requestMicrophone() }
                }
                Button("Prompt Accessibility") {
                    permissions.promptAccessibility()
                }
                Button("Retry keyboard event tap") {
                    HotkeyMonitor.shared.retryEventTap()
                    permissions.refresh()
                }
                Button("Refresh permission status") {
                    permissions.refresh()
                }
            }

            Section("App") {
                Toggle("Open Gemini Whisper at login", isOn: Bindable(settings).openAtLogin)
                if !loginItemError.isEmpty {
                    Text(loginItemError)
                        .foregroundStyle(.orange)
                }
            }

            Section("Last session") {
                LabeledContent("State") { Text(controller.statusTitle) }
                if !controller.lastTranscript.isEmpty {
                    Text(controller.lastTranscript)
                        .textSelection(.enabled)
                }
                if !controller.lastError.isEmpty {
                    Text(controller.lastError)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            devices = AudioDeviceList.inputDevices()
            permissions.refresh()
            settings.persist()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
        .onChange(of: settings.language) { _, _ in settings.persist() }
        .onChange(of: settings.vocabularyText) { _, _ in settings.persist() }
        .onChange(of: settings.mode) { _, _ in settings.persist() }
        .onChange(of: settings.polish) { _, _ in settings.persist() }
        .onChange(of: settings.vad) { _, _ in settings.persist() }
        .onChange(of: settings.vadPrefixPaddingMs) { _, _ in settings.persist() }
        .onChange(of: settings.vadSilenceDurationMs) { _, _ in settings.persist() }
        .onChange(of: settings.audioDevice) { _, _ in
            settings.persist()
            controller.prepareCapture()
        }
        .onChange(of: settings.openAtLogin) { _, enabled in
            settings.persist()
            do {
                try LoginItemController.setEnabled(enabled)
                loginItemError = ""
            } catch {
                loginItemError = error.localizedDescription
            }
        }
        .background(SettingsWindowActivator())
    }
}

private struct SettingsWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            activateWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            activateWindow(for: nsView)
        }
    }

    private func activateWindow(for view: NSView) {
        guard let window = view.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private extension AVAuthorizationStatus {
    var label: String {
        switch self {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}
