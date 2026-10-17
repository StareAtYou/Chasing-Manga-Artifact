import Foundation

public actor LibraryStore {
    private let db: SQLiteConnection
    public init(databaseURL: URL) throws { db = try SQLiteConnection(url: databaseURL); try Schema.migrate(db) }

    public func saveRecord<T: Encodable>(kind: String, key: String, parent: String? = nil, value: T) throws {
        let data = try JSONEncoder().encode(value)
        _ = try db.rows("INSERT INTO records(kind,id,parent,body) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET parent=excluded.parent,body=excluded.body", [.text(kind), .text(key), parent.map(SQLValue.text) ?? .null, .blob(data)])
    }
    public func record<T: Decodable>(kind: String, key: String, as: T.Type) throws -> T? {
        try db.rows("SELECT body FROM records WHERE kind=? AND id=?", [.text(kind), .text(key)]).first.map { try JSONDecoder().decode(T.self, from: $0) }
    }
    public func records<T: Decodable>(kind: String, parent: String? = nil, as: T.Type) throws -> [T] {
        let values: [SQLValue] = parent.map { [.text(kind), .text($0)] } ?? [.text(kind)]
        let sql = parent == nil ? "SELECT body FROM records WHERE kind=? ORDER BY id" : "SELECT body FROM records WHERE kind=? AND parent=? ORDER BY id"
        return try db.rows(sql, values).map { try JSONDecoder().decode(T.self, from: $0) }
    }
    public func deleteRecord(kind: String, key: String) throws {
        _ = try db.rows("DELETE FROM records WHERE kind=? AND id=?", [.text(kind), .text(key)])
    }
    public func save(source: Source) throws {
        var source = source
        source.baseURL = try canonicalSourceURL(source.baseURL)
        if try sources().contains(where: { $0.id != source.id && $0.baseURL == source.baseURL }) { throw MangaError.storage("该来源已经添加") }
        if let old = try self.source(id: source.id) {
            guard old.revision == source.revision, !old.removed else { throw MangaError.storage("来源已经修改，请重新打开编辑页") }
            if old.baseURL != source.baseURL { source.revision = old.revision + 1; source.binding = nil; source.capabilities = [] }
        }
        try saveRecord(kind: "source", key: source.id.key, value: source)
    }
    public func editSource(id: SourceID, name: String, baseURL: URL, expectedRevision: Int) throws -> Source {
        guard var current = try source(id: id), current.revision == expectedRevision, !current.removed else { throw MangaError.storage("来源已经修改，请重新打开编辑页") }
        current.name = name; current.baseURL = baseURL
        try save(source: current)
        return try source(id: id)!
    }
    public func setSourceEnabled(_ enabled: Bool, id: SourceID) throws {
        guard var current = try source(id: id), !current.removed else { throw MangaError.unsupported("来源不存在") }
        if current.enabled != enabled { current.enabled = enabled; current.revision += 1; try saveRecord(kind: "source", key: id.key, value: current) }
    }
    public func source(id: SourceID) throws -> Source? { try record(kind: "source", key: id.key, as: Source.self) }
    public func sources() throws -> [Source] { try records(kind: "source", as: Source.self).filter { !$0.removed } }
    public func save(binding: ParserBinding, sourceID: SourceID, expectedRevision: Int) throws -> Bool {
        try db.transaction {
            guard var source = try self.source(id: sourceID), source.revision == expectedRevision, !source.removed else { return false }
            source.binding = binding; source.capabilities.formUnion(.readable)
            try saveRecord(kind: "source", key: source.id.key, value: source); return true
        }
    }
    public func beginDetection(sourceID: SourceID) throws -> UUID {
        let id = UUID(); try saveRecord(kind: "detection-generation", key: sourceID.key, value: id); return id
    }
    public func commitDetection(binding: ParserBinding, sourceID: SourceID, expectedRevision: Int, works: [DetectedWork], generation: UUID) throws -> Bool {
        try Task.checkCancellation()
        guard works.allSatisfy({ item in item.work.id.sourceID == sourceID && item.chapters.allSatisfy { $0.id.sourceWorkID == item.work.id } }) else { throw MangaError.storage("检测结果来源不一致") }
        return try db.transaction {
            guard var source = try self.source(id: sourceID), source.enabled, !source.removed, source.revision == expectedRevision else { return false }
            guard try record(kind: "detection-generation", key: sourceID.key, as: UUID.self) == generation else { return false }
            source.binding = binding; source.capabilities.formUnion(.readable)
            try saveRecord(kind: "source", key: sourceID.key, value: source)
            for item in works {
                try saveRecord(kind: "sourceWork", key: item.work.id.key, parent: sourceID.key, value: item.work)
                for chapter in item.chapters { try saveRecord(kind: "chapter", key: chapter.id.key, parent: item.work.id.key, value: chapter) }
                if !item.chapters.isEmpty { try saveRecord(kind: "directory", key: item.work.id.key, value: item.chapters.sorted { $0.ordinal < $1.ordinal }) }
            }
            return true
        }
    }
    public func remove(sourceID: SourceID) throws {
        guard var source = try source(id: sourceID) else { return }
        source.removed = true; source.enabled = false; source.revision += 1; source.binding = nil
        try saveRecord(kind: "source", key: source.id.key, value: source)
    }
    public func save(sourceWork: SourceWork, chapters: [Chapter]) throws {
        guard chapters.allSatisfy({ $0.id.sourceWorkID == sourceWork.id }) else { throw MangaError.storage("章节来源与作品不一致") }
        try db.transaction {
            try saveRecord(kind: "sourceWork", key: sourceWork.id.key, parent: sourceWork.id.sourceID.key, value: sourceWork)
            for chapter in chapters { try saveRecord(kind: "chapter", key: chapter.id.key, parent: sourceWork.id.key, value: chapter) }
            if !chapters.isEmpty { try saveRecord(kind: "directory", key: sourceWork.id.key, value: chapters.sorted { $0.ordinal < $1.ordinal }) }
        }
    }
    public func sourceWork(id: SourceWorkID) throws -> SourceWork? { try record(kind: "sourceWork", key: id.key, as: SourceWork.self) }
    public func allSourceWorks() throws -> [SourceWork] { try records(kind: "sourceWork", as: SourceWork.self) }
    public func chapter(id: ChapterID) throws -> Chapter? { try record(kind: "chapter", key: id.key, as: Chapter.self) }
    public func chapters(for id: SourceWorkID) throws -> [Chapter] { try record(kind: "directory", key: id.key, as: [Chapter].self) ?? [] }
    public func work(id: WorkID) throws -> Work? { try record(kind: "work", key: id.key, as: Work.self) }
    public func library() throws -> [Work] {
        try db.rows("SELECT body FROM records WHERE kind='work' AND EXISTS(SELECT 1 FROM associations WHERE work_id=records.id)").map { try JSONDecoder().decode(Work.self, from: $0) }.filter { $0.isOnShelf != false }.sorted { $0.addedAt > $1.addedAt }
    }
    public func sourceWorks(for id: WorkID) throws -> [SourceWork] {
        try db.rows("SELECT body FROM records WHERE kind='sourceWork' AND EXISTS(SELECT 1 FROM associations WHERE source_work=records.id AND work_id=?)", [.text(id.key)]).map { try JSONDecoder().decode(SourceWork.self, from: $0) }
    }
    public func workID(for sourceWorkID: SourceWorkID) throws -> WorkID? {
        guard let data = try db.rows("SELECT work_id FROM associations WHERE source_work=?", [.text(sourceWorkID.key)]).first, let text = String(data: data, encoding: .utf8), let uuid = UUID(uuidString: text) else { return nil }
        return WorkID(rawValue: uuid)
    }
    public func createWork(from id: SourceWorkID, onShelf: Bool = true) throws -> Work {
        try db.transaction { try createWorkRecord(from: id, onShelf: onShelf) }
    }
    private func createWorkRecord(from id: SourceWorkID, onShelf: Bool) throws -> Work {
        if let workID = try workID(for: id), var work = try work(id: workID) {
            if onShelf && work.isOnShelf == false { work.isOnShelf = true; try saveRecord(kind: "work", key: workID.key, value: work) }; return work
        }
        guard let sourceWork = try sourceWork(id: id) else { throw MangaError.storage("作品不存在") }
        let work = Work(title: sourceWork.title, coverURL: sourceWork.coverURL, preferredSourceWorkID: id, isOnShelf: onShelf)
        try saveRecord(kind: "work", key: work.id.key, value: work)
        _ = try db.rows("INSERT INTO associations(source_work,work_id) VALUES(?,?)", [.text(id.key), .text(work.id.key)])
        return work
    }
    public func setPreferredSource(_ sourceWorkID: SourceWorkID, for workID: WorkID) throws {
        guard try self.workID(for: sourceWorkID) == workID, var work = try work(id: workID) else { throw MangaError.storage("来源尚未关联到此作品") }
        work.preferredSourceWorkID = sourceWorkID; try saveRecord(kind: "work", key: workID.key, value: work)
    }
    public func setOnShelf(_ value: Bool, workID: WorkID) throws { guard var work = try work(id: workID) else { return }; work.isOnShelf = value; try saveRecord(kind: "work", key: workID.key, value: work) }
    public func history() throws -> [ReadingProgress] { try records(kind: "progress", as: ReadingProgress.self).sorted { $0.updatedAt > $1.updatedAt } }
    public func link(_ id: SourceWorkID, to workID: WorkID) throws {
        guard try sourceWork(id: id) != nil, try work(id: workID) != nil else { throw MangaError.storage("作品不存在") }
        _ = try db.rows("INSERT INTO associations(source_work,work_id) VALUES(?,?) ON CONFLICT(source_work) DO UPDATE SET work_id=excluded.work_id", [.text(id.key), .text(workID.key)])
    }
    public func unlink(_ id: SourceWorkID, from workID: WorkID) throws {
        guard try self.workID(for: id) == workID else { return }
        try db.transaction {
            _ = try db.rows("DELETE FROM associations WHERE source_work=? AND work_id=?", [.text(id.key), .text(workID.key)])
            guard let sourceWork = try sourceWork(id: id) else { return }
            let newWork = Work(title: sourceWork.title, coverURL: sourceWork.coverURL, preferredSourceWorkID: id)
            try saveRecord(kind: "work", key: newWork.id.key, value: newWork)
            _ = try db.rows("INSERT INTO associations(source_work,work_id) VALUES(?,?)", [.text(id.key), .text(newWork.id.key)])
            try save(preferences: preferences(for: workID), for: newWork.id)
        }
    }
    public func save(progress: ReadingProgress) throws {
        try Task.checkCancellation()
        if let old = try self.progress(for: progress.sourceWorkID), old.updatedAt > progress.updatedAt { return }
        guard progress.pageID.chapterID == progress.chapterID else { throw MangaError.storage("阅读页面与章节不一致") }
        try db.transaction {
            try saveRecord(kind: "progress", key: progress.sourceWorkID.key, value: progress)
            if let id = try workID(for: progress.sourceWorkID), var work = try work(id: id) {
                work.preferredSourceWorkID = progress.sourceWorkID; try saveRecord(kind: "work", key: id.key, value: work)
            }
        }
    }
    public func progress(for id: SourceWorkID) throws -> ReadingProgress? { try record(kind: "progress", key: id.key, as: ReadingProgress.self) }
    public func save(preferences: ReaderPreferences, for id: WorkID) throws { try saveRecord(kind: "preferences", key: id.key, value: preferences) }
    public func preferences(for id: WorkID) throws -> ReaderPreferences { try record(kind: "preferences", key: id.key, as: ReaderPreferences.self) ?? ReaderPreferences() }
    public func saveRecommendations(_ snapshot: SourceRecommendations) throws {
        try Task.checkCancellation()
        guard let source = try source(id: snapshot.sourceID), source.enabled, !source.removed, source.revision == snapshot.sourceRevision else { throw CancellationError() }
        try saveRecord(kind: "recommendation-cache", key: source.id.key, value: snapshot)
    }
    public func downloadTask(chapterID: ChapterID) throws -> DownloadTask? {
        try records(kind: "download", parent: chapterID.key, as: DownloadTask.self).first { $0.state != .cancelled }
    }
    public func pauseDownloads(taskIDs: Set<UUID>) throws {
        try db.transaction {
            for id in taskIDs {
                guard var task = try downloadTask(id: id), [.queued, .running].contains(task.state) else { continue }
                task.state = .paused; task.generation = UUID(); task.updatedAt = Date()
                try saveRecord(kind: "download", key: id.uuidString, parent: task.chapter.id.key, value: task)
            }
        }
    }
    public func deleteDownloads(taskIDs: Set<UUID>) throws {
        try db.transaction {
            for id in taskIDs { try deleteRecord(kind: "download", key: id.uuidString); try deleteRecord(kind: "offline-manifest", key: id.uuidString) }
        }
    }
    public func downloadTask(id: UUID) throws -> DownloadTask? { try record(kind: "download", key: id.uuidString, as: DownloadTask.self) }
    public func downloadPreparationEpoch(for id: SourceWorkID) throws -> UUID {
        if let epoch = try record(kind: "download-epoch", key: id.key, as: UUID.self) { return epoch }
        let epoch = UUID(); try saveRecord(kind: "download-epoch", key: id.key, value: epoch); return epoch
    }
    public func invalidateDownloadPreparations(for ids: Set<SourceWorkID>) throws {
        try db.transaction { for id in ids { try saveRecord(kind: "download-epoch", key: id.key, value: UUID()) } }
    }
    public func ensureDownloadShelfOwner(for id: SourceWorkID, expectedEpoch: UUID? = nil) throws {
        try db.transaction {
            if let expectedEpoch, try downloadPreparationEpoch(for: id) != expectedEpoch { throw CancellationError() }
            if try sourceWork(id: id) != nil { _ = try createWorkRecord(from: id, onShelf: true) }
        }
    }
    public func downloadTasks() throws -> [DownloadTask] { try records(kind: "download", as: DownloadTask.self).sorted { $0.updatedAt > $1.updatedAt } }
    public func offlineManifest(taskID: UUID) throws -> OfflineManifest? { try record(kind: "offline-manifest", key: taskID.uuidString, as: OfflineManifest.self) }
    public func saveDownload(task: DownloadTask, manifest: OfflineManifest?, expectedGeneration: UUID? = nil, expectedWorkEpoch: UUID? = nil, bringToShelf: Bool = false) throws -> Bool {
        try db.transaction {
            if let expectedGeneration, try downloadTask(id: task.id)?.generation != expectedGeneration { return false }
            if let expectedWorkEpoch, try downloadPreparationEpoch(for: task.chapter.id.sourceWorkID) != expectedWorkEpoch { throw CancellationError() }
            if bringToShelf, try sourceWork(id: task.chapter.id.sourceWorkID) != nil { _ = try createWorkRecord(from: task.chapter.id.sourceWorkID, onShelf: true) }
            try saveRecord(kind: "download", key: task.id.uuidString, parent: task.chapter.id.key, value: task)
            if let manifest {
                guard manifest.taskID == task.id, manifest.chapterID == task.chapter.id else { throw MangaError.storage("离线清单身份不一致") }
                try saveRecord(kind: "offline-manifest", key: task.id.uuidString, parent: task.chapter.id.key, value: manifest)
            }
            return true
        }
    }
    public func deleteDownload(taskID: UUID) throws {
        try db.transaction { try deleteRecord(kind: "download", key: taskID.uuidString); try deleteRecord(kind: "offline-manifest", key: taskID.uuidString) }
    }
    public func markUpdateRead(chapterID: ChapterID) throws {
        guard var observation = try record(kind: "update-observation", key: chapterID.sourceWorkID.key, as: UpdateObservation.self) else { return }
        observation.newChapters.removeAll { $0.id == chapterID }
        try saveRecord(kind: "update-observation", key: chapterID.sourceWorkID.key, value: observation)
    }
    public func save(settings: UserSettings) throws { try saveRecord(kind: "settings", key: "local", value: settings) }
    public func settings() throws -> UserSettings { try record(kind: "settings", key: "local", as: UserSettings.self) ?? UserSettings() }
}
