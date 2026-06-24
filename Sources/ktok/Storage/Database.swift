import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(code: Int32, message: String, path: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String, sql: String)
    case bindFailed(code: Int32, message: String, index: Int)
    case unsupportedBind(description: String)

    var description: String {
        switch self {
        case let .openFailed(code, msg, path):
            return "sqlite3_open_v2 failed (code=\(code)) at \(path): \(msg)"
        case let .prepareFailed(code, msg, sql):
            return "sqlite3_prepare_v2 failed (code=\(code)): \(msg) — SQL: \(sql)"
        case let .stepFailed(code, msg, sql):
            return "sqlite3_step failed (code=\(code)): \(msg) — SQL: \(sql)"
        case let .bindFailed(code, msg, index):
            return "sqlite3_bind failed (code=\(code)) at index \(index): \(msg)"
        case let .unsupportedBind(desc):
            return "unsupported bind value: \(desc)"
        }
    }
}

/// Swift wrapper around libsqlite3 C API. Zero external deps (uses macOS
/// system `/usr/lib/libsqlite3.dylib` via the `SQLite3` module).
final class Database {
    fileprivate var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var rawHandle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &rawHandle, flags, nil)
        if rc != SQLITE_OK {
            let message = rawHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(rawHandle)
            throw DatabaseError.openFailed(code: rc, message: message, path: path)
        }
        self.handle = rawHandle

        try execute("PRAGMA busy_timeout = 5000")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    @discardableResult
    func execute(_ sql: String, bind values: [Any?] = []) throws -> Int32 {
        let stmt = try prepare(sql)
        try stmt.bindAll(values)
        _ = try stmt.step()
        return Int32(sqlite3_changes(handle))
    }

    /// Run a SQL script containing multiple statements separated by `;`.
    /// Uses `sqlite3_exec` which handles statement splitting natively.
    /// Binding parameters are not supported in scripts.
    func executeScript(_ script: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, script, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            if let errorPointer { sqlite3_free(errorPointer) }
            throw DatabaseError.prepareFailed(code: rc, message: message, sql: script)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var rawStmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &rawStmt, nil)
        guard rc == SQLITE_OK, let rawStmt else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(rawStmt)
            throw DatabaseError.prepareFailed(code: rc, message: message, sql: sql)
        }
        return Statement(db: self, handle: rawStmt, sql: sql)
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    func lastInsertRowId() -> Int64 {
        Int64(sqlite3_last_insert_rowid(handle))
    }

    func changes() -> Int {
        Int(sqlite3_changes(handle))
    }

    /// Standard location: `~/.ktok/accounts/<alias>/history.sqlite`
    static func defaultPath() -> String {
        (try? KtokPaths.activeDatabasePath()) ?? KtokPaths.defaultDB(alias: "unknown")
    }
}

final class Statement {
    fileprivate var handle: OpaquePointer?
    private unowned let db: Database
    private let sql: String

    init(db: Database, handle: OpaquePointer, sql: String) {
        self.db = db
        self.handle = handle
        self.sql = sql
    }

    deinit {
        if let handle {
            sqlite3_finalize(handle)
        }
    }

    func reset() {
        if let handle {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }
    }

    @discardableResult
    func bindAll(_ values: [Any?]) throws -> Statement {
        for (offset, value) in values.enumerated() {
            try bind(value, at: offset + 1)
        }
        return self
    }

    func bind(_ value: Any?, at index: Int) throws {
        guard let handle else { return }
        let idx = Int32(index)
        let rc: Int32

        switch value {
        case nil, is NSNull:
            rc = sqlite3_bind_null(handle, idx)
        case let v as Int:
            rc = sqlite3_bind_int64(handle, idx, Int64(v))
        case let v as Int64:
            rc = sqlite3_bind_int64(handle, idx, v)
        case let v as Int32:
            rc = sqlite3_bind_int(handle, idx, v)
        case let v as Double:
            rc = sqlite3_bind_double(handle, idx, v)
        case let v as Bool:
            rc = sqlite3_bind_int(handle, idx, v ? 1 : 0)
        case let v as String:
            rc = sqlite3_bind_text(handle, idx, v, -1, SQLITE_TRANSIENT)
        case let v as Data:
            rc = v.withUnsafeBytes { buf in
                sqlite3_bind_blob(handle, idx, buf.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
            }
        default:
            throw DatabaseError.unsupportedBind(description: String(describing: value))
        }

        if rc != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db.handle))
            throw DatabaseError.bindFailed(code: rc, message: message, index: index)
        }
    }

    /// Step the statement. Returns true if a row is available, false on DONE.
    @discardableResult
    func step() throws -> Bool {
        guard let handle else { return false }
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            let message = String(cString: sqlite3_errmsg(db.handle))
            throw DatabaseError.stepFailed(code: rc, message: message, sql: sql)
        }
    }

    func columnText(at index: Int) -> String? {
        guard let handle else { return nil }
        guard sqlite3_column_type(handle, Int32(index)) != SQLITE_NULL,
              let cstr = sqlite3_column_text(handle, Int32(index))
        else {
            return nil
        }
        return String(cString: cstr)
    }

    func columnInt64(at index: Int) -> Int64 {
        guard let handle else { return 0 }
        return sqlite3_column_int64(handle, Int32(index))
    }

    func columnInt(at index: Int) -> Int {
        Int(columnInt64(at: index))
    }

    func columnIsNull(at index: Int) -> Bool {
        guard let handle else { return true }
        return sqlite3_column_type(handle, Int32(index)) == SQLITE_NULL
    }

    /// Execute a SELECT and materialize all rows via `map`. Pairs with
    /// `Database.prepare` + `bindAll` for parameterized queries.
    func allRows<T>(_ map: (Statement) -> T) throws -> [T] {
        var results: [T] = []
        while try step() {
            results.append(map(self))
        }
        return results
    }
}
