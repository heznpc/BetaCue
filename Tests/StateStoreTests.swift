import XCTest
@testable import BetaCue

/// 전이 기록은 알림의 유일한 근거다. 여기가 조용히 죽으면 앱이 아무것도 안 알린다.
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
                     "처음 보는 앱은 nil이어야 최초 조회에서 알림이 안 쏟아진다")
    }

    /// 실제로 겪은 사고. 컬럼을 추가한 뒤 기존 DB에서 INSERT가 prepare 단계에서 실패해
    /// 전이가 통째로 유실됐고, 아무 오류도 보이지 않았다.
    func testMigratesOlderSchemaMissingFingerprint() throws {
        // fingerprint 컬럼이 없던 시절의 스키마를 그대로 만든다.
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
                       "구 스키마 DB에서도 전이가 기록돼야 한다")
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
                     "처음 보는 값은 이전 개수가 없다")
        XCTAssertEqual(store.exchangeFeedbackCount(appID: "app-1", kind: "crash", newCount: 5), 3)
    }

    // MARK: -

    private func runRawSQL(_ sql: String, at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "구 스키마 생성 실패")
    }
}
