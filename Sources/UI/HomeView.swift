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

    @ViewBuilder
    private var statusBar: some View {
        // 알림이 막혀 있으면 이 앱의 절반이 동작하지 않는다. 조용히 두면 안 된다.
        if store.notificationPermission.isBlocking {
            HStack(spacing: 7) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                Text("알림이 꺼져 있어 상태 변화를 알려드릴 수 없습니다")
                Spacer()
                Button("설정 열기") {
                    if let url = Notifier.settingsURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.12))
        }

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
        let status = app.status
        let state = status.state
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: state.severity.symbol)
                    .foregroundStyle(state.severity.tint)
                Text(app.name).font(.headline)
                if app.isPartial {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("일부 정보를 읽지 못했습니다")
                }
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

            // 최신 빌드가 아직 못 나갔어도 이전 빌드가 살아 있으면 그 사실을 잃지 않는다.
            if status.hasOlderTestableBuild, let alive = status.testable {
                Label("\(alive.displayVersion)은(는) 계속 테스트 가능", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

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
///
/// 레이블은 실제로 하는 일과 일치해야 한다. 앱 안에서 배포할 수 없는 상황이면
/// "배포"라고 쓰지 않고 App Store Connect로 넘긴다고 말한다.
struct ActionButton: View {
    let action: NextAction
    let app: AppSnapshot
    let store: Store

    /// 앱 안에서 바로 배포할 수 있는가 — 붙일 빌드와 받을 그룹이 둘 다 있어야 한다.
    private var inAppDistribution: (build: BuildSnapshot, groups: [GroupSnapshot])? {
        guard action == .assignBuildToGroup,
              let build = app.latestBuild, build.isValid
        else { return nil }
        let targets = store.distributionTargets(for: build, in: app)
            .filter(\.canReachSomeone)
        return targets.isEmpty ? nil : (build, targets)
    }

    var body: some View {
        Button {
            perform()
        } label: {
            Label(title, systemImage: symbol).font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(store.runningCommand == app.id)
    }

    private var title: String {
        guard action == .assignBuildToGroup else { return action.title }
        guard let target = inAppDistribution else { return "App Store Connect에서 배포" }
        return target.groups.count == 1
            ? "\(target.groups[0].name)에 배포"
            : "테스터에게 배포"
    }

    private var symbol: String {
        inAppDistribution == nil && action == .assignBuildToGroup
            ? "arrow.up.forward.app" : action.symbol
    }

    private func perform() {
        if let target = inAppDistribution {
            store.distribute(build: target.build, of: app, to: target.groups)
            return
        }
        if let url = app.appStoreConnectURL { NSWorkspace.shared.open(url) }
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
