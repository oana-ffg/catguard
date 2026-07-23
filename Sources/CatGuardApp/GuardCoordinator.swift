import Combine
import Foundation

@MainActor
final class GuardCoordinator: ObservableObject {
    @Published private(set) var protectionState: ProtectionState = .inputActive
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
            }
        )
    )
    private var session = GuardSessionTracker()
    private var bypassIdleTimer = BypassIdleTimer()
    private var savedRescuePhrase = RescuePhrase.default
    private var focusQueryFailurePolicy = FocusQueryFailurePolicy()
    private var monitorTask: Task<Void, Never>?
    private var focusChangeObserver: DistributedNotificationObserver?
    private var lastFocusRefresh = Date.distantPast
    private var lastUnavailableRetry = Date.distantPast

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        if defaults.object(forKey: Keys.circleEnabled) == nil {
            circleEnabled = true
        } else {
            circleEnabled = defaults.bool(forKey: Keys.circleEnabled)
        }

        do {
            if let storedPhrase = try keychain.read() {
                if let validatedPhrase = RescuePhrase(storedPhrase) {
                    savedRescuePhrase = validatedPhrase
                    rescuePhraseDraft = validatedPhrase.value
                    if storedPhrase != validatedPhrase.value {
                        try keychain.write(validatedPhrase.value)
                    }
                } else {
                    savedRescuePhrase = .default
                    rescuePhraseDraft = savedRescuePhrase.value
                    try keychain.write(savedRescuePhrase.value)
                    settingsMessage =
                        "The invalid rescue phrase in Keychain was replaced with “\(savedRescuePhrase.value)”."
                }
            } else {
                try keychain.write(savedRescuePhrase.value)
            }
        } catch {
            savedRescuePhrase = .default
            rescuePhraseDraft = savedRescuePhrase.value
            settingsMessage =
                "The rescue phrase could not be read from or updated in Keychain. Using “\(savedRescuePhrase.value)” for this launch. \(error.localizedDescription)"
        }
    }

    deinit {
        monitorTask?.cancel()
        if let focusChangeObserver {
            DistributedNotificationCenter.default().removeObserver(focusChangeObserver.token)
        }
    }

    func start(requestNotificationAuthorization: Bool) {
        launchAtLogin = loginItem.isEnabled
        observeFocusChanges()

        do {
            try inputGuard.start()
        } catch {
            protectionState = .unavailable(error.localizedDescription)
        }

        Task { [weak self] in
            await self?.prepareNotifications(requestAuthorizationIfNeeded: requestNotificationAuthorization)
        }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFocusStateIfNeeded()
                self?.retryUnavailableGuardIfNeeded()
                self?.evaluateBypassIdleTimer()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        stopObservingFocusChanges()
        inputGuard.setInactive()
    }

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
            rescuePhraseDraft = phrase.value
            if protectionState == .guarded {
                inputGuard.setGuarded(
                    circleEnabled: circleEnabled,
                    rescuePhrase: savedRescuePhrase
                )
            }
            settingsMessage = "Rescue phrase saved in Keychain."
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func beginBypass(trigger: BypassTrigger = .menu) {
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

    private func refreshFocusStateIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastFocusRefresh) >= 2 else { return }
        lastFocusRefresh = now
        await refreshFocusState()
    }

    private func refreshFocusState() async {
        let enabled: Bool
        do {
            enabled = try await FocusGuardIntent.current.isEnabled
        } catch {
            let shouldFailOpen = focusQueryFailurePolicy.recordFailure()
            focusMonitoringUnavailable = shouldFailOpen
            if shouldFailOpen {
                applyFocusState(false)
                let protectionSummary =
                    manualArmActive
                    ? "The manual-arm latch remains in effect."
                    : "Input is being left active until Focus monitoring recovers."
                focusMonitoringIssue =
                    "CatGuard could not determine the Focus state after \(focusQueryFailurePolicy.consecutiveFailures) attempts. \(protectionSummary) \(error.localizedDescription)"
            } else {
                focusMonitoringIssue =
                    "A Focus status check failed. CatGuard is preserving the last known state and will retry. \(error.localizedDescription)"
            }
            return
        }

        focusQueryFailurePolicy.recordSuccess()
        focusMonitoringIssue = nil
        focusMonitoringUnavailable = false
        applyFocusState(enabled)
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
    }

    private func arm() {
        guard activationReasons.shouldGuard else { return }
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
        guard case .unavailable = protectionState else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUnavailableRetry) >= 10 else { return }
        lastUnavailableRetry = now

        do {
            try inputGuard.start()
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
        let token = DistributedNotificationCenter.default().addObserver(
            forName: FocusGuardIntentNotification.didPerform,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshFocusState()
            }
        }
        focusChangeObserver = DistributedNotificationObserver(token: token)
    }

    private func stopObservingFocusChanges() {
        guard let focusChangeObserver else { return }
        DistributedNotificationCenter.default().removeObserver(focusChangeObserver.token)
        self.focusChangeObserver = nil
    }
}
