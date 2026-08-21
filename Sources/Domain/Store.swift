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

    /// Which app the window is showing. Owned here so the menu bar can steer it.
    var selectedAppID: String?

    /// Whether the local database is working. Its failure silences notifications.
    ///
    /// Stored rather than computed. These were computed properties reading a separate object
    /// and a static, and `@Observable` tracks stored properties — it cannot see a change it
    /// was never told about, so the window would have gone on showing the old answer even
    /// once something was wired to read it.
    private(set) var persistenceHealth: StateStore.Health = .healthy

    /// The last banner macOS refused to show, if any. A dropped notification is never
    /// retried — the transition is already recorded — so it has to be visible somewhere.
    private(set) var lastNotificationFailure: String?

    var config: BetaCueConfig {
        didSet {
            configGeneration &+= 1
            client = makeClient()
            // Whatever is already in flight was read with the previous key. Its results
            // describe a different account, and landing them would show one account's apps
            // under another's credentials.
            refreshTask?.cancel()
            followUpRequested = false
        }
    }

    private var client: ASCClient?
    private let persistence: StateStore
    private let session: URLSession
    private let notifier: NotificationSending
    private let retryDelayScale: Double
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// A request that arrived while a refresh was already running.
    private var followUpRequested = false
    /// Bumped whenever the credentials change, so results can be matched to the key that
    /// asked for them.
    private var configGeneration = 0

    /// States whose transition the database refused to take.
    ///
    /// The transition log is the only thing that makes a notification a one-time event. When
    /// a write fails, the durable log still holds the *previous* state, so the next poll would
    /// see the same change again and announce it again, once per poll, for as long as the disk
    /// stayed broken. When the database never opened at all it holds nothing, so every refresh
    /// looks like the first one and the app goes permanently silent instead.
    ///
    /// This holds only what the database would not take, and an entry is dropped the moment a
    /// write for that app succeeds. In the healthy case it stays empty and SQLite remains the
    /// single source of truth.
    private var unrecordedStates: [String: StateStore.LastState] = [:]

    var isConfigured: Bool { client != nil }

    /// Polling and notifications outlive any window, so this instance lives as long as the app.
    static let shared = Store()

    init(config: BetaCueConfig = .load(),
         persistence: StateStore = StateStore(),
         session: URLSession = .shared,
         notifier: NotificationSending = SystemNotifier(),
         retryDelayScale: Double = 1.0)
    {
        self.config = config
        self.persistence = persistence
        self.session = session
        self.notifier = notifier
        self.retryDelayScale = retryDelayScale
        self.client = config.credentials.map {
            ASCClient(credentials: $0, session: session, retryDelayScale: retryDelayScale)
        }
        // Show the last known state immediately instead of waiting on the network. (spec UC-01 ①)
        self.apps = Self.sorted(persistence.loadSnapshots())
        self.lastRefresh = apps.map(\.fetchedAt).max()
        // A database that failed to open has already happened by now, migration included.
        self.persistenceHealth = persistence.health
        notifier.observeFailures { [weak self] message in
            self?.lastNotificationFailure = message
        }
    }

    private func makeClient() -> ASCClient? {
        config.credentials.map {
            ASCClient(credentials: $0, session: session, retryDelayScale: retryDelayScale)
        }
    }

    // MARK: - Polling (spec §22)

    /// One minute while a build processes, five when something needs attention, fifteen when quiet.
    private var pollInterval: TimeInterval {
        if apps.contains(where: { $0.status.state.id == .buildProcessing }) { return 60 }
        if apps.contains(where: { $0.status.state.severity == .warning }) { return 300 }
        return apps.isEmpty ? 300 : 900
    }

    /// Re-reads the permission. The user can flip it in System Settings while the app runs.
    func refreshNotificationPermission() {
        Task { [weak self] in
            self?.notificationPermission = await Notifier.currentPermission()
        }
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
                if let task = self?.requestRefresh() { await task.value }
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Manual refresh. (spec §22, last line)
    func refresh() { requestRefresh() }

    /// Starts a refresh, or queues one behind the pass already running.
    ///
    /// Dropping the request was wrong in a way that showed: a refresh asked for right after a
    /// build was distributed would be discarded if polling happened to be mid-flight, leaving
    /// the old attachment on screen with nothing to indicate it was stale. A pass that is
    /// already reading App Store Connect cannot be assumed to have seen a change made after it
    /// started, so the answer is one more pass rather than joining that one. Repeated requests
    /// collapse into a single follow-up, so this cannot become a treadmill.
    @discardableResult
    private func requestRefresh() -> Task<Void, Never> {
        if let running = refreshTask {
            followUpRequested = true
            return running
        }
        let task = Task { [weak self] in
            repeat {
                await self?.performRefresh()
            } while !Task.isCancelled && self?.consumeFollowUp() == true
            self?.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func consumeFollowUp() -> Bool {
        defer { followUpRequested = false }
        return followUpRequested
    }

    private func performRefresh() async {
        // The credentials can be swapped while this runs. Everything below describes the key
        // held at this moment, and nothing may be committed under a different one.
        let generation = configGeneration
        guard let client else {
            errorMessage = ASCError.notConfigured.localizedDescription
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            // Every path below can degrade the database — a snapshot that would not save, a
            // transition that would not record. Mirror the verdict out on the way past.
            persistenceHealth = persistence.health
        }

        do {
            let appPage: PagedResult<ASCResource<AppAttributes>> =
                try await client.getAllPagesResult("/v1/apps?limit=200")
            let appList = appPage.values

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

            guard generation == configGeneration else { return }
            detectAndNotify(collected)
            persistence.saveSnapshots(collected,
                                      appListWasComplete: failedNames.isEmpty && appPage.isComplete)
            apps = collected

            lastRefresh = Date()
            errorMessage = failedNames.isEmpty
                ? nil
                : String(localized: "Couldn't read \(failedNames.joined(separator: ", ")); showing the previous state.")

            // Certificates are secondary. Their failure must not make a successful app refresh
            // look like a failed one.
            do {
                let loaded = try await Collector.loadCertificates(using: client)
                guard generation == configGeneration else { return }
                certificates = loaded
                notifyExpiringCertificates()
            } catch {
                if errorMessage == nil, generation == configGeneration {
                    errorMessage = String(localized: "Couldn't read certificates.")
                }
            }
        } catch {
            guard generation == configGeneration else { return }
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
            // Two different events wear the UNKNOWN badge. "Apple sent a value this version
            // has never seen" is news. "A fetch came back empty" is our own blind spot, and
            // writing it down produces READY → UNKNOWN → READY round trips in the timeline
            // that describe the network rather than the app. Silence is not enough on its
            // own: the entry would still be there to read, and the next real change would
            // be measured against it.
            guard current.reason?.isObservationFailure != true else { continue }
            // A state the database refused to take wins over what the database still says,
            // which is by definition out of date.
            let previous = unrecordedStates[snapshot.id]
                ?? persistence.lastFingerprint(appID: snapshot.id)
            guard previous?.fingerprint != current.fingerprint else { continue }

            // Recording and notifying are one unit. Announcing a change that was not written
            // down anywhere means announcing it again on the next poll.
            if persistence.recordTransition(appID: snapshot.id, from: previous?.state,
                                            to: current.id, fingerprint: current.fingerprint,
                                            reason: current.reason) {
                unrecordedStates[snapshot.id] = nil
            } else {
                unrecordedStates[snapshot.id] = StateStore.LastState(
                    state: current.id, fingerprint: current.fingerprint)
            }

            // Never notify on the first fetch, or every app announces itself at once.
            guard let previousState = previous?.state else { continue }
            guard shouldNotify(leaving: previousState, entering: current) else { continue }
            guard let message = notificationText(app: snapshot, from: previousState, to: current)
            else { continue }
            notifier.post(title: message.title, body: message.body)
        }
    }

    /// The state definitions own the notification policy. (spec §16)
    ///
    /// Keeping a second policy in the transition table below meant a state could declare
    /// `notifyWhenLeaving` while nothing ever fired, and the test asserting the declaration
    /// would still pass. The declaration decides; the table only supplies wording.
    private func shouldNotify(leaving previous: AppStateID, entering current: AppStateDefinition)
        -> Bool
    {
        if current.notificationPolicy == .notifyWhenEntering { return true }
        return AppStateDefinition.make(previous).notificationPolicy == .notifyWhenLeaving
    }

    /// Wording for a transition worth announcing. Returning nil means there is nothing useful
    /// to say, even though the policy allows a notification.
    private func notificationText(app: AppSnapshot, from: AppStateID, to: AppStateDefinition)
        -> (title: String, body: String)?
    {
        let version = app.latestBuild?.displayVersion ?? ""

        switch to.id {
        case .internalTestingReady, .externalTestingReady, .externalReviewRequired:
            guard from == .buildProcessing || from == .externalReviewPending
                    || from == .awaitingRelease else { return nil }
            if from == .externalReviewPending && to.id == .externalTestingReady {
                return (String(localized: "\(app.name) approved for external testing"),
                        String(localized: "You can now distribute to external testers."))
            }
            return (String(localized: "\(app.name) is ready to test"),
                    version.isEmpty
                        ? String(localized: "You can install it from TestFlight on your iPhone.")
                        : String(localized: "\(version) — install it from TestFlight on your iPhone."))

        case .buildReadyNotDistributed:
            return (String(localized: "\(app.name) reaches nobody"), to.blocker ?? to.description)

        case .buildInvalid:
            guard app.status.testable == nil else {
                let alive = app.status.testable?.displayVersion ?? ""
                return (String(localized: "\(app.name) new build rejected"),
                        String(localized: "\(alive) is still testable."))
            }
            return (String(localized: "\(app.name) build rejected"), to.description)

        case .actionRequired, .unknown:
            return (String(localized: "\(app.name) needs attention"), to.blocker ?? to.description)

        default:
            return nil
        }
    }

    private func notifyExpiringCertificates() {
        for cert in certificates where cert.isExpiringSoon {
            guard let days = cert.daysLeft, days >= 0 else { continue }
            // This banner is meant to appear once per certificate, and the stored count is
            // the only record of whether it already has. If that record is unreadable, a
            // "first sighting" would be claimed again on every poll — a banner every five
            // minutes about a certificate expiring in two months. Staying quiet is the
            // recoverable mistake; the degraded database is reported separately.
            guard case .exchanged(let previous) = persistence.exchangeFeedbackCount(
                appID: "certificate:\(cert.id)", kind: "expiry-notified", newCount: 1),
                  previous == nil
            else { continue }
            notifier.post(title: String(localized: "Certificate expiring soon"),
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
                // Not a plain refresh: this has to be a pass that started after the write.
                if let task = self?.requestRefresh() { await task.value }
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
