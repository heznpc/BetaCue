import SwiftUI

/// Menu-bar dropdown — the condensed home screen. (spec §14)
///
/// You should be able to tell whether anything is wrong without opening a window.
struct MenuBarView: View {
    @Bindable var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.isConfigured {
                Text(String(localized: "App Store Connect isn't connected yet"))
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else if store.apps.isEmpty {
                // "No apps" was shown for a failed first read too, which states as fact the
                // one thing that was never established.
                Text(emptyMessage)
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

            TimelineView(.periodic(from: .now, by: 10)) { context in
                HStack(spacing: 5) {
                    if case .stale = store.freshness {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(freshnessText(at: context.date))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }

            menuButton(String(localized: "Refresh"), symbol: "arrow.clockwise") { store.refresh() }
            menuButton(String(localized: "Open dashboard"), symbol: "macwindow") { openWindow(id: "main") }
            menuButton(String(localized: "Quit"), symbol: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 7)
        .frame(width: 292)
    }

    private var emptyMessage: String {
        switch store.freshness {
        case .checking: return String(localized: "Checking…")
        case .stale:    return String(localized: "Couldn't read your apps")
        case .checked:  return String(localized: "No apps")
        }
    }

    /// Never claims a check succeeded because an attempt finished.
    private func freshnessText(at now: Date) -> String {
        switch store.freshness {
        case .checking:
            return String(localized: "Checking…")
        case .checked(let at):
            return String(localized: "Last checked \(RelativeTime.string(at, relativeTo: now))")
        case .stale(let lastGood):
            guard let lastGood else { return String(localized: "No successful check yet") }
            return String(localized: "Check failed · showing data from \(RelativeTime.string(lastGood, relativeTo: now))")
        }
    }

    private func row(_ app: AppSnapshot) -> some View {
        let status = app.status
        let state = status.state
        return Button {
            // Opening the window without selecting the app leaves the user staring at whatever
            // they last looked at, which is not what they just clicked.
            store.selectedAppID = app.id
            openWindow(id: "main")
        } label: {
            HStack(spacing: 8) {
                Text(state.severity.glyph)
                    .foregroundStyle(state.severity.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.callout.weight(.medium))
                    Text(status.hasOlderTestableBuild
                         ? String(localized: "\(state.headline) · previous version testable")
                         : state.headline)
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
