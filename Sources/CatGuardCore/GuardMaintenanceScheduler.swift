import Foundation

/// One cancellable sleep for the next maintenance deadline. The pending sleep
/// is cleared before running work, so replanning never cancels an active query.
@MainActor
final class GuardMaintenanceScheduler {
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void

    private let sleep: Sleep
    private var pendingTask: Task<Void, Never>?

    init(sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    deinit {
        pendingTask?.cancel()
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    func schedule(
        focusRefreshDelay: TimeInterval?,
        guardRetryDelay: TimeInterval? = nil,
        isBypassed: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) {
        var delay = focusRefreshDelay
        if let guardRetryDelay { delay = min(delay ?? guardRetryDelay, guardRetryDelay) }
        // Preserve the existing one-second idle check only during bypass.
        if isBypassed { delay = min(delay ?? 1, 1) }
        cancel()
        guard let delay else { return }
        pendingTask = Task { [weak self, sleep] in
            do {
                try await sleep(max(0, delay))
            } catch is CancellationError {
                return
            } catch {
                // The production sleeper only throws CancellationError.
                preconditionFailure("Maintenance sleep failed: \(error)")
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingTask = nil
            await action()
        }
    }
}
