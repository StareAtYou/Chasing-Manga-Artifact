import Foundation

enum Schema {
    static func migrate(_ db: SQLiteConnection) throws {
        let version = try db.integer("PRAGMA user_version")
        guard version <= 1 else { throw MangaError.storage("数据库由更新版本创建，请更新应用") }
        if version == 0 {
            try db.transaction {
                _ = try db.rows("CREATE TABLE records(kind TEXT NOT NULL, id TEXT NOT NULL, parent TEXT, body BLOB NOT NULL, PRIMARY KEY(kind,id))")
                _ = try db.rows("CREATE INDEX records_parent ON records(kind,parent)")
                _ = try db.rows("CREATE TABLE associations(source_work TEXT PRIMARY KEY, work_id TEXT NOT NULL)")
                _ = try db.rows("CREATE INDEX associations_work ON associations(work_id)")
                _ = try db.rows("PRAGMA user_version=1")
            }
        }
    }
}
