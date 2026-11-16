import Testing
@testable import CatGuardCore

@Suite("Event tap health and recovery")
struct EventTapHealthCheckTests {
    @Test(arguments: [(false, true, true), (true, false, true), (true, true, false)])
    func revocationOrInvalidationFailsWithoutReenabling(_ snapshot: (Bool, Bool, Bool)) {
        var attemptedEnable = false
        #expect(throws: InputProtectionError.self) {
            try EventTapHealthCheck.validate(listenAccess: snapshot.0, postAccess: snapshot.1,
                portValid: snapshot.2, isEnabled: { true }, enable: { attemptedEnable = true })
        }
        #expect(!attemptedEnable)
    }

    @Test func disabledTapMustActuallyRecover() throws {
        var enabled = false
        var enables = 0
        try EventTapHealthCheck.validate(listenAccess: true, postAccess: true, portValid: true,
            isEnabled: { enabled }, enable: { enables += 1; enabled = true })
        #expect(enabled)
        #expect(enables == 1)
        try EventTapHealthCheck.validate(listenAccess: true, postAccess: true, portValid: true,
            isEnabled: { enabled }, enable: { enables += 1 })
        #expect(enables == 1)
        #expect(throws: InputProtectionError.self) {
            try EventTapHealthCheck.validate(listenAccess: true, postAccess: true, portValid: true,
                isEnabled: { false }, enable: {})
        }
    }
}
