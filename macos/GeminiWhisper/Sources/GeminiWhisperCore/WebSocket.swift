import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GeminiWebSocketState: Sendable, Equatable {
    case connecting
    case open
    case closing
    case closed
}

public protocol GeminiWebSocket: AnyObject {
    var readyState: GeminiWebSocketState { get }
    var onOpen: (() -> Void)? { get set }
    var onMessage: ((String) -> Void)? { get set }
    var onError: (() -> Void)? { get set }
    var onClose: ((Int, String) -> Void)? { get set }
    func send(_ text: String)
    func close(code: Int, reason: String)
}

public typealias GeminiWebSocketFactory = (URL) -> any GeminiWebSocket

/// One URLSession for every Live socket. Each WebSocket still needs its own
/// connection, but a shared session reuses DNS results and TLS session tickets,
/// which shortens every connect after the first.
final class GeminiWebSocketSessionPool: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let shared = GeminiWebSocketSessionPool()

    private final class WeakSocket {
        weak var socket: URLSessionGeminiWebSocket?
        init(_ socket: URLSessionGeminiWebSocket) { self.socket = socket }
    }

    private let lock = NSLock()
    private var sockets: [Int: WeakSocket] = [:]
    private var session: URLSession!

    override private init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        #if canImport(Darwin)
        configuration.waitsForConnectivity = false
        #endif
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 900
        // A private serial queue: socket callbacks never wait on the main thread.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.nithin.gemini-whisper.live-socket"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func makeTask(url: URL) -> URLSessionWebSocketTask {
        session.webSocketTask(with: url)
    }

    func register(_ socket: URLSessionGeminiWebSocket, for task: URLSessionTask) {
        lock.withLock { sockets[task.taskIdentifier] = WeakSocket(socket) }
    }

    func unregister(_ task: URLSessionTask) {
        _ = lock.withLock { sockets.removeValue(forKey: task.taskIdentifier) }
    }

    private func socket(for task: URLSessionTask) -> URLSessionGeminiWebSocket? {
        lock.withLock { sockets[task.taskIdentifier]?.socket }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        socket(for: webSocketTask)?.didOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        socket(for: webSocketTask)?.didClose(code: closeCode.rawValue, reason: reasonText)
        unregister(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        socket(for: task)?.didComplete(error: error)
        unregister(task)
    }
}

/// URLSessionWebSocketTask wrapper used in production. Tests inject a fake instead.
/// State and callbacks are locked: the transcriber sets callbacks from whichever
/// thread connects while URLSession reports on its own queue.
public final class URLSessionGeminiWebSocket: NSObject, GeminiWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var state: GeminiWebSocketState = .connecting
    private var openHandler: (() -> Void)?
    private var messageHandler: ((String) -> Void)?
    private var errorHandler: (() -> Void)?
    private var closeHandler: ((Int, String) -> Void)?
    private let task: URLSessionWebSocketTask

    public var readyState: GeminiWebSocketState { lock.withLock { state } }
    public var onOpen: (() -> Void)? {
        get { lock.withLock { openHandler } }
        set { lock.withLock { openHandler = newValue } }
    }
    public var onMessage: ((String) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }
    public var onError: (() -> Void)? {
        get { lock.withLock { errorHandler } }
        set { lock.withLock { errorHandler = newValue } }
    }
    public var onClose: ((Int, String) -> Void)? {
        get { lock.withLock { closeHandler } }
        set { lock.withLock { closeHandler = newValue } }
    }

    public init(url: URL) {
        let pool = GeminiWebSocketSessionPool.shared
        task = pool.makeTask(url: url)
        super.init()
        pool.register(self, for: task)
        task.resume()
        receiveNext()
    }

    public func send(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.deliverErrorAndClose()
            }
        }
    }

    public func close(code: Int, reason: String) {
        let proceed: Bool = lock.withLock {
            guard state != .closed else { return false }
            state = .closing
            return true
        }
        guard proceed else { return }
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: Data(reason.utf8))
    }

    fileprivate func didOpen() {
        let handler: (() -> Void)? = lock.withLock {
            guard state == .connecting else { return nil }
            state = .open
            return openHandler
        }
        handler?()
    }

    fileprivate func didClose(code: Int, reason: String) {
        let handler: ((Int, String) -> Void)? = lock.withLock {
            guard state != .closed else { return nil }
            state = .closed
            return closeHandler
        }
        handler?(code, reason)
    }

    fileprivate func didComplete(error: Error?) {
        let closing = lock.withLock { state == .closing }
        if error != nil, !closing {
            deliverErrorAndClose()
        } else {
            // A cancelled task may complete without a close frame; report it once.
            didClose(code: 1000, reason: "")
        }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.onMessage?(text)
                }
                self.receiveNext()
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    self.onMessage?(text)
                }
                self.receiveNext()
            case .failure:
                self.deliverErrorAndClose()
            @unknown default:
                self.receiveNext()
            }
        }
    }

    private func deliverErrorAndClose() {
        // RFC 6455 reserves 1006 for reporting an abnormal closure; it must not be
        // sent in a close frame. More importantly, URLSession does not reliably
        // deliver didClose after a receive/send failure followed by cancel(1006).
        // Mark the transport closed and deliver both callbacks ourselves so the
        // transcriber can reconnect instead of remaining stuck in `.ready` while
        // this wrapper is permanently `.closing`.
        let handlers: ((() -> Void)?, ((Int, String) -> Void)?)? = lock.withLock {
            guard state != .closed else { return nil }
            state = .closed
            return (errorHandler, closeHandler)
        }
        guard let handlers else { return }
        handlers.0?()
        handlers.1?(1006, "transport error")
        task.cancel()
    }
}

public func defaultGeminiWebSocketFactory(url: URL) -> any GeminiWebSocket {
    URLSessionGeminiWebSocket(url: url)
}
