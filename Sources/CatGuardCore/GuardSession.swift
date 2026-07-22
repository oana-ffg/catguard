import Foundation

public struct GuardSessionReport: Equatable, Sendable {
    public let blockedKeyboardInputs: Int
    public let blockedPointerClicks: Int
    public let bypassCount: Int

    public init(
        blockedKeyboardInputs: Int,
        blockedPointerClicks: Int,
        bypassCount: Int
    ) {
        precondition(blockedKeyboardInputs >= 0)
        precondition(blockedPointerClicks >= 0)
        precondition(bypassCount >= 0)

        self.blockedKeyboardInputs = blockedKeyboardInputs
        self.blockedPointerClicks = blockedPointerClicks
        self.bypassCount = bypassCount
    }

    public var notificationLines: [String] {
        var lines: [String] = []
        if bypassCount > 0 {
            lines.append("Bypasses: \(bypassCount)")
        }
        lines.append("Blocked keyboard inputs: \(blockedKeyboardInputs)")
        lines.append("Blocked pointer clicks: \(blockedPointerClicks)")
        return lines
    }
}

public struct GuardSessionTracker: Sendable {
    public private(set) var isActive = false
    private var blockedKeyboardInputs = 0
    private var blockedPointerClicks = 0
    private var bypassCount = 0

    public init() {}

    public mutating func begin() {
        guard !isActive else { return }
        isActive = true
        blockedKeyboardInputs = 0
        blockedPointerClicks = 0
        bypassCount = 0
    }

    public mutating func recordBlockedKeyboardInputs(_ count: Int = 1) {
        precondition(count >= 0)
        guard isActive else { return }
        blockedKeyboardInputs += count
    }

    public mutating func recordBlockedPointerClick() {
        guard isActive else { return }
        blockedPointerClicks += 1
    }

    public mutating func recordBypass() {
        guard isActive else { return }
        bypassCount += 1
    }

    public mutating func end() -> GuardSessionReport? {
        guard isActive else { return nil }
        isActive = false

        return GuardSessionReport(
            blockedKeyboardInputs: blockedKeyboardInputs,
            blockedPointerClicks: blockedPointerClicks,
            bypassCount: bypassCount
        )
    }
}

public struct BypassIdleTimer: Sendable {
    public let inactivityInterval: TimeInterval
    public private(set) var lastActivityAt: Date?

    public init(inactivityInterval: TimeInterval = 5 * 60) {
        precondition(inactivityInterval > 0)
        self.inactivityInterval = inactivityInterval
    }

    public mutating func begin(at date: Date) {
        lastActivityAt = date
    }

    public mutating func recordActivity(at date: Date) {
        guard lastActivityAt != nil else { return }
        lastActivityAt = date
    }

    public func shouldRearm(at date: Date) -> Bool {
        guard let lastActivityAt else { return false }
        return date.timeIntervalSince(lastActivityAt) >= inactivityInterval
    }

    public mutating func reset() {
        lastActivityAt = nil
    }
}
