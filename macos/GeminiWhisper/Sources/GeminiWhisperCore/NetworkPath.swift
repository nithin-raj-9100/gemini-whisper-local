import Foundation
#if canImport(Network)
import Network
#endif

/// Whether the system currently has a usable network route. Reconnects wait for
/// this instead of burning their limited attempts against a dead interface.
public protocol NetworkPathMonitoring: AnyObject, Sendable {
    var isSatisfied: Bool { get }
}

/// Treats the network as always available. Used in tests and where the Network
/// framework is unavailable.
public final class AlwaysAvailableNetwork: NetworkPathMonitoring, @unchecked Sendable {
    public init() {}
    public var isSatisfied: Bool { true }
}

#if canImport(Network)
/// Process-wide NWPathMonitor. Starts once and caches the latest status.
public final class SystemNetworkPath: NetworkPathMonitoring, @unchecked Sendable {
    public static let shared = SystemNetworkPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    // Optimistic until the first update arrives, so startup never blocks on it.
    private var satisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.satisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.nithin.gemini-whisper.network-path"))
    }

    public var isSatisfied: Bool { lock.withLock { satisfied } }
}

public func defaultNetworkPathMonitor() -> any NetworkPathMonitoring { SystemNetworkPath.shared }
#else
public func defaultNetworkPathMonitor() -> any NetworkPathMonitoring { AlwaysAvailableNetwork() }
#endif
