import XCTest

@testable import CatGuardCore

final class GuardSessionTests: XCTestCase {
    func testSessionCountsOnlyEventsRecordedWhileActive() {
        var tracker = GuardSessionTracker()
        tracker.recordBlockedKeyboardInputs()
        tracker.begin()
        tracker.recordBlockedKeyboardInputs(2)
        tracker.recordBlockedPointerClick()
        tracker.recordBypass()

        XCTAssertEqual(
            tracker.end(),
            GuardSessionReport(
                blockedKeyboardInputs: 2,
                blockedPointerClicks: 1,
                bypassCount: 1
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
        XCTAssertEqual(
            GuardSessionReport(
                blockedKeyboardInputs: 12,
                blockedPointerClicks: 3,
                bypassCount: 2
            ).notificationLines,
            [
                "Bypasses: 2",
                "Blocked keyboard inputs: 12",
                "Blocked pointer clicks: 3",
            ]
        )
        XCTAssertEqual(
            GuardSessionReport(
                blockedKeyboardInputs: 0,
                blockedPointerClicks: 0,
                bypassCount: 0
            ).notificationLines,
            [
                "Blocked keyboard inputs: 0",
                "Blocked pointer clicks: 0",
            ]
        )
    }
}
