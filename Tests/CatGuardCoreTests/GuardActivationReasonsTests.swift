import Testing

@testable import CatGuardCore

@Suite("Guard activation reasons")
struct GuardActivationReasonsTests {
    @Test("Manual arm survives Focus changes")
    func manualArmSurvivesFocusChanges() {
        var reasons = GuardActivationReasons()

        let manualArmTransition = reasons.latchManualArm()
        let focusActivationTransition = reasons.setFocusActive(true)
        let focusDeactivationTransition = reasons.setFocusActive(false)

        #expect(manualArmTransition == .activated)
        #expect(focusActivationTransition == .unchanged)
        #expect(focusDeactivationTransition == .unchanged)
        #expect(reasons.shouldGuard)
        #expect(reasons.manualArmActive)
    }

    @Test("Clearing manual arm disarms without Focus")
    func clearingManualArmDisarmsWithoutFocus() {
        var reasons = GuardActivationReasons()
        _ = reasons.latchManualArm()

        let transition = reasons.clearManualArm()

        #expect(transition == .deactivated)
        #expect(!reasons.shouldGuard)
    }

    @Test("Clearing manual arm leaves Focus protection active")
    func clearingManualArmLeavesFocusProtectionActive() {
        var reasons = GuardActivationReasons()
        _ = reasons.setFocusActive(true)
        _ = reasons.latchManualArm()

        let transition = reasons.clearManualArm()

        #expect(transition == .unchanged)
        #expect(reasons.shouldGuard)
        #expect(reasons.focusActive)
        #expect(!reasons.manualArmActive)
    }
}
