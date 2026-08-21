import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local state persistence. (spec §20, §21)
///
/// Two jobs:
///   1. Keep the last snapshot so opening the app shows something before the network answers. (UC-01 ①)
///   2. Record transitions to decide notifications and to answer "how long did processing take?".
final class StateStore: @unchecked Sendable {
    /// Whether persistence is actually working.
    ///
    /// SQLite is not a cache here — the transition log is the sole basis for deciding whether
    /// to notify. A schema failure once stopped every notification with nothing on screen to
    /// show for it, so failures are reported rather than swallowed.
    enum Health: Equatable, Sendable {
        case healthy
        case degraded(String)

        var isDegraded: Bool { self != .healthy }
        var message: String? {
            if case .degraded(let m) = self { return m }
            return nil
        }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.betacue.statestore")
    private var _health: Health = .healthy

    var health: Health { queue.sync { _health } }

    /// Bump this when the schema changes and add a matching step in `migrations`.
    private static let schemaVersion: Int32 = 2

    static let defaultURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BetaCue/state.sqlite")

    init(url: URL = StateStore.defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            _health = .degraded(String(localized: "Couldn't create the data folder: \(error.localizedDescription)"))
        }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            _health = .degraded(String(localized: "Couldn't open the local database: \(message)"))
            if db != nil { sqlite3_close(db) }
            db = nil
            return
        }
        migrate()
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Schema

    /// Versioned migrations keyed on `PRAGMA user_version`.
    ///
    /// Index i upgrades the database from version i to i+1. Adding a column ad hoc worked for
    /// one change; anything past that needs an ordered, recorded sequence.
    private static let migrations: [String] = [
        // 0 → 1: initial tables
        """
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
        """,
        // 1 → 2: keep the reason behind a transition, so history can say why rather than
        // collapsing every same-state change into "details changed".
        """
        ALTER TABLE state_transitions ADD COLUMN reason TEXT;
        """,
    ]

    private func migrate() {
        // Databases created before versioning exist and already carry the v1 tables plus the
        // fingerprint column, so adopt them at the right version instead of replaying step 0.
        var version = currentUserVersion()
        if version == 0 && tableExists("state_transitions") {
            version = columnExists(table: "state_transitions", column: "fingerprint") ? 1 : 0
            if version == 0 {
                // v0 table without fingerprint: bring it forward before entering the sequence.
                run("ALTER TABLE state_transitions ADD COLUMN fingerprint TEXT NOT NULL DEFAULT '';")
                version = 1
            }
            setUserVersion(version)
        }

        while version < Self.schemaVersion {
            let step = Self.migrations[Int(version)]
            guard run(step) else {
                _health = .degraded(String(localized: "The local database could not be upgraded, so state changes are not being recorded."))
                return
            }
            version += 1
            setUserVersion(version)
        }
    }

