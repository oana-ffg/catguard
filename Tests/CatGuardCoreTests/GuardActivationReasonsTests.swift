import XCTest

@testable import CatGuardCore

final class GuardActivationReasonsTests: XCTestCase {
    func testManualArmSurvivesFocusChanges() {
        var reasons = GuardActivationReasons()

        XCTAssertEqual(reasons.latchManualArm(), .activated)
        XCTAssertEqual(reasons.setFocusActive(true), .unchanged)
        XCTAssertEqual(reasons.setFocusActive(false), .unchanged)
        XCTAssertTrue(reasons.shouldGuard)
        XCTAssertTrue(reasons.manualArmActive)
    }

    func testClearingManualArmDisarmsWithoutFocus() {
        var reasons = GuardActivationReasons()
        _ = reasons.latchManualArm()

        XCTAssertEqual(reasons.clearManualArm(), .deactivated)
        XCTAssertFalse(reasons.shouldGuard)
    }

    func testClearingManualArmLeavesFocusProtectionActive() {
        var reasons = GuardActivationReasons()
        _ = reasons.setFocusActive(true)
        _ = reasons.latchManualArm()

        XCTAssertEqual(reasons.clearManualArm(), .unchanged)
        XCTAssertTrue(reasons.shouldGuard)
        XCTAssertTrue(reasons.focusActive)
        XCTAssertFalse(reasons.manualArmActive)
    }
}
