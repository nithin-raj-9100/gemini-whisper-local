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

    func refresh() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = microphoneStatus == .authorized
        accessibilityTrusted = AXIsProcessTrusted()
        eventTapInstalled = HotkeyMonitor.shared.eventTapInstalled
        eventTapFailureMessage = HotkeyMonitor.shared.eventTapFailureMessage ?? ""
        AppLog.line(
            "Permissions microphone=\(microphoneGranted) accessibility=\(accessibilityTrusted) " +
                "eventTap=\(eventTapInstalled) executable=\(PasteController.runningIdentity)"
        )
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
}
