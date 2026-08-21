import SwiftUI

/// Detail view — where the Apple concepts hidden on the home screen become available. (spec §15)
struct AppDetailView: View {
    let app: AppSnapshot
    let store: Store
    @State private var showsRawState = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                currentBuild
                distribution
                history
                timeline
                appleDetails
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(app.name)
    }

    private var header: some View {
        let status = app.status
        let state = status.state
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: state.severity.symbol)
                    .foregroundStyle(state.severity.tint)
                    .font(.title3)
                Text(state.headline).font(.title3.weight(.semibold))
                if let term = state.appleTerm {
                    Text(term)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                        .textSelection(.enabled)
                }
            }
            Text(state.description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // "Did the new one land?" and "can they install now?" are different questions.
            if let testable = status.testable {
                Label {
                    Text(status.hasOlderTestableBuild
                         ? String(localized: "\(testable.displayVersion) is what you can test right now")
                         : String(localized: "You can install it now"))
                    + Text(status.audienceDescription.map { " · \($0)" } ?? "")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(.green)
            }

            if app.isPartial {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(app.partialErrors, id: \.self) { problem in
                        Label(problem, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let blocker = state.blocker {
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                if let action = state.nextAction {
                    ActionButton(action: action, app: app, store: store)
                }
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    Text(String(localized: "Last checked \(RelativeTime.string(app.fetchedAt, relativeTo: context.date))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var currentBuild: some View {
        if let build = app.latestBuild {
            Section2(String(localized: "Current version")) {
                LabeledContent(String(localized: "Version"), value: build.displayVersion)
                if let uploaded = build.uploadedAt {
                    LabeledContent(String(localized: "Uploaded"), value: RelativeTime.string(uploaded))
                }
                LabeledContent(String(localized: "State"), value: "\(build.humanState)  ·  \(build.processingState)")
                if let days = build.daysUntilExpiry, !build.isExpired {
                    LabeledContent(String(localized: "Expires"), value: String(localized: "\(days) days left"))
                }
            }
        }
    }

    /// An app having groups and **this build being attached to them** are different facts.
    /// Conflating them means answering "who can install this?" confidently and wrongly.
    private var distribution: some View {
        Section2(String(localized: "Who can test this")) {
            if app.groups.isEmpty {
                Text(String(localized: "There is no tester group.")).foregroundStyle(.secondary)
            } else {
                let assigned = app.latestBuild?.assignedGroupIDs ?? []
                ForEach(app.groups) { group in
                    let isOn = assigned.contains(group.id)
                    LabeledContent {
                        HStack(spacing: 6) {
                            if group.publicLinkEnabled {
                                Image(systemName: "link").foregroundStyle(.blue)
                            }
                            Text(testerLabel(for: group))
                                .foregroundStyle(isOn ? .primary : .secondary)
                            if group.autoDistributes {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.secondary)
                                    .help(String(localized: "New builds distribute automatically"))
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isOn ? .green : .secondary)
                            Text("\(group.isInternal ? String(localized: "Internal") : String(localized: "External")) · \(group.name)")
                        }
                    }
                    .font(.callout)
                }
                Text(String(localized: "A check means the latest build is attached to that group. ")
                     + String(localized: "↻ means new builds distribute automatically; the link icon means a public link."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = app.groups.compactMap(\.publicLink).first {
                    HStack(spacing: 6) {
                        Text(link).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Copy public link"))
                    }
                }
            }
            if let count = app.latestBuild?.individualTesterCount, count > 0 {
                LabeledContent(String(localized: "Individual invites"), value: String(localized: "\(count) people")).font(.callout)
            }
            // Install status stays hidden until the data is trustworthy. (spec §28)
        }
    }

    @ViewBuilder
    private var history: some View {
        if app.builds.count > 1 {
            Section2(String(localized: "Earlier versions")) {
                ForEach(app.builds.dropFirst()) { build in
                    LabeledContent(build.displayVersion) {
                        Text(build.humanState).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// When and how the state changed. (spec §21)
    ///
    /// Also the evidence that answers "how long did processing take?" without an LLM.
    @ViewBuilder
    private var timeline: some View {
        let entries = store.transitions(for: app)
        if !entries.isEmpty {
            Section2(String(localized: "State history")) {
                ForEach(entries.prefix(8)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(Self.timeFormatter.string(from: entry.at))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(describe(entry))
                            .font(.callout)
                    }
                }
                if entries.count > 8 {
                    Text(String(localized: "\(entries.count - 8) earlier entries"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The state ID can stay put while the fingerprint moves — a different cause or build.
    /// Rendering that as "X → X" just confuses the reader.
    private func describe(_ entry: StateStore.Transition) -> String {
        guard let from = entry.from else { return String(localized: "first seen · \(label(for: entry.to))") }
        guard from != entry.to else { return String(localized: "\(label(for: entry.to)) · details changed") }
        return "\(label(for: from)) → \(label(for: entry.to))"
    }

    private func label(for id: AppStateID) -> String {
        AppStateDefinition.make(id).headline
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    /// "Couldn't read it" is not "there are none". Saying "none" for an unread count is
    /// exactly the confident wrong answer this app exists to avoid.
    private func testerLabel(for group: GroupSnapshot) -> String {
        guard let count = group.testerCount else { return String(localized: "unread") }
        return count == 0 ? String(localized: "none") : String(localized: "\(count) people")
    }

    /// Raw payload for advanced use. Collapsed by default. (spec §15, §29)
    private var appleDetails: some View {
        DisclosureGroup(String(localized: "Apple details"), isExpanded: $showsRawState) {
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent(String(localized: "State ID"), value: app.status.state.id.rawValue)
                if let reason = app.status.state.reason {
                    LabeledContent(String(localized: "Reason code"), value: reason)
                }
                LabeledContent("Bundle ID", value: app.bundleID)
                ForEach(app.status.state.rawEvidence.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent(key, value: value)
                }
                Button(String(localized: "Open in App Store Connect")) {
                    if let url = app.appStoreConnectURL { NSWorkspace.shared.open(url) }
                }
                .padding(.top, 5)
            }
            .font(.callout.monospaced())
            .padding(.top, 7)
        }
        .font(.callout)
    }
}

/// A titled block of content.
struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
