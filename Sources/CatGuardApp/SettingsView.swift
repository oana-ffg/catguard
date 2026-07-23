import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: GuardCoordinator

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Input", value: coordinator.protectionState.label)
                LabeledContent("Focus Filter", value: coordinator.focusActive ? "Active" : "Inactive")
                LabeledContent(
                    "Manual arm",
                    value: coordinator.manualArmActive ? "Latched until bypass" : "Off"
                )
                if !coordinator.manualArmActive {
                    Button("Arm now — until circle or rescue phrase") {
                        coordinator.activateManualGuard()
                    }
                }
            }

            Section("General") {
                Toggle(
                    "Start CatGuard at login",
                    isOn: Binding(
                        get: { coordinator.launchAtLogin },
                        set: { coordinator.setLaunchAtLogin($0) }
                    )
                )
                Toggle("Allow a pointer circle to bypass", isOn: $coordinator.circleEnabled)
                Text(
                    "A circle works with an ordinary mouse or trackpad. After any bypass, CatGuard waits for five continuous minutes without physical input before re-arming."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Input permissions") {
                Text(
                    "CatGuard needs Input Monitoring to distinguish physical keyboard and pointer input, and Accessibility to suppress it while armed."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Button("Open Input Monitoring") {
                        openInputMonitoringSettings()
                    }
                    Button("Open Accessibility") {
                        openAccessibilitySettings()
                    }
                }
            }

            Section("Fallback rescue phrase") {
                TextField("Rescue phrase", text: $coordinator.rescuePhraseDraft)
                HStack {
                    Text(
                        "Type 4–32 letters on the guarded keyboard to bypass until idle. A fresh install uses “catguard.”"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { coordinator.saveRescuePhrase() }
                }
            }

            Section("Session reports") {
                LabeledContent(
                    "Notifications",
                    value: coordinator.notificationAuthorizationStatus.label
                )
                Text("CatGuard sends a summary when a guarded session ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch coordinator.notificationAuthorizationStatus {
                case .notRequested:
                    Button("Enable Notifications") {
                        Task {
                            await coordinator.requestNotificationAuthorization()
                        }
                    }
                case .disabled:
                    Button("Open Notification Settings") {
                        openNotificationSettings()
                    }
                case .checking, .enabled:
                    EmptyView()
                }
            }

            Section("Focus") {
                Text(
                    "In System Settings, edit a Focus, choose Focus Filters, add CatGuard, and enable “Guard against cat input.” CatGuard runs in the background and follows that Focus automatically."
                )
                .foregroundStyle(.secondary)
                Button("Open Focus Settings") {
                    openFocusSettings()
                }
            }

            if let message = coordinator.settingsMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }

            if let issue = coordinator.focusMonitoringIssue {
                Section("Focus monitoring") {
                    Text(issue)
                        .foregroundStyle(coordinator.focusMonitoringUnavailable ? .orange : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 540, minHeight: 500)
    }

    private func openFocusSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openInputMonitoringSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openAccessibilitySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
