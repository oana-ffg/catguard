import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class GuardCoordinator: ObservableObject {
    @Published private(set) var protectionState: ProtectionState = .inputActive {
        didSet {
            if protectionState != oldValue { scheduleMaintenance() }
        }
    }
    @Published private var activationReasons = GuardActivationReasons()
    @Published private(set) var launchAtLogin = false
    @Published var circleEnabled: Bool {
        didSet {
            defaults.set(circleEnabled, forKey: Keys.circleEnabled)
            if protectionState == .guarded {
                inputGuard.setGuarded(
                    circleEnabled: circleEnabled,
                    rescuePhrase: savedRescuePhrase
                )
            }
        }
    }
    @Published var rescuePhraseDraft = RescuePhrase.default.value
    @Published private(set) var rescuePhraseIssue: String?
    @Published private(set) var settingsMessage: String?
    @Published private(set) var focusMonitoringIssue: String?
    @Published private(set) var focusMonitoringUnavailable = false
    @Published private(set) var notificationAuthorizationStatus: SessionNotificationAuthorizationStatus =
        .checking

    var focusActive: Bool { activationReasons.focusActive }
    var manualArmActive: Bool { activationReasons.manualArmActive }

    private enum Keys {
        static let circleEnabled = "circleEnabled"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let loginItem = LoginItemController()
    private let notifier = SessionNotifier()
    private lazy var inputGuard = PhysicalInputGuard(
        callbacks: PhysicalInputGuard.Callbacks(
            onBlockedKeyboardInput: { [weak self] in
                Task { @MainActor in self?.recordBlockedKeyboardInput() }
            },
            onBlockedPointerClick: { [weak self] in
                Task { @MainActor in self?.recordBlockedPointerClick() }
            },
            onCircle: { [weak self] in
                Task { @MainActor in self?.beginBypass(trigger: .circle) }
            },
            onRescuePhrase: { [weak self] in
                Task { @MainActor in self?.beginBypass(trigger: .rescuePhrase) }
            },
            onBypassActivity: { [weak self] in
                Task { @MainActor in self?.recordBypassActivity() }
            },
            onHealthChanged: { [weak self] in
                Task { @MainActor in self?.checkGuardHealth() }
            }
        )
    )
    private var session = GuardSessionTracker()
    private var bypassIdleTimer = BypassIdleTimer()
    private var savedRescuePhrase = RescuePhrase.default
    private let focusLogger = Logger(subsystem: "com.firefungames.catguard", category: "Focus")
    private lazy var focusMonitor = FocusStateMonitor(
        query: { try await FocusGuardIntent.current.isEnabled },
        onUpdate: { [weak self] update in self?.handleFocusUpdate(update) }
    )
    private let maintenance = GuardMaintenanceScheduler()
    private var isRunning = false
    private var focusChangeObserver: NotificationObservation?
    private var wakeObserver: NotificationObservation?
    let updateGate = UpdateInstallationGate()
    var onUpdateSafetyChanged: (() -> Void)?
    private var healthTimer: Timer?
    private var lastUnavailableRetry = Date.distantPast

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        LegacySettingsMigration.migrate(defaults: defaults, legacy: defaults.persistentDomain(forName: LegacySettingsMigration.legacyDomain) ?? [:])
        if defaults.object(forKey: Keys.circleEnabled) == nil {
            circleEnabled = true
        } else {
            circleEnabled = defaults.bool(forKey: Keys.circleEnabled)
        }

        loadRescuePhrase()
    }

    func loadRescuePhrase() {
        do {
            savedRescuePhrase = try RescuePhraseLoader.load(read: keychain.read, write: keychain.write)
            rescuePhraseDraft = savedRescuePhrase.value
            rescuePhraseIssue = nil
            if isRunning {
                if activationReasons.shouldGuard { arm() }
                else { protectionState = .inputActive }
            }
        } catch {
            rescuePhraseDraft = ""
            let issue = "Protection is unavailable until the saved rescue phrase can be read or explicitly replaced. Retry Keychain access in Settings. \(error.localizedDescription)"
            rescuePhraseIssue = issue
            inputGuard.setInactive()
            protectionState = .unavailable(issue)
        }
    }

    func start(requestNotificationAuthorization: Bool) {
        guard !isRunning else { return }
        isRunning = true
        launchAtLogin = loginItem.isEnabled
        focusMonitor.start()
        observeFocusChanges()

        do {
            guard rescuePhraseIssue == nil else { throw RescuePhraseLoader.LoadError.invalidPhrase }
            try inputGuard.start()
        } catch {
            protectionState = .unavailable(error.localizedDescription)
        }

        Task { [weak self] in
            await self?.prepareNotifications(requestAuthorizationIfNeeded: requestNotificationAuthorization)
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.checkGuardHealth()
                self.retryUnavailableGuardIfNeeded()
            }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleMaintenance()
    }

    private func scheduleMaintenance() {
        guard isRunning else { return }
        let retryDelay: TimeInterval?
        if case .unavailable = protectionState {
            retryDelay = max(0, 10 - Date().timeIntervalSince(lastUnavailableRetry))
        } else {
            retryDelay = nil
        }
        maintenance.schedule(
            focusRefreshDelay: focusMonitor.nextRefreshDelay,
            guardRetryDelay: retryDelay,
            isBypassed: protectionState.isBypassed
        ) { [weak self] in
            guard let self, self.isRunning else { return }
            self.retryUnavailableGuardIfNeeded()
            self.evaluateBypassIdleTimer()
            await self.focusMonitor.refreshIfNeeded()
            self.scheduleMaintenance()
        }
    }

    func stop() async {
        isRunning = false
        healthTimer?.invalidate()
        healthTimer = nil
        maintenance.cancel()
        focusMonitor.stop()
        stopObservingFocusChanges()
        inputGuard.stop()
    }

    func reportUpdateIssue(_ message: String) { settingsMessage = message }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            launchAtLogin = loginItem.isEnabled
            settingsMessage = nil
        } catch {
            launchAtLogin = loginItem.isEnabled
            settingsMessage = error.localizedDescription
        }
    }

    func requestNotificationAuthorization() async {
        do {
            _ = try await notifier.requestAuthorization()
            settingsMessage = nil
        } catch {
            settingsMessage = "Notification permission could not be requested: \(error.localizedDescription)"
        }
        await refreshNotificationAuthorizationStatus()
    }

    func saveRescuePhrase() {
        guard let phrase = RescuePhrase(rescuePhraseDraft) else {
            settingsMessage = "The rescue phrase must contain 4–32 English letters with no spaces."
            return
        }

        do {
            try keychain.write(phrase.value)
            savedRescuePhrase = phrase
            rescuePhraseIssue = nil
            rescuePhraseDraft = phrase.value
            if protectionState == .guarded {
                inputGuard.setGuarded(
                    circleEnabled: circleEnabled,
                    rescuePhrase: savedRescuePhrase
                )
            }
            settingsMessage = "Rescue phrase saved in Keychain."
            if activationReasons.shouldGuard { arm() }
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func beginBypass(trigger: BypassTrigger = .menu) {
        defer { updateSafetyChanged() }
        guard activationReasons.shouldGuard, protectionState == .guarded else { return }
        session.recordBypass(at: Date())
        _ = activationReasons.clearManualArm()

        if focusActive {
            inputGuard.setBypassed()
            bypassIdleTimer.begin(at: Date())
            protectionState = .bypassed(trigger)
        } else {
            inputGuard.setInactive()
            protectionState = .inputActive
            endSession()
        }
    }

    func activateManualGuard() {
        defer { updateSafetyChanged() }
        let transition = activationReasons.latchManualArm()
        settingsMessage = "Manual arm latched until a circle or the rescue phrase bypasses it."
        if transition == .activated {
            session.begin()
        }
        guard protectionState != .guarded else { return }
        bypassIdleTimer.reset()
        arm()
    }

    func rearmFocusNow() {
        guard focusActive else { return }
        bypassIdleTimer.reset()
        arm()
    }

    private func handleFocusUpdate(_ update: FocusStateMonitor.Update) {
        defer {
            updateSafetyChanged()
            scheduleMaintenance()
        }
        switch update {
        case .state(let enabled):
            updateGate.focusStateKnown = true
            focusMonitoringIssue = nil
            focusMonitoringUnavailable = false
            applyFocusState(enabled)
        case .failure(let attempts, let shouldFailOpen, let message):
            updateGate.focusStateKnown = false
            focusMonitoringUnavailable = shouldFailOpen
            if shouldFailOpen {
                applyFocusState(false)
                let protectionSummary =
                    manualArmActive
                    ? "The manual-arm latch remains in effect."
                    : "Input is being left active until Focus monitoring recovers."
                focusMonitoringIssue =
                    "CatGuard could not determine the Focus state after \(attempts) attempts. \(protectionSummary) \(message)"
            } else {
                focusMonitoringIssue =
                    "A Focus status check failed. CatGuard is preserving the last known state and will retry. \(message)"
            }
        }
    }

    private func applyFocusState(_ enabled: Bool) {
        guard enabled != focusActive else { return }
        let transition = activationReasons.setFocusActive(enabled)
        switch transition {
        case .activated:
            session.begin()
            arm()
        case .deactivated:
            endSession()
        case .unchanged:
            break
        }
        focusLogger.notice("Focus state changed: active=\(enabled, privacy: .public), protection=\(self.protectionState.label, privacy: .public)")
    }

    private func arm() {
        guard activationReasons.shouldGuard else { return }
        if let rescuePhraseIssue {
            inputGuard.setInactive()
            protectionState = .unavailable(rescuePhraseIssue)
            return
        }
        do {
            try inputGuard.start()
            inputGuard.setGuarded(
                circleEnabled: circleEnabled,
                rescuePhrase: savedRescuePhrase
            )
            protectionState = .guarded
        } catch {
            inputGuard.setInactive()
            protectionState = .unavailable(error.localizedDescription)
        }
    }

    private func endSession() {
        inputGuard.setInactive()
        bypassIdleTimer.reset()
        protectionState = .inputActive

        guard let report = session.end() else { return }
        Task { [weak self] in
            guard let self else { return }
            let authorizationStatus = await notifier.authorizationStatus()
            notificationAuthorizationStatus = authorizationStatus
            guard authorizationStatus == .enabled else { return }

            do {
                try await notifier.notify(report: report)
            } catch {
                settingsMessage = "The session report could not be delivered: \(error.localizedDescription)"
            }
        }
    }

    private func prepareNotifications(requestAuthorizationIfNeeded: Bool) async {
        await refreshNotificationAuthorizationStatus()
        guard requestAuthorizationIfNeeded, notificationAuthorizationStatus == .notRequested else {
            return
        }
        await requestNotificationAuthorization()
    }

    private func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await notifier.authorizationStatus()
    }

    private func retryUnavailableGuardIfNeeded() {
        guard case .unavailable = protectionState, rescuePhraseIssue == nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUnavailableRetry) >= 10 else { return }
        lastUnavailableRetry = now

        do {
            try inputGuard.start(requestPermissions: false)
            if activationReasons.shouldGuard {
                inputGuard.setGuarded(
                    circleEnabled: circleEnabled,
                    rescuePhrase: savedRescuePhrase
                )
                protectionState = .guarded
            } else {
                protectionState = .inputActive
            }
        } catch {
            protectionState = .unavailable(error.localizedDescription)
        }
    }

    private func updateSafetyChanged() {
        updateGate.protectionRequested = activationReasons.shouldGuard
        onUpdateSafetyChanged?()
    }

    private func checkGuardHealth() {
        guard rescuePhraseIssue == nil else { return }
        if case .unavailable = protectionState { return }
        do {
            try inputGuard.checkHealth()
        } catch {
            inputGuard.stop()
            protectionState = .unavailable(error.localizedDescription)
            lastUnavailableRetry = Date()
        }
    }

    private func evaluateBypassIdleTimer() {
        guard focusActive,
            protectionState.isBypassed,
            bypassIdleTimer.shouldRearm(at: Date())
        else { return }
        rearmFocusNow()
    }

    private func recordBlockedKeyboardInput() {
        session.recordBlockedKeyboardInputs()
    }

    private func recordBlockedPointerClick() {
        session.recordBlockedPointerClick()
    }

    private func recordBypassActivity() {
        guard protectionState.isBypassed else { return }
        bypassIdleTimer.recordActivity(at: Date())
    }

    private func observeFocusChanges() {
        guard focusChangeObserver == nil else { return }
        focusChangeObserver = NotificationObservation(
            name: FocusGuardIntentNotification.didPerform
        ) { [weak self] notification in
            guard let enabled = notification.userInfo?[FocusGuardIntentNotification.enabledKey] as? Bool else {
                return
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.focusLogger.notice("Focus callback: enabled=\(enabled, privacy: .public)")
                self.focusMonitor.receive(enabled)
            }
        }
        wakeObserver = NotificationObservation(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.didWakeNotification
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.focusMonitor.refresh()
                self.scheduleMaintenance()
            }
        }
    }

    private func stopObservingFocusChanges() {
        focusChangeObserver = nil
        wakeObserver = nil
    }
}
