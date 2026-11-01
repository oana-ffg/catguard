import Foundation
import Testing

@testable import CatGuardCore

@MainActor
@Suite("Maintenance deadlines")
struct GuardMaintenanceSchedulerTests {
    @Test("Eight idle hours sleep only until reconciliation is due")
    func idleWakeCount() async {
        let clock = MaintenanceTestClock()
        var queries = 0
        let monitor = FocusStateMonitor(
            now: { clock.time },
            query: {
                queries += 1
                return false
            },
            onUpdate: { _ in }
        )
        let scheduler = GuardMaintenanceScheduler(sleep: { try await clock.sleep($0) })
        monitor.start()
        await monitor.refreshIfNeeded()
        var wakeCount = 0
        func scheduleNext() {
            scheduler.schedule(focusRefreshDelay: monitor.nextRefreshDelay) {
                wakeCount += 1
                await monitor.refreshIfNeeded()
                if clock.time < 8 * 60 * 60 { scheduleNext() }
            }
        }
        scheduleNext()
        for _ in 0..<960 {
            let delay = await clock.waitForSleep()
            #expect(delay == 30)
            clock.advance()
        }
        await clock.waitForWakeCount { wakeCount == 960 }
        #expect(queries == 961)  // Initial query plus the timed reconciliations.
        #expect(clock.time == 28_800)
        #expect(clock.sleepCount == 960)
        scheduler.cancel()
        monitor.stop()
    }

    @Test("Maintenance sleeps until the earliest Focus, permission retry or bypass deadline")
    func earliestDeadline() async {
        let clock = MaintenanceTestClock()
        let scheduler = GuardMaintenanceScheduler(sleep: { try await clock.sleep($0) })
        for (focus, retry, bypass, expected) in [
            (30.0, 10.0, false, 10.0),
            (2.0, 10.0, false, 2.0),
            (30.0, 10.0, true, 1.0),
            (0.0, 10.0, true, 0.0),
        ] {
            scheduler.schedule(focusRefreshDelay: focus, guardRetryDelay: retry, isBypassed: bypass) {}
            #expect(await clock.waitForSleep() == expected)
            scheduler.cancel()
            clock.advance()
        }
    }

    @Test("Replacing a sleep ignores its completion, and stopping cancels the next wake")
    func cancellation() async {
        let clock = MaintenanceTestClock()
        let scheduler = GuardMaintenanceScheduler(sleep: { try await clock.sleep($0) })
        var runs = 0
        scheduler.schedule(focusRefreshDelay: 30) { runs += 1 }
        _ = await clock.waitForSleep()
        scheduler.schedule(focusRefreshDelay: 30, isBypassed: true) { runs += 1 }
        // An old sleeper that does not cooperate with cancellation still must
        // not execute its action after being replaced.
        clock.advance()
        #expect(await clock.waitForSleep() == 1)
        clock.advance()
        await clock.waitForWakeCount { runs == 1 }
        scheduler.schedule(focusRefreshDelay: 30) { runs += 1 }
        _ = await clock.waitForSleep()
        scheduler.cancel()
        clock.advance()
        // Scheduling a barrier lets the cancelled task finish first.
        scheduler.schedule(focusRefreshDelay: 0) {}
        _ = await clock.waitForSleep()
        #expect(runs == 1)
        scheduler.cancel()
        clock.advance()
    }

    @Test("Replanning while an action awaits does not cancel that active action")
    func inFlightAction() async {
        let clock = MaintenanceTestClock()
        let scheduler = GuardMaintenanceScheduler(sleep: { try await clock.sleep($0) })
        var finished = false
        scheduler.schedule(focusRefreshDelay: 0) {
            _ = try? await clock.sleep(5)
            #expect(!Task.isCancelled)
            finished = true
        }
        _ = await clock.waitForSleep()
        clock.advance()
        _ = await clock.waitForSleep()
        scheduler.schedule(focusRefreshDelay: nil) {}
        clock.advance()
        await clock.waitForWakeCount { finished }
    }
}

@MainActor
private final class MaintenanceTestClock {
    var time: TimeInterval = 0
    private(set) var sleepCount = 0
    private var pending: (delay: TimeInterval, continuation: CheckedContinuation<Void, Never>)?
    private var requested: CheckedContinuation<TimeInterval, Never>?

    func sleep(_ delay: TimeInterval) async throws {
        sleepCount += 1
        await withCheckedContinuation { continuation in
            precondition(pending == nil)
            pending = (delay, continuation)
            requested?.resume(returning: delay)
            requested = nil
        }
    }

    func waitForSleep() async -> TimeInterval {
        if let pending { return pending.delay }
        return await withCheckedContinuation { requested = $0 }
    }

    func advance() {
        let sleeper = pending!
        pending = nil
        time += sleeper.delay
        sleeper.continuation.resume()
    }

    func waitForWakeCount(_ condition: () -> Bool) async {
        // Only yield to already-runnable tasks; no wall-clock delay or timers.
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Scheduled work did not finish")
    }
}
