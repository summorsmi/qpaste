import AppKit
import Darwin
import Testing
@testable import Qpaste
import QpasteCore

// Explicit opt-in: synthetic data only, no system clipboard or user history.
@Suite("隔离性能测量", .serialized, .enabled(if: ProcessInfo.processInfo.environment["QPASTE_BENCHMARK"] == "1"))
@MainActor
struct PerformanceTests {
    @Test func historyAndPreviewMeasurements() throws {
        try measureHistory(count: 10_000, textBytes: 1_024, loadAll: false)
        try measureHistory(count: 400, textBytes: 128 * 1_024, loadAll: true)
        try fixture { repository, settings in
            let imageEntry = try autoreleasepool {
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6000, pixelsHigh: 4000,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                memset(try #require(bitmap.bitmapData), 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = try repository.saveImage(data)
                let entry = ClipboardEntry(kind: .image, imageFileName: name, imageWidth: 6000, imageHeight: 4000,
                                           byteCount: data.count)
                try repository.saveChanges(upserting: [entry])
                return entry
            }
            let store = try autoreleasepool { try HistoryStore(settings: settings, directory: repository.directory, synchronousQueries: true) }
            report("before-preview")
            let start = ProcessInfo.processInfo.systemUptime
            let image = try #require(store.previewImage(for: imageEntry))
            let decoded = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            report("image-preview", start: start, extra: "pixels=\(decoded.width)x\(decoded.height) decodedMiB=\(decoded.bytesPerRow * decoded.height / 1_048_576)")
        }
    }

    private func measureHistory(count: Int, textBytes: Int, loadAll: Bool) throws {
        try fixture { repository, settings in
            let now = Date()
            for first in stride(from: 0, to: count, by: 80) {
                try autoreleasepool {
                    let entries = (first..<min(count, first + 80)).map { index in
                        ClipboardEntry(kind: .text, text: "sample-\(index) " + String(repeating: "x", count: textBytes),
                                       now: now.addingTimeInterval(-Double(index)))
                    }
                    try repository.saveChanges(upserting: entries)
                }
            }
            report("seed-\(count)x\(textBytes)")
            var start = ProcessInfo.processInfo.systemUptime
            let store = try autoreleasepool { try HistoryStore(settings: settings, directory: repository.directory, synchronousQueries: true) }
            report("first-page", start: start, extra: "loaded=\(store.entries.count)")
            start = ProcessInfo.processInfo.systemUptime
            autoreleasepool { store.query = "sample-\(count - 1) " }
            #expect(store.resultCount == 1)
            report("search-last", start: start)
            autoreleasepool { store.query = "" }
            if loadAll {
                start = ProcessInfo.processInfo.systemUptime
                while store.hasMore { autoreleasepool { store.loadMore() } }
                report("load-all", start: start, extra: "loaded=\(store.entries.count) retainedTextMiB=\(store.entries.reduce(0) { $0 + $1.text.utf8.count } / 1_048_576)")
            }
            start = ProcessInfo.processInfo.systemUptime
            autoreleasepool { store.add(ClipboardEntry(kind: .text, text: "new captured sample")) }
            report("capture-and-refresh", start: start)
            start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<10 { for entry in store.entries { _ = entry.title; _ = entry.looksLikeCode } }
            report("row-summaries-x10", start: start)
        }
    }

    private func fixture(_ body: (HistoryRepository, AppSettings) throws -> Void) throws {
        let name = "qpaste-performance-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.maximumCount = 0; settings.retentionDays = 0
        try body(HistoryRepository(directory: directory), settings)
    }

    private func report(_ label: String, start: TimeInterval? = nil, extra: String = "") {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        let ms = start.map { String(format: "%.1fms", (ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? ""
        let memory = status == KERN_SUCCESS ? "rssMiB=\(info.resident_size / 1_048_576) footprintMiB=\(info.phys_footprint / 1_048_576)" : "memory-unavailable"
        print("QPASTE_BENCH \(label) \(ms) \(memory) \(extra)")
    }
}
