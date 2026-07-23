import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let didShowFirstLaunchSettingsKey = "didShowFirstLaunchSettings"

    let coordinator = GuardCoordinator()

    private var statusItemController: StatusItemController?
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var isFinishingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(
            coordinator: coordinator,
            showSettings: { [weak self] in self?.showSettings() },
            showAbout: { [weak self] in self?.showAbout() }
        )

        let isFirstLaunch = !UserDefaults.standard.bool(forKey: Self.didShowFirstLaunchSettingsKey)
        if isFirstLaunch {
            UserDefaults.standard.set(true, forKey: Self.didShowFirstLaunchSettingsKey)
            showSettings()
        }

        coordinator.start(requestNotificationAuthorization: isFirstLaunch)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishingTermination else { return .terminateNow }
        isFinishingTermination = true
        Task {
            await coordinator.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = makeWindowController(
                title: "CatGuard Settings",
                width: 560,
                height: 520,
                rootView: SettingsView(coordinator: coordinator)
            )
        }
        show(settingsWindowController)
    }

    private func showAbout() {
        if aboutWindowController == nil {
            aboutWindowController = makeWindowController(
                title: "About CatGuard",
                width: 480,
                height: 390,
                rootView: AboutView()
            )
        }
        show(aboutWindowController)
    }

    private func makeWindowController<Content: View>(
        title: String,
        width: CGFloat,
        height: CGFloat,
        rootView: Content
    ) -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        window.isReleasedWhenClosed = false
        return NSWindowController(window: window)
    }

    private func show(_ controller: NSWindowController?) {
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}
