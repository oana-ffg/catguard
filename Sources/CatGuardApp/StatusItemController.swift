import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: GuardCoordinator
    private let showSettings: () -> Void
    private let showAbout: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(
        coordinator: GuardCoordinator,
        showSettings: @escaping () -> Void,
        showAbout: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.showSettings = showSettings
        self.showAbout = showAbout
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(showMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        coordinator.$protectionState
            .combineLatest(coordinator.$focusMonitoringUnavailable)
            .sink { [weak self] state, focusMonitoringUnavailable in
                self?.updateAppearance(
                    for: state,
                    focusMonitoringUnavailable: focusMonitoringUnavailable
                )
            }
            .store(in: &cancellables)
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        let stateItem = NSMenuItem(title: coordinator.protectionState.label, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        if coordinator.focusMonitoringIssue != nil {
            let title: String
            if coordinator.focusMonitoringUnavailable {
                title =
                    coordinator.manualArmActive
                    ? "Focus monitoring unavailable — manual arm remains latched"
                    : "Focus monitoring unavailable — input left active"
            } else {
                title = "Focus monitoring retrying — last known state preserved"
            }
            let focusIssueItem = NSMenuItem(
                title: title,
                action: nil,
                keyEquivalent: ""
            )
            focusIssueItem.isEnabled = false
            menu.addItem(focusIssueItem)
        }
        menu.addItem(.separator())

        if coordinator.manualArmActive {
            let manualItem = NSMenuItem(
                title: "Manual arm latched until bypass",
                action: nil,
                keyEquivalent: ""
            )
            manualItem.isEnabled = false
            menu.addItem(manualItem)
            if case .unavailable = coordinator.protectionState {
                let retryItem = NSMenuItem(
                    title: "Manual arm remains latched; CatGuard will retry automatically",
                    action: nil,
                    keyEquivalent: ""
                )
                retryItem.isEnabled = false
                menu.addItem(retryItem)
            }
        } else {
            menu.addItem(
                withTitle: "Arm now — until circle or rescue phrase",
                action: #selector(activateManualGuard),
                keyEquivalent: ""
            )
        }

        if coordinator.focusActive {
            switch coordinator.protectionState {
            case .guarded:
                menu.addItem(
                    withTitle: "Bypass until 5 minutes idle",
                    action: #selector(beginBypass),
                    keyEquivalent: ""
                )
            case .bypassed:
                menu.addItem(
                    withTitle: "Re-arm Focus now",
                    action: #selector(rearmFocusNow),
                    keyEquivalent: ""
                )
            default:
                break
            }
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "About CatGuard", action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CatGuard", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items {
            if item.action != nil { item.target = self }
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func beginBypass() {
        coordinator.beginBypass()
    }

    @objc private func activateManualGuard() {
        coordinator.activateManualGuard()
    }

    @objc private func rearmFocusNow() {
        coordinator.rearmFocusNow()
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func openAbout() {
        showAbout()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateAppearance(
        for state: ProtectionState,
        focusMonitoringUnavailable: Bool
    ) {
        guard let button = statusItem.button else { return }
        let symbolName: String
        let tintColor: NSColor
        if focusMonitoringUnavailable, state != .guarded {
            symbolName = "exclamationmark.triangle.fill"
            tintColor = .systemOrange
        } else {
            switch state {
            case .guarded:
                symbolName = "lock.fill"
                tintColor = .systemRed
            case .inputActive:
                symbolName = "pawprint.fill"
                tintColor = .systemGreen
            case .bypassed:
                symbolName = "lock.open.fill"
                tintColor = .systemGreen
            case .unavailable:
                symbolName = "exclamationmark.triangle.fill"
                tintColor = .systemOrange
            }
        }
        let statusDescription: String
        if focusMonitoringUnavailable {
            statusDescription = "Focus monitoring unavailable; \(state.label)"
        } else {
            statusDescription = state.label
        }

        let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [tintColor])
        let configuration = sizeConfiguration.applying(colorConfiguration)
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "CatGuard: \(statusDescription)"
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        button.image = image
        button.contentTintColor = nil
        button.toolTip = statusDescription
        button.setAccessibilityLabel("CatGuard: \(statusDescription)")
    }
}
