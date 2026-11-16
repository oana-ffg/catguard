/// Protection intent, including a temporarily bypassed or unavailable Focus guard,
/// blocks updates. An unknown Focus state also blocks installation at startup.
@MainActor
final class UpdateInstallationGate {
    var protectionRequested = false
    var focusStateKnown = false
    private(set) var installationPending = false
    private var resumeInstallation: (() -> Void)?

    var canInstall: Bool { focusStateKnown && !protectionRequested }
    var shouldDeferTermination: Bool { installationPending && !canInstall }

    func deferInstallation(_ resume: @escaping () -> Void) {
        installationPending = true
        resumeInstallation = resume
    }

    func resumeIfSafe() {
        guard canInstall, let resume = resumeInstallation else { return }
        resumeInstallation = nil
        resume()
    }

    func clear() {
        installationPending = false
        resumeInstallation = nil
    }
}
