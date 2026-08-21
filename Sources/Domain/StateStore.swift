import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local state persistence. (spec §20, §21)
///
/// Two jobs:
///   1. Keep the last snapshot so opening the app shows something before the network answers. (UC-01 ①)
///   2. Record transitions to decide notifications and to answer "how long did processing take?".
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
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id      TEXT NOT NULL,
            from_state  TEXT,
            to_state    TEXT NOT NULL,
            fingerprint TEXT NOT NULL DEFAULT '',
            at          REAL NOT NULL
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

        // CREATE TABLE IF NOT EXISTS does not add columns to a table that already exists.
        // Skip this and, after a schema change, INSERT fails silently at prepare time,
        // no transition is recorded, and notifications stop entirely. That happened once.
        addColumnIfMissing(table: "state_transitions",
                           column: "fingerprint",
                           definition: "TEXT NOT NULL DEFAULT ''")
    }

    /// No-op when the column exists; otherwise adds it with ALTER TABLE.
    private func addColumnIfMissing(table: String, column: String, definition: String) {
        guard !columnExists(table: table, column: column) else { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func columnExists(table: String, column: String) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column {
                    return true
                }
            }
            return false
        }
    }

    private func exec(_ sql: String) {
        queue.sync { sqlite3_exec(db, sql, nil, nil, nil) }
    }

    // MARK: - Snapshots

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

    // MARK: - Transitions

    struct LastState: Sendable {
        var state: AppStateID
        var fingerprint: String
    }

    /// Previous state and fingerprint. nil for an app never seen, so the first fetch stays quiet.
    ///
    /// Comparing fingerprints is what catches a cause change inside `ACTION_REQUIRED`.
    func lastFingerprint(appID: String) -> LastState? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            SELECT to_state, fingerprint FROM state_transitions
            WHERE app_id = ? ORDER BY at DESC LIMIT 1
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let raw = sqlite3_column_text(stmt, 0),
                  let state = AppStateID(rawValue: String(cString: raw))
            else { return nil }
            let fingerprint = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            return LastState(state: state, fingerprint: fingerprint)
        }
    }

    func recordTransition(appID: String, from: AppStateID?, to: AppStateID,
                          fingerprint: String, at: Date = Date())
    {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO state_transitions (app_id, from_state, to_state, fingerprint, at)
            VALUES (?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
            if let from {
                sqlite3_bind_text(stmt, 2, from.rawValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, to.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, fingerprint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, at.timeIntervalSince1970)
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

    // MARK: - Feedback counts

    /// Returns the previously seen count and stores the new one. Only the increase notifies.
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
