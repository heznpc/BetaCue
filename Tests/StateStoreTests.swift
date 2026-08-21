import XCTest
@testable import BetaCue

/// Transition records are the only basis for notifications. If this dies quietly, nothing notifies.
final class StateStoreTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("betacue-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("state.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordsAndReadsBackTransition() {
        let store = StateStore(url: dbURL)
        store.recordTransition(appID: "app-1", from: nil, to: .buildProcessing,
                               fingerprint: "BUILD_PROCESSING|-|b1")
        let last = store.lastFingerprint(appID: "app-1")
        XCTAssertEqual(last?.state, .buildProcessing)
        XCTAssertEqual(last?.fingerprint, "BUILD_PROCESSING|-|b1")
    }

    func testUnknownAppHasNoPreviousState() {
        let store = StateStore(url: dbURL)
        XCTAssertNil(store.lastFingerprint(appID: "never-seen"),
                     "an unseen app must be nil so the first fetch stays quiet")
    }

    /// This actually happened: after adding a column, INSERT failed at prepare time on an
    /// existing database, every transition was lost, and no error surfaced anywhere.
    func testMigratesOlderSchemaMissingFingerprint() throws {
        // Recreate the schema exactly as it was before the fingerprint column existed.
        let legacy = """
        CREATE TABLE state_transitions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id     TEXT NOT NULL,
            from_state TEXT,
            to_state   TEXT NOT NULL,
            at         REAL NOT NULL
        );
        """
        try runRawSQL(legacy, at: dbURL)

        let store = StateStore(url: dbURL)
        store.recordTransition(appID: "app-1", from: .buildProcessing,
                               to: .internalTestingReady,
                               fingerprint: "INTERNAL_TESTING_READY|-|b2")

        let last = store.lastFingerprint(appID: "app-1")
        XCTAssertEqual(last?.state, .internalTestingReady,
                       "transitions must record even on an old-schema database")
        XCTAssertEqual(last?.fingerprint, "INTERNAL_TESTING_READY|-|b2")
    }

    func testSnapshotRoundTrip() {
        let store = StateStore(url: dbURL)
        let snapshot = AppSnapshot(
            id: "app-1", name: "Sample", bundleID: "app.sample",
            groups: [GroupSnapshot(id: "g", name: "QA", isInternal: true, testerCount: 2,
                                   autoDistributes: true, publicLinkEnabled: false,
                                   publicLink: nil)],
            builds: [], fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.saveSnapshots([snapshot])

        let loaded = StateStore(url: dbURL).loadSnapshots()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Sample")
        XCTAssertEqual(loaded.first?.groups.first?.testerCount, 2)
    }

    func testFeedbackCountExchangeReportsPreviousValue() {
        let store = StateStore(url: dbURL)
        XCTAssertNil(store.exchangeFeedbackCount(appID: "app-1", kind: "crash", newCount: 3),
                     "a first-seen key has no previous count")
        XCTAssertEqual(store.exchangeFeedbackCount(appID: "app-1", kind: "crash", newCount: 5), 3)
    }

    /// Versioned migrations must adopt a pre-versioning database instead of replaying step 0
    /// or refusing to run.
    func testAdoptsPreVersioningDatabase() throws {
        try runRawSQL("""
        CREATE TABLE state_transitions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id      TEXT NOT NULL,
            from_state  TEXT,
            to_state    TEXT NOT NULL,
            fingerprint TEXT NOT NULL DEFAULT '',
            at          REAL NOT NULL
        );
        """, at: dbURL)

        let store = StateStore(url: dbURL)
        XCTAssertEqual(store.health, .healthy)
        store.recordTransition(appID: "app-1", from: nil, to: .noBuild,
                               fingerprint: "NO_BUILD|-|-", reason: .expired)
        XCTAssertEqual(store.transitions(appID: "app-1").first?.reason, "EXPIRED",
                       "the reason column has to exist after adoption")
    }

    /// The reason behind a transition has to survive the round trip, or history collapses
    /// every same-state change into "details changed".
    func testTransitionKeepsItsReason() {
        let store = StateStore(url: dbURL)
        store.recordTransition(appID: "a", from: .internalTestingReady, to: .actionRequired,
                               fingerprint: "ACTION_REQUIRED|EXPIRED|b1", reason: .expired)
        XCTAssertEqual(store.transitions(appID: "a").first?.reason, "EXPIRED")
    }

    /// Apps removed from App Store Connect should not linger, but only a complete app list
    /// is safe to prune against.
    func testPrunesOnlyOnACompleteAppList() {
        let store = StateStore(url: dbURL)
        store.saveSnapshots([snapshot(id: "keep"), snapshot(id: "gone")],
                            appListWasComplete: true)
        XCTAssertEqual(store.loadSnapshots().count, 2)

        // Partial list: the missing app may just have failed to load, so keep it.
        store.saveSnapshots([snapshot(id: "keep")], appListWasComplete: false)
        XCTAssertEqual(Set(store.loadSnapshots().map(\.id)), ["keep", "gone"])

        // Complete list: it is really gone.
        store.saveSnapshots([snapshot(id: "keep")], appListWasComplete: true)
        XCTAssertEqual(store.loadSnapshots().map(\.id), ["keep"])
    }

    /// A database that cannot be opened has to say so rather than pretending to work.
    func testUnopenableDatabaseReportsDegraded() throws {
        let blocked = directory.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let store = StateStore(url: blocked)   // a directory is not a database file
        XCTAssertTrue(store.health.isDegraded)
        XCTAssertNotNil(store.health.message)
    }

    // MARK: -

    private func snapshot(id: String) -> AppSnapshot {
        AppSnapshot(id: id, name: id, bundleID: "app.\(id)", groups: [], builds: [],
                    fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func runRawSQL(_ sql: String, at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "failed to create the legacy schema")
    }
}
