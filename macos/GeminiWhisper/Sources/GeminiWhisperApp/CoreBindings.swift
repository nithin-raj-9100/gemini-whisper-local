import Foundation
import GeminiWhisperCore
import os

/// Maps App settings onto Core `TranscriptionConfig`.
@MainActor
enum CoreConfigFactory {
    static func make(settings: AppSettings) throws -> TranscriptionConfig {
        let mode: TranscriptionMode = settings.mode == .verbatim ? .verbatim : .smart
        let polish = settings.mode == .verbatim ? false : settings.polish
        let vad: VadMode
        switch settings.vad {
        case .automatic: vad = .automatic
        case .hybrid: vad = .hybrid
        case .manual: vad = .manual
        }

        var config = TranscriptionConfig.systemDictationDefaults
        config.mode = mode
        config.polish = polish
        config.languageCodes = settings.language.isEmpty ? [] : [settings.language]
        config.customVocabulary = settings.vocabularyTerms
        config.vad = vad
        config.vadPrefixPaddingMs = settings.vadPrefixPaddingMs
        config.vadSilenceDurationMs = settings.vadSilenceDurationMs
        return try normalizeConfig(config)
    }
}

/// App log: stderr, unified logging, and ~/Library/Logs/gemini-whisper.app.log.
/// The file rotates at 5 MB, keeping one previous file.
enum AppLog {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/gemini-whisper.app.log")
    static let previousFileURL: URL = fileURL.deletingPathExtension().appendingPathExtension("1.log")
    private static let maximumBytes: UInt64 = 5 * 1024 * 1024

    private static let logger = Logger(subsystem: "com.nithin.gemini-whisper", category: "app")
    private static let fileLock = NSLock()
    nonisolated(unsafe) private static let stampFormatter = ISO8601DateFormatter()

    static func line(_ message: String) {
        let redacted = redact(message)
        FileHandle.standardError.write(Data((redacted + "\n").utf8))
        logger.notice("\(redacted, privacy: .public)")
        appendToFile(redacted)
    }

    static func redact(_ message: String) -> String {
        redactApiKeys(message)
    }

    private static func appendToFile(_ message: String) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let line = Data("\(stampFormatter.string(from: Date())) \(message)\n".utf8)
        let url = fileURL
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let size = (try? handle.seekToEnd()) ?? 0
        if size + UInt64(line.count) > maximumBytes {
            try? handle.close()
            try? manager.removeItem(at: previousFileURL)
            try? manager.moveItem(at: url, to: previousFileURL)
            manager.createFile(atPath: url.path, contents: line)
            return
        }
        defer { try? handle.close() }
        try? handle.write(contentsOf: line)
    }
}
