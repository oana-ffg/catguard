import Foundation
import Testing

@testable import CatGuardCore

@MainActor
@Suite("Focus delivery and reconciliation")
struct FocusStateMonitorTests {
    @Test("Delivered activation and deactivation apply immediately without querying")
    func deliveredStates() {
        let harness = FocusMonitorHarness()
        harness.monitor.start()
        harness.monitor.receive(true)
        harness.monitor.receive(false)
        #expect(harness.updates == [.state(true), .state(false)])
        #expect(harness.queryCount == 0)
    }

    @Test("Startup queries immediately, callbacks postpone fallback, and fallback repairs a missed update")
    func reconciliation() async {
        let harness = FocusMonitorHarness()
        harness.monitor.start()
        await harness.monitor.refreshIfNeeded()
        #expect(harness.queryCount == 1)
        harness.time = 29
        await harness.monitor.refreshIfNeeded()
        #expect(harness.queryCount == 1)
        harness.monitor.receive(true)
        harness.time = 58
        await harness.monitor.refreshIfNeeded()
        #expect(harness.queryCount == 1)
        harness.time = 59
        await harness.monitor.refreshIfNeeded()
        #expect(harness.queryCount == 2)
        #expect(harness.updates == [.state(false), .state(true), .state(false)])
    }

    @Test("Query failures retry promptly and fail open; a callback restores the normal cadence")
    func failureRecovery() async {
        let harness = FocusMonitorHarness()
        harness.result = .failure(FocusTestError.unavailable)
        harness.monitor.start()
        await harness.monitor.refreshIfNeeded()
        harness.time = 1
        await harness.monitor.refreshIfNeeded()
        #expect(harness.queryCount == 1)
        harness.time = 2
        await harness.monitor.refreshIfNeeded()
        #expect(harness.queryCount == 2)
        #expect(harness.updates == [
            .failure(attempts: 1, shouldFailOpen: false, message: "Test query unavailable"),
            .failure(attempts: 2, shouldFailOpen: true, message: "Test query unavailable"),
        ])
        harness.monitor.receive(true)
        harness.time = 4
        await harness.monitor.refreshIfNeeded()
        #expect(harness.queryCount == 2)
        #expect(harness.updates.last == .state(true))
    }

    @Test("An in-flight query cannot overwrite newer activation and deactivation callbacks")
    func staleSuccess() async {
        let query = SuspendedFocusQuery()
        var updates: [FocusStateMonitor.Update] = []
        let monitor = FocusStateMonitor(query: { try await query.value() }, onUpdate: { updates.append($0) })
        monitor.start()
        let refresh = Task { await monitor.refreshIfNeeded() }
        await query.waitUntilRequested()
        monitor.receive(true)
        monitor.receive(false)
        await monitor.refreshIfNeeded()
        #expect(query.count == 1)
        query.complete(.success(true))
        await refresh.value
        #expect(updates == [.state(true), .state(false)])
    }

    @Test("An in-flight query failure cannot mark a newer callback unavailable")
    func staleFailure() async {
        let query = SuspendedFocusQuery()
        var updates: [FocusStateMonitor.Update] = []
        let monitor = FocusStateMonitor(query: { try await query.value() }, onUpdate: { updates.append($0) })
        monitor.start()
        let refresh = Task { await monitor.refresh() }
        await query.waitUntilRequested()
        monitor.receive(true)
        query.complete(.failure(FocusTestError.unavailable))
        await refresh.value
        #expect(updates == [.state(true)])
    }

    @Test("Wake refreshes coalesce without parallel queries")
    func coalescedRefresh() async {
        let query = SuspendedFocusQuery()
        var updates: [FocusStateMonitor.Update] = []
        let monitor = FocusStateMonitor(query: { try await query.value() }, onUpdate: { updates.append($0) })
        monitor.start()
        let refresh = Task { await monitor.refresh() }
        await query.waitUntilRequested()
        await monitor.refresh()
        await monitor.refresh()
        #expect(query.count == 1)
        query.complete(.success(false))
        await query.waitUntilRequested()
        #expect(query.count == 2)
        query.complete(.success(true))
        await refresh.value
        #expect(updates == [.state(false), .state(true)])
    }

    @Test("Stopping ignores pending queries and callbacks; restarting refreshes immediately")
    func stopAndRestart() async {
        let query = SuspendedFocusQuery()
        var updates: [FocusStateMonitor.Update] = []
        let monitor = FocusStateMonitor(query: { try await query.value() }, onUpdate: { updates.append($0) })
        monitor.start()
        let refresh = Task { await monitor.refresh() }
        await query.waitUntilRequested()
        monitor.stop()
        monitor.receive(true)
        query.complete(.success(true))
        await refresh.value
        #expect(updates.isEmpty)
        monitor.start()
        let restarted = Task { await monitor.refreshIfNeeded() }
        await query.waitUntilRequested()
        query.complete(.success(false))
        await restarted.value
        #expect(updates == [.state(false)])
    }
}

private enum FocusTestError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Test query unavailable" }
}

@MainActor
private final class FocusMonitorHarness {
    var time: TimeInterval = 0
    var result: Result<Bool, Error> = .success(false)
    var queryCount = 0
    var updates: [FocusStateMonitor.Update] = []
    lazy var monitor = FocusStateMonitor(
        now: { [unowned self] in self.time },
        query: { [unowned self] in
            self.queryCount += 1
            return try self.result.get()
        },
        onUpdate: { [unowned self] in self.updates.append($0) }
    )
}

@MainActor
private final class SuspendedFocusQuery {
    private var pending: CheckedContinuation<Bool, Error>?
    private var requested: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    func value() async throws -> Bool {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func complete(_ result: Result<Bool, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
