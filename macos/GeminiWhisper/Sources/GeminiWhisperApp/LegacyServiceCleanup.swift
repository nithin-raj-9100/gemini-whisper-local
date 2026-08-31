import Darwin
import Foundation
import ServiceManagement

/// Unload the old Bun LaunchAgent so it cannot fight the native app for Right Option.
enum LegacyServiceCleanup {
    static let agentLabel = "com.nithin.gemini-whisper"

    static var target: String {
        "gui/\(getuid())/\(agentLabel)"
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    @discardableResult
    static func bootout() -> Int32 {
        runLaunchctl(["bootout", target])
    }

    static func isLoaded() -> Bool {
        runLaunchctl(["print", target]) == 0
    }

    static func plistExists() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Boot out the agent and delete its LaunchAgent plist. Ignores "already unloaded" errors.
    @discardableResult
    static func removeCompletely() -> String {
        let bootStatus = bootout()
        var notes: [String] = []
        if bootStatus == 0 {
            notes.append("Unloaded \(target).")
        } else if !isLoaded() {
            notes.append("LaunchAgent \(agentLabel) is not loaded.")
        } else {
            notes.append("launchctl bootout returned \(bootStatus).")
        }

        if plistExists() {
            do {
                try FileManager.default.removeItem(at: plistURL)
                notes.append("Removed \(plistURL.path).")
            } catch {
                notes.append("Could not remove plist: \(error.localizedDescription)")
            }
        }

        return notes.joined(separator: " ")
    }

    static func loginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
