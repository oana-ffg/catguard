import Testing

@testable import CatGuardCore

@Test("A transient Focus query failure preserves the last known state")
func transientFocusQueryFailureDoesNotFailOpen() {
    var policy = FocusQueryFailurePolicy(failuresBeforeFailingOpen: 2)

    let shouldFailOpen = policy.recordFailure()
    #expect(!shouldFailOpen)
    policy.recordSuccess()
    #expect(policy.consecutiveFailures == 0)
}

@Test("Repeated Focus query failures eventually fail open")
func repeatedFocusQueryFailuresFailOpen() {
    var policy = FocusQueryFailurePolicy(failuresBeforeFailingOpen: 2)

    let firstFailureShouldFailOpen = policy.recordFailure()
    let secondFailureShouldFailOpen = policy.recordFailure()
    let laterFailuresShouldRemainOpen = policy.recordFailure()

    #expect(!firstFailureShouldFailOpen)
    #expect(secondFailureShouldFailOpen)
    #expect(laterFailuresShouldRemainOpen)
}
