import Foundation
import UserNotifications

/// The seam that lets notification decisions be tested without the system notification centre.
///
/// What matters is *which* transitions produce a banner, not that macOS displayed one.
protocol NotificationSending: Sendable {
    func post(title: String, body: String)

    /// Installs a handler for banners macOS refused.
    ///
    /// A refusal arrives after `post` has already returned, so it has to be pushed rather
    /// than polled — and it has to reach observable state, because a dropped banner is never
    /// retried and is therefore nowhere at all unless the window says so.
    func observeFailures(_ handler: @escaping @MainActor @Sendable (String) -> Void)
}

/// Delivers through macOS.
struct SystemNotifier: NotificationSending {
    func post(title: String, body: String) { Notifier.post(title: title, body: body) }

    func observeFailures(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        Notifier.observeDeliveryFailures { message in
            Task { @MainActor in handler(message) }
        }
    }
}

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

    /// Reports refusals as they happen. Only one observer is needed — the app has one Store.
    static func observeDeliveryFailures(_ handler: @escaping @Sendable (String) -> Void) {
        failureLog.observe(handler)
    }

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
        private var observer: (@Sendable (String) -> Void)?

        var latest: String? { lock.withLock { message } }

        func record(_ text: String) {
            // Call the observer outside the lock: it hops to the main actor, and holding a
            // lock across that is how a deadlock gets written.
            let observer: (@Sendable (String) -> Void)? = lock.withLock {
                message = text
                return self.observer
            }
            observer?(text)
        }

        func observe(_ handler: @escaping @Sendable (String) -> Void) {
            lock.withLock { observer = handler }
        }
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
