import Foundation
import CryptoKit

public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, link, image, files

    public var title: String {
        switch self {
        case .text: return "文本"
        case .link: return "链接"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    public var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }
}

public struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: ClipKind
    public var text: String
    public var filePaths: [String]
    public var imageFileName: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var richText: Data?
    public var byteCount: Int
    public var fingerprint: String
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var sourceName: String
    public var sourceBundleID: String?
    public var isFavorite: Bool
    public var snippetName: String?
    public var isSnippet: Bool { snippetName != nil }

    public init(kind: ClipKind, text: String = "", filePaths: [String] = [],
                imageFileName: String? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil,
                richText: Data? = nil, byteCount: Int = 0, fingerprint: String? = nil,
                sourceName: String = "未知应用", sourceBundleID: String? = nil,
                now: Date = Date(), isFavorite: Bool = false, snippetName: String? = nil) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.filePaths = filePaths
        self.imageFileName = imageFileName
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.richText = richText
        self.byteCount = byteCount > 0 ? byteCount : text.utf8.count + (richText?.count ?? 0)
        self.fingerprint = fingerprint ?? Self.digest(Data((kind.rawValue + "\0" + text).utf8))
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        createdAt = now
        lastCopiedAt = now
        self.isFavorite = isFavorite
        self.snippetName = snippetName
    }

    public var title: String {
        if let snippetName { return snippetName }
        switch kind {
        case .image: return "图片 · \(imageWidth ?? 0) × \(imageHeight ?? 0)"
        case .files:
            let first = filePaths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "文件"
            return filePaths.count > 1 ? "\(first) 等 \(filePaths.count) 个文件" : first
        case .text, .link:
            return String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(160) ?? "空白文本")
        }
    }

    public var looksLikeCode: Bool {
        guard kind == .text else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("{") || value.hasPrefix("[") || value.hasPrefix("<")
            || ["func ", "const ", "import ", "def ", "SELECT ", "#!/", "let ", "function ", "class "]
                .contains(where: value.hasPrefix)
    }

    public func matches(_ query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let searchable = [text, title, sourceName, filePaths.joined(separator: " ")].joined(separator: "\n")
        return tokens.allSatisfy { searchable.localizedStandardContains(String($0)) }
    }

    public static func kind(for text: String) -> ClipKind {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: \.isWhitespace), let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return .text }
        return .link
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, favorites, snippets, text, link, image, files
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "全部记录"
        case .favorites: return "我的收藏"
        case .snippets: return "文本片段"
        default: return ClipKind(rawValue: rawValue)?.title ?? ""
        }
    }
    public var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .favorites: return "star"
        case .snippets: return "text.badge.plus"
        default: return ClipKind(rawValue: rawValue)?.symbol ?? "doc"
        }
    }
    public func includes(_ entry: ClipboardEntry) -> Bool {
        if self == .all { return true }
        if self == .snippets { return entry.isSnippet }
        guard !entry.isSnippet else { return false }
        return self == .favorites ? entry.isFavorite : entry.kind.rawValue == rawValue
    }
}
