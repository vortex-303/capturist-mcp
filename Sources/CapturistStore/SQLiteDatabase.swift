import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String

    public var description: String {
        "SQLite error \(code): \(message)"
    }
}

public struct DatabaseRow: Sendable {
    public let values: [String: SQLValue]

    public subscript(key: String) -> SQLValue? {
        values[key]
    }

    public func string(_ key: String) -> String? {
        guard case .text(let value) = values[key] else { return nil }
        return value
    }

    public func int64(_ key: String) -> Int64? {
        switch values[key] {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }

    public func int(_ key: String) -> Int? {
        int64(key).map(Int.init)
    }

    public func double(_ key: String) -> Double? {
        switch values[key] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public func data(_ key: String) -> Data? {
        guard case .blob(let value) = values[key] else { return nil }
        return value
    }
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    /// `readOnly` opens an existing database without creating or changing it (used by the CLI).
    public init(path: String, readOnly: Bool = false) throws {
        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(database)
            throw SQLiteError(code: result, message: message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    public var userVersion: Int {
        get throws {
            try query("PRAGMA user_version").first?.int("user_version") ?? 0
        }
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    public func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, parameters)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw currentError()
        }
    }

    public func executeScript(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: result, message: message)
        }
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [DatabaseRow] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, parameters)
        var rows: [DatabaseRow] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                rows.append(readRow(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw currentError()
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed")
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw currentError()
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ parameters: [SQLValue]) throws {
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else {
                throw currentError()
            }
        }
    }

    private func readRow(_ statement: OpaquePointer) -> DatabaseRow {
        var values: [String: SQLValue] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                values[name] = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, index) {
                    values[name] = .text(String(cString: text))
                } else {
                    values[name] = .null
                }
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                if let bytes = sqlite3_column_blob(statement, index), count > 0 {
                    values[name] = .blob(Data(bytes: bytes, count: count))
                } else {
                    values[name] = .blob(Data())
                }
            default:
                values[name] = .null
            }
        }
        return DatabaseRow(values: values)
    }

    private func currentError() -> SQLiteError {
        guard let handle else {
            return SQLiteError(code: SQLITE_MISUSE, message: "database is closed")
        }
        return SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}
