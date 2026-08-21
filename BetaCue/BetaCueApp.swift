import SwiftUI

@main
struct BetaCueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = Store.shared

    var body: some Scene {
        // Declare Window first: the first scene in `body` is the one presented at launch,
        // and with MenuBarExtra ahead of it the window is never created at all.
        Window("BetaCue", id: "main") {
            HomeView(store: store)
        }
        .defaultSize(width: 860, height: 640)

        // The menu bar is always present: you should see trouble without opening a window. (spec §14)
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }

    /// The worst state across apps drives the icon.
    ///
    /// Not `airplane`: it is the same symbol macOS uses for Airplane Mode and reads as that.
    private var menuBarSymbol: String {
        guard let worst = store.apps.map(\.status.state.severity).min() else { return "paperplane" }
        switch worst {
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "paperplane.circle"
        case .success: return "paperplane.fill"
        case .idle:    return "paperplane"
        }
    }
}

/// Owns the work that has to keep running whether or not a window exists.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // State tracking and notifications must run even if the window is never opened. (spec §12)
        Store.shared.prepareNotifications()
        Store.shared.startPolling()

        NSApp.activate(ignoringOtherApps: true)
        presentMainWindow()
    }

    /// The user can flip notifications in System Settings while the app runs, so re-read the
    /// permission whenever the app comes forward rather than trusting the launch-time answer.
    func applicationDidBecomeActive(_ notification: Notification) {
        Store.shared.refreshNotificationPermission()
    }

    /// Reopen the window when the Dock icon is clicked and none is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { presentMainWindow() }
        return true
    }

    /// SwiftUI may create the window after launch finishes, so retry briefly instead of giving up.
    ///
    /// `NSApp.windows` also contains the menu-bar popover panel, so filter out `NSPanel`
    /// to avoid fronting the wrong thing.
    private func presentMainWindow(attemptsLeft: Int = 20) {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentMainWindow(attemptsLeft: attemptsLeft - 1)
        }
    }
}
