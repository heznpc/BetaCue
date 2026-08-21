import Foundation
import Observation

/// The single source of state the UI observes.
///
/// The pipeline is spec §2.1 verbatim:
/// ASC API → Collector → Normalizer → StateStore → RuleEngine → human-readable state → UI.
/// There is not one LLM call on that path.
@MainActor
@Observable
final class Store {
    private(set) var apps: [AppSnapshot] = []
    private(set) var certificates: [CertificateSnapshot] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    /// Notification permission. A denial means no state change can be announced, so the UI says so.
    private(set) var notificationPermission: Notifier.Permission = .unknown

    var config: BetaCueConfig {
        didSet { client = config.credentials.map { ASCClient(credentials: $0) } }
    }

    private var client: ASCClient?
    private let persistence: StateStore
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    var isConfigured: Bool { client != nil }

    /// Polling and notifications outlive any window, so this instance lives as long as the app.
    static let shared = Store()

    init(config: BetaCueConfig = .load(), persistence: StateStore = StateStore()) {
        self.config = config
        self.persistence = persistence
        self.client = config.credentials.map { ASCClient(credentials: $0) }
        // Show the last known state immediately instead of waiting on the network. (spec UC-01 ①)
        self.apps = Self.sorted(persistence.loadSnapshots())
        self.lastRefresh = apps.map(\.fetchedAt).max()
    }

    // MARK: - Polling (spec §22)

    /// One minute while a build processes, five when something needs attention, fifteen when quiet.
    private var pollInterval: TimeInterval {
        if apps.contains(where: { $0.status.state.id == .buildProcessing }) { return 60 }
        if apps.contains(where: { $0.status.state.severity == .warning }) { return 300 }
        return apps.isEmpty ? 300 : 900
    }

    /// Checks or requests notification permission and remembers the answer.
    func prepareNotifications() {
        Task { [weak self] in
            let current = await Notifier.currentPermission()
            self?.notificationPermission = current == .unknown
                ? await Notifier.requestAuthorization()
                : current
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Manual refresh. (spec §22, last line)
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refreshNow()
            self?.refreshTask = nil
        }
    }

