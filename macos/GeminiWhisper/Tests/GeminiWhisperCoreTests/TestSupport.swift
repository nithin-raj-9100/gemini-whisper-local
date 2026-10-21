import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GeminiWhisperCore
import Testing

/// In-memory socket. Thread-safe: the transcriber installs callbacks from the
/// connecting task while tests drive the socket from their own task.
final class FakeWebSocket: GeminiWebSocket, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var state: GeminiWebSocketState = .connecting
    private var sentMessages: [String] = []
    private var openHandler: (() -> Void)?
    private var messageHandler: ((String) -> Void)?
    private var errorHandler: (() -> Void)?
    private var closeHandler: ((Int, String) -> Void)?
    private var pendingOpen = false
    private var pendingMessages: [String] = []
    private var pendingClose: (Int, String)?

    var readyState: GeminiWebSocketState {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }

    var sent: [String] { lock.withLock { sentMessages } }

    var onOpen: (() -> Void)? {
        get { lock.withLock { openHandler } }
        set { lock.withLock { openHandler = newValue }; flushPending() }
    }

    var onMessage: ((String) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue }; flushPending() }
    }

    var onError: (() -> Void)? {
        get { lock.withLock { errorHandler } }
        set { lock.withLock { errorHandler = newValue } }
    }

    var onClose: ((Int, String) -> Void)? {
        get { lock.withLock { closeHandler } }
        set { lock.withLock { closeHandler = newValue }; flushPending() }
    }

    func send(_ text: String) {
        lock.withLock { sentMessages.append(text) }
    }

    func close(code: Int, reason: String) {
        let handler: ((Int, String) -> Void)? = lock.withLock {
            guard state != .closed else { return nil }
            state = .closed
            return closeHandler
        }
        handler?(code, reason)
    }

    func simulateOpen() {
        let handler: (() -> Void)? = lock.withLock {
            guard let openHandler else { pendingOpen = true; return nil }
            state = .open
            return openHandler
        }
        handler?()
    }

    func simulateJSON(_ value: Any) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        let text = String(data: data, encoding: .utf8)!
        let handler: ((String) -> Void)? = lock.withLock {
            guard let messageHandler else { pendingMessages.append(text); return nil }
            return messageHandler
        }
        handler?(text)
    }

    func remoteClose(code: Int, reason: String) {
        let handler: ((Int, String) -> Void)? = lock.withLock {
            state = .closed
            guard let closeHandler else { pendingClose = (code, reason); return nil }
            return closeHandler
        }
        handler?(code, reason)
    }

    private func flushPending() {
        let work: (open: (() -> Void)?, messages: [String], onMessage: ((String) -> Void)?,
                   close: (Int, String)?, onClose: ((Int, String) -> Void)?) = lock.withLock {
            var open: (() -> Void)?
            if pendingOpen, let openHandler {
                pendingOpen = false
                state = .open
                open = openHandler
            }
            var messages: [String] = []
            if messageHandler != nil, !pendingMessages.isEmpty {
                messages = pendingMessages
                pendingMessages = []
            }
            var close: (Int, String)?
            if let pending = pendingClose, closeHandler != nil {
                pendingClose = nil
                close = pending
            }
            return (open, messages, messageHandler, close, closeHandler)
        }
        work.open?()
        if let onMessage = work.onMessage { work.messages.forEach { onMessage($0) } }
        if let close = work.close { work.onClose?(close.0, close.1) }
    }
}

func jsonObject(_ string: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(string.utf8))
}

func jsonEquals(_ left: Any, _ right: Any) -> Bool {
    let options: JSONSerialization.WritingOptions = [.sortedKeys]
    let leftData = try! JSONSerialization.data(withJSONObject: left, options: options)
    let rightData = try! JSONSerialization.data(withJSONObject: right, options: options)
    return leftData == rightData
}

func expectMessage(_ error: Error, contains fragment: String) -> Bool {
    if let protocolError = error as? ProtocolError {
        return protocolError.message.contains(fragment)
    }
    if let transcriptionError = error as? TranscriptionError {
        return transcriptionError.message.contains(fragment)
    }
    return error.localizedDescription.contains(fragment)
}

struct ClosureHTTPClient: GeminiHTTPClient {
    var handler: @Sendable (URLRequest) async throws -> (Data, Int)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, status) = try await handler(request)
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

final class FakeTranscriber: LiveTranscriber, @unchecked Sendable {
    var audioBytes = 0
    var finishCalled = false
    var completeEmitted = false
    var finalText = "Testing."
    var interimText = "testing"
    var finishError: Error?
    var emitOnAudio: ServerEvent?
    private let emit: (ServerEvent) -> Void

    init(emit: @escaping (ServerEvent) -> Void) {
        self.emit = emit
    }

    func connect() async throws {
        emit(.ready)
        emit(.speechStart)
    }

    func sendAudio(_ chunk: Data) throws {
        audioBytes += chunk.count
        emit(.interim(text: interimText))
        if let emitOnAudio {
            emit(emitOnAudio)
        }
    }

