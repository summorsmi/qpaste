import Foundation
import CSQLite

enum SQLValue {
    case text(String), number(Double), integer(Int), data(Data), null
    var string: String { if case .text(let value) = self { return value }; return "" }
    var double: Double {
        switch self { case .number(let n): return n; case .integer(let n): return Double(n); default: return 0 }
    }
    var bytes: Data { if case .data(let value) = self { return value }; return Data() }
}

struct SQLiteFailure: LocalizedError {
    let message: String
    var errorDescription: String? { "历史数据库：\(message)" }
}

/// Accessed only while HistoryRepository's lock is held.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(handle, 3000)
            try execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { if let handle { sqlite3_close(handle) } }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return Int(sqlite3_changes(handle))
    }

    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = [[SQLValue]]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return .integer(Int(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: return .number(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard let value = sqlite3_column_text(statement, index) else { return .text("") }
                    return .text(String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard let value = sqlite3_column_blob(statement, index) else { return .data(Data()) }
                    return .data(Data(bytes: value, count: count))
                default: return .null
                }
            })
        }
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try work(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let string): status = string.withCString { sqlite3_bind_text(statement, index, $0, Int32(string.utf8.count), transient) }
            case .number(let number): status = sqlite3_bind_double(statement, index, number)
            case .integer(let number): status = sqlite3_bind_int64(statement, index, Int64(number))
            case .data(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            if status != SQLITE_OK { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    private func failure() -> SQLiteFailure { SQLiteFailure(message: String(cString: sqlite3_errmsg(handle))) }
}
