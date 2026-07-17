import Foundation
import Testing
@testable import CatGuardCore

@Test("A confident detection becomes present immediately")
func confidentDetectionBecomesPresentImmediately() {
    var machine = PresenceStateMachine(
        configuration: .init(confidenceThreshold: 0.6, awayDelay: 180, requiredNegativeDetections: 3)
    )

    let state = machine.observe(.detection(confidence: 0.8), at: Date(timeIntervalSince1970: 0))

    #expect(state == .present)
    #expect(machine.shouldEnablePhysicalInput)
}

@Test("Negative detections remain uncertain until both safeguards are met")
func negativeDetectionsRequireCountAndDelay() {
    var machine = PresenceStateMachine(
        configuration: .init(confidenceThreshold: 0.6, awayDelay: 180, requiredNegativeDetections: 3)
    )
    let start = Date(timeIntervalSince1970: 0)

    #expect(machine.observe(.detection(confidence: 0), at: start) == .uncertain)
    #expect(machine.observe(.detection(confidence: 0), at: start.addingTimeInterval(90)) == .uncertain)
    #expect(machine.observe(.detection(confidence: 0), at: start.addingTimeInterval(179)) == .uncertain)
    #expect(machine.shouldEnablePhysicalInput)

    #expect(machine.observe(.detection(confidence: 0), at: start.addingTimeInterval(180)) == .away)
    #expect(!machine.shouldEnablePhysicalInput)
}

@Test("A confident detection recovers immediately from away")
func confidentDetectionRecoversFromAway() {
    var machine = PresenceStateMachine(
        configuration: .init(confidenceThreshold: 0.6, awayDelay: 10, requiredNegativeDetections: 2)
    )
    let start = Date(timeIntervalSince1970: 0)

    _ = machine.observe(.detection(confidence: 0), at: start)
    #expect(machine.observe(.detection(confidence: 0), at: start.addingTimeInterval(10)) == .away)

    #expect(machine.observe(.detection(confidence: 0.9), at: start.addingTimeInterval(11)) == .present)
    #expect(machine.shouldEnablePhysicalInput)
}

@Test("Camera failure always enables physical input and clears absence evidence")
func cameraFailureIsFailSafe() {
    var machine = PresenceStateMachine(
        configuration: .init(confidenceThreshold: 0.6, awayDelay: 10, requiredNegativeDetections: 2)
    )
    let start = Date(timeIntervalSince1970: 0)

    _ = machine.observe(.detection(confidence: 0), at: start)
    _ = machine.observe(.detection(confidence: 0), at: start.addingTimeInterval(10))
    #expect(machine.state == .away)

    #expect(machine.observe(.cameraUnavailable, at: start.addingTimeInterval(11)) == .uncertain)
    #expect(machine.shouldEnablePhysicalInput)

    #expect(machine.observe(.detection(confidence: 0), at: start.addingTimeInterval(20)) == .uncertain)
    #expect(machine.observe(.detection(confidence: 0), at: start.addingTimeInterval(21)) == .uncertain)
}
