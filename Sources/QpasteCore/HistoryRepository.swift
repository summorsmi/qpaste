import Foundation

public struct HistoryArchive: Codable {
    public var version: Int = 1
    public var entries: [ClipboardEntry]
    public init(entries: [ClipboardEntry]) { self.entries = entries }
}

public final class HistoryRepository: @unchecked Sendable {
    public let directory: URL
    public var archiveURL: URL { directory.appendingPathComponent("history.json") }
    public var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private let lock = NSRecursiveLock()
    private var database: SQLiteDatabase?
    private var ready = false
    public var databaseURL: URL { directory.appendingPathComponent("history.sqlite") }

    public func load() throws -> [ClipboardEntry] {
        try withDatabase { db in
            try db.rows("SELECT payload FROM entries ORDER BY display_at DESC, id DESC")
                .map { try JSONDecoder().decode(ClipboardEntry.self, from: $0[0].bytes) }
                .filter(imageExists)
        }
    }

    public func preserveUnreadableArchive() throws {
        let backup = directory.appendingPathComponent("history-unreadable-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: archiveURL, to: backup)
    }

    /// Compatibility snapshot writer. Unchanged rows are not rewritten and copy
    /// events are appended only for captures, never for favorites or manual paste.
    public func save(_ entries: [ClipboardEntry], copyEvent: CopyEvent? = nil) throws {
        try withDatabase { db in
            try db.transaction {
                let existing = Set(try db.rows("SELECT id FROM entries").map { $0[0].string })
                let retained = Set(entries.map { $0.id.uuidString })
                for id in existing.subtracting(retained) { try db.run("DELETE FROM entries WHERE id=?", [.text(id)]) }
                for entry in entries {
                    try upsert(entry, in: db)
                    if !existing.contains(entry.id.uuidString), copyEvent?.entryID != entry.id {
                        try seedKnownEvents(entry, in: db)
                    }
                }
                if let copyEvent, retained.contains(copyEvent.entryID.uuidString) { try insert(copyEvent, in: db) }
            }
        }
    }

    public func copyEvents(for id: UUID) throws -> [CopyEvent] {
        try withDatabase { db in
            try db.rows("SELECT id, entry_id, copied_at, source_name, source_bundle FROM copy_events WHERE entry_id=? ORDER BY copied_at, id", [.text(id.uuidString)]).map(decodeEvent)
        }
    }

    public func latestCopyEvents(in interval: DateInterval) throws -> [UUID: CopyEvent] {
        try withDatabase { db in
            let rows = try db.rows("""
                SELECT id, entry_id, copied_at, source_name, source_bundle FROM copy_events
                WHERE copied_at>=? AND copied_at<? ORDER BY copied_at DESC, id DESC
                """, [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)])
            var result = [UUID: CopyEvent]()
            for row in rows { let event = try decodeEvent(row); if result[event.entryID] == nil { result[event.entryID] = event } }
            return result
        }
    }

