import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: GuardCoordinator

    var body: some View {
        Form {
            Section {
                Label {
                    Text(
                        "CatGuard prevents accidental input from cats. It does not protect this Mac from people and does not replace the lock screen."
                    )
                } icon: {
                    Image(systemName: "pawprint.fill")
                }
                .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Input", value: coordinator.protectionState.label)
                LabeledContent("Focus Filter", value: coordinator.focusActive ? "Active" : "Inactive")
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

            Section("Keyboard helper") {
                LabeledContent("Status", value: coordinator.keyboardHelperStatus)
                Text(
                    "One administrator approval installs a narrow root helper that can guard external physical keyboards. It restores input automatically if the app heartbeat stops."
                )
                .foregroundStyle(.secondary)
                Button("Install or Update Keyboard Helper") {
                    coordinator.installKeyboardHelper()
                }
            }

            Section("Fallback rescue phrase") {
                SecureField("Rescue phrase", text: $coordinator.rescuePhrase)
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
}
