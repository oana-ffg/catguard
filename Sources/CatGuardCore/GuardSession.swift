import Foundation

public struct GuardSessionReport: Equatable, Sendable {
    public let blockedKeyboardInputs: Int
    public let blockedPointerClicks: Int
    public let bypassTimes: [Date]

    public var bypassCount: Int {
        bypassTimes.count
    }

    public init(
        blockedKeyboardInputs: Int,
        blockedPointerClicks: Int,
        bypassTimes: [Date]
    ) {
        precondition(blockedKeyboardInputs >= 0)
        precondition(blockedPointerClicks >= 0)

        self.blockedKeyboardInputs = blockedKeyboardInputs
        self.blockedPointerClicks = blockedPointerClicks
        self.bypassTimes = bypassTimes
    }

    public func notificationLines(timeZone: TimeZone = .current) -> [String] {
        var lines: [String] = []
        if !bypassTimes.isEmpty {
            lines.append("Bypasses: \(bypassCount)")
            lines.append("Bypass times (\(timeZone.identifier)):")
            lines.append(contentsOf: bypassTimes.map { "• \(Self.formatDateAndTime($0, in: timeZone))" })
        }
        lines.append("Blocked keyboard inputs: \(blockedKeyboardInputs)")
        lines.append("Blocked pointer clicks: \(blockedPointerClicks)")
        return lines
    }

    private static func formatDateAndTime(_ date: Date, in timeZone: TimeZone) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: timeZone,
            from: date
        )
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}

public struct GuardSessionTracker: Sendable {
    public private(set) var isActive = false
    private var blockedKeyboardInputs = 0
    private var blockedPointerClicks = 0
    private var bypassTimes: [Date] = []

    public init() {}

    public mutating func begin() {
        guard !isActive else { return }
        isActive = true
        blockedKeyboardInputs = 0
        blockedPointerClicks = 0
        bypassTimes = []
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

    public mutating func recordBypass(at date: Date) {
        guard isActive else { return }
        bypassTimes.append(date)
    }

    public mutating func end() -> GuardSessionReport? {
        guard isActive else { return nil }
        isActive = false

        return GuardSessionReport(
            blockedKeyboardInputs: blockedKeyboardInputs,
            blockedPointerClicks: blockedPointerClicks,
            bypassTimes: bypassTimes
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
