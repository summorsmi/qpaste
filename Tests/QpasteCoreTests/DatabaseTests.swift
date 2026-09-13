import Foundation
import Testing
@testable import QpasteCore

@Suite("数据库迁移与复制时间")
struct DatabaseTests {
    private func fixture(_ body: (URL, HistoryRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qpaste-db-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, HistoryRepository(directory: directory))
    }

    @Test func legacyMigrationIsAtomicAndNeverReimportsDeletedHistory() throws {
        try fixture { directory, repository in
            var entry = ClipboardEntry(kind: .text, text: "旧记录", now: Date(timeIntervalSince1970: 100))
            entry.lastCopiedAt = Date(timeIntervalSince1970: 200)
            let original = try JSONEncoder().encode(HistoryArchive(entries: [entry]))
            try original.write(to: repository.archiveURL)
            #expect(try repository.load() == [entry])
            #expect(try Data(contentsOf: repository.archiveURL) == original)
            let events = try repository.copyEvents(for: entry.id)
            #expect(events.map(\.copiedAt) == [entry.createdAt, entry.lastCopiedAt])
            #expect(events[0].sourceName == "未知应用")
            #expect(try HistoryRepository(directory: directory).copyEvents(for: entry.id).count == 2)
            try repository.save([])
            #expect(try HistoryRepository(directory: directory).load().isEmpty)
            #expect(try repository.copyEvents(for: entry.id).isEmpty)
        }
    }

    @Test func repeatedCopyKeepsBothDaysWhileContentAndFavoriteStayUnique() throws {
        try fixture { _, repository in
            var entry = ClipboardEntry(kind: .text, text: "相同内容", sourceName: "昨天的来源", now: Date(timeIntervalSince1970: 100))
            try repository.save([entry])
            entry.lastCopiedAt = Date(timeIntervalSince1970: 100_000)
            entry.sourceName = "今天的来源"
            let copied = CopyEvent(entryID: entry.id, copiedAt: entry.lastCopiedAt, sourceName: entry.sourceName)
            try repository.save([entry], copyEvent: copied)
            entry.isFavorite = true
            try repository.save([entry])
            try repository.save([entry], copyEvent: copied) // Retrying an event is idempotent.
            #expect(try repository.load().count == 1)
            #expect(try repository.copyEvents(for: entry.id).count == 2)
            let yesterday = try repository.latestCopyEvents(in: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1000)))
            #expect(yesterday[entry.id]?.sourceName == "昨天的来源")
        }
    }

    @Test func dateIntervalsAreHalfOpenAndSnippetsHaveNoCopyEvents() throws {
        try fixture { _, repository in
            let entry = ClipboardEntry(kind: .text, text: "a", now: Date(timeIntervalSince1970: 100))
            let snippet = ClipboardEntry(kind: .text, text: "b", snippetName: "片段")
            try repository.save([entry, snippet])
            let before = try repository.latestCopyEvents(in: DateInterval(start: Date(timeIntervalSince1970: 0), end: entry.lastCopiedAt))
            #expect(before.isEmpty)
            let after = try repository.latestCopyEvents(in: DateInterval(start: entry.lastCopiedAt, duration: 1))
            #expect(after.count == 1)
            #expect(try repository.copyEvents(for: snippet.id).isEmpty)
        }
    }

    @Test func failedSaveRollsBackDeletionsAndEventChanges() throws {
        try fixture { _, repository in
            let original = ClipboardEntry(kind: .text, text: "original")
            try repository.save([original])
            var invalid = ClipboardEntry(kind: .text, text: "cannot encode")
            invalid.lastCopiedAt = Date(timeIntervalSince1970: .infinity)
            #expect(throws: (any Error).self) { try repository.save([invalid]) }
            #expect(try repository.load() == [original])
            #expect(try repository.copyEvents(for: original.id).count == 1)
        }
    }

    @Test func futureDatabaseVersionIsRejectedWithoutReplacingData() throws {
        try fixture { directory, repository in
            let original = ClipboardEntry(kind: .text, text: "keep")
            try repository.save([original])
            let db = try SQLiteDatabase(url: repository.databaseURL)
            try db.execute("PRAGMA user_version=99")
            #expect(throws: (any Error).self) { try HistoryRepository(directory: directory).load() }
            #expect(try db.rows("SELECT id FROM entries").first?.first?.string == original.id.uuidString)
        }
    }

    @Test func versionOneDatabaseUpgradesSearchColumnsWithoutInventingCopyEvents() throws {
        try fixture { directory, repository in
            let entry = ClipboardEntry(kind: .text, text: "Café 历史", sourceName: "Notes")
            let db = try SQLiteDatabase(url: repository.databaseURL)
            try db.execute("""
                CREATE TABLE entries(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,kind TEXT NOT NULL,
                    is_favorite INTEGER NOT NULL,is_snippet INTEGER NOT NULL,copied_at REAL NOT NULL,
                    display_at REAL NOT NULL,byte_count INTEGER NOT NULL,image_file TEXT,payload BLOB NOT NULL);
                CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                INSERT INTO metadata VALUES('legacy_imported','1');
                PRAGMA user_version=1;
                """)
            try db.run("INSERT INTO entries VALUES(?,?,?,?,?,?,?,?,?,?)",
                       [.text(entry.id.uuidString), .text(entry.fingerprint), .text("text"), .integer(0), .integer(0),
                        .number(entry.lastCopiedAt.timeIntervalSince1970), .number(entry.displayDate.timeIntervalSince1970),
                        .integer(entry.byteCount), .null, .data(try JSONEncoder().encode(entry))])
            let upgraded = try HistoryRepository(directory: directory)
            #expect(try upgraded.page(HistoryQuery(text: "cafe notes")).entries == [entry])
            #expect(try db.rows("PRAGMA user_version").first?.first?.double == 2)
            #expect(try upgraded.copyEvents(for: entry.id).isEmpty) // No invented events during the schema-only upgrade.
        }
    }

    @Test func databaseRetentionMatchesExistingPolicyAndCascadesEvents() throws {
        try fixture { _, repository in
            let now = Date()
            let entries = [
                ClipboardEntry(kind: .text, text: "expired", byteCount: 1, now: now.addingTimeInterval(-60 * 86400)),
                ClipboardEntry(kind: .text, text: "new", byteCount: 6, now: now),
                ClipboardEntry(kind: .text, text: "too big", byteCount: 6, now: now.addingTimeInterval(-1)),
                ClipboardEntry(kind: .text, text: "fits", byteCount: 3, now: now.addingTimeInterval(-2)),
                ClipboardEntry(kind: .text, text: "favorite", byteCount: 1000, now: now.addingTimeInterval(-70 * 86400), isFavorite: true),
                ClipboardEntry(kind: .text, text: "snippet", byteCount: 1000, now: now.addingTimeInterval(-80 * 86400), snippetName: "keep")
            ]
            let policy = HistoryPolicy(maximumCount: 2, retentionDays: 30, maximumBytes: 10)
            try repository.save(entries)
            try repository.saveChanges(policy: policy, now: now)
            let retained = try repository.page().entries
            #expect(Set(retained.map(\.id)) == Set(policy.applying(to: entries, now: now).map(\.id)))
            #expect(try repository.copyEvents(for: entries[0].id).isEmpty)
            #expect(try repository.copyEvents(for: entries[2].id).isEmpty)
            #expect(try repository.summary().usage.historyBytes == 9)
        }
    }
}
