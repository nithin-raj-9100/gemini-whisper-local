import Foundation
@testable import GeminiWhisperCore
import Testing

final class FakeWebSocket: GeminiWebSocket, @unchecked Sendable {
    var readyState: GeminiWebSocketState = .connecting
    var sent: [String] = []

    private var pendingOpen = false
    private var pendingMessages: [String] = []
    private var pendingClose: (Int, String)?

    var onOpen: (() -> Void)? {
        didSet { flushPending() }
    }

    var onMessage: ((String) -> Void)? {
        didSet { flushPending() }
    }

    var onError: (() -> Void)?

    var onClose: ((Int, String) -> Void)? {
        didSet { flushPending() }
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close(code: Int, reason: String) {
        guard readyState != .closed else { return }
        readyState = .closed
        onClose?(code, reason)
    }

    func simulateOpen() {
        if onOpen != nil {
            readyState = .open
            onOpen?()
        } else {
            pendingOpen = true
        }
    }

    func simulateJSON(_ value: Any) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        let text = String(data: data, encoding: .utf8)!
        if let onMessage {
            onMessage(text)
        } else {
            pendingMessages.append(text)
        }
    }

    func remoteClose(code: Int, reason: String) {
        readyState = .closed
        if let onClose {
            onClose(code, reason)
        } else {
            pendingClose = (code, reason)
        }
    }

    private func flushPending() {
        if pendingOpen, let onOpen {
            pendingOpen = false
            readyState = .open
            onOpen()
        }
        if let onMessage, !pendingMessages.isEmpty {
            let messages = pendingMessages
            pendingMessages = []
            messages.forEach { onMessage($0) }
        }
        if let pendingClose, let onClose {
            self.pendingClose = nil
            onClose(pendingClose.0, pendingClose.1)
        }
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
