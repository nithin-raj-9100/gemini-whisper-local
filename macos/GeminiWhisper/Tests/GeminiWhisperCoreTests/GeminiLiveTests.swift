import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("Gemini wire protocol")
struct GeminiLiveTests {
    @Test func buildsASmartTranscriptionSetup() {
        var config = TranscriptionConfig.default
        config.languageCodes = ["en-IN"]
        config.customVocabulary = ["Bun"]
        let expected: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.5-transcribe-live",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": [
                    "languageCodes": ["en-IN"],
                    "customVocabulary": ["Bun"],
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
        #expect(eventTypes == ["ready", "speech-start", "final", "speech-end", "complete"])
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

    @Test func finishTimeoutPromotesLatestInterimToComplete() async throws {
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
        #expect(events.contains(.final(text: "Words from the HUD")))
        #expect(events.contains { event in
            if case .warning(let code, _) = event { return code == "finalization_ack_timeout" }
            return false
        })
        #expect(events.last?.typeName == "complete")
        #expect(!events.contains { $0.typeName == "error" })
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
