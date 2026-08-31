import Foundation
import GeminiWhisperCore
import os

/// Maps App settings onto Core `TranscriptionConfig`.
@MainActor
enum CoreConfigFactory {
    static func make(settings: AppSettings) throws -> TranscriptionConfig {
        let mode: TranscriptionMode = settings.mode == .verbatim ? .verbatim : .smart
        let polish = settings.mode == .verbatim ? false : settings.polish
        let vad: VadMode
        switch settings.vad {
        case .automatic: vad = .automatic
        case .hybrid: vad = .hybrid
        case .manual: vad = .manual
        }

        var config = TranscriptionConfig.systemDictationDefaults
        config.mode = mode
        config.polish = polish
        config.languageCodes = settings.language.isEmpty ? [] : [settings.language]
        config.customVocabulary = settings.vocabularyTerms
        config.vad = vad
        config.vadPrefixPaddingMs = settings.vadPrefixPaddingMs
        config.vadSilenceDurationMs = settings.vadSilenceDurationMs
        return try normalizeConfig(config)
    }
}

enum AppLog {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/gemini-whisper.app.log")

    private static let logger = Logger(subsystem: "com.nithin.gemini-whisper", category: "app")
    private static let fileLock = NSLock()

    static func line(_ message: String) {
        let redacted = redact(message)
        FileHandle.standardError.write(Data((redacted + "\n").utf8))
        logger.notice("\(redacted, privacy: .public)")
        appendToFile(redacted)
    }

    static func redact(_ message: String) -> String {
        redactApiKeys(message)
    }

    private static func appendToFile(_ message: String) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) \(message)\n".utf8)
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

/// App-facing view of a Core `ServerEvent`.
struct AppTranscriptEvent: Sendable {
    enum Kind: Sendable {
        case connecting
        case ready
        case speechStart
        case speechEnd
        case interim
        case final
        case polished
        case warning
        case complete
        case cancelled
        case error
        case other
    }

    var kind: Kind
    var text: String
    var model: String
    var latencyMs: Int
    var speculative: Bool
    var code: String
    var message: String
    var retryable: Bool
}

func adaptServerEvent(_ event: ServerEvent) -> AppTranscriptEvent {
    switch event {
    case .connecting:
        return makeEvent(kind: .connecting)
    case .ready:
        return makeEvent(kind: .ready)
    case .speechStart:
        return makeEvent(kind: .speechStart)
    case .speechEnd:
        return makeEvent(kind: .speechEnd)
    case .interim(let text):
        return makeEvent(kind: .interim, text: text)
    case .final(let text):
        return makeEvent(kind: .final, text: text)
    case .polished(let text, let model, let latencyMs, let speculative):
        return makeEvent(
            kind: .polished,
            text: text,
            model: model,
            latencyMs: latencyMs,
            speculative: speculative ?? false
        )
    case .warning(let code, let message):
        return makeEvent(kind: .warning, code: code, message: AppLog.redact(message))
    case .complete:
        return makeEvent(kind: .complete)
    case .cancelled:
        return makeEvent(kind: .cancelled)
    case .error(let code, let message, let retryable):
        return makeEvent(kind: .error, code: code, message: AppLog.redact(message), retryable: retryable)
    case .hello, .pong:
        return makeEvent(kind: .other)
    }
}

private func makeEvent(
    kind: AppTranscriptEvent.Kind,
    text: String = "",
    model: String = "",
    latencyMs: Int = 0,
    speculative: Bool = false,
    code: String = "",
    message: String = "",
    retryable: Bool = false
) -> AppTranscriptEvent {
    AppTranscriptEvent(
        kind: kind,
        text: text,
        model: model,
        latencyMs: latencyMs,
        speculative: speculative,
        code: code,
        message: message,
        retryable: retryable
    )
}

/// Thin wrapper around Core `DictationSession` + `PcmChunker`.
/// `DictationSession` constructs `GeminiLiveTranscriber` (`LiveTranscriber`) by default.
final class CoreDictationBox: @unchecked Sendable {
    private let session: DictationSession
    private let chunker = PcmChunker()

    init(
        apiKey: String,
        config: TranscriptionConfig,
        intelligenceModel: String?,
        emit: @escaping (AppTranscriptEvent) -> Void
    ) {
        let intelligence: (any TranscriptIntelligence)? =
            config.polish ? createTranscriptIntelligence(apiKey: apiKey, model: intelligenceModel) : nil
        session = DictationSession(
            apiKey: apiKey,
            config: config,
            emit: { event in
                emit(adaptServerEvent(event))
            },
            intelligence: intelligence,
            speculativeIntelligence: true
        )
    }

    func connect() async throws {
        try await session.start()
    }

    func sendAudio(_ pcm: Data) throws {
        let frames = chunker.push(pcm)
        for frame in frames {
            try session.sendAudio(frame)
        }
    }

    func flush() throws {
        if let tail = chunker.flush(), !tail.isEmpty {
            try session.sendAudio(tail)
        }
    }

    func stop() throws {
        try session.stop()
    }

    func cancel() {
        session.cancel()
    }

    func close() {
        session.close()
    }
}
