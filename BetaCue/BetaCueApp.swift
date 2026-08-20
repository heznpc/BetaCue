import SwiftUI

@main
struct BetaCueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = Store.shared

    var body: some Scene {
        // Window를 먼저 선언한다. body의 첫 씬이 실행 시 표시되는 씬이고,
        // MenuBarExtra가 앞에 오면 창이 아예 만들어지지 않는다.
        Window("BetaCue", id: "main") {
            HomeView(store: store)
        }
        .defaultSize(width: 860, height: 640)

        // 메뉴바는 상시 표시. 창을 열지 않아도 이상 유무를 알 수 있어야 한다. (명세 §14)
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

    /// 가장 나쁜 상태를 아이콘에 반영한다.
    ///
    /// `airplane`은 쓰지 않는다 — macOS 비행기 모드와 같은 심볼이라 메뉴바에서 구별되지 않는다.
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

/// 창 존재 여부와 무관하게 살아 있어야 하는 것들을 담당한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 창을 한 번도 열지 않아도 상태를 따라가고 알림을 보내야 한다. (명세 §12)
        Store.shared.prepareNotifications()
        Store.shared.startPolling()

        NSApp.activate(ignoringOtherApps: true)
        presentMainWindow()
    }

    /// Dock 아이콘을 눌렀을 때 창이 없으면 다시 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { presentMainWindow() }
        return true
    }

    /// SwiftUI가 창을 만드는 시점이 실행 완료 시점보다 늦을 수 있어 잠깐 기다렸다 잡는다.
    ///
    /// `NSApp.windows`에는 메뉴바 팝오버 패널도 들어 있으므로 `NSPanel`을 걸러야
    /// 엉뚱한 걸 앞으로 가져오지 않는다.
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