    func finish() throws {
        finishCalled = true
        if let finishError {
            throw finishError
        }
        emit(.speechEnd)
        emit(.final(text: finalText))
        completeEmitted = true
        emit(.complete)
    }

    func emitLate(_ event: ServerEvent) {
        emit(event)
    }

    func close() {}
}

struct ClosureIntelligence: TranscriptIntelligence {
    var handler: @Sendable (String) async throws -> IntelligenceResult

    func polish(_ transcript: String) async throws -> IntelligenceResult {
        try await handler(transcript)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ServerEvent] = []

    func append(_ event: ServerEvent) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    func snapshot() -> [ServerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func waitForComplete() async {
        while true {
            if snapshot().contains(where: { $0.typeName == "complete" }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class SocketList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FakeWebSocket] = []

    func append(_ socket: FakeWebSocket) {
        lock.lock()
        items.append(socket)
        lock.unlock()
    }

    subscript(index: Int) -> FakeWebSocket {
        lock.lock()
        defer { lock.unlock() }
        return items[index]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}

/// 40 ms frames of PCM16. Voiced frames are well above the speech threshold.
func voicedPCM(ms: Int) -> Data { Data(repeating: 0x20, count: ms * PCM_BYTES_PER_MILLISECOND) }
func silentPCM(ms: Int) -> Data { Data(count: ms * PCM_BYTES_PER_MILLISECOND) }

/// Sends `pcm` in 40 ms frames, like the app's chunker does.
func sendFrames(_ session: DictationSession, _ pcm: Data) throws {
    var offset = 0
    while offset < pcm.count {
        let end = min(pcm.count, offset + PCM_CHUNK_BYTES)
        try session.sendAudio(pcm.subdata(in: offset..<end))
        offset = end
    }
}

/// Live transcriber whose every reaction is scripted by the test.
final class ScriptedTranscriber: LiveTranscriber, @unchecked Sendable {
    let emit: (ServerEvent) -> Void
    private let lock = NSLock()
    private var _audioBytes = 0
    private var _finishCalls = 0
    private var _closed = false
    private var _onAudio: ((ScriptedTranscriber, Data) throws -> Void)?
    private var _onFinish: ((ScriptedTranscriber) throws -> Void)?
    var connectEvents: [ServerEvent] = [.ready, .speechStart]

    var onAudio: ((ScriptedTranscriber, Data) throws -> Void)? {
        get { lock.withLock { _onAudio } }
        set { lock.withLock { _onAudio = newValue } }
    }
    var onFinish: ((ScriptedTranscriber) throws -> Void)? {
        get { lock.withLock { _onFinish } }
        set { lock.withLock { _onFinish = newValue } }
    }

    init(emit: @escaping (ServerEvent) -> Void) { self.emit = emit }

    var audioBytes: Int { lock.withLock { _audioBytes } }
    var finishCalls: Int { lock.withLock { _finishCalls } }
    var closed: Bool { lock.withLock { _closed } }

    func connect() async throws { connectEvents.forEach(emit) }

    func sendAudio(_ chunk: Data) throws {
        lock.withLock { _audioBytes += chunk.count }
        try onAudio?(self, chunk)
    }

    func finish() throws {
        lock.withLock { _finishCalls += 1 }
        if let onFinish { try onFinish(self) } else { emit(.complete) }
    }

    func close() { lock.withLock { _closed = true } }
}

final class TranscriberList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScriptedTranscriber] = []
    func append(_ item: ScriptedTranscriber) { lock.withLock { items.append(item) } }
    var count: Int { lock.withLock { items.count } }
    subscript(index: Int) -> ScriptedTranscriber { lock.withLock { items[index] } }
}

final class FakeBatchTranscriber: BatchTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [RecordedAudio] = []
    let result: @Sendable (RecordedAudio) async throws -> String

    init(result: @escaping @Sendable (RecordedAudio) async throws -> String) { self.result = result }

    var calls: [RecordedAudio] { lock.withLock { _calls } }

    func transcribe(_ audio: RecordedAudio, hints: BatchTranscriptionHints) async throws -> BatchTranscriptionResult {
        lock.withLock { _calls.append(audio) }
        return BatchTranscriptionResult(text: try await result(audio), model: "fake-batch", latencyMs: 1)
    }
}

extension EventLog {
    func waitFor(_ typeName: String, timeout: Duration = .seconds(3)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if snapshot().contains(where: { $0.typeName == typeName }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TranscriptionError("Timed out waiting for \(typeName).")
    }

    var warningCodes: [String] {
        snapshot().compactMap { if case .warning(let code, _) = $0 { return code }; return nil }
    }

    var lastTranscript: String? {
        snapshot().last { $0.typeName == "transcript" }.flatMap { if case .transcript(let text) = $0 { return text }; return nil }
    }

    var timing: DictationTiming? {
        snapshot().compactMap { if case .timing(let value) = $0 { return value }; return nil }.last
    }
}
