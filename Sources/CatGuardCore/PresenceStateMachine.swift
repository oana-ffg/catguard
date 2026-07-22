import Foundation

public enum PresenceState: String, Equatable, Sendable {
    case present = "PRESENT"
    case uncertain = "UNCERTAIN"
    case away = "AWAY"
}

public enum PresenceObservation: Equatable, Sendable {
    case detection(confidence: Float)
    case cameraUnavailable
}

public struct PresenceConfiguration: Equatable, Sendable {
    public var confidenceThreshold: Float
    public var awayDelay: TimeInterval
    public var requiredNegativeDetections: Int

    public init(
        confidenceThreshold: Float = 0.6,
        awayDelay: TimeInterval = 180,
        requiredNegativeDetections: Int = 3
    ) {
        precondition((0...1).contains(confidenceThreshold))
        precondition(awayDelay >= 0)
        precondition(requiredNegativeDetections > 0)

        self.confidenceThreshold = confidenceThreshold
        self.awayDelay = awayDelay
        self.requiredNegativeDetections = requiredNegativeDetections
    }
}

public struct PresenceStateMachine: Sendable {
    public private(set) var state: PresenceState = .uncertain
    public private(set) var shouldEnablePhysicalInput = true

    private let configuration: PresenceConfiguration
    private var firstNegativeDetectionAt: Date?
    private var consecutiveNegativeDetections = 0

    public init(configuration: PresenceConfiguration = .init()) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func observe(
        _ observation: PresenceObservation,
        at timestamp: Date = Date()
    ) -> PresenceState {
        switch observation {
        case .detection(let confidence) where confidence >= configuration.confidenceThreshold:
            state = .present
            shouldEnablePhysicalInput = true
            resetNegativeDetections()

        case .detection:
            consecutiveNegativeDetections += 1
            firstNegativeDetectionAt = firstNegativeDetectionAt ?? timestamp

            let negativeDuration = timestamp.timeIntervalSince(firstNegativeDetectionAt ?? timestamp)
            let hasEnoughNegativeDetections =
                consecutiveNegativeDetections >= configuration.requiredNegativeDetections

            if hasEnoughNegativeDetections && negativeDuration >= configuration.awayDelay {
                state = .away
                shouldEnablePhysicalInput = false
            } else {
                state = .uncertain
                shouldEnablePhysicalInput = true
            }

        case .cameraUnavailable:
            state = .uncertain
            shouldEnablePhysicalInput = true
            resetNegativeDetections()
        }

        return state
    }

    private mutating func resetNegativeDetections() {
        firstNegativeDetectionAt = nil
        consecutiveNegativeDetections = 0
    }
}
