import Foundation

public struct BackgroundPolishPolicy: Sendable {
    public var minimumInterval: TimeInterval
    public var maximumJobs: Int
    public var minimumNewWords: Int
    public var stabilityDelay: TimeInterval
    public var failureCooldown: TimeInterval

    public init(minimumInterval: TimeInterval = 4, maximumJobs: Int = 6,
                minimumNewWords: Int = 12, stabilityDelay: TimeInterval = 0.6,
                failureCooldown: TimeInterval = 10) {
        self.minimumInterval = max(0, minimumInterval)
        self.maximumJobs = max(0, maximumJobs)
        self.minimumNewWords = max(1, minimumNewWords)
        self.stabilityDelay = max(0, stabilityDelay)
        self.failureCooldown = max(0, failureCooldown)
    }
}

/// Session-local admission control. Final work never passes through this budget.
struct BackgroundPolishScheduler {
    let policy: BackgroundPolishPolicy
    private(set) var jobs = 0
    private(set) var throttled = false
    private var nextAllowedAt: TimeInterval = 0
    private var lastInput = ""
    private var failedInputs = Set<String>()

    init(policy: BackgroundPolishPolicy = .init()) { self.policy = policy }

    func delay(for input: String, stableFor: TimeInterval, now: TimeInterval) -> TimeInterval? {
        guard !throttled, jobs < policy.maximumJobs, !input.isEmpty,
              input != lastInput, !failedInputs.contains(input) else { return nil }
        let old = lastInput.split(whereSeparator: { $0.isWhitespace })
        let new = input.split(whereSeparator: { $0.isWhitespace })
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
        let changedWords = max(old.count, new.count) - prefix - suffix
        let sentence = input.last.map { ".!?。！？".contains($0) } == true
        let contentDelay: TimeInterval
        if changedWords >= policy.minimumNewWords { contentDelay = 0 }
        else if sentence, changedWords >= 4 { contentDelay = max(0, policy.stabilityDelay - stableFor) }
        else { return nil }
        return max(contentDelay, nextAllowedAt - now, 0)
    }

    /// Budget-only admission, without the stability/new-word content gate.
    /// The stop edge is the last chance to speculate, so a small edit still
    /// earns a call, but a throttled or already-failed input never does.
    func admitsStopEdge(_ input: String) -> Bool {
        !throttled && jobs < policy.maximumJobs && !input.isEmpty && !failedInputs.contains(input)
    }

    mutating func started(_ input: String, now: TimeInterval) {
        jobs += 1
        lastInput = input
        nextAllowedAt = now + policy.minimumInterval
    }

    mutating func failed(_ input: String, now: TimeInterval, rateLimited: Bool) {
        failedInputs.insert(input)
        nextAllowedAt = max(nextAllowedAt, now + policy.failureCooldown)
        if rateLimited { throttled = true }
    }
}
