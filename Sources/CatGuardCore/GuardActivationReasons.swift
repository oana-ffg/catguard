struct GuardActivationReasons: Equatable, Sendable {
    enum Transition: Equatable, Sendable {
        case unchanged
        case activated
        case deactivated
    }

    private(set) var focusActive = false
    private(set) var manualArmActive = false

    var shouldGuard: Bool {
        focusActive || manualArmActive
    }

    mutating func setFocusActive(_ active: Bool) -> Transition {
        let wasGuarding = shouldGuard
        focusActive = active
        return transition(from: wasGuarding, to: shouldGuard)
    }

    mutating func latchManualArm() -> Transition {
        let wasGuarding = shouldGuard
        manualArmActive = true
        return transition(from: wasGuarding, to: shouldGuard)
    }

    mutating func clearManualArm() -> Transition {
        let wasGuarding = shouldGuard
        manualArmActive = false
        return transition(from: wasGuarding, to: shouldGuard)
    }

    private func transition(from wasGuarding: Bool, to isGuarding: Bool) -> Transition {
        switch (wasGuarding, isGuarding) {
        case (false, true):
            .activated
        case (true, false):
            .deactivated
        default:
            .unchanged
        }
    }
}
