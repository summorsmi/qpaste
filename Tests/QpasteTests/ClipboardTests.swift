import AppKit
import Testing
import QpasteCore
@testable import Qpaste

@Suite("本机剪贴板集成", .serialized)
@MainActor
struct ClipboardTests {
    private func withFixture(_ body: (HistoryStore, ClipboardMonitor, NSPasteboard) throws -> Void) throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qpaste-app-tests-\(id)")
        let defaults = UserDefaults(suiteName: "qpaste-tests-\(id)")!
        let pasteboard = NSPasteboard(name: .init("qpaste-tests-\(id)"))
        pasteboard.clearContents()
        let available = pasteboard.setString("Qpaste isolated test fixture", forType: .string)
        try #require(available, "The macOS pasteboard service must be available to the test process")
        pasteboard.clearContents()
        let settings = AppSettings(defaults: defaults)
        let store = try HistoryStore(settings: settings, directory: directory, synchronousQueries: true)
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        defer {
            monitor.stop()
            store.flush()
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: "qpaste-tests-\(id)")
            try? FileManager.default.removeItem(at: directory)
        }
        try body(store, monitor, pasteboard)
    }

    @Test func captureDeduplicateAndPersistText() throws {
        try withFixture { store, monitor, pasteboard in
            for _ in 0..<2 {
                pasteboard.clearContents()
                pasteboard.setString("Qpaste integration test", forType: .string)
                monitor.poll()
            }
            #expect(store.entries.count == 1)
            store.flush()
            let loaded = try store.repository.load()
            #expect(loaded.first?.text == "Qpaste integration test")
        }
    }

    @Test func capturesSensitiveMarkedText() throws {
        try withFixture { store, monitor, pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("synthetic marked sample", forType: .string)
            pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
            monitor.poll()
            #expect(store.selected?.text == "synthetic marked sample")
        }
    }

    @Test func pauseAndResumeDoNotBackfillPausedClipboard() throws {
        try withFixture { store, monitor, pasteboard in
            store.settings.isPaused = true
            pasteboard.clearContents()
            pasteboard.setString("while paused", forType: .string)
            monitor.poll()
            store.settings.isPaused = false
            monitor.poll()
            #expect(store.entries.isEmpty)
            pasteboard.clearContents()
            pasteboard.setString("after resume", forType: .string)
            monitor.poll()
            #expect(store.entries.map(\.title) == ["after resume"])
        }
    }

    @Test func plainTextRemovesRichTextAndOwnWriteDoesNotLoop() throws {
        try withFixture { store, monitor, pasteboard in
            let rich = NSAttributedString(string: "Styled text", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
            let rtf = try #require(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
            pasteboard.clearContents()
            pasteboard.setString(rich.string, forType: .string)
            pasteboard.setData(rtf, forType: .rtf)
            monitor.poll()
            let entry = try #require(store.selected)
            #expect(entry.richText != nil)
            try monitor.write(entry, plainText: false)
            #expect(pasteboard.data(forType: .rtf) == rtf)
            try monitor.write(entry, plainText: true)
            #expect(pasteboard.string(forType: .string) == "Styled text")
            #expect(pasteboard.data(forType: .rtf) == nil)
            monitor.poll()
            #expect(store.entries.count == 1)
        }
    }

    @Test func oversizedRichTextIsBoundedBeforeParsingButPlainFallbackStillWorks() throws {
        try withFixture { _, _, pasteboard in
            let ignored = String(repeating: "x", count: ClipboardMonitor.maximumTextBytes)
            let rtf = Data(("{\\rtf1\\ansi {\\*\\qpastesample " + ignored + "}visible}").utf8)
            pasteboard.setData(rtf, forType: .rtf)
            // macOS may synthesize a string flavor for an RTF-only pasteboard.
            // Exercise the raw RTF fallback directly, then the real plain flavor.
            #expect(throws: CaptureError.self) {
                try ClipboardMonitor.captureText(nil, richData: rtf, sourceName: "Test", sourceBundleID: nil)
            }
            pasteboard.setString("plain fallback", forType: .string)
            let fallback = try ClipboardMonitor.capture(from: pasteboard, sourceName: "Test", sourceBundleID: nil)
            let captured = try #require(fallback)
            #expect(captured.entry.text == "plain fallback")
            #expect(captured.entry.richText == nil)
        }
    }

    @Test func imagesSurviveCaptureDiskAndClipboardRestore() throws {
        try withFixture { store, monitor, pasteboard in
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<8 { for y in 0..<6 { bitmap.setColor(NSColor(srgbRed: 0.9, green: 0.4, blue: 0.2, alpha: 1), atX: x, y: y) } }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            monitor.poll()
            let entry = try #require(store.selected)
            #expect(entry.kind == .image)
            #expect(entry.imageWidth == 8 && entry.imageHeight == 6)
            #expect(store.image(for: entry) != nil)
            store.flush()
            #expect(try store.repository.load().first?.id == entry.id)
            try monitor.write(entry, plainText: false)
            #expect(pasteboard.data(forType: .png) != nil)
            #expect(pasteboard.data(forType: .tiff) != nil)
            store.delete(entry)
            store.flush()
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.repository.imagesDirectory.path).isEmpty)
        }
    }

    @Test func multiFileRestoreAndMissingFileLeaveClipboardUntouched() throws {
        try withFixture { store, monitor, pasteboard in
            let urls = ["第一份 sample.txt", "second.txt"].map { store.repository.directory.appendingPathComponent($0) }
            for url in urls { try Data("sample".utf8).write(to: url) }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            monitor.poll()
            let entry = try #require(store.selected)
            #expect(entry.kind == .files)
            #expect(entry.filePaths == urls.map(\.path))
            try monitor.write(entry, plainText: false)
            let restored = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            #expect(restored == urls)
            try monitor.write(entry, plainText: true)
            #expect(pasteboard.string(forType: .string) == urls.map(\.path).joined(separator: "\n"))
            try FileManager.default.removeItem(at: urls[0])
            let baseline = pasteboard.changeCount
            #expect(throws: CaptureError.self) { try monitor.write(entry, plainText: false) }
            #expect(pasteboard.changeCount == baseline)
        }
    }

    @Test func snippetsEditSearchAndSurviveClear() throws {
        try withFixture { store, monitor, pasteboard in
            store.add(ClipboardEntry(kind: .text, text: "history"))
            store.saveSnippet(SnippetDraft(name: "签名", body: "Hello"))
            let found = store.entries.first { $0.isSnippet }
            let original = try #require(found)
            store.saveSnippet(SnippetDraft(entryID: original.id, name: "工作签名", body: "Hello again"))
            store.query = "工作 again"
            #expect(store.filteredEntries.count == 1)
            #expect(store.selected?.id == original.id)
            store.clearHistory(includeFavorites: true)
            #expect(store.entries.count == 1)
            #expect(store.selected?.text == "Hello again")
            store.flush()
            #expect(try store.repository.load().first?.snippetName == "工作签名")
        }
    }

    @Test func searchSelectionNeverTargetsHiddenItem() throws {
        try withFixture { store, _, _ in
            store.add(ClipboardEntry(kind: .text, text: "first"))
            store.add(ClipboardEntry(kind: .link, text: "https://example.com"))
            store.query = "example"
            #expect(store.selected?.kind == .link)
            store.filter = .text
            #expect(store.selected == nil)
            store.query = ""
            #expect(store.selected?.text == "first")
        }
    }

    @Test func mouseSelectionDoesNotScrollButKeyboardSelectionDoes() throws {
        try withFixture { store, _, _ in
            store.add(ClipboardEntry(kind: .text, text: "first"))
            store.add(ClipboardEntry(kind: .text, text: "second", now: Date().addingTimeInterval(1)))
            let before = store.selectionScrollToken
            store.selectedID = store.filteredEntries[0].id
            #expect(store.selectionScrollToken == before)
            store.moveSelection(by: 1)
            #expect(store.selectedID == store.filteredEntries[1].id)
            #expect(store.selectionScrollToken > before)
        }
    }

    @Test func unifiedSearchIncludesSnippetNamesContentAndFavorites() throws {
        try withFixture { store, _, _ in
            store.add(ClipboardEntry(kind: .text, text: "项目 普通历史"))
            store.add(ClipboardEntry(kind: .text, text: "项目 收藏", isFavorite: true))
            store.saveSnippet(SnippetDraft(name: "项目签名", body: "独有正文"))
            store.filter = .all
            store.query = "项目"
            #expect(store.filteredEntries.count == 3)
            #expect(store.count(for: .all) == 3)
            store.query = "项目 独有"
            #expect(store.selected?.snippetName == "项目签名")
            store.filter = .favorites
            #expect(store.filteredEntries.isEmpty)
            store.query = "项目"
            #expect(store.filteredEntries.count == 1)
            #expect(store.selected?.isFavorite == true)
        }
    }

    @Test func capacityUsageRefreshesAfterFavoriteAndSnippetEdits() throws {
        try withFixture { store, _, _ in
            let entry = ClipboardEntry(kind: .text, text: "12345")
            store.add(entry)
            #expect(store.usage.historyBytes == 5)
            store.toggleFavorite(entry)
            #expect(store.usage.historyBytes == 0)
            #expect(store.usage.favoriteBytes == 5)
            store.saveSnippet(SnippetDraft(name: "片段", body: "你好"))
            #expect(store.usage.snippetBytes == 6)
            let found = store.entries.first { $0.isSnippet }
            let snippet = try #require(found)
            store.saveSnippet(SnippetDraft(entryID: snippet.id, name: "片段", body: "abc"))
            #expect(store.usage.snippetBytes == 3)
            #expect(store.usage.totalBytes == 8)
            store.flush()
            #expect(HistoryUsage(entries: try store.repository.load()) == store.usage)
        }
    }

    @Test func listThumbnailIsSmallAndPreservesOriginalImage() throws {
        try withFixture { store, monitor, pasteboard in
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = ClipboardEntry.digest(png) + ".png"
            let entry = ClipboardEntry(kind: .image, imageFileName: name, imageWidth: 800, imageHeight: 400, byteCount: png.count)
            store.add(entry, imageData: png)
            let thumbnail = try #require(store.thumbnail(for: entry))
            #expect(thumbnail.size == NSSize(width: 168, height: 84))
            #expect(store.thumbnail(for: entry) === thumbnail)
            store.flush()
            let url = try #require(store.repository.imageURL(named: name))
            #expect(ImageThumbnail.make(url: url)?.size == thumbnail.size)
            #expect(ImageThumbnail.make(data: Data("invalid".utf8)) == nil)
            #expect(try Data(contentsOf: url) == png)
            try monitor.write(entry, plainText: false)
            let restored = try #require(pasteboard.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)))
            #expect(restored.pixelsWide == 800 && restored.pixelsHigh == 400)
        }
    }

    @Test func displayPreviewIsBoundedAndExplicitPreviewAndPasteKeepOriginalPixels() throws {
        try withFixture { store, monitor, pasteboard in
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2800, pixelsHigh: 1600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            memset(try #require(bitmap.bitmapData), 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = ClipboardEntry.digest(png) + ".png"
            let entry = ClipboardEntry(kind: .image, imageFileName: name, imageWidth: 2800, imageHeight: 1600, byteCount: png.count)
            store.add(entry, imageData: png)
            let preview = try #require(store.previewImage(for: entry))
            #expect(preview.size == NSSize(width: 1400, height: 800))
            #expect(store.previewImage(for: entry) === preview)
            let original = try #require(store.image(for: entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(original.width == 2800 && original.height == 1600)
            try monitor.write(entry, plainText: false)
            #expect(pasteboard.data(forType: .png) == png)
            let tall = ImageThumbnail.previewPixelSize(width: 1000, height: 16000)
            #expect(Double(tall) * Double(tall) / 16 <= 8_000_000)
            #expect(tall > 11000) // Long screenshots still have enough detail to scroll.
            #expect(ImageThumbnail.previewPixelSize(width: 400, height: 200) == 400)
        }
    }

    @Test func dateFilterFindsEarlierCopyWithoutOverwritingLatestMetadata() throws {
        try withFixture { store, _, _ in
            store.settings.retentionDays = 0
            let today = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            store.add(ClipboardEntry(kind: .text, text: "same content", sourceName: "Earlier App", now: yesterday))
            store.add(ClipboardEntry(kind: .text, text: "same content", sourceName: "Latest App", now: today))
            store.flush()
            #expect(store.entries.count == 1)
            let id = try #require(store.entries.first?.id)
            store.dateFilter = .custom(start: yesterday, end: yesterday)
            store.query = "earlier"
            let oldCopy = try #require(store.selected)
            #expect(oldCopy.id == id)
            #expect(abs(oldCopy.lastCopiedAt.timeIntervalSince(yesterday)) < 0.000001)
            store.toggleFavorite(oldCopy)
            store.flush()
            let persisted = try #require(store.repository.load().first)
            #expect(abs(persisted.lastCopiedAt.timeIntervalSince(today)) < 0.000001)
            #expect(persisted.sourceName == "Latest App")
            #expect(persisted.isFavorite)
            #expect(try store.repository.copyEvents(for: id).count == 2)
            store.dateFilter = .all
            store.query = ""
            let selected = try #require(store.selected)
            #expect(abs(selected.lastCopiedAt.timeIntervalSince(today)) < 0.000001)
        }
    }

    @Test func relativeDateFilterRefreshesAtMidnightAndDoesNotCleanHistory() throws {
        try withFixture { store, _, _ in
            store.settings.retentionDays = 0
            let today = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            store.add(ClipboardEntry(kind: .text, text: "yesterday", now: yesterday))
            store.add(ClipboardEntry(kind: .text, text: "today", now: today))
            store.flush()
            store.refreshDates(now: yesterday)
            store.dateFilter = .today
            #expect(store.filteredEntries.map(\.title) == ["yesterday"])
            store.refreshDates(now: today)
            #expect(store.filteredEntries.map(\.title) == ["today"])
            #expect(store.historyCount == 2)
            let savedCount = try store.repository.load().count
            #expect(savedCount == 2)
            #expect(store.settings.retentionDays == 0)
        }
    }
}
