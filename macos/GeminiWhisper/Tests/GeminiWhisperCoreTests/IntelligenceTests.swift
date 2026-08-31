import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("transcript intelligence")
struct IntelligenceTests {
    @Test func usesFlashLiteWithMinimalThinkingAndReturnsOnlyModelText() async throws {
        nonisolated(unsafe) var requestURL = ""
        nonisolated(unsafe) var request: URLRequest?
        let intelligence = createTranscriptIntelligence(
            apiKey: "test-only",
            httpClient: ClosureHTTPClient { incoming in
                requestURL = incoming.url?.absoluteString ?? ""
                request = incoming
                let body: [String: Any] = [
                    "candidates": [
                        ["content": ["parts": [["text": "1. Milk\n2. Vegetables"]]]],
                    ],
                ]
                return (try JSONSerialization.data(withJSONObject: body), 200)
            }
        )

        let result = try await intelligence.polish("number one milk number two vegetables")
        let body = try JSONSerialization.jsonObject(with: request!.httpBody!) as! [String: Any]
        let generationConfig = body["generationConfig"] as! [String: Any]
        let thinking = generationConfig["thinkingConfig"] as! [String: Any]
        let systemInstruction = body["systemInstruction"] as! [String: Any]
        let parts = systemInstruction["parts"] as! [[String: Any]]

        #expect(requestURL.contains("/gemini-3.5-flash-lite:generateContent"))
        #expect(!requestURL.contains("test-only"))
        #expect(request?.value(forHTTPHeaderField: "x-goog-api-key") == "test-only")
        #expect(thinking["thinkingLevel"] as? String == "MINIMAL")
        #expect(thinking["includeThoughts"] as? Bool == false)
        #expect((parts[0]["text"] as? String)?.contains("ALWAYS format the items") == true)
        #expect((parts[0]["text"] as? String)?.contains("@src/app.tsx") == true)
        #expect((parts[0]["text"] as? String)?.contains("Keep each actually spoken") == true)
        #expect((parts[0]["text"] as? String)?.contains("Never change the preposition \"to\"") == true)
        #expect((parts[0]["text"] as? String)?.contains("Semantic fidelity always outranks token reduction") == true)
        #expect((parts[0]["text"] as? String)?.contains("Let's see if this actually works now") == true)
        #expect((parts[0]["text"] as? String)?.contains("never summarize, generalize") == true)
        #expect(result.text == "1. Milk\n2. Vegetables")
        #expect(result.model == "gemini-3.5-flash-lite")
        #expect(TRANSCRIPT_INTELLIGENCE_SYSTEM_INSTRUCTION.contains("ALWAYS format the items"))
    }

    @Test func retriesATransientSocketFailureOnce() async throws {
        nonisolated(unsafe) var attempts = 0
        let intelligence = createTranscriptIntelligence(
            apiKey: "test-only",
            httpClient: ClosureHTTPClient { _ in
                attempts += 1
                if attempts == 1 {
                    throw URLError(.networkConnectionLost)
                }
                let body: [String: Any] = [
                    "candidates": [
                        ["content": ["parts": [["text": "Recovered text"]]]],
                    ],
                ]
                return (try JSONSerialization.data(withJSONObject: body), 200)
            }
        )

        let result = try await intelligence.polish("raw text")
        #expect(attempts == 2)
        #expect(result.text == "Recovered text")
    }

    @Test func retriesRetryableHTTPStatuses() async throws {
        nonisolated(unsafe) var attempts = 0
        let intelligence = createTranscriptIntelligence(
            apiKey: "test-only",
            httpClient: ClosureHTTPClient { _ in
                attempts += 1
                if attempts == 1 {
                    return (Data("{}".utf8), 429)
                }
                let body: [String: Any] = [
                    "candidates": [
                        ["content": ["parts": [["text": "After retry"]]]],
                    ],
                ]
                return (try JSONSerialization.data(withJSONObject: body), 200)
            }
        )

        let result = try await intelligence.polish("raw text")
        #expect(attempts == 2)
        #expect(result.text == "After retry")
    }

    @Test func returnsEmptyResultForEmptyTranscript() async throws {
        nonisolated(unsafe) var attempts = 0
        let intelligence = createTranscriptIntelligence(
            apiKey: "test-only",
            httpClient: ClosureHTTPClient { _ in
                attempts += 1
                return (Data(), 200)
            }
        )
        let result = try await intelligence.polish("   ")
        #expect(attempts == 0)
        #expect(result.text.isEmpty)
        #expect(result.latencyMs == 0)
    }
}
