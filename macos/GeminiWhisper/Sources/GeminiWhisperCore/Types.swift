import Foundation

public enum TranscriptionMode: String, Sendable, Equatable {
    case smart
    case verbatim
}

public enum VadMode: String, Sendable, Equatable {
    case automatic
    case hybrid
    case manual
}

public struct TranscriptionConfig: Sendable, Equatable {
    public var mode: TranscriptionMode
    public var polish: Bool
    public var languageCodes: [String]
    public var customVocabulary: [String]
    public var vad: VadMode
    public var vadPrefixPaddingMs: Int
    public var vadSilenceDurationMs: Int

    public init(
        mode: TranscriptionMode,
        polish: Bool,
        languageCodes: [String],
        customVocabulary: [String],
        vad: VadMode,
        vadPrefixPaddingMs: Int,
        vadSilenceDurationMs: Int
    ) {
        self.mode = mode
        self.polish = polish
        self.languageCodes = languageCodes
        self.customVocabulary = customVocabulary
        self.vad = vad
        self.vadPrefixPaddingMs = vadPrefixPaddingMs
        self.vadSilenceDurationMs = vadSilenceDurationMs
    }

    public static let `default` = TranscriptionConfig(
        mode: .smart,
        polish: true,
        languageCodes: [],
        customVocabulary: [],
        vad: .manual,
        vadPrefixPaddingMs: 500,
        vadSilenceDurationMs: 1500
    )

    /// Option-toggle dictation: manual VAD so pauses stay in one utterance until the user stops.
    public static let systemDictationDefaults = TranscriptionConfig.default
}

public struct AudioContract: Sendable, Equatable {
    public var encoding: String
    public var sampleRate: Int
    public var channels: Int
    public var chunkMilliseconds: Int

    public init(encoding: String, sampleRate: Int, channels: Int, chunkMilliseconds: Int) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channels = channels
        self.chunkMilliseconds = chunkMilliseconds
    }
}

public let AUDIO_CONTRACT = AudioContract(
    encoding: "pcm_s16le",
    sampleRate: 16_000,
    channels: 1,
    chunkMilliseconds: 100
)

public enum ClientCommand: Sendable, Equatable {
    case start(config: [String: JSONValue]?)
    case stop
    case cancel
    case ping
}

public enum ServerEvent: Sendable, Equatable {
    case hello(protocolVersion: Int, audio: AudioContract)
    case connecting
    case ready
    case speechStart
    case speechEnd
    case interim(text: String)
    case final(text: String)
    case polished(text: String, model: String, latencyMs: Int, speculative: Bool?)
    case warning(code: String, message: String)
    case complete
    case cancelled
    case pong
    case error(code: String, message: String, retryable: Bool)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .speechStart: return "speech-start"
        case .speechEnd: return "speech-end"
        case .interim: return "interim"
        case .final: return "final"
        case .polished: return "polished"
        case .warning: return "warning"
        case .complete: return "complete"
        case .cancelled: return "cancelled"
        case .pong: return "pong"
        case .error: return "error"
        }
    }
}

public struct IntelligenceResult: Sendable, Equatable {
    public var text: String
    public var model: String
    public var latencyMs: Int

    public init(text: String, model: String, latencyMs: Int) {
        self.text = text
        self.model = model
        self.latencyMs = latencyMs
    }
}

public struct TranscriptionError: Error, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// JSON-compatible value used when parsing loosely typed protocol payloads.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.rounded() == value:
            return Int(value)
        default:
            return nil
        }
    }

    public var isExactInt: Bool {
        switch self {
        case .int:
            return true
        case .double(let value):
            return value.rounded() == value && value >= Double(Int.min) && value <= Double(Int.max)
        default:
            return false
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public static func fromJSONObject(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            if double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) {
                return .int(number.intValue)
            }
            return .double(double)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let string as String:
            return .string(string)
        case let array as [String]:
            return .array(array.map { .string($0) })
        case let array as [Any]:
            return .array(array.map(JSONValue.fromJSONObject))
        case let array as NSArray:
            return .array(array.map { JSONValue.fromJSONObject($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues(JSONValue.fromJSONObject))
        case let dict as [String: String]:
            return .object(dict.mapValues { .string($0) })
        case let dict as NSDictionary:
            var result: [String: JSONValue] = [:]
            for (key, nested) in dict {
                if let key = key as? String {
                    result[key] = JSONValue.fromJSONObject(nested)
                }
            }
            return .object(result)
        default:
            return .null
        }
    }
}

public func redactApiKeys(_ text: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "AIza[\\w-]+")
    let range = NSRange(text.startIndex..., in: text)
    let redacted = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "[redacted]")
    return String(redacted.prefix(240))
}

func nowMilliseconds() -> Double {
    ProcessInfo.processInfo.systemUptime * 1000
}
