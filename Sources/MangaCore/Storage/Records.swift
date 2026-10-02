import Foundation
import SQLite3

enum SQLValue { case text(String), blob(Data), integer(Int), null }
// This connection is used synchronously only by its owning LibraryStore actor.
final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }; throw MangaError.storage("无法打开数据库")
        }
        handle = connection
        sqlite3_busy_timeout(handle, 5000)
        _ = try rows("PRAGMA journal_mode=WAL")
        _ = try rows("PRAGMA foreign_keys=ON")
    }
    deinit { sqlite3_close(handle) }
    private var failure: MangaError { .storage(String(cString: sqlite3_errmsg(handle))) }
    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text): status = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .integer(let n): status = sqlite3_bind_int64(statement, index, Int64(n))
            case .null: status = sqlite3_bind_null(statement, index)
            }
            if status != SQLITE_OK { sqlite3_finalize(statement); throw failure }
        }
        return statement
    }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [Data] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure }
            if let bytes = sqlite3_column_blob(statement, 0) { result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) }
        }
    }
    func integer(_ sql: String) throws -> Int {
        let statement = try prepare(sql, []); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        _ = try rows("BEGIN IMMEDIATE")
        do { let value = try operation(); _ = try rows("COMMIT"); return value }
        catch { _ = try? rows("ROLLBACK"); throw error }
    }
}
