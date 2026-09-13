import AppKit
import Testing
@testable import QpasteCore
@testable import Qpaste

@Suite("正文按需读取与缓存", .serialized)
@MainActor
struct LazyContentTests {
    private func fixture(count: Int = 40, synchronous: Bool = true,
                         _ body: (HistoryStore) async throws -> Void) async throws {
        let name = "qpaste-lazy-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.maximumCount = 0; settings.retentionDays = 0
        let repository = try HistoryRepository(directory: directory)
        let now = Date()
        for index in 0..<count {
            let entry = ClipboardEntry(kind: .text,
                text: "标题 \(index)\n" + String(repeating: "x", count: 256 * 1024) + "\n尾部关键词-\(index)",
                richText: Data(repeating: UInt8(index % 255), count: 256 * 1024), now: now.addingTimeInterval(-Double(index)))
            try repository.saveChanges(upserting: [entry])
        }
        let store = try HistoryStore(settings: settings, directory: directory, synchronousQueries: synchronous)
        defer { store.flush() }
        try await body(store)
    }

    @Test func scrollingKeepsSummariesAndOnlyRequestedBodiesEnterBoundedCache() async throws {
        try await fixture(count: 180) { store in
            #expect(store.entries.count == 80)
            #expect(store.cachedContentCount == 1)
            while store.hasMore { store.loadMore() }
            #expect(store.entries.count == 180)
            #expect(store.cachedContentCount == 1)
            #expect(try JSONEncoder().encode(store.entries).count < 200_000)
            for item in store.entries.prefix(30) {
                let entry = try await store.content(for: item)
                #expect(entry.text.hasPrefix(item.title + "\n"))
                #expect(entry.text.utf8.count > 256 * 1024)
                #expect(entry.richText?.count == 256 * 1024)
            }
            #expect(store.cachedContentCount <= 12)
            #expect(store.cachedContentBytes <= 8 * 1024 * 1024)
            store.query = "尾部关键词-179"
            #expect(store.resultCount == 1)
            #expect(store.selected?.text.hasSuffix("尾部关键词-179") == true)
        }
    }

    @Test func lazyActionsCopyCompleteTextFormatsAndEditCompleteSnippetBody() async throws {
        try await fixture { store in
            let item = store.entries[25] // Never selected or previewed.
            let entry = try await store.content(for: item)
            let pasteboard = NSPasteboard(name: .init("qpaste-lazy-copy-\(UUID())"))
            defer { pasteboard.releaseGlobally() }
            let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
            try monitor.write(entry, plainText: false)
            #expect(pasteboard.string(forType: .string) == entry.text)
            #expect(pasteboard.data(forType: .rtf) == entry.richText)
            try monitor.write(entry, plainText: true)
            #expect(pasteboard.string(forType: .string)?.hasSuffix("尾部关键词-25") == true)
            #expect(pasteboard.data(forType: .rtf) == nil)
            store.editSnippet(from: item)
            for _ in 0..<100 where store.snippetDraft == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(store.snippetDraft?.body == entry.text)
            store.saveSnippet(SnippetDraft(name: "完整片段", body: entry.text))
            let oldItem = try #require(store.entries.first)
            _ = try await store.content(for: oldItem)
            store.saveSnippet(SnippetDraft(entryID: oldItem.id, name: "修改后的片段", body: "完整的新正文"))
            await #expect(throws: (any Error).self) { try await store.content(for: oldItem) }
            let newItem = try #require(store.entries.first)
            let updated = try await store.content(for: newItem)
            #expect(updated.text == "完整的新正文" && updated.snippetName == "修改后的片段")
        }
    }

    @Test func rapidSelectionAndCancellationNeverShowAnEarlierBody() async throws {
        try await fixture(synchronous: false) { store in
            for item in store.entries.prefix(30) { store.selectedID = item.id }
            let last = store.entries[29]
            for _ in 0..<100 where store.isLoadingContent { try await Task.sleep(for: .milliseconds(10)) }
            #expect(store.selected?.id == last.id)
            #expect(store.selected?.text.hasSuffix("尾部关键词-29") == true)
            let task = Task { try await store.content(for: store.entries[35]) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(store.selected?.id == last.id)
            #expect(store.cachedContentCount <= 2)
        }
    }

    @Test func unreadableBodyShowsErrorInsteadOfSubstitutingASummary() async throws {
        try await fixture(synchronous: false) { store in
            let item = store.entries[35]
            let db = try SQLiteDatabase(url: store.repository.databaseURL)
            try db.run("UPDATE entries SET payload=? WHERE id=?", [.data(Data("invalid".utf8)), .text(item.id.uuidString)])
            store.selectedID = item.id
            for _ in 0..<100 where store.isLoadingContent { try await Task.sleep(for: .milliseconds(10)) }
            #expect(store.selected == nil)
            #expect(store.contentError != nil)
            #expect(store.selectedItem == item)
            await #expect(throws: (any Error).self) { try await store.content(for: item) }
        }
    }

    @Test func cacheEvictsLeastRecentlyUsedAndSkipsOversizedBodies() {
        var cache = EntryContentCache(maximumCount: 2, maximumBytes: 4_000)
        let entries = (0..<3).map { ClipboardEntry(kind: .text, text: String(repeating: "\($0)", count: 800)) }
        let items = entries.map { HistoryListItem($0) }
        cache.insert(entries[0], for: items[0]); cache.insert(entries[1], for: items[1])
        #expect(cache.value(for: items[0]) != nil)
        cache.insert(entries[2], for: items[2])
        #expect(cache.value(for: items[1]) == nil)
        #expect(cache.value(for: items[0]) != nil)
        #expect(cache.count == 2 && cache.byteCount <= 4_000)
        let oversized = ClipboardEntry(kind: .text, text: String(repeating: "x", count: 5_000))
        let bigItem = HistoryListItem(oversized)
        cache.insert(oversized, for: bigItem)
        #expect(cache.value(for: bigItem) == nil)
        #expect(cache.count == 2)
        #expect(cache.value(for: HistoryListItem(entries[0])) == nil) // Another revision is not reused.
    }
}
