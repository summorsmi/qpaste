import Foundation

public struct HistoryPolicy: Sendable {
    /// Zero disables count-based cleanup; size and age limits still apply.
    public var maximumCount: Int
    public var retentionDays: Int
    public var maximumBytes: Int

    public init(maximumCount: Int = 300, retentionDays: Int = 30, maximumBytes: Int = 5 * 1_024 * 1_024 * 1_024) {
        self.maximumCount = max(0, maximumCount)
        self.retentionDays = max(0, retentionDays)
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Favorites are explicitly kept until the user removes them.
    public func applying(to entries: [ClipboardEntry], now: Date = Date()) -> [ClipboardEntry] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var count = 0
        var bytes = 0
        return entries.sorted { $0.lastCopiedAt > $1.lastCopiedAt }.filter { entry in
            if entry.isFavorite || entry.isSnippet { return true }
            guard retentionDays == 0 || entry.lastCopiedAt >= cutoff else { return false }
            guard maximumCount == 0 || count < maximumCount else { return false }
            guard bytes + entry.byteCount <= maximumBytes else { return false }
            count += 1
            bytes += entry.byteCount
            return true
        }
    }

    public func inserting(_ entry: ClipboardEntry, into entries: [ClipboardEntry], now: Date = Date()) -> [ClipboardEntry] {
        var result = entries
        var incoming = entry
        if let index = result.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            let previous = result.remove(at: index)
            incoming.id = previous.id
            incoming.createdAt = previous.createdAt
            incoming.isFavorite = previous.isFavorite
        }
        result.insert(incoming, at: 0)
        return applying(to: result, now: now)
    }
}

public enum ClipboardPrivacy {
    // This personal app captures marked content too. Only its own writes are ignored.
    public static let ignoredTypes: Set<String> = ["app.qpaste.restored"]

    public static func shouldIgnore(types: [String], sourceBundleID: String?, excludedApps: Set<String>) -> Bool {
        if !ignoredTypes.isDisjoint(with: types) { return true }
        guard let sourceBundleID else { return false }
        return excludedApps.contains(sourceBundleID)
    }
}
