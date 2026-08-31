import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("local protocol")
struct ProtocolTests {
    @Test func parsesCommandsAndAppliesSafeDefaults() throws {
        let parsed = try parseClientCommand(#"{"type":"stop"}"#)
        #expect(parsed == .stop)

        let config = try normalizeConfig()
        #expect(config == TranscriptionConfig(
            mode: .smart,
            polish: true,
            languageCodes: [],
            customVocabulary: [],
            vad: .manual,
            vadPrefixPaddingMs: 500,
            vadSilenceDurationMs: 1500
        ))
    }

    @Test func deduplicatesVocabularyAndLanguages() throws {
        let config = try normalizeConfig([
            "languageCodes": ["en-IN", "en-IN"],
            "customVocabulary": [" Gemini ", "Gemini"],
        ])
        #expect(config.languageCodes == ["en-IN"])
        #expect(config.customVocabulary == ["Gemini"])
    }

    @Test func rejectsMalformedCommandsAndConfig() {
        do {
            _ = try parseClientCommand("nope")
            Issue.record("expected throw")
        } catch {
            #expect(expectMessage(error, contains: "valid JSON"))
        }

        do {
            _ = try parseClientCommand(#"{"type":"wat"}"#)
            Issue.record("expected throw")
        } catch {
            #expect(expectMessage(error, contains: "Unknown command"))
        }

        do {
            _ = try normalizeConfig(["mode": "other"])
            Issue.record("expected throw")
        } catch {
            #expect(expectMessage(error, contains: "mode"))
        }

        do {
            _ = try normalizeConfig(["polish": "yes"])
            Issue.record("expected throw")
        } catch {
            #expect(expectMessage(error, contains: "polish"))
        }

        do {
            _ = try normalizeConfig(["languageCodes": ["not a code"]])
            Issue.record("expected throw")
        } catch {
            #expect(expectMessage(error, contains: "BCP-47"))
        }

        do {
            _ = try normalizeConfig(["vadPrefixPaddingMs": 2001])
            Issue.record("expected throw")
        } catch {
            #expect(expectMessage(error, contains: "2,000"))
        }

        do {
            _ = try normalizeConfig(["vadSilenceDurationMs": 50])
            Issue.record("expected throw")
        } catch {
            #expect(expectMessage(error, contains: "5,000"))
        }
    }

    @Test func systemDictationDefaultsUseManualVad() {
        #expect(TranscriptionConfig.systemDictationDefaults.vadPrefixPaddingMs == 500)
        #expect(TranscriptionConfig.systemDictationDefaults.vadSilenceDurationMs == 1500)
        #expect(TranscriptionConfig.systemDictationDefaults.vad == .manual)
        #expect(TranscriptionConfig.systemDictationDefaults.mode == .smart)
        #expect(TranscriptionConfig.systemDictationDefaults.polish == true)
        #expect(TranscriptionConfig.systemDictationDefaults == TranscriptionConfig.default)
    }
}
