import Foundation

/// Applies delivered Focus values immediately and reconciles missed updates.
@MainActor
final class FocusStateMonitor {
    enum Update: Equatable {
        case state(Bool)
        case failure(attempts: Int, shouldFailOpen: Bool, message: String)
    }

    private let query: @MainActor () async throws -> Bool
    private let onUpdate: (Update) -> Void
    private let now: () -> TimeInterval
    private let reconciliationInterval: TimeInterval
    private let retryInterval: TimeInterval
    private var failurePolicy = FocusQueryFailurePolicy()
    private var isRunning = false
    private var revision = 0
    private var activeQueryID: UUID?
    private var refreshAfterQuery = false
    private var lastRefresh: TimeInterval?

    init(
        reconciliationInterval: TimeInterval = 30,
        retryInterval: TimeInterval = 2,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        query: @escaping @MainActor () async throws -> Bool,
        onUpdate: @escaping (Update) -> Void
    ) {
        precondition(reconciliationInterval > 0 && retryInterval > 0)
        self.reconciliationInterval = reconciliationInterval
        self.retryInterval = retryInterval
        self.now = now
        self.query = query
        self.onUpdate = onUpdate
    }

    func start() {
        revision += 1
        isRunning = true
        activeQueryID = nil
        refreshAfterQuery = false
        lastRefresh = nil
        failurePolicy.recordSuccess()
    }

    func stop() {
        revision += 1
        isRunning = false
        activeQueryID = nil
        refreshAfterQuery = false
    }

    func receive(_ enabled: Bool) {
        guard isRunning else { return }
        revision += 1
        lastRefresh = now()
        failurePolicy.recordSuccess()
        onUpdate(.state(enabled))
    }

    func refreshIfNeeded() async {
        guard isRunning, activeQueryID == nil else { return }
        let interval = failurePolicy.consecutiveFailures == 0 ? reconciliationInterval : retryInterval
        if let lastRefresh, now() - lastRefresh < interval { return }
        await refresh()
    }

    /// Explicit refreshes (such as wake) coalesce behind an in-flight query.
    func refresh() async {
        guard isRunning else { return }
        guard activeQueryID == nil else {
            refreshAfterQuery = true
            return
        }
        let queryID = UUID()
        activeQueryID = queryID
        defer {
            if activeQueryID == queryID { activeQueryID = nil }
        }

        repeat {
            refreshAfterQuery = false
            let queryRevision = revision
            lastRefresh = now()
            let result: Result<Bool, Error>
            do {
                result = .success(try await query())
            } catch {
                result = .failure(error)
            }

            guard isRunning, activeQueryID == queryID, !Task.isCancelled else { return }
            // A callback received during the query is newer than its result.
            if revision == queryRevision {
                switch result {
                case .success(let enabled):
                    failurePolicy.recordSuccess()
                    onUpdate(.state(enabled))
                case .failure(let error):
                    let shouldFailOpen = failurePolicy.recordFailure()
                    onUpdate(.failure(
                        attempts: failurePolicy.consecutiveFailures,
                        shouldFailOpen: shouldFailOpen,
                        message: error.localizedDescription
                    ))
                }
            }
        } while refreshAfterQuery
    }
}
