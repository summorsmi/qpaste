import Foundation
import Testing
@testable import QpasteCore

@Suite("列表摘要与正文存储")
struct ListRepositoryTests {
    private func fixture(_ body: (HistoryRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qpaste-list-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(HistoryRepository(directory: directory))
    }

    @Test func listHasNoBodiesButSearchStillFindsTailAndFullContentKeepsFormats() throws {
        try fixture { repository in
            let body = String(repeating: "很长的文字👩🏽‍💻\n", count: 10_000) + "只在末尾出现的关键词"
            let rich = Data(repeating: 42, count: 40_000)
            let entry = ClipboardEntry(kind: .text, text: body, richText: rich)
            try repository.save([entry])
            let page = try repository.listPage(HistoryQuery(text: "末尾出现"))
            let item = try #require(page.entries.first)
            #expect(page.totalCount == 1)
            #expect(item.title == entry.title)
            #expect(try JSONEncoder().encode(item).count < 2_048)
            let full = try repository.content(for: item)
            #expect(full?.text == body && full?.richText == rich)
            let db = try SQLiteDatabase(url: repository.databaseURL)
            try db.run("UPDATE entries SET payload=? WHERE id=?", [.data(Data("invalid body".utf8)), .text(entry.id.uuidString)])
            #expect(try repository.listPage().entries == [item]) // A list never decodes the body.
            #expect(throws: (any Error).self) { try repository.content(for: item) }
        }
    }

    @Test func summariesCarryDateContextAndRevisionPreventsStaleSnippetReads() throws {
        try fixture { repository in
            var entry = ClipboardEntry(kind: .text, text: "same", sourceName: "Earlier", now: Date(timeIntervalSince1970: 100))
            try repository.save([entry])
            entry.lastCopiedAt = Date(timeIntervalSince1970: 2000); entry.sourceName = "Latest"
            try repository.save([entry], copyEvent: CopyEvent(entryID: entry.id, copiedAt: entry.lastCopiedAt, sourceName: entry.sourceName))
            let page = try repository.listPage(HistoryQuery(interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1000)))
            let item = try #require(page.entries.first)
            let content = try repository.content(for: item)
            #expect(content?.sourceName == "Earlier")
            #expect(content?.lastCopiedAt == Date(timeIntervalSince1970: 100))
            #expect(try repository.entry(id: entry.id)?.sourceName == "Latest")
            var snippet = ClipboardEntry(kind: .text, text: "old body", snippetName: "old name")
            try repository.saveChanges(upserting: [snippet])
            let before = try repository.listPage(HistoryQuery(filter: .snippets))
            let oldItem = try #require(before.entries.first)
            snippet.text = "new body"; snippet.snippetName = "new name"; snippet.updatedAt = Date()
            try repository.saveChanges(upserting: [snippet])
            #expect(try repository.content(for: oldItem) == nil)
            let after = try repository.listPage(HistoryQuery(filter: .snippets))
            let newItem = try #require(after.entries.first)
            #expect(newItem.revision != oldItem.revision)
            #expect(try repository.content(for: newItem)?.text == "new body")
        }
    }

    @Test func versionTwoBackfillPreservesExactBodyBytesAndCopyEvents() throws {
        try fixture { repository in
            let entry = ClipboardEntry(kind: .text, text: "迁移完整正文", richText: Data([1, 2, 3]))
            try repository.save([entry])
            let events = try repository.copyEvents(for: entry.id)
            let db = try SQLiteDatabase(url: repository.databaseURL)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
            let original = try encoder.encode(entry)
            try db.run("UPDATE entries SET payload=?", [.data(original)])
            try db.execute("ALTER TABLE entries DROP COLUMN list_payload; ALTER TABLE entries DROP COLUMN revision; PRAGMA user_version=2;")
            let next = try HistoryRepository(directory: repository.directory)
            let page = try next.listPage()
            #expect(page.entries.count == 1)
            #expect(try db.rows("SELECT payload FROM entries").first?.first?.bytes == original)
            #expect(try next.copyEvents(for: entry.id) == events)
            #expect(try db.rows("PRAGMA user_version").first?.first?.double == 3)
        }
    }

    @Test func failedBackfillRollsBackSchemaAndKeepsOriginalRecords() throws {
        try fixture { repository in
            try repository.save([ClipboardEntry(kind: .text, text: "keep")])
            let db = try SQLiteDatabase(url: repository.databaseURL)
            let invalid = Data("unreadable body".utf8)
            try db.run("UPDATE entries SET payload=?", [.data(invalid)])
            try db.execute("ALTER TABLE entries DROP COLUMN list_payload; ALTER TABLE entries DROP COLUMN revision; PRAGMA user_version=2;")
            let next = try HistoryRepository(directory: repository.directory)
            #expect(throws: (any Error).self) { try next.listPage() }
            #expect(try db.rows("PRAGMA user_version").first?.first?.double == 2)
            #expect(try db.rows("SELECT payload FROM entries").first?.first?.bytes == invalid)
            #expect(try db.rows("PRAGMA table_info(entries)").contains { $0[1].string == "list_payload" } == false)
        }
    }
}
