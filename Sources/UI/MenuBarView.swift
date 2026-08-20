import SwiftUI

/// 메뉴바 드롭다운. 홈의 축약판. (명세 §14)
///
/// 창을 열지 않고도 이상 유무를 판단할 수 있어야 한다.
struct MenuBarView: View {
    @Bindable var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.isConfigured {
                Text("App Store Connect 연결이 필요합니다")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else if store.apps.isEmpty {
                Text(store.isRefreshing ? "확인 중…" : "앱이 없습니다")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(store.apps) { app in
                    row(app)
                }
            }

            Divider().padding(.vertical, 5)

            HStack {
                Text("마지막 확인: \(RelativeTime.string(store.lastRefresh))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 7)

            menuButton("새로고침", symbol: "arrow.clockwise") { store.refresh() }
            menuButton("대시보드 열기", symbol: "macwindow") { openWindow(id: "main") }
            menuButton("종료", symbol: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 7)
        .frame(width: 292)
    }

    private func row(_ app: AppSnapshot) -> some View {
        let state = app.state
        return Button {
            openWindow(id: "main")
        } label: {
            HStack(spacing: 8) {
                Text(state.severity.glyph)
                    .foregroundStyle(state.severity.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.callout.weight(.medium))
                    Text(state.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(.rect)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func menuButton(_ title: String, symbol: String,
                            action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}
