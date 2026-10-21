import AVFoundation
import GeminiWhisperCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @Environment(PermissionsMonitor.self) private var permissions

    @State private var devices: [AudioDeviceList.Device] = []
    @State private var loginItemError = ""
    @State private var newAPIKey = ""
    @State private var apiKeyMessage = ""

    var body: some View {
        Form {
            Section("Gemini API key") {
                LabeledContent("Status") {
                    Text(settings.apiKey.isEmpty ? "not configured" : "loaded from \(settings.apiKeySource.rawValue)")
                }
                if AppEnvironment.keychainAvailable {
                    SecureField("Paste a new API key", text: $newAPIKey)
                    HStack {
                        Button("Save to Keychain") {
                            do {
                                try settings.saveAPIKey(newAPIKey)
                                newAPIKey = ""
                                apiKeyMessage = "Saved to the Keychain."
                            } catch {
                                apiKeyMessage = error.localizedDescription
                            }
                        }
                        .disabled(newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove from Keychain") {
                            do {
                                try settings.removeAPIKeyFromKeychain()
                                apiKeyMessage = "Removed from the Keychain."
                            } catch {
                                apiKeyMessage = error.localizedDescription
                            }
                        }
                        .disabled(settings.apiKeySource != .keychain)
                    }
                    Text("The key is stored in your login Keychain and never written to the app bundle. GEMINI_API_KEY in the process environment overrides it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Running outside the app bundle: set GEMINI_API_KEY in the environment or .env.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !apiKeyMessage.isEmpty {
                    Text(apiKeyMessage)
                        .font(.caption)
                }
            }

            Section("Hotkey") {
                Picker("Dictation key", selection: Bindable(settings).hotkey) {
                    ForEach(HotkeyKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                Text("Tap to start and stop, or hold while speaking. Pick a key you never use for typing: Right Option types special characters on many layouts. For Fn/Globe, set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Text("Off by default. Pastes the raw transcript the moment it settles, then replaces it once polish lands. The replacement only happens when Accessibility confirms the inserted text is still right before the cursor; otherwise, or if you type or click first, the raw text stays. Editors that auto-format, terminals, and many web apps keep the raw text.")
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
                LabeledContent("Log") {
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

            Section("Recent transcripts (this session only)") {
                if controller.history.entries.isEmpty {
                    Text("Nothing yet. Transcripts are kept in memory until the app quits.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.history.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                            Text(entry.outcome.rawValue)
                                .foregroundStyle(entry.outcome == .inserted ? Color.secondary : Color.orange)
                            if let target = entry.targetName {
                                Text(target).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Copy") { controller.copyHistoryEntry(entry.id) }
                                .disabled(entry.text.isEmpty)
                        }
                        .font(.caption)
                        if !entry.text.isEmpty {
                            Text(entry.text)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
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
        .onChange(of: settings.mode) { _, _ in
            settings.persist()
            controller.applySettings()
        }
        .onChange(of: settings.polish) { _, _ in
            settings.persist()
            controller.applySettings()
        }
        .onChange(of: settings.vad) { _, _ in settings.persist() }
        .onChange(of: settings.vadPrefixPaddingMs) { _, _ in settings.persist() }
        .onChange(of: settings.vadSilenceDurationMs) { _, _ in settings.persist() }
        .onChange(of: settings.optimisticPaste) { _, _ in
            settings.persist()
            controller.applySettings()
        }
        .onChange(of: settings.hotkey) { _, _ in
            settings.persist()
            controller.applySettings()
        }
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
