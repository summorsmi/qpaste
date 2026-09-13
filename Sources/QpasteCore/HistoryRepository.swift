import Foundation

public struct HistoryArchive: Codable {
    public var version: Int = 1
    public var entries: [ClipboardEntry]
    public init(entries: [ClipboardEntry]) { self.entries = entries }
}

public final class HistoryRepository: @unchecked Sendable {
    public let directory: URL
    public var archiveURL: URL { directory.appendingPathComponent("history.json") }
    public var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func load() throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return [] }
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: archiveURL))
        guard archive.version == 1 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "历史记录版本不受支持"])
        }
        return archive.entries.filter { entry in
            guard entry.kind == .image else { return true }
            guard let name = entry.imageFileName, let url = imageURL(named: name) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// A corrupt/unknown archive remains intact until explicitly recovered by the caller.
    public func preserveUnreadableArchive() throws {
        let backup = directory.appendingPathComponent("history-unreadable-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: archiveURL, to: backup)
    }

    public func save(_ entries: [ClipboardEntry]) throws {
        let data = try JSONEncoder().encode(HistoryArchive(entries: entries))
        try data.write(to: archiveURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
    }

    public func imageURL(named name: String) -> URL? {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasSuffix(".png"), !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    public func saveImage(_ data: Data) throws -> String {
        let name = ClipboardEntry.digest(data) + ".png"
        let url = imagesDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return name
    }

    /// Run on the same serial executor as image writes and archive saves.
    public func removeUnreferencedImages(keeping entries: [ClipboardEntry]) throws {
        let retained = Set(entries.compactMap(\.imageFileName))
        for url in try FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) {
            if url.pathExtension == "png", !retained.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
