import Foundation
import UserNotifications

enum SessionNotificationAuthorizationStatus: Equatable {
    case checking
    case notRequested
    case enabled
    case disabled

    var label: String {
        switch self {
        case .checking:
            "Checking…"
        case .notRequested:
            "Not requested"
        case .enabled:
            "Enabled"
        case .disabled:
            "Off"
        }
    }
}

struct SessionNotifier {
    func authorizationStatus() async -> SessionNotificationAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notRequested
        case .denied:
            return .disabled
        case .authorized, .provisional, .ephemeral:
            return .enabled
        @unknown default:
            return .disabled
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func notify(report: GuardSessionReport) async throws {
        let content = UNMutableNotificationContent()
        content.title = "CatGuard session ended"

        content.body = report.notificationLines().joined(separator: "\n")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "catguard-session-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}
