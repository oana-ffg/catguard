import Foundation

/// Owns a thread-safe notification registration and removes it on release.
final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
    }

    deinit {
        center.removeObserver(token)
    }
}
