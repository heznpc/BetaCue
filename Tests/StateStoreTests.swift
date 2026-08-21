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

    // MARK: -

    private func runRawSQL(_ sql: String, at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "failed to create the legacy schema")
    }
}
