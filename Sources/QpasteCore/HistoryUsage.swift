import Foundation

/// Saved content bytes, using the same accounting as HistoryPolicy's capacity limit.
/// This excludes archive metadata and the original files referenced by file records.
public struct HistoryUsage: Equatable, Sendable {
    public private(set) var historyBytes = 0
    public private(set) var favoriteBytes = 0
    public private(set) var snippetBytes = 0
    public var totalBytes: Int { historyBytes + favoriteBytes + snippetBytes }

    public init(entries: [ClipboardEntry] = []) {
        for entry in entries {
            let bytes = max(0, entry.byteCount)
            if entry.isSnippet { snippetBytes += bytes }
            else if entry.isFavorite { favoriteBytes += bytes }
            else { historyBytes += bytes }
        }
    }

    public init(historyBytes: Int, favoriteBytes: Int, snippetBytes: Int) {
        self.historyBytes = historyBytes
        self.favoriteBytes = favoriteBytes
        self.snippetBytes = snippetBytes
    }
}
