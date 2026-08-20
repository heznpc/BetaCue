import SwiftUI

/// 홈. 앱 하나당 정체·현재 상태·막힌 이유·다음 할 일·마지막 확인이 반드시 있다. (명세 §13)
struct HomeView: View {
    @Bindable var store: Store
    @State private var selection: AppSnapshot.ID?

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            if let selection, let app = store.apps.first(where: { $0.id == selection }) {
                AppDetailView(app: app, store: store)
            } else {
                ContentUnavailableView("앱을 선택하세요", systemImage: "sidebar.left")
            }
        }
        .navigationTitle("BetaCue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if !store.isConfigured {
            OnboardingView(store: store)
        } else {
            List(store.apps, selection: $selection) { app in
                AppRow(app: app, store: store)
                    .tag(app.id)
            }
            .listStyle(.inset)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            .safeAreaInset(edge: .bottom) { statusBar }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
                Text("확인 중…")
            } else if let error = store.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1)
            } else {
                Text("마지막 확인: \(RelativeTime.string(store.lastRefresh))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// 목록의 한 줄. Apple 용어를 쓰지 않는다.
private struct AppRow: View {
    let app: AppSnapshot
    let store: Store

    var body: some View {
        let state = app.state
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: state.severity.symbol)
                    .foregroundStyle(state.severity.tint)
                Text(app.name).font(.headline)
                Spacer()
                if let build = app.latestBuild {
                    Text(build.displayVersion)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(state.headline)
                .font(.subheadline)
                .foregroundStyle(state.severity == .warning ? state.severity.tint : .primary)

            if let blocker = state.blocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action = state.nextAction, action != .openInAppStoreConnect {
                ActionButton(action: action, app: app, store: store)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 5)
    }
}

/// 다음 행동 버튼. v0에서는 두 가지뿐이다. (명세 §26)
struct ActionButton: View {
    let action: NextAction
    let app: AppSnapshot
    let store: Store

    var body: some View {
        Button {
            perform()
        } label: {
            Label(action.title, systemImage: action.symbol)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func perform() {
        switch action {
        case .openInAppStoreConnect, .assignBuildToGroup:
            // v0에서 배포 연결은 App Store Connect로 넘긴다. (명세 §26 ② escape hatch)
            if let url = app.appStoreConnectURL { NSWorkspace.shared.open(url) }
        }
    }
}

extension Severity {
    var tint: Color {
        switch self {
        case .warning: return .orange
        case .info:    return .blue
        case .success: return .green
        case .idle:    return .secondary
        }
    }
}

enum RelativeTime {
    static func string(_ date: Date?) -> String {
        guard let date else { return "아직 없음" }
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<10:     return "방금"
        case ..<60:     return "\(seconds)초 전"
        case ..<3600:   return "\(seconds / 60)분 전"
        case ..<86_400: return "\(seconds / 3600)시간 전"
        default:        return "\(seconds / 86_400)일 전"
        }
    }
}
