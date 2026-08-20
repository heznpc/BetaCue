import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 로컬 상태 영속화. (명세 §20, §21)
///
/// 두 가지 일을 한다.
///   1. 마지막 스냅샷을 저장해 앱을 열자마자 보여준다 — 네트워크를 기다리지 않는다. (UC-01 ①)
///   2. 상태 전이를 기록해 알림 여부를 판정하고 나중에 "처리에 얼마나 걸렸나"를 답한다.
final class StateStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.betacue.statestore")

    static let defaultURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BetaCue/state.sqlite")

    init(url: URL = StateStore.defaultURL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        migrate()
    }

    deinit { if let db { sqlite3_close(db) } }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS snapshots (
            app_id     TEXT PRIMARY KEY,
            payload    BLOB NOT NULL,
            fetched_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS state_transitions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id     TEXT NOT NULL,
            from_state TEXT,
            to_state   TEXT NOT NULL,
            at         REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_transitions_app
            ON state_transitions(app_id, at DESC);
        CREATE TABLE IF NOT EXISTS seen_feedback (
            app_id TEXT NOT NULL,
            kind   TEXT NOT NULL,
            count  INTEGER NOT NULL,
            PRIMARY KEY (app_id, kind)
        );
        """)
    }

    private func exec(_ sql: String) {
        queue.sync { sqlite3_exec(db, sql, nil, nil, nil) }
    }

    // MARK: - 스냅샷

    func saveSnapshots(_ snapshots: [AppSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        queue.sync {
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
            for snapshot in snapshots {
                guard let payload = try? encoder.encode(snapshot) else { continue }
                var stmt: OpaquePointer?
                let sql = """
                INSERT INTO snapshots (app_id, payload, fetched_at) VALUES (?, ?, ?)
                ON CONFLICT(app_id) DO UPDATE SET payload = excluded.payload,
                                                  fetched_at = excluded.fetched_at
                """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_text(stmt, 1, snapshot.id, -1, SQLITE_TRANSIENT)
                _ = payload.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_double(stmt, 3, snapshot.fetchedAt.timeIntervalSince1970)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    func loadSnapshots() -> [AppSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM snapshots", -1, &stmt, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }

            var result: [AppSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
                let count = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: bytes, count: count)
                if let snapshot = try? decoder.decode(AppSnapshot.self, from: data) {
                    result.append(snapshot)
                }
            }
            return result
        }
    }

    // MARK: - 전이

    /// 직전 상태를 돌려준다. 처음 보는 앱이면 nil — 최초 조회에서 알림이 쏟아지지 않게 한다.
    func lastState(appID: String) -> AppStateID? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT to_state FROM state_transitions WHERE app_id = ? ORDER BY at DESC LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let raw = sqlite3_column_text(stmt, 0)
            else { return nil }
            return AppStateID(rawValue: String(cString: raw))
        }
    }

    func recordTransition(appID: String, from: AppStateID?, to: AppStateID, at: Date = Date()) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO state_transitions (app_id, from_state, to_state, at) VALUES (?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
            if let from {
                sqlite3_bind_text(stmt, 2, from.rawValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, to.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, at.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    struct Transition: Identifiable, Sendable {
        var id: Int
        var from: AppStateID?
        var to: AppStateID
        var at: Date
    }

    func transitions(appID: String, limit: Int = 30) -> [Transition] {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, from_state, to_state, at FROM state_transitions
            WHERE app_id = ? ORDER BY at DESC LIMIT ?
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var result: [Transition] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let from = sqlite3_column_text(stmt, 1).map { AppStateID(rawValue: String(cString: $0)) } ?? nil
                guard let toRaw = sqlite3_column_text(stmt, 2),
                      let to = AppStateID(rawValue: String(cString: toRaw)) else { continue }
                result.append(Transition(
                    id: Int(sqlite3_column_int(stmt, 0)), from: from, to: to,
                    at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
            }
            return result
        }
    }

    // MARK: - 피드백 카운트

    /// 이전에 본 개수를 돌려주고 새 값을 저장한다. 증가분만 알림 대상이다.
    func exchangeFeedbackCount(appID: String, kind: String, newCount: Int) -> Int? {
        queue.sync {
            var previous: Int?
            var stmt: OpaquePointer?
            let select = "SELECT count FROM seen_feedback WHERE app_id = ? AND kind = ?"
            if sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW { previous = Int(sqlite3_column_int(stmt, 0)) }
            }
            sqlite3_finalize(stmt)

            var upsert: OpaquePointer?
            let sql = """
            INSERT INTO seen_feedback (app_id, kind, count) VALUES (?, ?, ?)
            ON CONFLICT(app_id, kind) DO UPDATE SET count = excluded.count
            """
            if sqlite3_prepare_v2(db, sql, -1, &upsert, nil) == SQLITE_OK {
                sqlite3_bind_text(upsert, 1, appID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(upsert, 2, kind, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(upsert, 3, Int32(newCount))
                sqlite3_step(upsert)
            }
            sqlite3_finalize(upsert)
            return previous
        }
    }
}
