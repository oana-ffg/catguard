public struct FocusQueryFailurePolicy: Equatable, Sendable {
    public let failuresBeforeFailingOpen: Int
    public private(set) var consecutiveFailures = 0

    public init(failuresBeforeFailingOpen: Int = 2) {
        precondition(failuresBeforeFailingOpen > 0)
        self.failuresBeforeFailingOpen = failuresBeforeFailingOpen
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    @discardableResult
    public mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures >= failuresBeforeFailingOpen
    }
}
