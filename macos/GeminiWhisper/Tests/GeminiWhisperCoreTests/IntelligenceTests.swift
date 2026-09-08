import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("transcript intelligence")
struct IntelligenceTests {
    @Test func revisionGetsWholeContextAndCanChangeEarlierSentences() async throws {
        let intelligence = GeminiTranscriptIntelligence(apiKey: "test-only", httpClient: ClosureHTTPClient { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let contents = body["contents"] as! [[String: Any]]
            let parts = contents[0]["parts"] as! [[String: String]]
            let context = try JSONSerialization.jsonObject(with: Data(parts[0]["text"]!.utf8)) as! [String: String]
            #expect(context["previousCandidate"] == "Set the timeout to 15 seconds.")
            #expect(context["currentRawTranscript"] == "set timeout to fifteen seconds actually make that fifty")
            let response: [String: Any] = ["candidates": [["content": ["parts": [["text": "Set the timeout to 50 seconds."]]]]]]
            return (try JSONSerialization.data(withJSONObject: response), 200)
        })
        let result = try await intelligence.revise("set timeout to fifteen seconds actually make that fifty",
            previousInput: "set timeout to fifteen seconds", previousOutput: "Set the timeout to 15 seconds.")
        #expect(result.text == "Set the timeout to 50 seconds.")
    }

    @Test func invalidPatchFallsBackToCompleteCurrentTranscript() async throws {
        nonisolated(unsafe) var calls = 0
        let raw = String(repeating: "word ", count: 170) + "last words"
        let intelligence = GeminiTranscriptIntelligence(apiKey: "test-only", httpClient: ClosureHTTPClient { request in
            calls += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let config = body["generationConfig"] as! [String: Any]
            if calls == 1 { #expect(config["responseMimeType"] as? String == "application/json") }
            let text = calls == 1 ? #"{"revision":"wrong","edits":[]}"# : raw
            let response: [String: Any] = ["candidates": [["content": ["parts": [["text": text]]]]]]
            return (try JSONSerialization.data(withJSONObject: response), 200)
        }, patchEditing: true)
        let result = try await intelligence.revise(raw, previousInput: "earlier words", previousOutput: "Earlier words.")
        #expect(calls == 2)
        #expect(result.text == raw)
        #expect(result.attempts == 2)
    }

    @Test func usesFlashLiteWithThinkingDisabledAndReturnsOnlyModelText() async throws {
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
        #expect(thinking["thinkingBudget"] as? Int == 0)
        // thinkingLevel and thinkingBudget are mutually exclusive; sending both is rejected.
        #expect(thinking["thinkingLevel"] == nil)
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
        #expect(result.attempts == 1)
        #expect(result.statuses == [200])
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
        #expect(result.attempts == 2)
        #expect(result.statuses == [429, 200])
    }

    @Test func throwsWhenOutputIsTruncatedByTokenCap() async throws {
        let intelligence = createTranscriptIntelligence(
            apiKey: "test-only",
            httpClient: ClosureHTTPClient { _ in
                let body: [String: Any] = [
                    "candidates": [
                        [
                            "content": ["parts": [["text": "partial polish"]]],
                            "finishReason": "MAX_TOKENS",
                        ],
                    ],
                ]
                return (try JSONSerialization.data(withJSONObject: body), 200)
            }
        )

        var threw = false
        do {
            _ = try await intelligence.polish("some transcript that would be cut off")
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test func returnsEmptyResultForEmptyTranscript() async throws {        nonisolated(unsafe) var attempts = 0
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
