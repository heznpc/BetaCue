import SwiftUI

/// Home. Every app shows identity, current state, blocker, next action and last check. (spec §13)
struct HomeView: View {
    @Bindable var store: Store

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            if let selection = store.selectedAppID,
               let app = store.apps.first(where: { $0.id == selection }) {
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
            List(store.apps, selection: $store.selectedAppID) { app in
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
            alertRow(String(localized: "Notifications are off, so state changes can't be announced"),
                     symbol: "bell.slash.fill") {
                Button(String(localized: "Open Settings")) {
                    if let url = Notifier.settingsURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }
        }

        // The transition log is what decides whether a change is announced at all, so a
        // database that stopped working is not a background detail — it is the difference
        // between this app watching and this app only appearing to.
        if let problem = store.persistenceHealth.message {
            alertRow(problem, symbol: "externaldrive.badge.exclamationmark")
        }

        // A refused banner is never retried, because the transition it described is already
        // recorded. If it is not on screen it is nowhere.
        if let failure = store.lastNotificationFailure {
            alertRow(String(localized: "The last notification couldn't be shown: \(failure)"),
                     symbol: "bell.badge.slash")
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

extension HomeView {
    private func alertRow(_ message: String, symbol: String) -> some View {
        alertRow(message, symbol: symbol) { EmptyView() }
    }

    private func alertRow<Trailing: View>(
        _ message: String, symbol: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.12))
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
    @State private var showingPicker = false

    /// Groups this build could be attached to that would actually reach someone.
    private var candidates: [GroupSnapshot] {
        guard action == .assignBuildToGroup,
              let build = app.latestBuild, build.processingSucceeded
        else { return [] }
        return store.distributionTargets(for: build, in: app)
            .filter { $0.reachability == .reachable }
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
        .sheet(isPresented: $showingPicker) {
            if let build = app.latestBuild {
                DistributionPicker(build: build, groups: candidates, app: app, store: store)
            }
        }
    }

    private var title: String {
        guard action == .assignBuildToGroup else { return action.title }
        switch candidates.count {
        case 0:  return String(localized: "Distribute in App Store Connect")
        case 1:  return String(localized: "Distribute to \(candidates[0].name)")
        default: return String(localized: "Choose who gets this build")
        }
    }

    private var symbol: String {
        candidates.isEmpty && action == .assignBuildToGroup
            ? "arrow.up.forward.app" : action.symbol
    }

    private func perform() {
        guard let build = app.latestBuild, !candidates.isEmpty else {
            if let url = app.appStoreConnectURL { NSWorkspace.shared.open(url) }
            return
        }
        // Never fan a build out to every candidate on one click. One unambiguous internal
        // group can go straight through; anything else — more than one option, or a group
        // that reaches outside — has to be chosen explicitly.
        if candidates.count == 1, candidates[0].isInternal, !candidates[0].publicLinkEnabled {
            store.distribute(build: build, of: app, to: candidates)
        } else {
            showingPicker = true
        }
    }
}

/// Explicit choice of who receives a build.
///
/// This is the only write the app performs, and attaching a build to an external group or a
/// public link puts it in front of people outside the team. That is not a side effect of a
/// single click.
struct DistributionPicker: View {
    let build: BuildSnapshot
    let groups: [GroupSnapshot]
    let app: AppSnapshot
    let store: Store

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var reachesOutside: Bool {
        groups.filter { selected.contains($0.id) }
              .contains { !$0.isInternal || $0.publicLinkEnabled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Who gets \(build.displayVersion)?"))
                    .font(.headline)
                Text(String(localized: "Pick the groups to attach this build to."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach(groups) { group in
                Toggle(isOn: Binding(
                    get: { selected.contains(group.id) },
                    set: { on in
                        if on { selected.insert(group.id) } else { selected.remove(group.id) }
                    })
                ) {
                    HStack(spacing: 6) {
                        Text(group.name)
                        if !group.isInternal {
                            Text(String(localized: "External"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if group.publicLinkEnabled {
                            Label(String(localized: "public link"), systemImage: "link")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        if let count = group.testerCount {
                            Text(String(localized: "\(count) people"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if reachesOutside {
                Label(String(localized: "This reaches people outside your team."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 7))
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Distribute")) {
                    store.distribute(build: build, of: app,
                                     to: groups.filter { selected.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
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
