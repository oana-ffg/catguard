import AppKit
import Sparkle

// Sparkle 2.8.1 guarantees main-thread delegates but predates Swift actor annotations.
@MainActor
final class UpdateController: NSObject, @preconcurrency SPUUpdaterDelegate {
    private let gate: UpdateInstallationGate
    private var controller: SPUStandardUpdaterController!
    var onError: ((String) -> Void)?

    init(gate: UpdateInstallationGate) {
        self.gate = gate
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() {
        do { try controller.updater.start() }
        catch { onError?("Automatic updates could not start: \(error.localizedDescription)") }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    func protectionChanged() { gate.resumeIfSafe() }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        gate.deferInstallation(installHandler)
        // Sparkle requires the delegate to return before invoking this handler.
        Task { @MainActor [weak self] in self?.gate.resumeIfSafe() }
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate.deferInstallation(installHandler)
        Task { @MainActor [weak self] in self?.gate.resumeIfSafe() }
        return true
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        gate.markInstallationPending()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        gate.markInstallationPending()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let updateError = error as NSError
        // Sparkle reports these normal outcomes through the same abort callback.
        if updateError.domain == SUSparkleErrorDomain,
           updateError.code == SUError.noUpdateError.rawValue
            || updateError.code == SUError.installationCanceledError.rawValue {
            return
        }
        onError?("Update failed: \(error.localizedDescription)")
    }
}