    private func currentUserVersion() -> Int32 {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
        }
    }

    private func setUserVersion(_ v: Int32) {
        _ = run("PRAGMA user_version = \(v);")
    }

    private func tableExists(_ name: String) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
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

    /// Runs SQL and reports whether it worked, instead of discarding the result.
    @discardableResult
    private func run(_ sql: String) -> Bool {
        queue.sync {
            guard db != nil else { return false }
            var error: UnsafeMutablePointer<CChar>?
            let ok = sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK
            if let error { sqlite3_free(error) }
            return ok
        }
    }

    /// Records a failure that the user should know about.
    private func degrade(_ message: String) {
        queue.sync { if _health == .healthy { _health = .degraded(message) } }
    }

    // MARK: - Snapshots

    /// Upserts the given snapshots and removes rows for apps that no longer exist.
    ///
    /// `appListWasComplete` guards the prune: deleting on a partial list would drop apps that
    /// simply failed to load this time.
    func saveSnapshots(_ snapshots: [AppSnapshot], appListWasComplete: Bool = false) {
        upsert(snapshots)
        guard appListWasComplete else { return }
        prune(keeping: Set(snapshots.map(\.id)))
    }

    private func prune(keeping ids: Set<String>) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT app_id FROM snapshots", -1, &stmt, nil) == SQLITE_OK
            else { return }
            var stale: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let raw = sqlite3_column_text(stmt, 0) {
                    let id = String(cString: raw)
                    if !ids.contains(id) { stale.append(id) }
                }
            }
            sqlite3_finalize(stmt)

            for id in stale {
                var del: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM snapshots WHERE app_id = ?", -1, &del, nil)
                        == SQLITE_OK else { continue }
                sqlite3_bind_text(del, 1, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(del)
                sqlite3_finalize(del)
            }
        }
    }

    private func upsert(_ snapshots: [AppSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var failed = false
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
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    failed = true
                    continue
                }
                sqlite3_bind_text(stmt, 1, snapshot.id, -1, SQLITE_TRANSIENT)
                _ = payload.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_double(stmt, 3, snapshot.fetchedAt.timeIntervalSince1970)
                if sqlite3_step(stmt) != SQLITE_DONE { failed = true }
                sqlite3_finalize(stmt)
            }
        }
        if failed { degrade(String(localized: "Couldn't save the latest state locally.")) }
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

    /// Writes a transition and says whether the write landed.
    ///
    /// The caller needs the answer. This log is what makes a notification a one-time event,
    /// so a banner sent for a transition that was never written would be re-announced on
    /// every poll for as long as the disk stayed broken.
    @discardableResult
    func recordTransition(appID: String, from: AppStateID?, to: AppStateID,
                          fingerprint: String, reason: StateReason? = nil,
                          at: Date = Date()) -> Bool
    {
        let ok: Bool = queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO state_transitions (app_id, from_state, to_state, fingerprint, reason, at)
            VALUES (?, ?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
            if let from {
                sqlite3_bind_text(stmt, 2, from.rawValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, to.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, fingerprint, -1, SQLITE_TRANSIENT)
            if let reason {
                sqlite3_bind_text(stmt, 5, reason.rawValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_double(stmt, 6, at.timeIntervalSince1970)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
        // The transition log is what decides notifications. Losing a write silently is how
        // notifications stopped once already.
        if !ok { degrade(String(localized: "Couldn't record a state change, so notifications may be missed.")) }
        return ok
    }

    struct Transition: Identifiable, Sendable {
        var id: Int
        var from: AppStateID?
        var to: AppStateID
        /// Why the state changed, when the state ID alone doesn't say.
        ///
        /// Kept as text on the way out: rows written by older versions carry reason codes
        /// this build no longer defines, and dropping them would blank a history entry
        /// rather than show it.
        var reason: String?
        var at: Date
    }

    func transitions(appID: String, limit: Int = 30) -> [Transition] {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, from_state, to_state, at, reason FROM state_transitions
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
                let reason = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                result.append(Transition(
                    id: Int(sqlite3_column_int(stmt, 0)), from: from, to: to, reason: reason,
                    at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
            }
            return result
        }
    }

    // MARK: - Feedback counts

    /// What an exchange could establish.
    ///
    /// "No row yet" and "couldn't read the table" are different answers, and collapsing them
    /// into `nil` meant a broken database looked like a first sighting on every single poll —
    /// which for a once-per-certificate notification is a banner every five minutes.
    enum Exchange: Equatable, Sendable {
        /// The value stored before this call. `nil` means there was none.
        case exchanged(previous: Int?)
        /// The store could not answer, or could not save the new value.
        case unavailable
    }

    /// Returns the previously seen count and stores the new one. Only the increase notifies.
    func exchangeFeedbackCount(appID: String, kind: String, newCount: Int) -> Exchange {
        let outcome: Exchange = queue.sync {
            guard db != nil else { return .unavailable }
            var previous: Int?
            var stmt: OpaquePointer?
            let select = "SELECT count FROM seen_feedback WHERE app_id = ? AND kind = ?"
            guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else {
                return .unavailable
            }
            sqlite3_bind_text(stmt, 1, appID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_TRANSIENT)
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { previous = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { return .unavailable }

            var upsert: OpaquePointer?
            let sql = """
            INSERT INTO seen_feedback (app_id, kind, count) VALUES (?, ?, ?)
            ON CONFLICT(app_id, kind) DO UPDATE SET count = excluded.count
            """
            guard sqlite3_prepare_v2(db, sql, -1, &upsert, nil) == SQLITE_OK else {
                return .unavailable
            }
            sqlite3_bind_text(upsert, 1, appID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(upsert, 2, kind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(upsert, 3, Int32(newCount))
            let saved = sqlite3_step(upsert) == SQLITE_DONE
            sqlite3_finalize(upsert)
            return saved ? .exchanged(previous: previous) : .unavailable
        }
        if outcome == .unavailable {
            degrade(String(localized: "Couldn't record what has already been announced, so some notifications are being held back."))
        }
        return outcome
    }
}
