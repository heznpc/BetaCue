import XCTest
@testable import BetaCue

/// Orchestration: what Store does with what the collector returns.
///
/// Most of the defects the review found lived here rather than in the rule engine — refresh
/// racing itself, a fallback keyed on a name, a partial read becoming a notification.
@MainActor
final class StoreTests: XCTestCase {
    private var directory: URL!
    private var config: BetaCueConfig!
    private var notifier: FakeNotifier!

    // The throwing overrides are nonisolated, so a @MainActor class cannot touch its own
    // properties from them. The async variants inherit the class's isolation.
    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("betacue-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (credentials, _) = try Fixture.credentials(in: directory)
        config = BetaCueConfig(keyID: credentials.keyID, issuerID: credentials.issuerID,
                               keyDirectory: credentials.keyDirectory)
        notifier = FakeNotifier()
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(dbName: String = "state.sqlite") -> Store {
        makeStore(persistence: StateStore(url: directory.appendingPathComponent(dbName)))
    }

    private func makeStore(persistence: StateStore) -> Store {
        Store(config: config,
              persistence: persistence,
              session: MockURLProtocol.makeSession(),
              notifier: notifier,
              retryDelayScale: 0)
    }

    /// A store whose database cannot be opened at all — nothing reads back, nothing writes.
    private func unopenablePersistence() throws -> StateStore {
        let blocked = directory.appendingPathComponent("blocked-db", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let persistence = StateStore(url: blocked)   // a directory is not a database file
        XCTAssertTrue(persistence.health.isDegraded, "the fixture has to actually be broken")
        return persistence
    }

    private func table(apps: [String] = ["a1"],
                       internalState: String = "IN_BETA_TESTING",
                       testers: [String] = ["t1"]) -> [String: MockURLProtocol.Response] {
        [
            "/v1/apps": .json(Fixture.apps(apps)),
            "/v1/certificates": .json(#"{"data":[]}"#),
            "/betaGroups": .json(Fixture.groups(["g1"])),
            "/v1/builds?": .json(Fixture.builds(["1"])),
            "/buildBetaDetail": .json(Fixture.betaDetail(internalState: internalState)),
            "/preReleaseVersion": .json(Fixture.nullSingle),
            "relationships/individualTesters": .json(Fixture.emptyRelationship),
            "relationships/betaTesters": .json(Fixture.relationship(testers)),
            "relationships/builds": .json(Fixture.relationship(["1"])),
        ]
    }

    private func appListCallCount() -> Int {
        MockURLProtocol.requests.filter { $0.url?.path.hasSuffix("/v1/apps") ?? false }.count
    }

    /// Waits until nothing is in flight any more, follow-ups included.
    private func settle(_ store: Store) async {
        var quiet = 0
        for _ in 0..<400 {
            try? await Task.sleep(for: .milliseconds(20))
            quiet = store.isRefreshing || store.runningCommand != nil ? 0 : quiet + 1
            if quiet >= 3 { return }
        }
        XCTFail("the store never settled")
    }

    /// Waits for a *new* refresh to land, not merely for one to have happened before.
    private func refreshAndWait(_ store: Store) async {
        let before = store.lastRefresh
        store.refresh()
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(20))
            if !store.isRefreshing && store.lastRefresh != before { return }
        }
        XCTFail("refresh did not complete")
    }

    // MARK: - Refresh

    func testRefreshPopulatesApps() async {
        MockURLProtocol.respond(table())
        let store = makeStore()
        await refreshAndWait(store)

        XCTAssertEqual(store.apps.count, 1)
        XCTAssertEqual(store.apps.first?.status.state.id, .internalTestingReady)
        XCTAssertNil(store.errorMessage)
    }

    /// P1-5. Requests arriving during a refresh used to be dropped, which is how a refresh
    /// asked for right after distributing a build could vanish and leave the old attachment
    /// on screen. They are queued instead — and collapsed, so a burst is one follow-up and
    /// not a treadmill.
    func testConcurrentRequestsCollapseIntoOneFollowUp() async {
        MockURLProtocol.respond(table())
        let store = makeStore()

        store.refresh()
        store.refresh()
        store.refresh()
        await settle(store)

        XCTAssertEqual(appListCallCount(), 2,
                       "the running pass, plus exactly one pass for everything asked after it")
    }

    /// A single request while nothing is running is still a single pass.
    func testOneRequestIsOnePass() async {
        MockURLProtocol.respond(table())
        let store = makeStore()
        await refreshAndWait(store)
        XCTAssertEqual(appListCallCount(), 1)
    }

    /// P1-5. Distributing has to be followed by a read that started *after* the write, or the
    /// screen keeps showing the attachment the build had before the button was pressed.
    func testDistributingIsFollowedByAFreshRead() async {
        MockURLProtocol.respond(table())
        let store = makeStore(dbName: "distribute.sqlite")
        await refreshAndWait(store)

        let app = store.apps.first!
        store.distribute(build: app.builds.first!, of: app, to: app.groups)
        await settle(store)

        let paths = MockURLProtocol.requests.map {
            ($0.httpMethod ?? "GET") + " " + ($0.url?.path ?? "")
        }
        let write = paths.lastIndex { $0.hasPrefix("POST") }
        let read = paths.lastIndex { $0 == "GET /v1/apps" }
        XCTAssertNotNil(write, "the write itself has to happen: \(paths)")
        XCTAssertNotNil(read)
        XCTAssertGreaterThan(read ?? -1, write ?? .max,
                             "the refresh has to start after the write, not race it")
    }

    /// P1-5. A key swapped mid-flight leaves an answer in the air that describes the previous
    /// account. Landing it would show one account's apps under another's credentials.
    func testResultsReadWithAReplacedKeyNeverLand() async {
        let gate = RequestGate()
        let responses = table(apps: ["belongs-to-the-old-key"])
        MockURLProtocol.handler = { request in
            let path = request.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? ""
            if path.hasPrefix("/v1/apps") { gate.waitUntilOpen() }
            for (key, response) in responses.sorted(by: { $0.key.count > $1.key.count })
            where path.contains(key) { return response }
            return .init(status: 404)
        }

        let store = makeStore(dbName: "generation.sqlite")
        store.refresh()
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(10))
            if store.isRefreshing { break }
        }
        XCTAssertTrue(store.isRefreshing, "the fetch has to be genuinely in flight")

