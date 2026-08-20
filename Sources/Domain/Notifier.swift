import Foundation
import UserNotifications

/// 알림 전송.
///
/// 권한이 거부되면 이 앱의 핵심 기능이 통째로 죽는다 — 그런데 아무 표시도 없이 죽는다.
/// 그래서 권한 상태를 밖에서 읽을 수 있게 두고 화면에서 알린다.
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

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 시스템 설정의 이 앱 알림 상세 화면을 연다. 거부된 권한은 앱에서 되돌릴 수 없다.
    static var settingsURL: URL? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        return settingsURL(for: bundleIdentifier)
    }

    static func settingsURL(for bundleIdentifier: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                   + "?id=\(bundleIdentifier)")
    }
}
