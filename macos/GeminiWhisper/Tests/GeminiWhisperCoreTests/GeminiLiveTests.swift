import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("Gemini wire protocol")
struct GeminiLiveTests {
    @Test func buildsASmartTranscriptionSetup() {
        var config = TranscriptionConfig.default
        config.languageCodes = ["en-IN"]
        config.customVocabulary = ["Codex"]
        let expected: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.5-transcribe-live",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": [
                    "languageCodes": ["en-IN"],
                    "customVocabulary": ["Codex"],
                    "mode": "SMART",
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": true,
                    ],
                ],
            ],
        ]
        #expect(jsonEquals(buildGeminiSetup(config), expected))
    }

    @Test func buildsHybridVadSetupWithSilenceDuration() {
        var config = TranscriptionConfig.default
        config.vad = .hybrid
        let setup = (buildGeminiSetup(config)["setup"] as! [String: Any])["realtimeInputConfig"] as! [String: Any]
        let detection = setup["automaticActivityDetection"] as! [String: Any]
        #expect(detection["disabled"] as? Bool == false)
        #expect(detection["silenceDurationMs"] as? Int == 1500)
    }

    @Test func addsManualVADConfiguration() {
        var config = TranscriptionConfig.default
        config.vad = .manual
        let message = buildGeminiSetup(config)
        let setup = (message["setup"] as! [String: Any])["realtimeInputConfig"] as! [String: Any]
        let detection = setup["automaticActivityDetection"] as! [String: Any]
        #expect(detection["disabled"] as? Bool == true)
    }

    @Test func extractsSetupInterimFinalAndCompletionEvents() {
        #expect(parseGeminiMessage(["setupComplete": [String: Any]()]) == [.ready])
        #expect(
            parseGeminiMessage([
                "serverContent": [
                    "interimInputTranscription": ["text": "hel"],
                    "inputTranscription": ["text": "Hello."],
                    "turnComplete": true,
                ],
            ]) == [.interim(text: "hel"), .final(text: "Hello."), .complete]
        )
        #expect(
            parseGeminiMessage([
                "error": ["code": 400, "message": "bad request", "status": "INVALID_ARGUMENT"],
            ]).contains { event in
                if case .error(let code, let message, _) = event {
                    return code == "INVALID_ARGUMENT" && message.contains("bad request")
                }
                return false
            }
        )
    }

    @Test func preservesPriorTextWhenGeminiStartsANewInterimWindow() {
        var accumulator = InterimTranscriptAccumulator()
        _ = accumulator.accept("No, this is not what I meant.")
        let first = accumulator.accept(
            "No, this is not what I meant. As seen in the attached image, when I speak some part"
        )
        #expect(first == "No, this is not what I meant. As seen in the attached image, when I speak some part")

        let reset = accumulator.accept("after this You can see that it")
        #expect(reset == first + " after this You can see that it")

        let expanded = accumulator.accept(
            "after this You can see that it no longer shows the earlier transcript"
        )
        #expect(expanded == first + " after this You can see that it no longer shows the earlier transcript")
    }

    @Test func allowsARewrittenInterimHypothesisToReplaceSimilarSizedText() {
        var accumulator = InterimTranscriptAccumulator()
        _ = accumulator.accept("The model should tell me what went correctly today")
        #expect(accumulator.accept("The model should tell the team what went wrong today")
            == "The model should tell the team what went wrong today")
    }

    @Test func slidingInterimRevisionsDoNotFabricateRepeatedParagraphs() {
        var accumulator = InterimTranscriptAccumulator()
        _ = accumulator.accept("My app targets developers and should make prompts shorter")
        _ = accumulator.accept("making prompts shorter for example oh my god should become OMG")
        let result = accumulator.accept(
            "for example oh my god should become OMG and numeric quantities should use digits"
        )

        #expect(result == "My app targets developers and should make prompts shorter "
            + "making prompts shorter for example oh my god should become OMG "
            + "and numeric quantities should use digits")
        #expect(result.components(separatedBy: "oh my god should become OMG").count == 2)
    }

    @Test func preservesPriorSentenceWhenNewSentenceBeginsWithCapitalLetters() {
        var accumulator = InterimTranscriptAccumulator()
        _ = accumulator.accept("There are two types of inconsistencies observed in this application.")
        let second = accumulator.accept("Second inconsistency is sometimes the end words are being cut off.")
        #expect(second == "There are two types of inconsistencies observed in this application. Second inconsistency is sometimes the end words are being cut off.")
    }

    @Test func finalEventPreservesAccumulatedInterimText() async throws {
        let socket = FakeWebSocket()
        var events: [ServerEvent] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: .default,
            emit: { events.append($0) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()

        socket.simulateJSON([
            "serverContent": ["interimInputTranscription": ["text": "First sentence was spoken earlier."]],
        ])
        await Task.yield()

        socket.simulateJSON([
            "serverContent": ["inputTranscription": ["text": "Second sentence is final."]],
        ])
        await Task.yield()

        #expect(events.contains(.final(text: "First sentence was spoken earlier. Second sentence is final.")))
    }

    @Test func keepsSessionOpenThroughMidUtteranceTurnCompleteAndPauseAudio() async throws {
        let socket = FakeWebSocket()
        var eventTypes: [String] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: .default,
            emit: { eventTypes.append($0.typeName) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        #expect(jsonEquals(jsonObject(socket.sent[0]), buildGeminiSetup(.default)))
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()

        #expect(eventTypes == ["ready", "speech-start"])
        #expect(jsonEquals(jsonObject(socket.sent[1]), [
            "realtimeInput": ["activityStart": [String: Any]()],
        ]))
        try transcriber.sendAudio(Data([1, 0]))
        #expect(jsonEquals(jsonObject(socket.sent[2]), [
            "realtimeInput": [
                "audio": ["data": "AQA=", "mimeType": "audio/pcm;rate=16000"],
            ],
        ]))
        socket.simulateJSON(["serverContent": ["turnComplete": true]])
        await Task.yield()
        #expect(eventTypes == ["ready", "speech-start"])
        try transcriber.sendAudio(Data([2, 0]))
        #expect(jsonEquals(jsonObject(socket.sent[3]), [
            "realtimeInput": [
                "audio": ["data": "AgA=", "mimeType": "audio/pcm;rate=16000"],
            ],
        ]))
        try transcriber.finish()
        #expect(jsonEquals(jsonObject(socket.sent[4]), [
            "realtimeInput": ["activityEnd": [String: Any]()],
        ]))

        socket.simulateJSON([
            "serverContent": [
                "inputTranscription": ["text": "Hello."],
                "turnComplete": true,
            ],
        ])
        await Task.yield()
        #expect(eventTypes == ["ready", "speech-start", "speech-end", "final", "complete"])
    }

    @Test func finishesImmediatelyWhenAutomaticVADAlreadyCompletedTheLastAudio() async throws {
        let socket = FakeWebSocket()
        var eventTypes: [String] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: hybridConfig(),
            emit: { eventTypes.append($0.typeName) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()
        try transcriber.sendAudio(Data([1, 0]))
        try await Task.sleep(for: .milliseconds(900))
        socket.simulateJSON([
            "serverContent": [
                "inputTranscription": ["text": "Already final."],
                "turnComplete": true,
            ],
        ])
        await Task.yield()

        let sentBeforeFinish = socket.sent.count
        try transcriber.finish()

        #expect(socket.sent.count == sentBeforeFinish)
        #expect(eventTypes == ["ready", "speech-start", "final", "turn-boundary", "speech-end", "complete"])
    }

    @Test func promotesAnInterimHypothesisWhenTurnCompletionOmitsAFinalTranscript() async throws {
        let socket = FakeWebSocket()
        var events: [ServerEvent] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: hybridConfig(),
            emit: { events.append($0) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()
        try transcriber.sendAudio(Data([1, 0]))
        try await Task.sleep(for: .milliseconds(900))
        socket.simulateJSON([
            "serverContent": [
                "interimInputTranscription": ["text": "Buffered words"],
                "turnComplete": true,
            ],
        ])
        await Task.yield()
        try transcriber.finish()

        #expect(events.contains(.final(text: "Buffered words")))
        #expect(events.last?.typeName == "complete")
    }

    @Test func doesNotSkipFinalizationWhenALateTurnCompleteRacesWithRecentAudio() async throws {
        let socket = FakeWebSocket()
        var events: [ServerEvent] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: hybridConfig(),
            emit: { events.append($0) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()
        try transcriber.sendAudio(Data([1, 0]))
        socket.simulateJSON(["serverContent": ["turnComplete": true]])
        await Task.yield()
        try transcriber.finish()

        #expect(jsonEquals(jsonObject(socket.sent.last!), [
            "realtimeInput": ["audioStreamEnd": true],
        ]))
        #expect(!events.contains { $0.typeName == "complete" })

        socket.simulateJSON([
            "serverContent": [
                "inputTranscription": ["text": "Resumed speech."],
                "turnComplete": true,
            ],
        ])
        await Task.yield()
        #expect(events.contains(.final(text: "Resumed speech.")))
        #expect(events.last?.typeName == "complete")
    }

    @Test func reconnectsAnUnexpectedUpstreamCloseAndFlushesBufferedAudio() async throws {
        let sockets = SocketList()
        var eventTypes: [String] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: .default,
            emit: { eventTypes.append($0.typeName) },
            webSocketFactory: { _ in
                let socket = FakeWebSocket()
                sockets.append(socket)
                return socket
            }
        )

        async let connected: Void = transcriber.connect()
        for _ in 0..<50 where sockets.count == 0 {
            await Task.yield()
        }
        sockets[0].simulateOpen()
        sockets[0].simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()
        sockets[0].remoteClose(code: 1000, reason: "Connection ended")
        try transcriber.sendAudio(Data([3, 0]))

        try await Task.sleep(for: .milliseconds(250))
        #expect(sockets.count == 2)
        sockets[1].simulateOpen()
        sockets[1].simulateJSON(["setupComplete": [String: Any]()])
        await Task.yield()

        #expect(eventTypes == ["ready", "speech-start", "connecting", "ready", "speech-start"])
        #expect(jsonEquals(jsonObject(sockets[1].sent[1]), [
            "realtimeInput": ["activityStart": [String: Any]()],
        ]))
        let audio = jsonObject(sockets[1].sent[2]) as! [String: Any]
        let realtime = audio["realtimeInput"] as! [String: Any]
        let payload = realtime["audio"] as! [String: Any]
        #expect(payload["data"] as? String == "AwA=")
        transcriber.close()
    }

    @Test func reconnectsWhenTransportIsClosingBeforeCloseCallback() async throws {
        let sockets = SocketList()
        var eventTypes: [String] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: .default,
            emit: { eventTypes.append($0.typeName) },
            webSocketFactory: { _ in
                let socket = FakeWebSocket()
                sockets.append(socket)
                return socket
            }
        )

        async let connected: Void = transcriber.connect()
        for _ in 0..<50 where sockets.count == 0 {
            await Task.yield()
        }
        sockets[0].simulateOpen()
        sockets[0].simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()

        // Reproduce URLSession's failure window: its wrapper has stopped being
        // open, but the transcriber has not received a close callback yet.
        sockets[0].readyState = .closing
        try transcriber.sendAudio(Data([4, 0]))

        try await Task.sleep(for: .milliseconds(250))
        #expect(sockets.count == 2)
        sockets[1].simulateOpen()
        sockets[1].simulateJSON(["setupComplete": [String: Any]()])
        await Task.yield()

        #expect(eventTypes == ["ready", "speech-start", "connecting", "ready", "speech-start"])
        let audio = jsonObject(sockets[1].sent[2]) as! [String: Any]
        let realtime = audio["realtimeInput"] as! [String: Any]
        let payload = realtime["audio"] as! [String: Any]
        #expect(payload["data"] as? String == "BAA=")
        transcriber.close()
    }

    @Test func redactsApiKeysInCloseReasons() async throws {
        let socket = FakeWebSocket()
        var events: [ServerEvent] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: .default,
            emit: { events.append($0) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        socket.remoteClose(code: 1008, reason: "quota AIzaSyTestKey123 for project")
        await Task.yield()

        let warning = events.last { event in
            if case .error = event { return true }
            if case .warning = event { return true }
            return false
        }
        if case .error(_, let message, _) = warning {
            #expect(!message.contains("AIza"))
            #expect(message.contains("[redacted]"))
        } else if case .warning(_, let message) = warning {
            #expect(!message.contains("AIza"))
            #expect(message.contains("[redacted]"))
        } else {
            Issue.record("expected a closed-session error or warning")
        }
    }

    @Test func waitsBeyondFastGraceForFinalWords() async throws {
        let socket = FakeWebSocket()
        var events: [ServerEvent] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: .default,
            emit: { events.append($0) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()
        try transcriber.sendAudio(Data([1, 0]))
        socket.simulateJSON([
            "serverContent": ["interimInputTranscription": ["text": "Words from the HUD"]],
        ])
        await Task.yield()
        try transcriber.finish()

        try await Task.sleep(for: .milliseconds(1_500))
        #expect(!events.contains { $0.typeName == "complete" })
        socket.simulateJSON([
            "serverContent": ["inputTranscription": ["text": "Words from the HUD including the last words"]],
        ])
        #expect(events.contains(.final(text: "Words from the HUD including the last words")))
        #expect(events.last?.typeName == "complete")
    }

    @Test func unexpectedCloseWhileListeningDoesNotCompleteUntilFinish() async throws {
        let socket = FakeWebSocket()
        var events: [ServerEvent] = []
        let transcriber = GeminiLiveTranscriber(
            apiKey: "test-only",
            config: .default,
            emit: { events.append($0) },
            webSocketFactory: { _ in socket }
        )

        async let connected: Void = transcriber.connect()
        await Task.yield()
        socket.simulateOpen()
        socket.simulateJSON(["setupComplete": [String: Any]()])
        try await connected
        await Task.yield()
        try transcriber.sendAudio(Data([1, 0]))
        socket.simulateJSON([
            "serverContent": ["interimInputTranscription": ["text": "Still on the HUD"]],
        ])
        await Task.yield()
        socket.remoteClose(code: 1008, reason: "policy")
        await Task.yield()

        #expect(!events.contains { $0.typeName == "complete" })
        #expect(!events.contains { $0.typeName == "error" })
        #expect(events.contains { event in
            if case .warning(let code, _) = event { return code == "gemini_connection_closed" }
            return false
        })

        try transcriber.finish()
        await Task.yield()
        #expect(events.contains(.final(text: "Still on the HUD")))
        #expect(events.last?.typeName == "complete")
    }
}

private func hybridConfig() -> TranscriptionConfig {
    var config = TranscriptionConfig.default
    config.vad = .hybrid
    return config
}
