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
            button.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "CatGuard")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(showMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        coordinator.$protectionState
            .sink { [weak self] state in self?.updateAppearance(for: state) }
            .store(in: &cancellables)
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        let stateItem = NSMenuItem(title: coordinator.protectionState.label, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        if coordinator.focusActive {
            switch coordinator.protectionState {
            case .guarded:
                menu.addItem(
                    withTitle: "Bypass until 5 minutes idle",
                    action: #selector(beginBypass),
                    keyEquivalent: ""
                )
            case .bypassed:
                menu.addItem(withTitle: "Arm now", action: #selector(armNow), keyEquivalent: "")
            default:
                break
            }
            menu.addItem(.separator())
        }

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

    @objc private func armNow() {
        coordinator.armNow()
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

    private func updateAppearance(for state: ProtectionState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .guarded:
            button.contentTintColor = .systemRed
        case .inputActive, .bypassed:
            button.contentTintColor = .systemGreen
        case .unavailable:
            button.contentTintColor = .systemOrange
        }
        button.toolTip = state.label
        button.setAccessibilityLabel("CatGuard: \(state.label)")
    }
}
