import XCTest

@testable import CatGuardCore

final class GuardSessionTests: XCTestCase {
    func testSessionCountsOnlyEventsRecordedWhileActive() {
        let bypassTime = Date(timeIntervalSince1970: 1_000)
        var tracker = GuardSessionTracker()
        tracker.recordBlockedKeyboardInputs()
        tracker.begin()
        tracker.recordBlockedKeyboardInputs(2)
        tracker.recordBlockedPointerClick()
        tracker.recordBypass(at: bypassTime)

        XCTAssertEqual(
            tracker.end(),
            GuardSessionReport(
                blockedKeyboardInputs: 2,
                blockedPointerClicks: 1,
                bypassTimes: [bypassTime]
            )
        )
        tracker.recordBlockedPointerClick()
        XCTAssertNil(tracker.end())
    }

    func testBeginningAnActiveSessionDoesNotEraseItsCounts() {
        var tracker = GuardSessionTracker()
        tracker.begin()
        tracker.recordBlockedPointerClick()
        tracker.begin()

        XCTAssertEqual(tracker.end()?.blockedPointerClicks, 1)
    }

    func testBypassRearmsOnlyAfterContinuousInactivity() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = BypassIdleTimer(inactivityInterval: 300)
        timer.begin(at: start)

        XCTAssertFalse(timer.shouldRearm(at: start.addingTimeInterval(299)))
        timer.recordActivity(at: start.addingTimeInterval(250))
        XCTAssertFalse(timer.shouldRearm(at: start.addingTimeInterval(500)))
        XCTAssertTrue(timer.shouldRearm(at: start.addingTimeInterval(550)))
    }

    func testResetCancelsPendingRearm() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = BypassIdleTimer(inactivityInterval: 300)
        timer.begin(at: start)
        timer.reset()

        XCTAssertFalse(timer.shouldRearm(at: start.addingTimeInterval(1_000)))
    }

    func testNotificationPutsBypassesFirstAndOmitsThemWhenZero() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(
            GuardSessionReport(
                blockedKeyboardInputs: 12,
                blockedPointerClicks: 3,
                bypassTimes: [
                    Date(timeIntervalSince1970: 3_661),
                    Date(timeIntervalSince1970: 7_322),
                ]
            ).notificationLines(timeZone: timeZone),
            [
                "Bypasses: 2",
                "Bypass times (GMT):",
                "• 1970-01-01 01:01:01",
                "• 1970-01-01 02:02:02",
                "Blocked keyboard inputs: 12",
                "Blocked pointer clicks: 3",
            ]
        )
        XCTAssertEqual(
            GuardSessionReport(
                blockedKeyboardInputs: 0,
                blockedPointerClicks: 0,
                bypassTimes: []
            ).notificationLines(timeZone: timeZone),
            [
                "Blocked keyboard inputs: 0",
                "Blocked pointer clicks: 0",
            ]
        )
    }
}
