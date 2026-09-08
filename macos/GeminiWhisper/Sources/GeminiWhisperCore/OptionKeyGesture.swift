import Foundation

/// Gesture decisions are independent of event taps and timer scheduling.
public struct OptionKeyGesture {
    public enum Action: Equatable, Sendable {
        case prepare, toggle, startHold, finishHold, discardPreparation, cancelHold
    }
    private enum State {
        case idle, pressed(TimeInterval), held, interrupted
    }
    public let holdThreshold: TimeInterval
    private var state: State = .idle

    public init(holdThreshold: TimeInterval = 0.6) { self.holdThreshold = holdThreshold }

    public mutating func press(at time: TimeInterval) -> [Action] {
        guard case .idle = state else { return [] }
        state = .pressed(time)
        return [.prepare]
    }

    public mutating func advance(to time: TimeInterval) -> [Action] {
        guard case .pressed(let start) = state, time - start >= holdThreshold else { return [] }
        state = .held
        return [.startHold]
    }

    public mutating func release(at time: TimeInterval) -> [Action] {
        defer { state = .idle }
        switch state {
        case .pressed(let start):
            // Release may arrive before a delayed timer: still recognize a hold.
            return time - start >= holdThreshold ? [.startHold, .finishHold] : [.toggle]
        case .held: return [.finishHold]
        case .idle, .interrupted: return []
        }
    }

    public mutating func interrupt() -> [Action] {
        switch state {
        case .idle, .interrupted: return []
        case .pressed:
            state = .interrupted
            return [.discardPreparation]
        case .held:
            state = .interrupted
            return [.cancelHold]
        }
    }
}
