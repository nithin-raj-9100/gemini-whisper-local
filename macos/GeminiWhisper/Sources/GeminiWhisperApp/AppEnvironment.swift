import Foundation

/// Runtime knobs loaded from the project `.env`.
/// Never logs `GEMINI_API_KEY` or other secret values.
struct AppEnvironment: Sendable {
    var apiKey: String
    var language: String
    var audioDevice: String
    var stopTailMs: Int
    var intelligenceModel: String?
    var patchEditing: Bool
    /// nil when unset: the Settings toggle owns this unless .env forces a value.
    var optimisticPasteOverride: Bool?
    var envFileURL: URL?

    static let defaultLanguage = "en-IN"
    static let defaultStopTailMs = 400
    static let defaultAudioDevice = ":0"

    var hasAPIKey: Bool { !apiKey.isEmpty }

    static func load() -> AppEnvironment {
        let fileURL = locateDotEnv()
        let fileValues = fileURL.flatMap { parseDotEnv(at: $0) } ?? [:]

        func value(_ key: String, default defaultValue: String = "") -> String {
            if let existing = ProcessInfo.processInfo.environment[key], !existing.isEmpty {
                return existing
            }
            return fileValues[key] ?? defaultValue
        }

        let stopTail = Int(value("GEMINI_WHISPER_STOP_TAIL_MS")) ?? defaultStopTailMs
        let model = value("GEMINI_WHISPER_INTELLIGENCE_MODEL")

        return AppEnvironment(
            apiKey: value("GEMINI_API_KEY"),
            language: value("GEMINI_WHISPER_LANGUAGE", default: defaultLanguage),
            audioDevice: value("GEMINI_WHISPER_AUDIO_DEVICE", default: defaultAudioDevice),
            stopTailMs: max(0, stopTail),
            intelligenceModel: model.isEmpty ? nil : model,
            patchEditing: value("GEMINI_WHISPER_PATCH_EDITING") == "1",
            optimisticPasteOverride: {
                let raw = value("GEMINI_WHISPER_OPTIMISTIC_PASTE")
                return raw.isEmpty ? nil : raw == "1"
            }(),
            envFileURL: fileURL
        )
    }

    /// Walk from the compiled source path, the .app bundle, and cwd until `.env` is found.
    private static func locateDotEnv() -> URL? {
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(".env"))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".config/gemini-whisper/.env"))
        candidates.append(home.appendingPathComponent(".gemini-whisper.env"))

        var sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            candidates.append(sourceDir.appendingPathComponent(".env"))
            sourceDir.deleteLastPathComponent()
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var dir = cwd
        for _ in 0..<8 {
            candidates.append(dir.appendingPathComponent(".env"))
            dir.deleteLastPathComponent()
        }

        if let bundleURL = Bundle.main.bundleURL as URL? {
            var parent = bundleURL.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(parent.appendingPathComponent(".env"))
                parent.deleteLastPathComponent()
            }
        }

        if let exec = Bundle.main.executableURL {
            var parent = exec.deletingLastPathComponent()
            for _ in 0..<10 {
                candidates.append(parent.appendingPathComponent(".env"))
                parent.deleteLastPathComponent()
            }
        }

        let seen = NSMutableSet()
        for url in candidates {
            let path = url.standardizedFileURL.path
            if seen.contains(path) { continue }
            seen.add(path)
            if FileManager.default.isReadableFile(atPath: path) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    private static func parseDotEnv(at url: URL) -> [String: String]? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}
