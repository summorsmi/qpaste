import Foundation

public protocol HistoryDatedEntry: Identifiable where ID == UUID {
    var displayDate: Date { get }
}

public protocol HistoryImageReference {
    var imageFileName: String? { get }
    var imageWidth: Int? { get }
    var imageHeight: Int? { get }
}

extension ClipboardEntry: HistoryDatedEntry, HistoryImageReference {}

/// A list item deliberately has no body, RTF or file paths. Actions must resolve
/// its full content before copying, pasting, editing or presenting details.
public struct HistoryListItem: Identifiable, Codable, Equatable, Sendable, HistoryDatedEntry, HistoryImageReference {
    public let id: UUID
    public let revision: String
    public let kind: ClipKind
    public let title: String
    public let looksLikeCode: Bool
    public let isFavorite: Bool
    public let isSnippet: Bool
    public let imageFileName: String?
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let byteCount: Int
    public let updatedAt: Date?
    public var lastCopiedAt: Date
    public var sourceName: String
    public var sourceBundleID: String?
    public var displayDate: Date { isSnippet ? (updatedAt ?? lastCopiedAt) : lastCopiedAt }

    public init(_ entry: ClipboardEntry, revision: String = UUID().uuidString) {
        id = entry.id; self.revision = revision; kind = entry.kind
        title = String(entry.title.prefix(160)); looksLikeCode = entry.looksLikeCode
        isFavorite = entry.isFavorite; isSnippet = entry.isSnippet
        imageFileName = entry.imageFileName; imageWidth = entry.imageWidth; imageHeight = entry.imageHeight
        byteCount = entry.byteCount; updatedAt = entry.updatedAt; lastCopiedAt = entry.lastCopiedAt
        sourceName = entry.sourceName; sourceBundleID = entry.sourceBundleID
    }

    public func displaying(_ entry: ClipboardEntry) -> ClipboardEntry {
        var result = entry
        if !isSnippet {
            result.lastCopiedAt = lastCopiedAt
            result.sourceName = sourceName
            result.sourceBundleID = sourceBundleID
        }
        return result
    }
}

public struct HistoryListPage: Sendable {
    public let entries: [HistoryListItem]
    public let totalCount: Int
}
