import Foundation
import UserNotifications

/// Notification delivery.
///
/// A denied permission kills half of what this app is for — and kills it with no visible sign.
/// So the permission state is readable from outside and surfaced in the UI.
enum Notifier {
    enum Permission: Sendable {
        case unknown
        case granted
        case denied

        var isBlocking: Bool { self == .denied }
    }

    static func requestAuthorization() async -> Permission {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    static func currentPermission() async -> Permission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default: return .unknown
        }
    }

    /// Delivery failures, most recent first. The transition is already recorded by the time
    /// this runs, so a dropped banner is never retried — at minimum it has to be visible.
    private static let failureLog = FailureLog()

    static var lastDeliveryFailure: String? { failureLog.latest }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { failureLog.record(error.localizedDescription) }
        }
    }

    private final class FailureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var message: String?

        var latest: String? { lock.withLock { message } }
        func record(_ text: String) { lock.withLock { message = text } }
    }

    /// Opens this app's notification pane in System Settings. A denial cannot be undone in-app.
    static var settingsURL: URL? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        return settingsURL(for: bundleIdentifier)
    }

    static func settingsURL(for bundleIdentifier: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                   + "?id=\(bundleIdentifier)")
    }
}
