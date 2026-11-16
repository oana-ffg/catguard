/// Protection intent, including a temporarily bypassed or unavailable Focus guard,
/// blocks updates. An unknown Focus state also blocks installation at startup.
@MainActor
final class UpdateInstallationGate {
    var protectionRequested = false
    var focusStateKnown = false
    private var resumeInstallation: (() -> Void)?

    var canInstall: Bool { focusStateKnown && !protectionRequested }

    // Only the immediate install-and-relaunch is gated. Quitting is never blocked:
    // it is a documented recovery path, and logout/restart must not be vetoed.
    func deferInstallation(_ resume: @escaping () -> Void) {
        resumeInstallation = resume
    }

    func resumeIfSafe() {
        guard canInstall, let resume = resumeInstallation else { return }
        resumeInstallation = nil
        resume()
    }
}
