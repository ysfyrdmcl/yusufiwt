import Foundation
import SQLite3

enum SQLiteValue: Sendable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

enum SQLiteConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case open(code: Int32, message: String)
    case execute(code: Int32, message: String, sql: String)
    case bind(code: Int32, message: String)
    case invalidColumn(Int32)
    case closed

    var description: String {
        switch self {
        case let .open(code, message): "SQLite open failed (\(code)): \(message)"
        case let .execute(code, message, sql): "SQLite statement failed (\(code)): \(message); SQL: \(sql)"
        case let .bind(code, message): "SQLite bind failed (\(code)): \(message)"
        case let .invalidColumn(index): "SQLite column \(index) has an unsupported type"
        case .closed: "SQLite connection is closed"
        }
    }
}

final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    let url: URL?

    init(url: URL?, readOnly: Bool = false) throws {
        self.url = url
        let filePath = url?.path(percentEncoded: false) ?? ":memory:"
        let path = readOnly && url != nil ? "file:\(filePath)?immutable=1" : filePath
        let flags: Int32 = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database {
                sqlite3_close_v2(database)
            }
            throw SQLiteConnectionError.open(code: result, message: message)
        }
        handle = database
        sqlite3_extended_result_codes(database, 1)
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return
                }
                guard result == SQLITE_ROW else { throw statementError(result, sql: sql) }
            }
        }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try withStatement(sql, bindings: bindings) { statement in
            var rows: [[SQLiteValue]] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return rows
                }
                guard result == SQLITE_ROW else { throw statementError(result, sql: sql) }
                try rows.append((0 ..< sqlite3_column_count(statement)).map { try column(statement, index: $0) })
            }
        }
    }

    func scalarInt(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int64? {
        guard let value = try query(sql, bindings: bindings).first?.first else { return nil }
        if case let .integer(integer) = value {
            return integer
        }
        return nil
    }

    var changes: Int32 {
        handle.map(sqlite3_changes) ?? 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func backup(to destinationURL: URL) throws {
        let destination = try SQLiteConnection(url: destinationURL)
        guard let sourceHandle = handle, let destinationHandle = destination.handle else {
            throw SQLiteConnectionError.closed
        }
        guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
            throw SQLiteConnectionError.execute(
                code: sqlite3_errcode(destinationHandle),
                message: String(cString: sqlite3_errmsg(destinationHandle)),
                sql: "sqlite3_backup_init"
            )
        }
        defer { sqlite3_backup_finish(backup) }
        let result = sqlite3_backup_step(backup, -1)
        guard result == SQLITE_DONE else {
            throw SQLiteConnectionError.execute(
                code: result,
                message: String(cString: sqlite3_errmsg(destinationHandle)),
                sql: "sqlite3_backup_step"
            )
        }
    }

    private func withStatement<T>(
        _ sql: String,
        bindings: [SQLiteValue],
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let handle else { throw SQLiteConnectionError.closed }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else { throw statementError(prepareResult, sql: sql) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, to: statement, index: Int32(offset + 1))
        }
        return try body(statement)
    }

    private func bind(_ value: SQLiteValue, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result: Int32 = switch value {
        case let .integer(integer): sqlite3_bind_int64(statement, index, integer)
        case let .real(real): sqlite3_bind_double(statement, index, real)
        case let .text(text): sqlite3_bind_text(statement, index, text, -1, transient)
        case let .blob(data):
            data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
            }
        case .null: sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteConnectionError.bind(code: result, message: errorMessage)
        }
    }

    private func column(_ statement: OpaquePointer, index: Int32) throws -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, index) {
                .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
            } else {
                .blob(Data())
            }
        case SQLITE_NULL: .null
        default: throw SQLiteConnectionError.invalidColumn(index)
        }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "connection closed"
    }

    private func statementError(_ code: Int32, sql: String) -> SQLiteConnectionError {
        .execute(code: code, message: errorMessage, sql: sql)
    }
}
