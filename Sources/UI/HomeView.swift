import SwiftUI

/// Home. Every app shows identity, current state, blocker, next action and last check. (spec §13)
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
                ContentUnavailableView(String(localized: "Select an app"), systemImage: "sidebar.left")
            }
        }
        .navigationTitle("BetaCue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
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
        // With notifications blocked, half of this app does nothing. Do not stay quiet about it.
        if store.notificationPermission.isBlocking {
            HStack(spacing: 7) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                Text(String(localized: "Notifications are off, so state changes can't be announced"))
                Spacer()
                Button(String(localized: "Open Settings")) {
                    if let url = Notifier.settingsURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.12))
        }

        TimelineView(.periodic(from: .now, by: 10)) { context in
            HStack(spacing: 8) {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Checking…"))
                } else if let error = store.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(1)
                } else {
                    Text(String(localized: "Last checked \(RelativeTime.string(store.lastRefresh, relativeTo: context.date))"))
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
}

/// One row of the list. No Apple vocabulary here.
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
                        .help(String(localized: "Some information couldn't be read"))
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

            // Even when the newest build is stuck, say so if an older one is still serving.
            if status.hasOlderTestableBuild, let alive = status.testable {
                Label(String(localized: "\(alive.displayVersion) is still testable"), systemImage: "checkmark.circle")
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

/// The next-action button. v0 has two. (spec §26)
///
/// The label has to match what actually happens. When in-app distribution is impossible,
/// it says it hands off to App Store Connect rather than claiming to distribute.
struct ActionButton: View {
    let action: NextAction
    let app: AppSnapshot
    let store: Store

    /// Can this be distributed from here? Needs both a build to attach and a group that reaches someone.
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
        guard let target = inAppDistribution else { return String(localized: "Distribute in App Store Connect") }
        return target.groups.count == 1
            ? String(localized: "Distribute to \(target.groups[0].name)")
            : String(localized: "Distribute to testers")
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
    /// The bucket a timestamp falls into.
    ///
    /// Split out from the string so tests can assert the logic without depending on
    /// which language the process happens to be running in.
    enum Bucket: Equatable, Sendable {
        case never
        case justNow
        case seconds(Int)
        case minutes(Int)
        case hours(Int)
        case days(Int)
    }

    static func bucket(_ date: Date?, relativeTo now: Date = Date()) -> Bucket {
        guard let date else { return .never }
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<10:     return .justNow
        case ..<60:     return .seconds(seconds)
        case ..<3600:   return .minutes(seconds / 60)
        case ..<86_400: return .hours(seconds / 3600)
        default:        return .days(seconds / 86_400)
        }
    }

    static func string(_ date: Date?, relativeTo now: Date = Date()) -> String {
        switch bucket(date, relativeTo: now) {
        case .never:            return String(localized: "never")
        case .justNow:          return String(localized: "just now")
        case .seconds(let n):   return String(localized: "\(n)s ago")
        case .minutes(let n):   return String(localized: "\(n)m ago")
        case .hours(let n):     return String(localized: "\(n)h ago")
        case .days(let n):      return String(localized: "\(n)d ago")
        }
    }
}
