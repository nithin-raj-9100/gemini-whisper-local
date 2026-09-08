import Foundation

/// One capture epoch. Handoff and the seal marker use the same lock and FIFO queue.
/// Audio buffered before a hotkey is confirmed stays local until commit().
public final class PCMDeliveryStream: @unchecked Sendable {
    public struct Block: Sendable {
        public let sequence: Int
        public let firstSample: Int
        public let pcm: Data
    }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var pending: [Block] = []
    private var handler: ((Block) -> Void)?
    private var sealed = false
    private var sequence = 0
    private var samples = 0

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    public func append(_ pcm: Data) {
        lock.withLock {
            guard !sealed, !pcm.isEmpty else { return }
            let block = Block(sequence: sequence, firstSample: samples, pcm: pcm)
            sequence += 1
            samples += pcm.count / 2
            if let handler { queue.async { handler(block) } }
            else { pending.append(block) }
        }
    }

    public func commit(_ handler: @escaping (Block) -> Void) {
        lock.withLock {
            guard !sealed, self.handler == nil else { return }
            self.handler = handler
            for block in pending { queue.async { handler(block) } }
            pending.removeAll()
        }
    }

    /// The producer must stop handing off blocks before calling this method.
    /// Returns only after every accepted block has run its delivery callback.
    public func drain() async -> Int {
        await withCheckedContinuation { continuation in
            lock.withLock {
                sealed = true
                let boundary = samples
                queue.async { continuation.resume(returning: boundary) }
            }
        }
    }

    public func discard() {
        lock.withLock {
            sealed = true
            pending.removeAll()
            handler = nil
        }
    }
}
