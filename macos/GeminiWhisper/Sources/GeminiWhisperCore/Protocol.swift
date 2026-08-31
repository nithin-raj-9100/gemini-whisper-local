import Foundation

public struct ProtocolError: Error, Equatable, LocalizedError {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

private let languageCodePattern = try! NSRegularExpression(
    pattern: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"
)

public func parseClientCommand(_ raw: String) throws -> ClientCommand {
    let data = Data(raw.utf8)
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw ProtocolError(code: "invalid_json", message: "Control messages must be valid JSON.")
    }

    guard let object = parsed as? [String: Any], let type = object["type"] as? String else {
        throw ProtocolError(code: "invalid_command", message: "A control message requires a string type.")
    }

    switch type {
    case "start":
        if let config = object["config"] {
            guard config is [String: Any] else {
                throw ProtocolError(code: "invalid_config", message: "start.config must be an object.")
            }
            if let dict = config as? [String: Any] {
                return .start(config: dict.mapValues(JSONValue.fromJSONObject))
            }
        }
        return .start(config: nil)
    case "stop":
        return .stop
    case "cancel":
        return .cancel
    case "ping":
        return .ping
    default:
        throw ProtocolError(code: "unknown_command", message: "Unknown command: \(type)")
    }
}

public func normalizeConfig(_ input: [String: Any]? = nil) throws -> TranscriptionConfig {
    try normalizeConfig(input?.mapValues(JSONValue.fromJSONObject))
}

public func normalizeConfig(_ input: [String: JSONValue]? = nil) throws -> TranscriptionConfig {
    let defaults = TranscriptionConfig.default
    let modeRaw = stringValue(input?["mode"]) ?? defaults.mode.rawValue
    let mode: TranscriptionMode
    switch modeRaw {
    case "smart":
        mode = .smart
    case "verbatim":
        mode = .verbatim
    default:
        throw ProtocolError(code: "invalid_mode", message: "mode must be smart or verbatim.")
    }

    let polish: Bool
    if let polishValue = input?["polish"] {
        guard let bool = polishValue.boolValue else {
            throw ProtocolError(code: "invalid_polish", message: "polish must be a boolean.")
        }
        polish = bool
    } else {
        polish = mode != .verbatim && defaults.polish
    }

    let vadRaw = stringValue(input?["vad"]) ?? defaults.vad.rawValue
    let vad: VadMode
    switch vadRaw {
    case "automatic":
        vad = .automatic
    case "hybrid":
        vad = .hybrid
    case "manual":
        vad = .manual
    default:
        throw ProtocolError(code: "invalid_vad", message: "vad must be automatic, hybrid, or manual.")
    }

    let languageCodes: [String]
    if let languages = input?["languageCodes"] {
        guard let array = languages.arrayValue, array.count <= 10 else {
            throw ProtocolError(
                code: "invalid_languages",
                message: "languageCodes must contain at most 10 entries."
            )
        }
        languageCodes = try array.map { value in
            guard let code = value.stringValue, isLanguageCode(code) else {
                throw ProtocolError(
                    code: "invalid_languages",
                    message: "languageCodes must contain BCP-47-like codes."
                )
            }
            return code
        }
    } else {
        languageCodes = defaults.languageCodes
    }

    let customVocabulary: [String]
    if let vocabulary = input?["customVocabulary"] {
        guard let array = vocabulary.arrayValue, array.count <= 1000 else {
            throw ProtocolError(
                code: "invalid_vocabulary",
                message: "customVocabulary must contain at most 1,000 terms."
            )
        }
        customVocabulary = try array.map { value in
            guard let term = value.stringValue, !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, term.count <= 100
            else {
                throw ProtocolError(
                    code: "invalid_vocabulary",
                    message: "Vocabulary terms must be non-empty strings no longer than 100 characters."
                )
            }
            return term
        }
    } else {
        customVocabulary = defaults.customVocabulary
    }

    let vadPrefixPaddingMs = try intField(
        input?["vadPrefixPaddingMs"],
        default: defaults.vadPrefixPaddingMs,
        code: "invalid_vad_padding",
        message: "vadPrefixPaddingMs must be an integer between 0 and 2,000.",
        min: 0,
        max: 2000
    )
    let vadSilenceDurationMs = try intField(
        input?["vadSilenceDurationMs"],
        default: defaults.vadSilenceDurationMs,
        code: "invalid_vad_silence",
        message: "vadSilenceDurationMs must be an integer between 100 and 5,000.",
        min: 100,
        max: 5000
    )

    return TranscriptionConfig(
        mode: mode,
        polish: polish,
        languageCodes: uniqued(languageCodes),
        customVocabulary: uniqued(customVocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
        vad: vad,
        vadPrefixPaddingMs: vadPrefixPaddingMs,
        vadSilenceDurationMs: vadSilenceDurationMs
    )
}

public func normalizeConfig(_ config: TranscriptionConfig) throws -> TranscriptionConfig {
    try normalizeConfig([
        "mode": config.mode.rawValue,
        "polish": config.polish,
        "languageCodes": config.languageCodes,
        "customVocabulary": config.customVocabulary,
        "vad": config.vad.rawValue,
        "vadPrefixPaddingMs": config.vadPrefixPaddingMs,
        "vadSilenceDurationMs": config.vadSilenceDurationMs,
    ])
}

private func stringValue(_ value: JSONValue?) -> String? {
    value?.stringValue
}

private func isLanguageCode(_ code: String) -> Bool {
    let range = NSRange(code.startIndex..., in: code)
    return languageCodePattern.firstMatch(in: code, range: range) != nil
}

private func intField(
    _ value: JSONValue?,
    default defaultValue: Int,
    code: String,
    message: String,
    min: Int,
    max: Int
) throws -> Int {
    let resolved: Int
    if let value {
        guard value.isExactInt, let int = value.intValue else {
            throw ProtocolError(code: code, message: message)
        }
        resolved = int
    } else {
        resolved = defaultValue
    }
    guard resolved >= min, resolved <= max else {
        throw ProtocolError(code: code, message: message)
    }
    return resolved
}

private func uniqued(_ items: [String]) -> [String] {
    var seen = Set<String>()
    return items.filter { seen.insert($0).inserted }
}
