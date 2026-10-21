import Foundation

/// Runtime knobs from the process environment and an optional `.env` file, plus
/// the API key resolved from the environment, the Keychain, or `.env`.
/// Never logs `GEMINI_API_KEY` or other secret values.
struct AppEnvironment: Sendable {
    enum KeySource: String, Sendable {
        case environment = "process environment"
        case keychain = "Keychain"
        case dotEnv = ".env file"
        case none = "not configured"
    }

    var apiKey: String
    var apiKeySource: KeySource
    /// GEMINI_API_KEY from the process environment / `.env`, kept so the key can
    /// be resolved again after the Keychain entry changes.
    var processAPIKey: String
    var dotEnvAPIKey: String
    /// The `.env` key was copied into the Keychain at this launch.
    var migratedToKeychain: Bool
    var language: String
    var audioDevice: String
    var stopTailMs: Int
    var intelligenceModel: String?
    var batchModel: String?
    /// Upper bound, in ms, on waiting for the final polish after stop.
    var polishDeadlineMs: Int?
    /// nil when unset: patch editing defaults on and .env may force a value.
    var patchEditingOverride: Bool?
    /// nil when unset: the Settings toggle owns this unless .env forces a value.
    var optimisticPasteOverride: Bool?
    var envFileURL: URL?
    /// `.env` was found inside the app bundle, where older builds copied it.
    var envFileIsBundled: Bool

    static let defaultLanguage = "en-IN"
    static let defaultStopTailMs = 400
    static let defaultAudioDevice = ":0"

    var hasAPIKey: Bool { !apiKey.isEmpty }

    /// Keychain items belong to the binary that created them, so only the signed
    /// app bundle uses the Keychain; `swift run` reads the environment and `.env`.
    static var keychainAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func load(keychainKey: () -> String? = { AppEnvironment.keychainAvailable ? KeychainStore.readAPIKey() : nil }) -> AppEnvironment {
        let (fileURL, bundled) = locateDotEnv()
        let fileValues = fileURL.flatMap { parseDotEnv(at: $0) } ?? [:]

        func value(_ key: String, default defaultValue: String = "") -> String {
            if let existing = ProcessInfo.processInfo.environment[key], !existing.isEmpty {
                return existing
            }
            return fileValues[key] ?? defaultValue
        }
        func optional(_ key: String) -> String? {
            let raw = value(key)
            return raw.isEmpty ? nil : raw
        }
        func flag(_ key: String) -> Bool? {
            optional(key).map { $0 == "1" }
        }

        let processKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        let fileKey = fileValues["GEMINI_API_KEY"] ?? ""
        var storedKey = keychainKey()
        var migrated = false
        // First launch after the Keychain change: move a .env key into the Keychain
        // so later launches no longer depend on a plain-text file.
        if storedKey == nil, keychainAvailable, processKey.isEmpty, !fileKey.isEmpty,
           (try? KeychainStore.saveAPIKey(fileKey)) != nil
        {
            storedKey = fileKey
            migrated = true
        }
        let (apiKey, source) = resolveAPIKey(process: processKey, keychain: storedKey, dotEnv: fileKey)

        return AppEnvironment(
            apiKey: apiKey,
            apiKeySource: source,
            processAPIKey: processKey,
            dotEnvAPIKey: fileKey,
            migratedToKeychain: migrated,
            language: value("GEMINI_WHISPER_LANGUAGE", default: defaultLanguage),
            audioDevice: value("GEMINI_WHISPER_AUDIO_DEVICE", default: defaultAudioDevice),
            stopTailMs: max(0, Int(value("GEMINI_WHISPER_STOP_TAIL_MS")) ?? defaultStopTailMs),
            intelligenceModel: optional("GEMINI_WHISPER_INTELLIGENCE_MODEL"),
            batchModel: optional("GEMINI_WHISPER_BATCH_MODEL"),
            polishDeadlineMs: optional("GEMINI_WHISPER_POLISH_DEADLINE_MS").flatMap(Int.init).map { max(500, $0) },
            patchEditingOverride: flag("GEMINI_WHISPER_PATCH_EDITING"),
            optimisticPasteOverride: flag("GEMINI_WHISPER_OPTIMISTIC_PASTE"),
            envFileURL: fileURL,
            envFileIsBundled: bundled
        )
    }

    /// The process environment wins (explicit override), then the Keychain, then `.env`.
    static func resolveAPIKey(process: String, keychain: String?, dotEnv: String) -> (String, KeySource) {
        if !process.isEmpty { return (process, .environment) }
        if let keychain, !keychain.isEmpty { return (keychain, .keychain) }
        if !dotEnv.isEmpty { return (dotEnv, .dotEnv) }
        return ("", .none)
    }

    /// Known `.env` locations, most specific first. Older builds copied `.env` into
    /// the app bundle; that copy is still read so an existing install keeps working
    /// and its key migrates to the Keychain, but new builds no longer create it.
    private static func locateDotEnv() -> (URL?, Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Sources/GeminiWhisperApp/AppEnvironment.swift -> repository root.
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repoRoot.deleteLastPathComponent() }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidates = [
            home.appendingPathComponent(".config/gemini-whisper/.env"),
            home.appendingPathComponent(".gemini-whisper.env"),
            repoRoot.appendingPathComponent(".env"),
            cwd.appendingPathComponent(".env"),
        ]
        for url in candidates where FileManager.default.isReadableFile(atPath: url.path) {
            return (url.standardizedFileURL, false)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(".env"),
           FileManager.default.isReadableFile(atPath: bundled.path)
        {
            return (bundled.standardizedFileURL, true)
        }
        return (nil, false)
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
