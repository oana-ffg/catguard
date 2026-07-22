import AppIntents
import Combine
import Foundation

@MainActor
final class GuardCoordinator: ObservableObject {
    @Published private(set) var protectionState: ProtectionState = .inputActive
    @Published private(set) var focusActive = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var keyboardHelperStatus = "Checking…"
    @Published var circleEnabled: Bool {
        didSet {
            defaults.set(circleEnabled, forKey: Keys.circleEnabled)
            if protectionState == .guarded {
                pointerGuard.setGuarded(true, circleEnabled: circleEnabled)
            }
        }
    }
    @Published var rescuePhrase: String
    @Published private(set) var settingsMessage: String?

    private enum Keys {
        static let circleEnabled = "circleEnabled"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let loginItem = LoginItemController()
    private let notifier = SessionNotifier()
    private let keyboardGuard = KeyboardGuardClient()
    private lazy var pointerGuard = PointerGuard(
        callbacks: PointerGuard.Callbacks(
            onBlockedClick: { [weak self] in
                Task { @MainActor in self?.recordBlockedPointerClick() }
            },
            onCircle: { [weak self] in
                Task { @MainActor in self?.beginBypass() }
            },
            onBypassActivity: { [weak self] in
                Task { @MainActor in self?.recordBypassActivity() }
            }
        )
    )
    private var session = GuardSessionTracker()
    private var bypassIdleTimer = BypassIdleTimer()
    private var monitorTask: Task<Void, Never>?
    private var lastFocusRefresh = Date.distantPast
    private var lastIdleHelperRefresh = Date.distantPast
    private var lastUnavailableArmRetry = Date.distantPast

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
                rescuePhrase = storedPhrase
            } else {
                rescuePhrase = "catguard"
                try keychain.write(rescuePhrase)
            }
        } catch {
            rescuePhrase = "catguard"
            settingsMessage = error.localizedDescription
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    func start() {
        launchAtLogin = loginItem.isEnabled
        keyboardGuard.start()

        do {
            try pointerGuard.start()
        } catch {
            protectionState = .unavailable(error.localizedDescription)
        }

        Task {
            _ = try? await notifier.requestAuthorization()
        }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshKeyboardStateIfNeeded()
                await self?.refreshFocusStateIfNeeded()
                self?.evaluateBypassIdleTimer()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshFocusStateIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastFocusRefresh) >= 2 else { return }
        lastFocusRefresh = now
        await refreshFocusState()
    }

    private func refreshKeyboardStateIfNeeded() async {
        if focusActive {
            if case .unavailable = protectionState {
                let now = Date()
                guard now.timeIntervalSince(lastUnavailableArmRetry) >= 10 else { return }
                lastUnavailableArmRetry = now
                await arm()
                return
            }
            await refreshKeyboardState()
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastIdleHelperRefresh) >= 10 else { return }
        lastIdleHelperRefresh = now
        await refreshKeyboardState()
    }

    func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        pointerGuard.setInactive()
        await keyboardGuard.stop()
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

    func saveRescuePhrase() {
        let normalized = rescuePhrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        guard (4...32).contains(normalized.count),
            normalized.unicodeScalars.allSatisfy(allowed.contains)
        else {
            settingsMessage = "The rescue phrase must contain 4–32 English letters with no spaces."
            return
        }

        do {
            try keychain.write(normalized)
            rescuePhrase = normalized
            settingsMessage = "Rescue phrase saved in Keychain."
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func installKeyboardHelper() {
        do {
            try keyboardGuard.install()
            settingsMessage =
                "Keyboard helper installed. Add it separately in Input Monitoring, then CatGuard will retry automatically."
            Task {
                if focusActive {
                    await arm()
                } else {
                    await refreshKeyboardState()
                }
            }
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func beginBypass() {
        guard focusActive, protectionState == .guarded else { return }
        session.recordBypass()
        pointerGuard.setBypassed()
        bypassIdleTimer.begin(at: Date())
        protectionState = .bypassed
        Task {
            let count = await keyboardGuard.disarm()
            session.recordBlockedKeyboardInputs(count)
        }
    }

    func armNow() {
        guard focusActive else { return }
        bypassIdleTimer.reset()
        Task { await arm() }
    }

    private func refreshFocusState() async {
        let enabled: Bool
        do {
            enabled = try await FocusGuardIntent.current.isEnabled
        } catch {
            enabled = false
        }

        guard enabled != focusActive else { return }
        focusActive = enabled
        if enabled {
            session.begin()
            await arm()
        } else {
            await endSession()
        }
    }

    private func arm() async {
        do {
            try pointerGuard.start()
        } catch {
            let count = await keyboardGuard.disarm()
            session.recordBlockedKeyboardInputs(count)
            pointerGuard.setInactive()
            protectionState = .unavailable(error.localizedDescription)
            return
        }

        do {
            try await keyboardGuard.arm(rescuePhrase: rescuePhrase)
            pointerGuard.setGuarded(true, circleEnabled: circleEnabled)
            protectionState = .guarded
        } catch {
            let count = await keyboardGuard.disarm()
            session.recordBlockedKeyboardInputs(count)
            pointerGuard.setInactive()
            protectionState = .unavailable(error.localizedDescription)
        }
    }

    private func endSession() async {
        pointerGuard.setInactive()
        bypassIdleTimer.reset()
        protectionState = .inputActive
        let count = await keyboardGuard.disarm()
        session.recordBlockedKeyboardInputs(count)

        guard let report = session.end() else { return }
        Task {
            try? await notifier.notify(report: report)
        }
    }

    private func refreshKeyboardState() async {
        do {
            let heartbeat = try await keyboardGuard.heartbeat()
            keyboardHelperStatus = "Installed and reachable"
            if !focusActive { return }
            session.recordBlockedKeyboardInputs(heartbeat.blockedKeyboardInputs)

            if heartbeat.rescuePhraseTriggered, protectionState == .guarded {
                beginBypass()
                return
            }

            if protectionState == .guarded, !heartbeat.isGuarded {
                pointerGuard.setInactive()
                protectionState = .unavailable(
                    heartbeat.errorMessage ?? "The keyboard helper restored input unexpectedly."
                )
            }
        } catch {
            keyboardHelperStatus = "Not installed or unreachable"
            if !focusActive { return }
            if protectionState == .guarded {
                pointerGuard.setInactive()
                protectionState = .unavailable(error.localizedDescription)
            }
        }
    }

    private func evaluateBypassIdleTimer() {
        guard focusActive,
            protectionState == .bypassed,
            bypassIdleTimer.shouldRearm(at: Date())
        else { return }
        armNow()
    }

    private func recordBlockedPointerClick() {
        session.recordBlockedPointerClick()
    }

    private func recordBypassActivity() {
        guard protectionState == .bypassed else { return }
        bypassIdleTimer.recordActivity(at: Date())
    }
}
