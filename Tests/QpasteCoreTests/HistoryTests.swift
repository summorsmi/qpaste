import Foundation
import Testing
@testable import QpasteCore

@Suite("历史规则与存储")
struct HistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func classifiesOnlyCompleteWebURLs() {
        #expect(ClipboardEntry.kind(for: " https://example.com/path?q=中文 \n") == .link)
        #expect(ClipboardEntry.kind(for: "请看 https://example.com") == .text)
        #expect(ClipboardEntry.kind(for: "https://") == .text)
        #expect(ClipboardEntry.kind(for: "file:///tmp/example") == .text)
    }

    @Test func searchesAcrossContentSourceAndSnippetName() {
        let entry = ClipboardEntry(kind: .text, text: "Café 项目计划", sourceName: "Notes", snippetName: "周会")
        #expect(entry.matches("cafe NOTES"))
        #expect(entry.matches("周会 计划"))
        #expect(entry.matches("   \n"))
        #expect(!entry.matches("周会 缺失"))
    }

    @Test func repeatCopyKeepsIdentityAndFavoriteButRefreshesSource() {
        let original = ClipboardEntry(kind: .text, text: "same", sourceName: "A", now: now.addingTimeInterval(-500), isFavorite: true)
        let next = ClipboardEntry(kind: .text, text: "same", sourceName: "B", now: now)
        let entries = HistoryPolicy().inserting(next, into: [original], now: now)
        #expect(entries.count == 1)
        #expect(entries[0].id == original.id)
        #expect(entries[0].createdAt == original.createdAt)
        #expect(entries[0].lastCopiedAt == now)
        #expect(entries[0].sourceName == "B")
        #expect(entries[0].isFavorite)
    }

    @Test func retentionProtectsFavoritesAndSnippets() {
        let old = now.addingTimeInterval(-60 * 86_400)
        let entries = [
            ClipboardEntry(kind: .text, text: "expired", now: old),
            ClipboardEntry(kind: .text, text: "favorite", now: old, isFavorite: true),
            ClipboardEntry(kind: .text, text: "snippet", now: old, snippetName: "keep"),
            ClipboardEntry(kind: .text, text: "new", now: now),
            ClipboardEntry(kind: .text, text: "older", now: now.addingTimeInterval(-1))
        ]
        let result = HistoryPolicy(maximumCount: 1, retentionDays: 30).applying(to: entries, now: now)
        #expect(Set(result.map(\.text)) == ["favorite", "snippet", "new"])
    }

    @Test func byteBudgetAndNoAgeLimitAreRespected() {
        let entries = [
            ClipboardEntry(kind: .text, text: "a", byteCount: 60, now: now),
            ClipboardEntry(kind: .text, text: "b", byteCount: 60, now: now.addingTimeInterval(-1)),
            ClipboardEntry(kind: .text, text: "c", byteCount: 30, now: now.addingTimeInterval(-200 * 86_400))
        ]
        let result = HistoryPolicy(retentionDays: 0, maximumBytes: 100).applying(to: entries, now: now)
        #expect(result.map(\.text) == ["a", "c"])
    }

    @Test func allIncludesSnippetsWhileDedicatedFiltersKeepTheirScope() {
        let snippet = ClipboardEntry(kind: .text, text: "hello", snippetName: "greeting")
        let favorite = ClipboardEntry(kind: .text, text: "saved", isFavorite: true)
        let history = ClipboardEntry(kind: .text, text: "ordinary")
        #expect([snippet, favorite, history].allSatisfy(HistoryFilter.all.includes))
        #expect(HistoryFilter.snippets.includes(snippet))
        #expect(!HistoryFilter.text.includes(snippet))
        #expect(!HistoryFilter.favorites.includes(snippet))
        #expect(HistoryFilter.favorites.includes(favorite))
        #expect(!HistoryFilter.snippets.includes(history))
    }

    @Test func usageSeparatesProtectedContentFromCapacityBudget() {
        let entries = [
            ClipboardEntry(kind: .text, text: "普通文本", richText: Data([1, 2, 3])),
            ClipboardEntry(kind: .image, byteCount: 2048, isFavorite: true),
            ClipboardEntry(kind: .text, text: "片段", isFavorite: true, snippetName: "名称"),
            ClipboardEntry(kind: .files, text: "/tmp/file", byteCount: 32)
        ]
        let usage = HistoryUsage(entries: entries)
        #expect(usage.historyBytes == "普通文本".utf8.count + 3 + 32)
        #expect(usage.favoriteBytes == 2048)
        #expect(usage.snippetBytes == "片段".utf8.count)
        #expect(usage.totalBytes == entries.reduce(0) { $0 + $1.byteCount })
        #expect(HistoryUsage().totalBytes == 0)
        let limit = HistoryPolicy(maximumCount: 0, retentionDays: 0, maximumBytes: usage.historyBytes)
        #expect(limit.applying(to: entries).count == entries.count)
    }

    @Test func unlimitedCountStillRespectsSizeAndAge() {
        let entries = (0..<301).map { index in
            ClipboardEntry(kind: .text, text: "item \(index)", byteCount: 1,
                           now: now.addingTimeInterval(-Double(index)))
        }
        #expect(HistoryPolicy(maximumCount: 0).applying(to: entries, now: now).count == 301)
        let sizeLimited = HistoryPolicy(maximumCount: 0, maximumBytes: 3).applying(to: entries, now: now)
        #expect(sizeLimited.map(\.text) == ["item 0", "item 1", "item 2"])
        let old = ClipboardEntry(kind: .text, text: "expired", now: now.addingTimeInterval(-60 * 86_400))
        let ageLimited = HistoryPolicy(maximumCount: 0).applying(to: entries + [old], now: now)
        #expect(!ageLimited.contains { $0.text == "expired" })
        #expect(HistoryPolicy(maximumCount: 0, retentionDays: 0).applying(to: entries + [old], now: now).count == 302)
    }

    @Test func markedSensitiveContentIsCapturedAsRequested() {
        #expect(!ClipboardPrivacy.shouldIgnore(types: ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword"], sourceBundleID: nil, excludedApps: []))
        #expect(!ClipboardPrivacy.shouldIgnore(types: ["org.nspasteboard.TransientType"], sourceBundleID: nil, excludedApps: []))
        #expect(ClipboardPrivacy.shouldIgnore(types: ["app.qpaste.restored"], sourceBundleID: nil, excludedApps: []))
    }

    @Test func archiveRoundTripIncludesRichTextAndSnippets() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(directory: directory)
        let entries = [ClipboardEntry(kind: .text, text: "你好\nworld", richText: Data([1, 2, 3]), now: now, snippetName: "签名")]
        try repository.save(entries)
        #expect(try repository.load() == entries)
        let permissions = try FileManager.default.attributesOfItem(atPath: repository.archiveURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func corruptArchiveIsBackedUpWithoutDataLoss() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(directory: directory)
        let original = Data("not valid json".utf8)
        try original.write(to: repository.archiveURL)
        #expect(throws: (any Error).self) { try repository.load() }
        try repository.preserveUnreadableArchive()
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("history-unreadable-") })
        #expect(try Data(contentsOf: backup) == original)
        #expect(try repository.load().isEmpty)
    }

    @Test func imagePathsAreContainedAndUnusedImagesAreRemoved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(directory: directory)
        #expect(repository.imageURL(named: "../private.png") == nil)
        #expect(repository.imageURL(named: "/tmp/private.png") == nil)
        let keepName = try repository.saveImage(Data([1, 2, 3]))
        let removeName = try repository.saveImage(Data([4, 5, 6]))
        let entry = ClipboardEntry(kind: .image, imageFileName: keepName)
        try repository.removeUnreferencedImages(keeping: [entry])
        #expect(FileManager.default.fileExists(atPath: repository.imageURL(named: keepName)!.path))
        #expect(!FileManager.default.fileExists(atPath: repository.imageURL(named: removeName)!.path))
        try repository.save([entry, ClipboardEntry(kind: .image, imageFileName: "missing.png")])
        #expect(try repository.load() == [entry])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qpaste-core-tests-\(UUID().uuidString)")
    }
}
