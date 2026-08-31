import Foundation

enum SystemSound: String {
    case tink = "Tink"
    case pop = "Pop"
    case glass = "Glass"
    case basso = "Basso"
}

enum SoundPlayer {
    static func play(_ sound: SystemSound) {
        let path = "/System/Library/Sounds/\(sound.rawValue).aiff"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Sound cues are best-effort.
        }
    }
}

enum UserNotify {
    static func show(_ message: String) {
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

    static func dictationFailure(detail: String, code: String = "") {
        let message: String
        if detail.contains("exceeded your current quota") {
            message = "Gemini Live quota is temporarily unavailable. Try again after the quota resets."
        } else if code == "final_transcript_timeout" || detail.contains("final_transcript_timeout") {
            message = "Gemini did not finalize this transcript. Please try again."
        } else if !code.isEmpty {
            let clipped = detail.count > 140 ? String(detail.prefix(137)) + "…" : detail
            message = "Dictation failed (\(code)). \(clipped)"
        } else if !detail.isEmpty {
            message = "Dictation failed. \(detail)"
        } else {
            message = "Dictation failed. Check the Gemini Whisper log for details."
        }
        show(message)
    }
}
