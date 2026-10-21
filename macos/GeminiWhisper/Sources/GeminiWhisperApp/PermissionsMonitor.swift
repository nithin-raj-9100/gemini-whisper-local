@preconcurrency import ApplicationServices
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PermissionsMonitor {
    var microphoneGranted = false
    var microphoneStatus: AVAuthorizationStatus = .notDetermined
    var accessibilityTrusted = false
    var eventTapInstalled = false
    var eventTapFailureMessage = ""
    @ObservationIgnored private var pollTimer: Timer?

    func refresh() {
        let previous = (microphoneGranted, accessibilityTrusted, eventTapInstalled)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = microphoneStatus == .authorized
        accessibilityTrusted = AXIsProcessTrusted()
        eventTapInstalled = HotkeyMonitor.shared.eventTapInstalled
        eventTapFailureMessage = HotkeyMonitor.shared.eventTapFailureMessage ?? ""
        if previous != (microphoneGranted, accessibilityTrusted, eventTapInstalled) {
            AppLog.line(
                "Permissions microphone=\(microphoneGranted) accessibility=\(accessibilityTrusted) " +
                    "eventTap=\(eventTapInstalled) executable=\(PasteController.runningIdentity)"
            )
        }
    }

    func requestMicrophone() async {
        if microphoneStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
    }

    func promptAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [prompt: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// Re-checks every 2 seconds until Accessibility and the event tap are in
    /// place, so granting permission in System Settings takes effect without a restart.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if self.accessibilityTrusted, self.eventTapInstalled {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }
}
