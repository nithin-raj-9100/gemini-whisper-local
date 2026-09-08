import Foundation
import Observation

enum AppTranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case smart
    case verbatim
    var id: String { rawValue }
    var title: String { self == .smart ? "SMART" : "Verbatim" }
}

enum AppVadMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case hybrid
    case manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .hybrid: return "Hybrid"
        case .manual: return "Manual"
        }
    }
}

/// User-facing knobs. Seeded from `.env`, then overridden by UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let language = "language"
        static let vocabulary = "vocabulary"
        static let mode = "mode"
        static let polish = "polish"
        static let vad = "vad"
        static let audioDevice = "audioDevice"
        static let vadPrefixPaddingMs = "vadPrefixPaddingMs"
        static let vadSilenceDurationMs = "vadSilenceDurationMs"
        static let openAtLogin = "openAtLogin"
        static let optimisticPaste = "optimisticPaste"
    }

    /// Empty string means the system default input (not an ffmpeg `:N` index).
    static let systemDefaultDeviceID = AudioDeviceList.systemDefaultPreference

    var language: String
    var vocabularyText: String
    var mode: AppTranscriptionMode
    var polish: Bool
    var vad: AppVadMode
    var audioDevice: String
    var vadPrefixPaddingMs: Int
    var vadSilenceDurationMs: Int
    var openAtLogin: Bool
    var optimisticPaste: Bool
    var stopTailMs: Int
    let environment: AppEnvironment

    var vocabularyTerms: [String] {
        vocabularyText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    init(environment: AppEnvironment = .load(), defaults: UserDefaults = .standard) {
        self.environment = environment
        self.stopTailMs = environment.stopTailMs
        self.language = defaults.string(forKey: Keys.language) ?? environment.language
        self.vocabularyText = defaults.string(forKey: Keys.vocabulary) ?? ""
        if let raw = defaults.string(forKey: Keys.mode), let parsed = AppTranscriptionMode(rawValue: raw) {
            self.mode = parsed
        } else {
            self.mode = .smart
        }
        if defaults.object(forKey: Keys.polish) != nil {
            self.polish = defaults.bool(forKey: Keys.polish)
        } else {
            self.polish = true
        }
        if let raw = defaults.string(forKey: Keys.vad), let parsed = AppVadMode(rawValue: raw) {
            self.vad = parsed
        } else {
            self.vad = .manual
        }
        let storedDevice = defaults.string(forKey: Keys.audioDevice) ?? environment.audioDevice
        self.audioDevice = AudioDeviceList.normalizedPreference(storedDevice)
        if defaults.object(forKey: Keys.vadPrefixPaddingMs) != nil {
            self.vadPrefixPaddingMs = defaults.integer(forKey: Keys.vadPrefixPaddingMs)
        } else {
            self.vadPrefixPaddingMs = 500
        }
        if defaults.object(forKey: Keys.vadSilenceDurationMs) != nil {
            self.vadSilenceDurationMs = defaults.integer(forKey: Keys.vadSilenceDurationMs)
        } else {
            self.vadSilenceDurationMs = 1500
        }
        self.openAtLogin = defaults.object(forKey: Keys.openAtLogin) != nil
            ? defaults.bool(forKey: Keys.openAtLogin)
            : false
        // On by default: every failure path leaves the raw text in place, so the
        // worst case is verbatim output at verbatim latency. The env var only
        // seeds the first launch; the Settings toggle owns it afterwards.
        self.optimisticPaste = environment.optimisticPasteOverride
            ?? (defaults.object(forKey: Keys.optimisticPaste) != nil
                ? defaults.bool(forKey: Keys.optimisticPaste)
                : true)
    }

    func persist(defaults: UserDefaults = .standard) {
        vadPrefixPaddingMs = min(2000, max(0, vadPrefixPaddingMs))
        vadSilenceDurationMs = min(5000, max(100, vadSilenceDurationMs))
        defaults.set(language, forKey: Keys.language)
        defaults.set(vocabularyText, forKey: Keys.vocabulary)
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(polish, forKey: Keys.polish)
        defaults.set(vad.rawValue, forKey: Keys.vad)
        defaults.set(audioDevice, forKey: Keys.audioDevice)
        defaults.set(vadPrefixPaddingMs, forKey: Keys.vadPrefixPaddingMs)
        defaults.set(vadSilenceDurationMs, forKey: Keys.vadSilenceDurationMs)
        defaults.set(openAtLogin, forKey: Keys.openAtLogin)
        defaults.set(optimisticPaste, forKey: Keys.optimisticPaste)
    }
}
