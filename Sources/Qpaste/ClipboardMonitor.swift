import AppKit
import ImageIO
import QpasteCore

struct CapturedClipboard {
    var entry: ClipboardEntry
    var imageData: Data?
}

@MainActor
final class ClipboardMonitor {
    static let restoredType = NSPasteboard.PasteboardType("app.qpaste.restored")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    static let maximumTextBytes = 2 * 1_024 * 1_024
    static let maximumImageBytes = 20 * 1_024 * 1_024

    let pasteboard: NSPasteboard
    private let store: HistoryStore
    private var timer: Timer?
    private var changeCount: Int
    private var wasPaused: Bool
    private var ticks = 0

    init(store: HistoryStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        wasPaused = store.settings.isPaused
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func resetBaseline() {
        changeCount = pasteboard.changeCount
        wasPaused = store.settings.isPaused
    }

    func poll() {
        ticks += 1
        if ticks % 120 == 0 { store.applyRetention() }
        if store.settings.isPaused || wasPaused != store.settings.isPaused {
            resetBaseline()
            return
        }
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let observedCount = changeCount
        let source = NSWorkspace.shared.frontmostApplication
        do {
            if let captured = try Self.capture(from: pasteboard, sourceName: source?.localizedName ?? "未知应用",
                                                sourceBundleID: source?.bundleIdentifier),
               pasteboard.changeCount == observedCount {
                store.add(captured.entry, imageData: captured.imageData)
            }
        } catch {
            store.notify(error.localizedDescription, isError: true)
        }
    }

    static func capture(from pasteboard: NSPasteboard, sourceName: String, sourceBundleID: String?) throws -> CapturedClipboard? {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let originalSource = pasteboard.string(forType: sourceType)
        let bundleID = originalSource?.isEmpty == false ? originalSource : sourceBundleID
        guard !ClipboardPrivacy.shouldIgnore(types: types, sourceBundleID: bundleID, excludedApps: []) else { return nil }
        var name = sourceName
        if let originalSource, !originalSource.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: originalSource) {
            name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            let encoded = try JSONEncoder().encode(paths)
            return CapturedClipboard(entry: ClipboardEntry(kind: .files, text: paths.joined(separator: "\n"),
                filePaths: paths, byteCount: encoded.count,
                fingerprint: ClipboardEntry.digest(Data("files:".utf8) + encoded), sourceName: name, sourceBundleID: bundleID))
        }

        // Prefer a real image representation over text fallbacks emitted by browsers.
        if types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) {
            if let sourceData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                guard sourceData.count <= maximumImageBytes else { throw CaptureError.imageTooLarge }
                guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 16_384, height <= 16_384,
                      width * height <= 40_000_000 else { throw CaptureError.imageTooLarge }
                guard let bitmap = NSBitmapImageRep(data: sourceData),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
                guard png.count <= maximumImageBytes else { throw CaptureError.imageTooLarge }
                let fingerprint = ClipboardEntry.digest(png)
                return CapturedClipboard(entry: ClipboardEntry(kind: .image,
                    imageFileName: fingerprint + ".png", imageWidth: width, imageHeight: height,
                    byteCount: png.count, fingerprint: "image:" + fingerprint, sourceName: name, sourceBundleID: bundleID), imageData: png)
            }
        }

        let richText = pasteboard.data(forType: .rtf)
        let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL)
            ?? richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count <= maximumTextBytes else { throw CaptureError.textTooLarge }
        let rtf = richText.flatMap { $0.count <= maximumTextBytes ? $0 : nil }
        let kind = ClipboardEntry.kind(for: text)
        let fingerprint = ClipboardEntry.digest(Data((kind.rawValue + ":" + text).utf8) + (rtf ?? Data()))
        return CapturedClipboard(entry: ClipboardEntry(kind: kind, text: text, richText: rtf,
            fingerprint: fingerprint, sourceName: name, sourceBundleID: bundleID))
    }

    func write(_ entry: ClipboardEntry, plainText: Bool) throws {
        let item = NSPasteboardItem()
        if plainText || entry.kind == .text || entry.kind == .link {
            guard entry.kind != .image else { throw CaptureError.noText }
            item.setString(entry.text, forType: .string)
            if !plainText, let rtf = entry.richText { item.setData(rtf, forType: .rtf) }
            if !plainText, entry.kind == .link { item.setString(entry.text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .URL) }
        } else if entry.kind == .image {
            store.flush()
            guard let name = entry.imageFileName, let url = store.repository.imageURL(named: name),
                  let data = try? Data(contentsOf: url) else { throw CaptureError.missingImage }
            item.setData(data, forType: .png)
            if let bitmap = NSBitmapImageRep(data: data), let tiff = bitmap.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        } else if entry.kind == .files {
            let urls = entry.filePaths.map { URL(fileURLWithPath: $0) }
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw CaptureError.missingFile }
            let items = urls.map { url in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setData(Data(), forType: Self.restoredType)
                item.setString(entry.sourceBundleID ?? "", forType: Self.sourceType)
                return item
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(items) else { throw CaptureError.writeFailed }
            resetBaseline()
            return
        }
        item.setData(Data(), forType: Self.restoredType)
        item.setString(entry.sourceBundleID ?? "", forType: Self.sourceType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CaptureError.writeFailed }
        resetBaseline()
    }
}

enum CaptureError: LocalizedError {
    case imageTooLarge, textTooLarge, missingImage, missingFile, noText, writeFailed
    var errorDescription: String? {
        switch self {
        case .imageTooLarge: return "这张图片过大，未加入历史（上限 20 MB / 4000 万像素）"
        case .textTooLarge: return "这段文本超过 2 MB，未加入历史"
        case .missingImage: return "图片文件无法读取"
        case .missingFile: return "原文件已移动或删除，无法再次粘贴；仍可复制文件路径"
        case .noText: return "图片没有可粘贴的文本"
        case .writeFailed: return "无法写入系统剪贴板，请重试"
        }
    }
}
