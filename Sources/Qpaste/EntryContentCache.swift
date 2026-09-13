import Foundation
import QpasteCore

/// Deterministic LRU limits for decoded bodies, independent of image caches.
struct EntryContentCache {
    let maximumCount: Int
    let maximumBytes: Int
    private struct Value {
        let revision: String
        let entry: ClipboardEntry
        let bytes: Int
        var used: UInt64
    }
    private var values: [UUID: Value] = [:]
    private var clock: UInt64 = 0
    private(set) var byteCount = 0
    var count: Int { values.count }

    init(maximumCount: Int = 12, maximumBytes: Int = 8 * 1_024 * 1_024) {
        self.maximumCount = maximumCount; self.maximumBytes = maximumBytes
    }

    mutating func value(for item: HistoryListItem) -> ClipboardEntry? {
        guard var value = values[item.id], value.revision == item.revision else { return nil }
        clock &+= 1; value.used = clock; values[item.id] = value
        return item.displaying(value.entry)
    }

    mutating func insert(_ entry: ClipboardEntry, for item: HistoryListItem) {
        remove(item.id)
        let bytes = entry.text.utf8.count + (entry.richText?.count ?? 0)
            + entry.filePaths.reduce(0) { $0 + $1.utf8.count }
            + (entry.snippetName?.utf8.count ?? 0) + entry.sourceName.utf8.count
            + (entry.sourceBundleID?.utf8.count ?? 0) + entry.fingerprint.utf8.count + 512
        guard maximumCount > 0, bytes <= maximumBytes else { return }
        while values.count >= maximumCount || byteCount + bytes > maximumBytes {
            guard let oldest = values.min(by: { $0.value.used < $1.value.used })?.key else { break }
            remove(oldest)
        }
        clock &+= 1
        values[item.id] = Value(revision: item.revision, entry: entry, bytes: bytes, used: clock)
        byteCount += bytes
    }

    mutating func remove(_ id: UUID) {
        if let removed = values.removeValue(forKey: id) { byteCount -= removed.bytes }
    }

    mutating func removeAll() { values.removeAll(); byteCount = 0 }
}
