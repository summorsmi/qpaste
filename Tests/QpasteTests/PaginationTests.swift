import AppKit
import Testing
@testable import QpasteCore
@testable import Qpaste

@Suite("分页与后台查询", .serialized)
@MainActor
struct PaginationTests {
    @Test func noOpRetentionDoesNotInterruptSelectionOrAnActiveSearch() async throws {
        try await fixture(synchronous: false) { store in
            store.selectedID = store.entries[5].id
            let selected = store.selectedID
            store.applyRetention()
            #expect(!store.isLoading)
            #expect(store.selected?.id == selected)
            store.query = "key299"
            store.applyRetention()
            try await settle(store)
            #expect(store.entries.map(\.text) == ["项目 Café key299"])
            store.settings.maximumCount = 100
            store.applyRetention()
            try await settle(store)
            #expect(store.entries.isEmpty)
            #expect(store.historyCount == 100)
        }
    }

    private func fixture(synchronous: Bool = true, _ body: (HistoryStore) async throws -> Void) async throws {
        let name = "qpaste-pagination-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.maximumCount = 0; settings.retentionDays = 0
        let repository = try HistoryRepository(directory: directory)
        let now = Date()
        let entries = (0..<300).map {
            ClipboardEntry(kind: .text, text: "项目 Café key\($0)", now: now.addingTimeInterval(-Double($0)))
        }
        try repository.save(entries)
        let store = try HistoryStore(settings: settings, directory: directory, synchronousQueries: synchronous)
        defer { store.flush() }
        try await body(store)
    }

    @Test func pagesKeepGlobalCountsAndNeverOverwriteUnloadedHistory() async throws {
        try await fixture { store in
            #expect(store.entries.count == 80)
            #expect(store.historyCount == 300)
            #expect(store.resultCount == 300)
            let total = store.usage.totalBytes
            store.selectedID = store.entries.last?.id
            store.moveSelection(by: 1)
            #expect(store.entries.count == 160)
            #expect(store.selected?.text == "项目 Café key80")
            store.toggleFavorite(try #require(store.entries.first))
            #expect(try store.repository.page().totalCount == 300)
            #expect(store.usage.totalBytes == total)
            store.delete(try #require(store.entries.first))
            #expect(try store.repository.page().totalCount == 299)
            #expect(try store.repository.page(HistoryQuery(text: "key299")).entries.count == 1)
        }
    }

    @Test func newQueryDiscardsOlderResultsAndLoadingCannotPasteStaleSelection() async throws {
        try await fixture(synchronous: false) { store in
            store.query = "key299"
            #expect(store.selected == nil)
            store.query = "cafe key198"
            try await settle(store)
            #expect(store.entries.map(\.text) == ["项目 Café key198"])
            #expect(store.resultCount == 1)
            store.query = ""
            try await settle(store)
            store.loadMore()
            let chosen = store.entries[5].id
            store.selectedID = chosen
            try await settle(store)
            #expect(store.entries.count == 160)
            #expect(store.selectedID == chosen)
        }
    }

    @Test func cleanupKeepsImagesReferencedOnlyByUnloadedPages() async throws {
        try await fixture { store in
            let data = Data([1, 2, 3])
            let name = try store.repository.saveImage(data)
            let entry = ClipboardEntry(kind: .image, imageFileName: name, now: Date().addingTimeInterval(-1000))
            try store.repository.saveChanges(upserting: [entry])
            store.delete(try #require(store.entries.first))
            let url = try #require(store.repository.imageURL(named: name))
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try store.repository.entry(id: entry.id) != nil)
        }
    }

    @Test func failedCaptureStaysInMemoryAndRetriesWithoutDuplicateEvents() async throws {
        try await fixture { store in
            let db = try SQLiteDatabase(url: store.repository.databaseURL)
            try db.execute("CREATE TRIGGER test_write_failure BEFORE INSERT ON entries BEGIN SELECT RAISE(FAIL,'test write failure'); END")
            store.add(ClipboardEntry(kind: .text, text: "pending capture"))
            let pending = try #require(store.entries.first { $0.text == "pending capture" })
            #expect(store.storageError != nil)
            #expect(try store.repository.entry(id: pending.id) == nil)
            try db.execute("DROP TRIGGER test_write_failure")
            store.applyRetention()
            #expect(store.storageError == nil)
            #expect(try store.repository.copyEvents(for: pending.id).count == 1)
            #expect(store.historyCount == 301)
        }
    }

    private func settle(_ store: HistoryStore) async throws {
        for _ in 0..<300 {
            if !store.isLoading && !store.isLoadingMore { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!store.isLoading && !store.isLoadingMore, "后台查询应在测试时限内完成")
    }
}