    private func refreshNow() async {
        // Polling calls this directly while a manual refresh may be in flight. @MainActor is not
        // a mutex across suspension points, so guard explicitly.
        guard !isRefreshing else { return }
        guard let client else {
            errorMessage = ASCError.notConfigured.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let appList: [ASCResource<AppAttributes>] =
                try await client.getAllPages("/v1/apps?limit=200")

            // One app failing must not block the rest; the failed one keeps its last state.
            var collected: [AppSnapshot] = []
            var failedNames: [String] = []
            await withTaskGroup(of: Result<AppSnapshot, AppLoadFailure>.self) { group in
                for app in appList {
                    group.addTask {
                        do { return .success(try await Collector.loadApp(app, using: client)) }
                        catch {
                            return .failure(AppLoadFailure(id: app.id, name: app.attributes.name,
                                                           underlying: error))
                        }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let snapshot): collected.append(snapshot)
                    case .failure(let failure):
                        failedNames.append(failure.name)
                        // Match on ID: app names are not identifiers and can collide or change.
                        if let stale = apps.first(where: { $0.id == failure.id }) {
                            collected.append(stale)
                        }
                    }
                }
            }
            collected = Self.sorted(collected)

            detectAndNotify(collected)
            persistence.saveSnapshots(collected)
            apps = collected

            lastRefresh = Date()
            errorMessage = failedNames.isEmpty
                ? nil
                : String(localized: "Couldn't read \(failedNames.joined(separator: ", ")); showing the previous state.")

            // Certificates are secondary. Their failure must not make a successful app refresh
            // look like a failed one.
            do {
                certificates = try await Collector.loadCertificates(using: client)
                notifyExpiringCertificates()
            } catch {
                if errorMessage == nil {
                    errorMessage = String(localized: "Couldn't read certificates.")
                }
            }
        } catch {
            errorMessage = (error as? ASCError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Needs-attention first, then alphabetical. (spec §13)
    private static func sorted(_ list: [AppSnapshot]) -> [AppSnapshot] {
        list.sorted {
            let a = $0.status.state.severity, b = $1.status.state.severity
            return a == b
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : a < b
        }
    }

    // MARK: - Transition detection and notification (spec §12, §21)

    private func detectAndNotify(_ next: [AppSnapshot]) {
        for snapshot in next {
            // Incomplete data must not become a state transition. A transient API failure
            // reads as "unknown", and announcing that as a change would turn every blip into
            // a notification. Record only what was read completely.
            guard !snapshot.isPartial else { continue }
            let current = snapshot.status.state
            let previous = persistence.lastFingerprint(appID: snapshot.id)
            guard previous?.fingerprint != current.fingerprint else { continue }

            persistence.recordTransition(appID: snapshot.id, from: previous?.state,
                                         to: current.id, fingerprint: current.fingerprint)

            // Never notify on the first fetch, or every app announces itself at once.
            guard let previousState = previous?.state else { continue }
            guard let message = notificationText(app: snapshot, from: previousState, to: current)
            else { continue }
            Notifier.post(title: message.title, body: message.body)
        }
    }

    /// Not every change deserves a banner. Only these transitions do. (spec §12)
    private func notificationText(app: AppSnapshot, from: AppStateID, to: AppStateDefinition)
        -> (title: String, body: String)?
    {
        let version = app.latestBuild?.displayVersion ?? ""

        switch (from, to.id) {
        case (.buildProcessing, .internalTestingReady),
             (.buildProcessing, .externalTestingReady),
             (.buildProcessing, .externalReviewRequired):
            return (String(localized: "\(app.name) is ready to test"),
                    version.isEmpty ? String(localized: "You can install it from TestFlight on your iPhone.")
                                    : String(localized: "\(version) — install it from TestFlight on your iPhone."))

        case (.buildProcessing, .buildReadyNotDistributed):
            return (String(localized: "\(app.name) reaches nobody"), to.blocker ?? to.description)

        case (_, .buildInvalid) where app.status.testable != nil:
            let alive = app.status.testable?.displayVersion ?? ""
            return (String(localized: "\(app.name) new build rejected"), String(localized: "\(alive) is still testable."))

        case (.externalReviewPending, .externalTestingReady):
            return (String(localized: "\(app.name) approved for external testing"), String(localized: "You can now distribute to external testers."))

        case (_, .buildInvalid):
            return (String(localized: "\(app.name) build rejected"), to.description)

        case (_, .actionRequired), (_, .unknown):
            // Only when a blocker appears that was not there before.
            return (String(localized: "\(app.name) needs attention"), to.blocker ?? to.description)

        case (_, .buildReadyNotDistributed):
            return (String(localized: "\(app.name) reaches nobody"), to.blocker ?? to.description)

        default:
            return nil
        }
    }

    private func notifyExpiringCertificates() {
        for cert in certificates where cert.isExpiringSoon {
            guard let days = cert.daysLeft, days >= 0 else { continue }
            let previous = persistence.exchangeFeedbackCount(
                appID: "certificate:\(cert.id)", kind: "expiry-notified", newCount: 1)
            guard previous == nil else { continue }   // once per certificate
            Notifier.post(title: String(localized: "Certificate expiring soon"),
                          body: String(localized: "\(cert.name) expires in \(days) days."))
        }
    }

    // MARK: - Commands (spec §25)

    /// Command in flight, used to disable buttons and show progress.
    private(set) var runningCommand: String?

    /// Attach a build to groups — the only write in v0. (spec §26)
    func distribute(build: BuildSnapshot, of app: AppSnapshot, to groups: [GroupSnapshot]) {
        guard let client, runningCommand == nil else { return }
        runningCommand = app.id
        Task { [weak self] in
            defer { self?.runningCommand = nil }
            do {
                try await Commands.assign(build: build.id, toGroups: groups.map(\.id), using: client)
                await self?.refreshNow()
            } catch {
                self?.errorMessage = (error as? ASCError)?.localizedDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Groups this build could be attached to, excluding the ones it already belongs to.
    ///
    /// Returns nothing when the attachments could not be read — offering to distribute a build
    /// whose current attachments are unknown risks a duplicate or unwanted assignment.
    func distributionTargets(for build: BuildSnapshot, in app: AppSnapshot) -> [GroupSnapshot] {
        guard let assigned = build.assignedGroupIDs else { return [] }
        return app.groups.filter { !assigned.contains($0.id) }
    }

    // MARK: - Read helpers

    func transitions(for app: AppSnapshot) -> [StateStore.Transition] {
        persistence.transitions(appID: app.id)
    }
}

/// Knowing which app failed is what lets only that app fall back to its previous state.
struct AppLoadFailure: Error {
    var id: String
    var name: String
    var underlying: Error
}
