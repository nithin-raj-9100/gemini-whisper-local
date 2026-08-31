import Foundation

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

/// URLSessionWebSocketTask wrapper used in production. Tests inject a fake instead.
public final class URLSessionGeminiWebSocket: NSObject, GeminiWebSocket, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public var readyState: GeminiWebSocketState = .connecting
    public var onOpen: (() -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onError: (() -> Void)?
    public var onClose: ((Int, String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var receiving = false

    public init(url: URL) {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        task = session.webSocketTask(with: url)
        task.resume()
        startReceiveLoop()
    }

    public func send(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.deliverErrorAndClose()
            }
        }
    }

    public func close(code: Int, reason: String) {
        guard readyState != .closed else { return }
        readyState = .closing
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: Data(reason.utf8))
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        readyState = .open
        onOpen?()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard readyState != .closed else { return }
        readyState = .closed
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        onClose?(closeCode.rawValue, reasonText)
        session.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard readyState != .closed else { return }
        if error != nil, readyState != .closing {
            deliverErrorAndClose()
        }
    }

    private func startReceiveLoop() {
        guard !receiving else { return }
        receiving = true
        receiveNext()
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
        guard readyState != .closed else { return }

        // RFC 6455 reserves 1006 for reporting an abnormal closure; it must not be
        // sent in a close frame. More importantly, URLSession does not reliably
        // deliver didClose after a receive/send failure followed by cancel(1006).
        // Mark the transport closed and deliver both callbacks ourselves so the
        // transcriber can reconnect instead of remaining stuck in `.ready` while
        // this wrapper is permanently `.closing`.
        readyState = .closed
        onError?()
        onClose?(1006, "transport error")
        session.invalidateAndCancel()
    }
}

public func defaultGeminiWebSocketFactory(url: URL) -> any GeminiWebSocket {
    URLSessionGeminiWebSocket(url: url)
}
