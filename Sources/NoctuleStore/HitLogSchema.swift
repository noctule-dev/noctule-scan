// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import SQLite3

/// An error from the hit log's SQLite database.
public enum HitLogError: Error, Equatable, CustomStringConvertible {
    /// SQLite returned `code`; `message` is `sqlite3_errmsg` at that point.
    case sqlite(code: Int32, message: String)
    /// The file holds a schema newer than this build understands.
    case unsupportedSchemaVersion(Int32)
    /// The log was used after `close()`.
    case closed

    public var description: String {
        switch self {
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .unsupportedSchemaVersion(let v): "hit log schema version \(v) is newer than this app supports"
        case .closed: "the hit log is closed"
        }
    }
}

// MARK: - Schema

enum HitLogSchema {
    static let version: Int32 = 2

    /// Version 1. Dates are REAL Unix seconds, `unit_ids` is a JSON array of strings, booleans
    /// are INTEGER 0/1.
    static let v1 = """
        CREATE TABLE hits (
            id TEXT PRIMARY KEY,
            system TEXT, department TEXT, channel TEXT, site TEXT, talkgroup_id TEXT,
            frequency_mhz REAL,
            unit_ids TEXT,
            modulation TEXT, tone_or_code TEXT,
            rssi_max INTEGER, programmed INTEGER, continued INTEGER,
            started_at REAL, ended_at REAL, end_reason TEXT,
            audio_path TEXT, audio_error TEXT
        );
        CREATE TABLE first_seen (key TEXT PRIMARY KEY, first_seen_at REAL);
        CREATE INDEX hits_started_at ON hits(started_at);
        CREATE INDEX hits_talkgroup_id ON hits(talkgroup_id);
        CREATE INDEX hits_frequency_mhz ON hits(frequency_mhz);
        PRAGMA user_version = 1;
        """

    /// Version 2 adds `audio_clipped`: 1 when the recording's line-in audio clipped, 0 when it
    /// didn't, NULL when unknown (a hit logged before version 2, a hit with no line-in audio).
    static let v1ToV2 = """
        ALTER TABLE hits ADD COLUMN audio_clipped INTEGER;
        PRAGMA user_version = 2;
        """

    /// Opens (creating if needed) the database at `path`, sets the connection pragmas and brings
    /// the schema to the current version.
    static func open(path: String) throws -> SQLiteDB {
        let db = try SQLiteDB(path: path)
        try enableWAL(db)
        try db.exec("PRAGMA foreign_keys=ON")
        let current = try db.scalarInt("PRAGMA user_version")
        if current > Int64(version) {
            throw HitLogError.unsupportedSchemaVersion(Int32(current))
        }
        // A new database is created at version 1 and migrated, so both paths run the same code.
        if current < Int64(version) {
            try migrate(db, from: 0, sql: v1)
            try migrate(db, from: 1, sql: v1ToV2)
        }
        return db
    }

    /// Switching a file that isn't WAL yet (a new one) takes an exclusive lock, and when another
    /// connection is making the same switch SQLite answers `SQLITE_BUSY` at once, without waiting
    /// out the busy timeout, since waiting could deadlock. So that statement is tried again for up
    /// to 5 s, as long as the busy timeout. A file already in WAL mode needs no lock for it.
    private static func enableWAL(_ db: SQLiteDB) throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            do {
                return try db.exec("PRAGMA journal_mode=WAL")
            } catch HitLogError.sqlite(let code, _) where code == SQLITE_BUSY && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    /// Runs `sql`, which ends by writing the next version, if the file is still at version `from`.
    /// Another connection may open the same file at the same moment (the session and the hit-log
    /// window, or `noctule hits` and the app), so the version is read again inside the write
    /// transaction, and a step another connection has already made is skipped. The schema change
    /// and the version write share that transaction, so another connection sees both or neither.
    private static func migrate(_ db: SQLiteDB, from: Int64, sql: String) throws {
        try db.transaction {
            let current = try db.scalarInt("PRAGMA user_version")
            if current > Int64(version) {
                throw HitLogError.unsupportedSchemaVersion(Int32(current))
            }
            if current == from { try db.exec(sql) }
        }
    }
}

// MARK: - A minimal SQLite wrapper

enum SQLValue {
    case null, int(Int64), double(Double), text(String)

    static func optText(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }
    static func optDouble(_ d: Double?) -> SQLValue { d.map(SQLValue.double) ?? .null }
    static func optInt(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
    static func bool(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
    static func optBool(_ b: Bool?) -> SQLValue { b.map(SQLValue.bool) ?? .null }
}

/// One connection. Not thread-safe by itself: `HitLog` owns it and only touches it on the actor.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(h)
            throw HitLogError.sqlite(code: rc, message: message)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
    }

    deinit { close() }

    /// Closes the connection. `sqlite3_close_v2` defers the real close until any statements still
    /// alive are finalized, so this is safe to call at any time. Idempotent.
    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func live() throws -> OpaquePointer {
        guard let handle else { throw HitLogError.closed }
        return handle
    }

    func error(_ rc: Int32) -> HitLogError {
        .sqlite(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    /// Runs one or more statements that take no parameters (rows, if any, are discarded).
    func exec(_ sql: String) throws {
        let rc = sqlite3_exec(try live(), sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    func prepare(_ sql: String, _ args: [SQLValue] = []) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(try live(), sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        let s = SQLiteStatement(stmt, db: self)
        try s.bind(args)
        return s
    }

    /// Runs one statement to completion and returns `sqlite3_changes`.
    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let s = try prepare(sql, args)
        while try s.step() {}
        return Int(sqlite3_changes(try live()))
    }

    func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int64 {
        let s = try prepare(sql, args)
        return try s.step() ? s.int(0) ?? 0 : 0
    }

    /// Runs `body` in a transaction: commit on success, roll back on throw.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let db: SQLiteDB

    /// `SQLITE_TRANSIENT`: SQLite copies bound text before the call returns.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    }

    init(_ stmt: OpaquePointer, db: SQLiteDB) { self.stmt = stmt; self.db = db }
    deinit { sqlite3_finalize(stmt) }

    func bind(_ args: [SQLValue]) throws {
        for (i, value) in args.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32 = switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .int(let v): sqlite3_bind_int64(stmt, index, v)
            case .double(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            }
            guard rc == SQLITE_OK else { throw db.error(rc) }
        }
    }

    /// True when a row is ready, false when the statement is done.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw db.error(rc)
        }
    }

    func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }
    func text(_ col: Int32) -> String? {
        guard !isNull(col), let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
    func double(_ col: Int32) -> Double? { isNull(col) ? nil : sqlite3_column_double(stmt, col) }
    func int(_ col: Int32) -> Int64? { isNull(col) ? nil : sqlite3_column_int64(stmt, col) }
}
