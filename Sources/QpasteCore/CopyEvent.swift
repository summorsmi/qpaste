import Foundation

public struct CopyEvent: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var entryID: UUID
    public var copiedAt: Date
    public var sourceName: String
    public var sourceBundleID: String?

    public init(entryID: UUID, copiedAt: Date, sourceName: String, sourceBundleID: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.entryID = entryID
        self.copiedAt = copiedAt
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
    }
}