    private func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let db: SQLiteDatabase
        if let database { db = database }
        else { db = try SQLiteDatabase(url: databaseURL); database = db }
        if !ready {
            let version = Int(try db.rows("PRAGMA user_version").first?.first?.double ?? 0)
            guard version <= 1 else { throw SQLiteFailure(message: "版本不受支持，原数据库未修改") }
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS entries(
                        id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL,
                        is_favorite INTEGER NOT NULL, is_snippet INTEGER NOT NULL,
                        copied_at REAL NOT NULL, display_at REAL NOT NULL, byte_count INTEGER NOT NULL,
                        image_file TEXT, payload BLOB NOT NULL);
                    CREATE INDEX IF NOT EXISTS entries_time ON entries(display_at DESC, id DESC);
                    CREATE INDEX IF NOT EXISTS entries_fingerprint ON entries(fingerprint);
                    CREATE TABLE IF NOT EXISTS copy_events(
                        id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                        copied_at REAL NOT NULL, source_name TEXT NOT NULL, source_bundle TEXT);
                    CREATE INDEX IF NOT EXISTS events_time ON copy_events(copied_at, entry_id);
                    CREATE INDEX IF NOT EXISTS events_entry_time ON copy_events(entry_id, copied_at DESC);
                    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    """)
                if try db.rows("SELECT value FROM metadata WHERE key='legacy_imported'").isEmpty {
                    if FileManager.default.fileExists(atPath: archiveURL.path) {
                        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: archiveURL))
                        guard archive.version == 1 else { throw SQLiteFailure(message: "旧历史版本不受支持") }
                        for var entry in archive.entries {
                            if entry.isSnippet { entry.updatedAt = entry.updatedAt ?? entry.lastCopiedAt }
                            try upsert(entry, in: db)
                            try seedKnownEvents(entry, in: db)
                        }
                    }
                    try db.run("INSERT INTO metadata(key,value) VALUES('legacy_imported','1')")
                }
                try db.execute("PRAGMA user_version=1")
            }
            ready = true
        }
        return try body(db)
    }

    private func upsert(_ entry: ClipboardEntry, in db: SQLiteDatabase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.run("""
            INSERT INTO entries(id,fingerprint,kind,is_favorite,is_snippet,copied_at,display_at,byte_count,image_file,payload)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint, kind=excluded.kind,
                is_favorite=excluded.is_favorite, is_snippet=excluded.is_snippet,
                copied_at=excluded.copied_at, display_at=excluded.display_at, byte_count=excluded.byte_count,
                image_file=excluded.image_file, payload=excluded.payload WHERE entries.payload<>excluded.payload
            """, [.text(entry.id.uuidString), .text(entry.fingerprint), .text(entry.kind.rawValue),
                    .integer(entry.isFavorite ? 1 : 0), .integer(entry.isSnippet ? 1 : 0),
                    .number(entry.lastCopiedAt.timeIntervalSince1970), .number(entry.displayDate.timeIntervalSince1970),
                    .integer(entry.byteCount), entry.imageFileName.map(SQLValue.text) ?? .null,
                    .data(try encoder.encode(entry))])
    }

    private func seedKnownEvents(_ entry: ClipboardEntry, in db: SQLiteDatabase) throws {
        guard !entry.isSnippet else { return }
        if entry.createdAt < entry.lastCopiedAt {
            try insert(CopyEvent(entryID: entry.id, copiedAt: entry.createdAt, sourceName: "未知应用"), in: db)
        }
        try insert(CopyEvent(entryID: entry.id, copiedAt: entry.lastCopiedAt, sourceName: entry.sourceName, sourceBundleID: entry.sourceBundleID), in: db)
    }

    private func insert(_ event: CopyEvent, in db: SQLiteDatabase) throws {
        try db.run("INSERT OR IGNORE INTO copy_events(id,entry_id,copied_at,source_name,source_bundle) VALUES(?,?,?,?,?)",
                   [.text(event.id.uuidString), .text(event.entryID.uuidString), .number(event.copiedAt.timeIntervalSince1970),
                    .text(event.sourceName), event.sourceBundleID.map(SQLValue.text) ?? .null])
    }

    private func decodeEvent(_ row: [SQLValue]) throws -> CopyEvent {
        guard let id = UUID(uuidString: row[0].string), let entry = UUID(uuidString: row[1].string) else {
            throw SQLiteFailure(message: "复制时间记录无法读取")
        }
        return CopyEvent(entryID: entry, copiedAt: Date(timeIntervalSince1970: row[2].double), sourceName: row[3].string,
                         sourceBundleID: row[4].string.isEmpty ? nil : row[4].string, id: id)
    }

    private func imageExists(_ entry: ClipboardEntry) -> Bool {
        guard entry.kind == .image else { return true }
        guard let name = entry.imageFileName, let url = imageURL(named: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func imageURL(named name: String) -> URL? {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasSuffix(".png"), !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    public func saveImage(_ data: Data) throws -> String {
        let name = ClipboardEntry.digest(data) + ".png"
        let url = imagesDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return name
    }

    /// Run on the same serial executor as image writes and archive saves.
    public func removeUnreferencedImages(keeping entries: [ClipboardEntry]) throws {
        let retained = Set(entries.compactMap(\.imageFileName))
        for url in try FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) {
            if url.pathExtension == "png", !retained.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
