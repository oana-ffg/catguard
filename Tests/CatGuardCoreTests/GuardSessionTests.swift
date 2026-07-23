import Foundation
import Testing

@testable import CatGuardCore

@Suite("Guard sessions")
struct GuardSessionTests {
    @Test("Sessions count only events recorded while active")
    func sessionCountsOnlyEventsRecordedWhileActive() {
        let bypassTime = Date(timeIntervalSince1970: 1_000)
        var tracker = GuardSessionTracker()
        tracker.recordBlockedKeyboardInputs()
        tracker.begin()
        tracker.recordBlockedKeyboardInputs(2)
        tracker.recordBlockedPointerClick()
        tracker.recordBypass(at: bypassTime)

        let report = tracker.end()
        #expect(
            report
                == GuardSessionReport(
                    blockedKeyboardInputs: 2,
                    blockedPointerClicks: 1,
                    bypassTimes: [bypassTime]
                )
        )
        tracker.recordBlockedPointerClick()
        let secondReport = tracker.end()
        #expect(secondReport == nil)
    }

    @Test("Beginning an active session does not erase its counts")
    func beginningAnActiveSessionDoesNotEraseItsCounts() {
        var tracker = GuardSessionTracker()
        tracker.begin()
        tracker.recordBlockedPointerClick()
        tracker.begin()

        let report = tracker.end()
        #expect(report?.blockedPointerClicks == 1)
    }

    @Test("A bypass re-arms only after continuous inactivity")
    func bypassRearmsOnlyAfterContinuousInactivity() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = BypassIdleTimer(inactivityInterval: 300)
        timer.begin(at: start)

        #expect(!timer.shouldRearm(at: start.addingTimeInterval(299)))
        timer.recordActivity(at: start.addingTimeInterval(250))
        #expect(!timer.shouldRearm(at: start.addingTimeInterval(500)))
        #expect(timer.shouldRearm(at: start.addingTimeInterval(550)))
    }

    @Test("Reset cancels a pending re-arm")
    func resetCancelsPendingRearm() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = BypassIdleTimer(inactivityInterval: 300)
        timer.begin(at: start)
        timer.reset()

        #expect(!timer.shouldRearm(at: start.addingTimeInterval(1_000)))
    }

    @Test("Notifications put bypasses first and omit them when zero")
    func notificationPutsBypassesFirstAndOmitsThemWhenZero() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(
            GuardSessionReport(
                blockedKeyboardInputs: 12,
                blockedPointerClicks: 3,
                bypassTimes: [
                    Date(timeIntervalSince1970: 3_661),
                    Date(timeIntervalSince1970: 7_322),
                ]
            ).notificationLines(timeZone: timeZone)
                == [
                    "Bypasses: 2",
                    "Bypass times (GMT):",
                    "• 1970-01-01 01:01:01",
                    "• 1970-01-01 02:02:02",
                    "Blocked keyboard inputs: 12",
                    "Blocked pointer clicks: 3",
                ]
        )
        #expect(
            GuardSessionReport(
                blockedKeyboardInputs: 0,
                blockedPointerClicks: 0,
                bypassTimes: []
            ).notificationLines(timeZone: timeZone)
                == [
                    "Blocked keyboard inputs: 0",
                    "Blocked pointer clicks: 0",
                ]
        )
    }
}
