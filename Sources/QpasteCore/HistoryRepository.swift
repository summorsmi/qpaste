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
    public private(set) var legacyImportFailed = false
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
            guard version <= 3 else { throw SQLiteFailure(message: "版本不受支持，原数据库未修改") }
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS entries(
                        id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL,
                        is_favorite INTEGER NOT NULL, is_snippet INTEGER NOT NULL,
                        copied_at REAL NOT NULL, display_at REAL NOT NULL, byte_count INTEGER NOT NULL,
                        image_file TEXT, payload BLOB NOT NULL,
                        search_text TEXT NOT NULL DEFAULT '', source_name TEXT NOT NULL DEFAULT '', source_bundle TEXT,
                        list_payload BLOB NOT NULL DEFAULT X'7B7D', revision TEXT NOT NULL DEFAULT '');
                    CREATE INDEX IF NOT EXISTS entries_time ON entries(display_at DESC, id DESC);
                    CREATE INDEX IF NOT EXISTS entries_fingerprint ON entries(fingerprint);
                    CREATE TABLE IF NOT EXISTS copy_events(
                        id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                        copied_at REAL NOT NULL, source_name TEXT NOT NULL, source_bundle TEXT);
                    CREATE INDEX IF NOT EXISTS events_time ON copy_events(copied_at, entry_id);
                    CREATE INDEX IF NOT EXISTS events_entry_time ON copy_events(entry_id, copied_at DESC);
                    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    """)
                if version == 1 {
                    try db.execute("ALTER TABLE entries ADD COLUMN search_text TEXT NOT NULL DEFAULT ''; ALTER TABLE entries ADD COLUMN source_name TEXT NOT NULL DEFAULT ''; ALTER TABLE entries ADD COLUMN source_bundle TEXT;")
                }
                if version == 1 || version == 2 {
                    try db.execute("ALTER TABLE entries ADD COLUMN list_payload BLOB NOT NULL DEFAULT X'7B7D'; ALTER TABLE entries ADD COLUMN revision TEXT NOT NULL DEFAULT '';")
                    // Backfill one body at a time. Never materialize the entire archive
                    // in RAM, or rewrite existing body bytes and copy occurrences.
                    var lastRowID: Int?
                    while let row = try db.rows("SELECT rowid,payload FROM entries" + (lastRowID == nil ? "" : " WHERE rowid>?") + " ORDER BY rowid LIMIT 1",
                                               lastRowID.map { [.integer($0)] } ?? []).first {
                        guard case .integer(let rowID) = row[0] else { throw SQLiteFailure(message: "记录索引无法读取") }
                        let entry = try JSONDecoder().decode(ClipboardEntry.self, from: row[1].bytes)
                        let item = HistoryListItem(entry)
                        try db.run("UPDATE entries SET list_payload=?,revision=? WHERE rowid=?",
                                   [.data(try JSONEncoder().encode(item)), .text(item.revision), .integer(rowID)])
                        if version == 1 {
                            try db.run("UPDATE entries SET search_text=?,source_name=?,source_bundle=? WHERE rowid=?",
                                       [.text(searchText(entry)), .text(entry.sourceName), entry.sourceBundleID.map(SQLValue.text) ?? .null, .integer(rowID)])
                        }
                        lastRowID = rowID
                    }
                }
                if try db.rows("SELECT value FROM metadata WHERE key='legacy_imported'").isEmpty {
                    if FileManager.default.fileExists(atPath: archiveURL.path) {
                        let archive: HistoryArchive
                        do {
                            archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: archiveURL))
                            guard archive.version == 1 else { throw SQLiteFailure(message: "旧历史版本不受支持") }
                        } catch { legacyImportFailed = true; throw error }
                        for var entry in archive.entries {
                            if entry.isSnippet { entry.updatedAt = entry.updatedAt ?? entry.lastCopiedAt }
                            try upsert(entry, in: db)
                            try seedKnownEvents(entry, in: db)
                        }
                    }
                    try db.run("INSERT INTO metadata(key,value) VALUES('legacy_imported','1')")
                }
                try db.execute("PRAGMA user_version=3")
            }
            ready = true
            legacyImportFailed = false
        }
        return try body(db)
    }

    private func upsert(_ entry: ClipboardEntry, in db: SQLiteDatabase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let item = HistoryListItem(entry)
        try db.run("""
            INSERT INTO entries(id,fingerprint,kind,is_favorite,is_snippet,copied_at,display_at,byte_count,image_file,payload,search_text,source_name,source_bundle,list_payload,revision)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint, kind=excluded.kind,
                is_favorite=excluded.is_favorite, is_snippet=excluded.is_snippet,
                copied_at=excluded.copied_at, display_at=excluded.display_at, byte_count=excluded.byte_count,
                image_file=excluded.image_file, payload=excluded.payload,
                search_text=excluded.search_text, source_name=excluded.source_name, source_bundle=excluded.source_bundle,
                list_payload=excluded.list_payload, revision=excluded.revision
                WHERE entries.payload<>excluded.payload OR entries.search_text<>excluded.search_text
            """, [.text(entry.id.uuidString), .text(entry.fingerprint), .text(entry.kind.rawValue),
                    .integer(entry.isFavorite ? 1 : 0), .integer(entry.isSnippet ? 1 : 0),
                    .number(entry.lastCopiedAt.timeIntervalSince1970), .number(entry.displayDate.timeIntervalSince1970),
                    .integer(entry.byteCount), entry.imageFileName.map(SQLValue.text) ?? .null,
                    .data(try encoder.encode(entry)),
                    .text(searchText(entry)), .text(entry.sourceName), entry.sourceBundleID.map(SQLValue.text) ?? .null,
                    .data(try encoder.encode(item)), .text(item.revision)])
    }

    private func searchText(_ entry: ClipboardEntry) -> String {
        [entry.text, entry.title, entry.filePaths.joined(separator: " ")].joined(separator: "\n")
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

extension HistoryRepository {
    public func content(for item: HistoryListItem) throws -> ClipboardEntry? {
        try withDatabase { db in
            try db.rows("SELECT payload FROM entries WHERE id=? AND revision=?", [.text(item.id.uuidString), .text(item.revision)]).first
                .map { item.displaying(try JSONDecoder().decode(ClipboardEntry.self, from: $0[0].bytes)) }
        }
    }

    public func entry(id: UUID) throws -> ClipboardEntry? {
        try withDatabase { db in
            try db.rows("SELECT payload FROM entries WHERE id=?", [.text(id.uuidString)]).first
                .map { try JSONDecoder().decode(ClipboardEntry.self, from: $0[0].bytes) }
        }
    }

    public func entry(fingerprint: String) throws -> ClipboardEntry? {
        try withDatabase { db in
            try db.rows("SELECT payload FROM entries WHERE fingerprint=? LIMIT 1", [.text(fingerprint)]).first
                .map { try JSONDecoder().decode(ClipboardEntry.self, from: $0[0].bytes) }
        }
    }

    /// Changes only the named records; unloaded pages can never be removed by a UI save.
    @discardableResult
    public func saveChanges(upserting entries: [ClipboardEntry] = [], deleting ids: [UUID] = [],
                            copyEvents: [CopyEvent] = [], policy: HistoryPolicy? = nil, now: Date = Date()) throws -> Bool {
        try withDatabase { db in
            try db.transaction {
                for id in ids { try db.run("DELETE FROM entries WHERE id=?", [.text(id.uuidString)]) }
                for entry in entries { try upsert(entry, in: db) }
                for event in copyEvents { try insert(event, in: db) }
                let trimmed = try policy.map { try enforce($0, now: now, in: db) } ?? false
                return !ids.isEmpty || trimmed
            }
        }
    }

    public func clearHistory(includeFavorites: Bool) throws {
        _ = try withDatabase { db in
            try db.transaction { try db.run("DELETE FROM entries WHERE is_snippet=0" + (includeFavorites ? "" : " AND is_favorite=0")) }
        }
    }

    private func enforce(_ policy: HistoryPolicy, now: Date, in db: SQLiteDatabase) throws -> Bool {
        var removed = false
        if policy.retentionDays > 0 {
            removed = try db.run("DELETE FROM entries WHERE is_favorite=0 AND is_snippet=0 AND copied_at<?",
                       [.number(now.addingTimeInterval(-Double(policy.retentionDays) * 86400).timeIntervalSince1970)]) > 0
        }
        let rows = try db.rows("SELECT id,byte_count FROM entries WHERE is_favorite=0 AND is_snippet=0 ORDER BY copied_at DESC,id DESC")
        var count = 0
        var bytes = 0
        for row in rows {
            let size = max(0, Int(row[1].double))
            if (policy.maximumCount > 0 && count >= policy.maximumCount) || size > policy.maximumBytes - bytes {
                try db.run("DELETE FROM entries WHERE id=?", [.text(row[0].string)])
                removed = true
            } else { count += 1; bytes += size }
        }
        return removed
    }

    public func summary() throws -> HistorySummary {
        try withDatabase { db in
            var result = HistorySummary()
            var ordinary = 0, favorites = 0, snippets = 0
            for row in try db.rows("SELECT kind,is_favorite,is_snippet,COUNT(*),COALESCE(SUM(byte_count),0) FROM entries GROUP BY kind,is_favorite,is_snippet") {
                let count = Int(row[3].double), bytes = Int(row[4].double)
                result.counts[.all, default: 0] += count
                if row[2].double == 1 {
                    result.counts[.snippets, default: 0] += count
                    snippets += bytes
                } else {
                    if let kind = HistoryFilter(rawValue: row[0].string) { result.counts[kind, default: 0] += count }
                    if row[1].double == 1 { result.counts[.favorites, default: 0] += count; favorites += bytes }
                    else { ordinary += bytes }
                }
            }
            result.usage = HistoryUsage(historyBytes: ordinary, favoriteBytes: favorites, snippetBytes: snippets)
            return result
        }
    }

    public func page(_ query: HistoryQuery = HistoryQuery(), limit: Int = 80, offset: Int = 0, cancellation: HistoryQueryCancellation? = nil) throws -> HistoryPage {
        let result = try pageRows(query, limit: limit, offset: offset, column: "payload", cancellation: cancellation)
        let entries = try result.rows.map { row -> ClipboardEntry in
            var entry = try JSONDecoder().decode(ClipboardEntry.self, from: row[0].bytes)
            if query.interval != nil && !entry.isSnippet {
                entry.lastCopiedAt = Date(timeIntervalSince1970: row[1].double)
                entry.sourceName = row[2].string
                entry.sourceBundleID = row[3].string.isEmpty ? nil : row[3].string
            }
            return entry
        }
        return HistoryPage(entries: entries, totalCount: result.totalCount)
    }

    public func listPage(_ query: HistoryQuery = HistoryQuery(), limit: Int = 80, offset: Int = 0, cancellation: HistoryQueryCancellation? = nil) throws -> HistoryListPage {
        let result = try pageRows(query, limit: limit, offset: offset, column: "list_payload", cancellation: cancellation)
        let entries = try result.rows.map { row -> HistoryListItem in
            var item = try JSONDecoder().decode(HistoryListItem.self, from: row[0].bytes)
            if query.interval != nil && !item.isSnippet {
                item.lastCopiedAt = Date(timeIntervalSince1970: row[1].double)
                item.sourceName = row[2].string
                item.sourceBundleID = row[3].string.isEmpty ? nil : row[3].string
            }
            return item
        }
        return HistoryListPage(entries: entries, totalCount: result.totalCount)
    }

    private func pageRows(_ query: HistoryQuery, limit: Int, offset: Int, column: String, cancellation: HistoryQueryCancellation?) throws -> (rows: [[SQLValue]], totalCount: Int) {
        try withDatabase { db in
            try db.withCancellation(cancellation) {
                try db.transaction(readOnly: true) {
                    var values = [SQLValue]()
                    let base: String
                    if let range = query.interval {
                        base = """
                            WITH matching AS (
                                SELECT entry_id,MAX(copied_at) AS at FROM copy_events WHERE copied_at>=? AND copied_at<? GROUP BY entry_id
                            ), candidates AS (
                                SELECT e.id,e.kind,e.is_favorite,e.is_snippet,e.search_text,e.\(column) AS content,CASE WHEN e.is_snippet=1 THEN e.display_at ELSE m.at END AS sort_at,
                                    CASE WHEN e.is_snippet=1 THEN e.source_name ELSE
                                        (SELECT source_name FROM copy_events WHERE entry_id=e.id AND copied_at=m.at ORDER BY id DESC LIMIT 1) END AS matched_source,
                                    CASE WHEN e.is_snippet=1 THEN e.source_bundle ELSE
                                        (SELECT source_bundle FROM copy_events WHERE entry_id=e.id AND copied_at=m.at ORDER BY id DESC LIMIT 1) END AS matched_bundle
                                FROM entries e LEFT JOIN matching m ON e.id=m.entry_id
                                WHERE (e.is_snippet=0 AND m.entry_id IS NOT NULL) OR (e.is_snippet=1 AND e.display_at>=? AND e.display_at<?)
                            )
                            """
                        values = [.number(range.start.timeIntervalSince1970), .number(range.end.timeIntervalSince1970),
                                  .number(range.start.timeIntervalSince1970), .number(range.end.timeIntervalSince1970)]
                    } else {
                        base = "WITH candidates AS (SELECT id,kind,is_favorite,is_snippet,search_text,\(column) AS content,display_at AS sort_at,source_name AS matched_source,source_bundle AS matched_bundle FROM entries)"
                    }
                    var predicate = "1=1"
                    switch query.filter {
                    case .all: break
                    case .favorites: predicate += " AND is_snippet=0 AND is_favorite=1"
                    case .snippets: predicate += " AND is_snippet=1"
                    default: predicate += " AND is_snippet=0 AND kind=?"; values.append(.text(query.filter.rawValue))
                    }
                    if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        predicate += " AND qp_matches(search_text,matched_source,?)=1"
                        values.append(.text(query.text))
                    }
                    if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Materialize only matching IDs and date context, never all bodies.
                        // COUNT and pagination share one match pass, even for an empty page.
                        let sql = base + """
                            , matched AS MATERIALIZED (
                                SELECT id,sort_at,matched_source,matched_bundle FROM candidates WHERE \(predicate)
                            ), selected_page AS (
                                SELECT * FROM matched ORDER BY sort_at DESC,id DESC LIMIT ? OFFSET ?
                            ), total AS (SELECT COUNT(*) AS n FROM matched)
                            SELECT e.\(column),p.sort_at,p.matched_source,p.matched_bundle,total.n
                            FROM total LEFT JOIN selected_page p ON 1=1 LEFT JOIN entries e ON e.id=p.id
                            ORDER BY p.sort_at DESC,p.id DESC
                            """
                        let rows = try db.rows(sql, values + [.integer(max(1, limit)), .integer(max(0, offset))])
                        let count = Int(rows.first?[4].double ?? 0)
                        return (rows.filter { if case .null = $0[0] { return false }; return true }, count)
                    }
                    let count = Int(try db.rows(base + " SELECT COUNT(*) FROM candidates WHERE " + predicate, values).first?.first?.double ?? 0)
                    let rows = try db.rows(base + " SELECT content,sort_at,matched_source,matched_bundle FROM candidates WHERE " + predicate + " ORDER BY sort_at DESC,id DESC LIMIT ? OFFSET ?",
                                           values + [.integer(max(1, limit)), .integer(max(0, offset))])
                    return (rows, count)
                }
            }
        }
    }

    public func removeUnreferencedImages() throws {
        try withDatabase { db in
            let names = Set(try db.rows("SELECT image_file FROM entries WHERE image_file IS NOT NULL").map { $0[0].string })
            for url in try FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) {
                if url.pathExtension == "png" && !names.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
            }
        }
    }
}
