import AppKit
import Foundation
import UserNotifications

enum SystemSound: String {
    case tink = "Tink"
    case pop = "Pop"
    case glass = "Glass"
    case basso = "Basso"
}

/// In-process system sounds. Starting `afplay` for every cue cost a process
/// launch per sound and could fail silently under load.
@MainActor
enum SoundPlayer {
    private static var sounds: [SystemSound: NSSound] = [:]

    static func play(_ sound: SystemSound) {
        let player = sounds[sound] ?? NSSound(named: NSSound.Name(sound.rawValue))
        guard let player else { return }
        sounds[sound] = player
        if player.isPlaying { player.stop() }
        player.play()
    }
}

/// User-visible notifications. Uses the Notification Center when running as the
/// app bundle (attributed to Gemini Whisper); `swift run` and a denied permission
/// fall back to AppleScript so a failure is never silent.
enum UserNotify {
    nonisolated(unsafe) private static var requestedAuthorization = false

    private static var usesNotificationCenter: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks once for permission to show alerts.
    static func prepare() {
        guard usesNotificationCenter, !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            AppLog.line("Notifications authorized=\(granted)")
        }
    }

    static func show(_ message: String) {
        guard usesNotificationCenter else {
            showWithAppleScript(message)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = "Gemini Whisper"
                content.body = message
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            default:
                showWithAppleScript(message)
            }
        }
    }

    private static func showWithAppleScript(_ message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "on run argv\ndisplay notification (item 1 of argv) with title \"Gemini Whisper\"\nend run",
            "--",
            message,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
