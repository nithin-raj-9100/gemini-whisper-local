import Foundation

public enum DeadlineOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case failure(any Error)
    case timedOut
}

/// Runs `operation` and returns whichever comes first: its result or the deadline.
/// On timeout the operation is cancelled and abandoned, so an uncooperative await
/// (such as `Task.value`) cannot hold the caller past the deadline.
public func raceDeadline<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async -> DeadlineOutcome<Value> {
    let gate = ResumeOnce<DeadlineOutcome<Value>>()
    let work = Task {
        do { gate.resume(.value(try await operation())) } catch { gate.resume(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(for: .milliseconds(Int(max(0, seconds) * 1000)))
        if !Task.isCancelled { gate.resume(.timedOut) }
    }
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in gate.install(continuation) }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
    }
    timer.cancel()
    if case .value = outcome {} else { work.cancel() }
    return outcome
}

/// Resumes a continuation exactly once, whichever side arrives first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let pending {
            finished = true
            self.pending = nil
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let continuation {
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else if pending == nil {
            pending = value
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}
