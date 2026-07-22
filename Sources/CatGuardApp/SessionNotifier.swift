import Foundation
import UserNotifications

struct SessionNotifier {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func notify(report: GuardSessionReport) async throws {
        let content = UNMutableNotificationContent()
        content.title = "CatGuard session ended"

        content.body = report.notificationLines.joined(separator: "\n")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "catguard-session-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}