        var replacement = config!
        replacement.keyID = "OTHERKEY456"
        store.config = replacement
        gate.open()
        await settle(store)

        XCTAssertTrue(store.apps.isEmpty,
                      "got: \(store.apps.map(\.id)) — read with a key that is no longer set")
        XCTAssertNil(store.lastRefresh, "and it did not count as a successful check either")
    }

    /// Certificates are secondary; their failure must not mark a good app refresh as failed.
    func testCertificateFailureDoesNotSpoilTheRefresh() async {
        var t = table()
        t["/v1/certificates"] = .init(status: 500)
        MockURLProtocol.respond(t)

        let store = makeStore()
        await refreshAndWait(store)

        XCTAssertEqual(store.apps.count, 1, "the apps still loaded")
        XCTAssertNotNil(store.lastRefresh, "the refresh did happen")
    }

    // MARK: - Notifications

    func testFirstFetchNeverNotifies() async {
        MockURLProtocol.respond(table())
        let store = makeStore()
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 0, "opening the app must not announce every app at once")
    }

    func testNotifiesWhenProcessingBecomesReady() async {
        MockURLProtocol.respond(table(internalState: "PROCESSING"))
        let store = makeStore(dbName: "shared.sqlite")
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 0)

        MockURLProtocol.respond(table(internalState: "IN_BETA_TESTING"))
        await refreshAndWait(store)

        XCTAssertEqual(notifier.count, 1)
        XCTAssertTrue(notifier.messages.first?.title.contains("ready to test") == true
                      || notifier.messages.first?.title.contains("테스트") == true,
                      "got: \(notifier.messages)")
    }

    func testUnchangedStateDoesNotNotifyAgain() async {
        MockURLProtocol.respond(table())
        let store = makeStore(dbName: "same.sqlite")
        await refreshAndWait(store)
        await refreshAndWait(store)
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 0)
    }

    /// A transient failure reads as unknown; announcing that would make every blip a banner.
    func testPartialDataNeverNotifies() async {
        MockURLProtocol.respond(table())
        let store = makeStore(dbName: "partial.sqlite")
        await refreshAndWait(store)

        var broken = table()
        broken["/buildBetaDetail"] = .init(status: 500)
        MockURLProtocol.respond(broken)
        await refreshAndWait(store)

        XCTAssertEqual(notifier.count, 0, "a failed fetch is not a state change")
    }

    /// P0-2. The individual-tester fetch failing used to leave no trace on the snapshot, so
    /// the refresh looked complete, the audience resolved to UNKNOWN, and a transient blip
    /// was recorded as a transition and announced as "needs attention".
    func testAFailedIndividualTesterFetchNeitherNotifiesNorRecords() async {
        MockURLProtocol.respond(table())
        let store = makeStore(dbName: "individuals.sqlite")
        await refreshAndWait(store)
        let recorded = store.apps.first.map { store.transitions(for: $0).count } ?? 0

        var broken = table()
        broken["relationships/individualTesters"] = .init(status: 500)
        MockURLProtocol.respond(broken)
        await refreshAndWait(store)

        let app = try? XCTUnwrap(store.apps.first)
        XCTAssertEqual(app?.isPartial, true, "the failed channel has to be on the snapshot")
        XCTAssertEqual(notifier.count, 0, "an unread channel is not a state change")
        XCTAssertEqual(app.map { store.transitions(for: $0).count }, recorded,
                       "a partial read must not enter the timeline either")
    }

    /// P1-1. The other half of the split: a value Apple has never sent before is news, and
    /// silencing UNKNOWN wholesale would have swallowed it along with the blips.
    func testAnUnrecognizedAppleValueStillNotifies() async {
        MockURLProtocol.respond(table())
        let store = makeStore(dbName: "unrecognized.sqlite")
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 0)

        var strange = table()
        strange["/v1/builds?"] = .json(Fixture.builds(["1"], state: "QUANTUM_PROCESSING"))
        MockURLProtocol.respond(strange)
        await refreshAndWait(store)

        XCTAssertEqual(store.apps.first?.status.state.id, .unknown)
        XCTAssertEqual(store.apps.first?.status.state.reason, .unrecognizedProcessingState)
        XCTAssertEqual(notifier.count, 1, "a value nobody has seen before is worth a banner")
    }

    /// P1-2. `AWAITING_RELEASE` declares notifyWhenLeaving; the wording table has to agree,
    /// or the policy is a declaration nothing acts on.
    func testBecomingReadyAfterWaitingOnAppleNotifies() async {
        MockURLProtocol.respond(table(internalState: "READY_FOR_BETA_TESTING"))
        let store = makeStore(dbName: "awaiting.sqlite")
        await refreshAndWait(store)
        XCTAssertEqual(store.apps.first?.status.state.id, .awaitingRelease)
        XCTAssertEqual(notifier.count, 0)

        MockURLProtocol.respond(table(internalState: "IN_BETA_TESTING"))
        await refreshAndWait(store)

        XCTAssertEqual(store.apps.first?.status.state.id, .internalTestingReady)
        XCTAssertEqual(notifier.count, 1, "the build becoming installable is the whole point")
    }

    // MARK: - Persistence failure and notification consistency

    /// P1-3. The transition log is the only thing that makes a banner a one-time event. With
    /// nothing written down, the previous state stayed unknown and every refresh looked like
    /// the first one — so the app either announced the same change forever or, taking the
    /// other branch, never announced anything at all.
    func testABrokenDatabaseStillNotifiesExactlyOnce() async throws {
        let store = makeStore(persistence: try unopenablePersistence())

        MockURLProtocol.respond(table(internalState: "PROCESSING"))
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 0, "the first sighting is never an announcement")

        MockURLProtocol.respond(table(internalState: "IN_BETA_TESTING"))
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 1)

        // The change has not moved. Nothing new to say, however broken the disk is.
        await refreshAndWait(store)
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 1, "an unwritten transition must not repeat every poll")
    }

    /// The failure is not silent: it is on `persistenceHealth`, which the UI reads.
    func testABrokenDatabaseIsReportedWhileStillNotifying() async throws {
        let store = makeStore(persistence: try unopenablePersistence())
        MockURLProtocol.respond(table())
        await refreshAndWait(store)
        XCTAssertTrue(store.persistenceHealth.isDegraded)
        XCTAssertNotNil(store.persistenceHealth.message)
    }

    /// P1-3. A certificate banner is meant to fire once, and the stored count is the only
    /// record of whether it already did. Unreadable is not the same as "never announced".
    func testCertificateNoticeIsHeldBackWhenNothingCanBeRecorded() async throws {
        let store = makeStore(persistence: try unopenablePersistence())
        var t = table()
        t["/v1/certificates"] = .json(Fixture.expiringCertificate(daysFromNow: 10))
        MockURLProtocol.respond(t)

        await refreshAndWait(store)
        await refreshAndWait(store)
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 0,
                       "without a record of what was announced, repeating it every poll is worse")
    }

    /// With a working database it still fires, and still only once.
    func testCertificateNoticeFiresOncePerCertificate() async {
        var t = table()
        t["/v1/certificates"] = .json(Fixture.expiringCertificate(daysFromNow: 10))
        MockURLProtocol.respond(t)
        let store = makeStore(dbName: "certs.sqlite")

        await refreshAndWait(store)
        await refreshAndWait(store)
        XCTAssertEqual(notifier.count, 1, "got: \(notifier.messages)")
    }

    // MARK: - Failure isolation

    /// Apps are matched by ID, not by name: names collide and change.
    func testFailedAppKeepsItsPreviousSnapshot() async {
        MockURLProtocol.respond(table(apps: ["a1"]))
        let store = makeStore(dbName: "fallback.sqlite")
        await refreshAndWait(store)
        XCTAssertEqual(store.apps.first?.status.state.id, .internalTestingReady)

        // The app list still answers, but everything under it fails.
        MockURLProtocol.respond([
            "/v1/apps": .json(Fixture.apps(["a1"])),
            "/v1/certificates": .json(#"{"data":[]}"#),
        ], fallback: .init(status: 500))
        await refreshAndWait(store)

        XCTAssertEqual(store.apps.count, 1, "the app must not vanish from the list")
        XCTAssertNotNil(store.errorMessage, "and the failure has to be visible")
    }

    // MARK: - Configuration

    func testChangingConfigurationSwapsTheClient() async {
        var blank = BetaCueConfig()
        blank.keyDirectory = config.keyDirectory
        let store = Store(config: blank,
                          persistence: StateStore(url: directory.appendingPathComponent("cfg.sqlite")),
                          session: MockURLProtocol.makeSession(),
                          notifier: notifier,
                          retryDelayScale: 0)
        XCTAssertFalse(store.isConfigured)

        MockURLProtocol.respond(table())
        store.config = config
        XCTAssertTrue(store.isConfigured)

        await refreshAndWait(store)
        XCTAssertEqual(store.apps.count, 1)
    }

    // MARK: - Persistence

    func testLoadsTheLastSnapshotBeforeAnyNetworkCall() async {
        MockURLProtocol.respond(table())
        let store = makeStore(dbName: "reopen.sqlite")
        await refreshAndWait(store)

        // A fresh Store over the same database shows the previous state immediately.
        MockURLProtocol.reset()
        let reopened = makeStore(dbName: "reopen.sqlite")
        XCTAssertEqual(reopened.apps.count, 1)
        XCTAssertNotNil(reopened.lastRefresh)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "no network was needed to show it")
    }

    func testDegradedDatabaseIsVisible() {
        let blocked = directory.appendingPathComponent("blocked", isDirectory: true)
        try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let store = Store(config: config,
                          persistence: StateStore(url: blocked),
                          session: MockURLProtocol.makeSession(),
                          notifier: notifier,
                          retryDelayScale: 0)
        XCTAssertTrue(store.persistenceHealth.isDegraded)
    }

    // MARK: - Distribution targets

    func testDistributionTargetsExcludeAlreadyAttachedGroups() async {
        MockURLProtocol.respond(table())
        let store = makeStore(dbName: "targets.sqlite")
        await refreshAndWait(store)

        guard let app = store.apps.first, let build = app.latestBuild else {
            return XCTFail("expected a build")
        }
        XCTAssertTrue(store.distributionTargets(for: build, in: app).isEmpty,
                      "the build is already attached to the only group")
    }

    /// Offering to distribute a build whose attachments are unknown risks a duplicate write.
    func testNoDistributionTargetsWhenAttachmentsAreUnknown() async {
        var t = table()
        t["relationships/builds"] = .init(status: 500)
        MockURLProtocol.respond(t)
        let store = makeStore(dbName: "unknown-targets.sqlite")
        await refreshAndWait(store)

        guard let app = store.apps.first, let build = app.latestBuild else {
            return XCTFail("expected a build")
        }
        XCTAssertTrue(store.distributionTargets(for: build, in: app).isEmpty)
    }
}
