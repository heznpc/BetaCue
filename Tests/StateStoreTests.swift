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

    /// P1-4. The old migrator ran the schema change and recorded the version as two separate
    /// statements. A crash in between left the column applied with the version still at the
    /// previous value, and every later launch replayed the ALTER, hit "duplicate column", and
    /// degraded — permanently, since nothing ever moved the version forward.
    func testAdoptsAMigrationThatWasAppliedButNeverRecorded() throws {
        try runRawSQL("""
        CREATE TABLE snapshots (
            app_id TEXT PRIMARY KEY, payload BLOB NOT NULL, fetched_at REAL NOT NULL
        );
        CREATE TABLE state_transitions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id      TEXT NOT NULL,
            from_state  TEXT,
            to_state    TEXT NOT NULL,
            fingerprint TEXT NOT NULL DEFAULT '',
            at          REAL NOT NULL,
            reason      TEXT
        );
        CREATE TABLE seen_feedback (
            app_id TEXT NOT NULL, kind TEXT NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY (app_id, kind)
        );
        PRAGMA user_version = 1;
        """, at: dbURL)

        let store = StateStore(url: dbURL)
        XCTAssertEqual(store.health, .healthy,
                       "an applied step has to be adopted, not replayed: \(store.health)")
        XCTAssertTrue(store.recordTransition(appID: "a", from: nil, to: .noBuild,
                                             fingerprint: "NO_BUILD|-|-", reason: .expired))
        XCTAssertEqual(store.transitions(appID: "a").first?.reason, "EXPIRED")
    }

    /// And the adoption has to be recorded, or the next launch is back where it started.
    func testTheAdoptedVersionSticksAcrossReopening() throws {
        try runRawSQL("""
        CREATE TABLE snapshots (
            app_id TEXT PRIMARY KEY, payload BLOB NOT NULL, fetched_at REAL NOT NULL
        );
        CREATE TABLE state_transitions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, app_id TEXT NOT NULL, from_state TEXT,
            to_state TEXT NOT NULL, fingerprint TEXT NOT NULL DEFAULT '', at REAL NOT NULL,
            reason TEXT
        );
        CREATE TABLE seen_feedback (
            app_id TEXT NOT NULL, kind TEXT NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY (app_id, kind)
        );
        PRAGMA user_version = 1;
        """, at: dbURL)

        _ = StateStore(url: dbURL)
        XCTAssertEqual(StateStore(url: dbURL).health, .healthy)
        XCTAssertEqual(try userVersion(of: dbURL), 2)
    }

    /// A normal upgrade leaves the version and the schema agreeing with each other.
    func testAFreshDatabaseEndsAtTheCurrentSchemaVersion() throws {
        _ = StateStore(url: dbURL)
        XCTAssertEqual(try userVersion(of: dbURL), 2,
                       "the schema and the recorded version have to move together")
    }

    /// P1-3. A write that did not land has to say so; the caller's notification decision
    /// depends on knowing whether the record exists.
    func testARefusedWriteIsReportedRatherThanSwallowed() throws {
        let blocked = directory.appendingPathComponent("blocked-write", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let store = StateStore(url: blocked)

        XCTAssertFalse(store.recordTransition(appID: "a", from: nil, to: .noBuild,
                                              fingerprint: "NO_BUILD|-|-"))
        XCTAssertEqual(store.exchangeFeedbackCount(appID: "a", kind: "k", newCount: 1),
                       .unavailable,
                       "'couldn't read' is not the same answer as 'nothing stored yet'")
    }

    /// A healthy store distinguishes the first exchange from later ones.
    func testFeedbackExchangeSeparatesFirstSightingFromRepeat() {
        let store = StateStore(url: dbURL)
        XCTAssertEqual(store.exchangeFeedbackCount(appID: "a", kind: "k", newCount: 1),
                       .exchanged(previous: nil))
        XCTAssertEqual(store.exchangeFeedbackCount(appID: "a", kind: "k", newCount: 2),
                       .exchanged(previous: 1))
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

    private func userVersion(of url: URL) throws -> Int {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "PRAGMA user_version;"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(text) ?? -1
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
