import AppKit
import ImageIO
import QpasteCore

struct CapturedClipboard {
    var entry: ClipboardEntry
    var imageData: Data?
    var thumbnail: NSImage?

    var retainedBytes: Int {
        entry.text.utf8.count + (entry.richText?.count ?? 0) + (imageData?.count ?? 0)
            + entry.filePaths.reduce(0) { $0 + $1.utf8.count + 64 }
            + (entry.snippetName?.utf8.count ?? 0) + entry.sourceName.utf8.count
            + (entry.sourceBundleID?.utf8.count ?? 0) + entry.fingerprint.utf8.count + 1_024
    }
}

struct ClipboardSnapshot {
    enum Payload { case files([String]), image(Data), text(String?, Data?) }
    let payload: Payload
    let sourceName: String
    let sourceBundleID: String?
    let date: Date

    // Reserve both the snapshot and the largest accepted encoded result before
    // enqueueing. Decoded image pixels are temporary worker memory, not this budget.
    var reservedBytes: Int {
        let overhead = 4_096 + 2 * (sourceName.utf8.count + (sourceBundleID?.utf8.count ?? 0))
        switch payload {
        case .image(let data):
            return overhead + data.count + ClipboardMonitor.maximumImageBytes
                + ImageThumbnail.maximumPixelSize * ImageThumbnail.maximumPixelSize * 4
        case .text(let text, let rich):
            return overhead + (text?.utf8.count ?? ClipboardMonitor.maximumTextBytes) + (rich?.count ?? 0)
        case .files(let paths):
            return overhead + paths.reduce(0) { $0 + $1.utf8.count * 8 + 128 }
        }
    }
}

struct ClipboardImageData {
    let png: Data
    let tiff: Data?
}

@MainActor
final class ClipboardMonitor {
    static let restoredType = NSPasteboard.PasteboardType("app.qpaste.restored")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    nonisolated static let maximumTextBytes = 2 * 1_024 * 1_024
    nonisolated static let maximumImageBytes = 20 * 1_024 * 1_024

    let pasteboard: NSPasteboard
    private let store: HistoryStore
    private var timer: Timer?
    private var changeCount: Int
    private var wasPaused: Bool
    private var ticks = 0
    private let captureQueue = DispatchQueue(label: "app.qpaste.capture", qos: .userInitiated)
    private let pasteQueue = DispatchQueue(label: "app.qpaste.image-paste", qos: .userInitiated)
    private let completions = CaptureCompletions()
    private let synchronousCapture: Bool
    private let decode: (ClipboardSnapshot) throws -> CapturedClipboard?

    init(store: HistoryStore, pasteboard: NSPasteboard = .general, synchronousCapture: Bool = false,
         decode: @escaping (ClipboardSnapshot) throws -> CapturedClipboard? = ClipboardMonitor.decodeSnapshot) {
        self.store = store
        self.synchronousCapture = synchronousCapture
        self.decode = decode
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        wasPaused = store.settings.isPaused
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        // Captures accepted before termination must reach disk before store.flush().
        captureQueue.sync {}
        completions.drain()
    }

    func resetBaseline() {
        changeCount = pasteboard.changeCount
        wasPaused = store.settings.isPaused
    }

    func poll() {
        ticks += 1
        if ticks % 120 == 0 { store.applyRetention() }
        if ticks % 10 == 0 { store.retryBufferedCaptures() }
        if store.capturePauseReason != nil {
            store.resumeCaptureIfPossible()
            // Copies made while automatically paused must not be replayed later.
            resetBaseline()
            return
        }
        if store.settings.isPaused || wasPaused != store.settings.isPaused {
            resetBaseline()
            return
        }
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let observedCount = changeCount
        let source = NSWorkspace.shared.frontmostApplication
        do {
            guard let snapshot = try Self.readSnapshot(from: pasteboard, sourceName: source?.localizedName ?? "未知应用",
                                                       sourceBundleID: source?.bundleIdentifier),
                  pasteboard.changeCount == observedCount else { return }
            guard let write = store.makeCaptureWriter(reserving: snapshot.reservedBytes) else { return }
            if synchronousCapture {
                do { write(try decode(snapshot))() }
                catch { write(nil)(); throw error }
                return
            }
            let decode = decode, completions = completions
            captureQueue.async { [weak self] in
                autoreleasepool {
                    do {
                        let accept = write(try decode(snapshot))
                        completions.append(accept)
                        DispatchQueue.main.async { completions.drain() }
                    } catch {
                        let discard = write(nil)
                        completions.append { discard(); self?.store.notify(error.localizedDescription, isError: true) }
                        DispatchQueue.main.async { completions.drain() }
                    }
                }
            }
        } catch { store.notify(error.localizedDescription, isError: true) }
    }

    static func capture(from pasteboard: NSPasteboard, sourceName: String, sourceBundleID: String?) throws -> CapturedClipboard? {
        guard let snapshot = try readSnapshot(from: pasteboard, sourceName: sourceName, sourceBundleID: sourceBundleID) else { return nil }
        return try decodeSnapshot(snapshot)
    }

    private static func readSnapshot(from pasteboard: NSPasteboard, sourceName: String, sourceBundleID: String?) throws -> ClipboardSnapshot? {
        let date = Date()
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let originalSource = pasteboard.string(forType: sourceType)
        let bundleID = originalSource?.isEmpty == false ? originalSource : sourceBundleID
        guard !ClipboardPrivacy.shouldIgnore(types: types, sourceBundleID: bundleID, excludedApps: []) else { return nil }
        var name = sourceName
        if let originalSource, !originalSource.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: originalSource) {
            name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        }
        let payload: ClipboardSnapshot.Payload
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            payload = .files(urls.map(\.path))
        } else if (types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)),
                  let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            guard data.count <= maximumImageBytes else { throw CaptureError.imageTooLarge }
            payload = .image(data)
        } else {
            let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL)
            guard (text?.utf8.count ?? 0) <= maximumTextBytes else { throw CaptureError.textTooLarge }
            let rich = pasteboard.data(forType: .rtf)
            if text == nil, (rich?.count ?? 0) > maximumTextBytes { throw CaptureError.richTextTooLarge }
            payload = .text(text, rich.flatMap { $0.count <= maximumTextBytes ? $0 : nil })
        }
        return ClipboardSnapshot(payload: payload, sourceName: name, sourceBundleID: bundleID, date: date)
    }

    nonisolated static func decodeSnapshot(_ snapshot: ClipboardSnapshot) throws -> CapturedClipboard? {
        switch snapshot.payload {
        case .files(let paths):
            let encoded = try JSONEncoder().encode(paths)
            return CapturedClipboard(entry: ClipboardEntry(kind: .files, text: paths.joined(separator: "\n"),
                filePaths: paths, byteCount: encoded.count, fingerprint: ClipboardEntry.digest(Data("files:".utf8) + encoded),
                sourceName: snapshot.sourceName, sourceBundleID: snapshot.sourceBundleID, now: snapshot.date))
        case .image(let data):
            guard data.count <= maximumImageBytes else { throw CaptureError.imageTooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height <= 40_000_000 else { throw CaptureError.imageTooLarge }
            guard let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            guard png.count <= maximumImageBytes else { throw CaptureError.imageTooLarge }
            let fingerprint = ClipboardEntry.digest(png)
            return CapturedClipboard(entry: ClipboardEntry(kind: .image,
                imageFileName: fingerprint + ".png", imageWidth: width, imageHeight: height,
                byteCount: png.count, fingerprint: "image:" + fingerprint,
                sourceName: snapshot.sourceName, sourceBundleID: snapshot.sourceBundleID, now: snapshot.date),
                imageData: png, thumbnail: ImageThumbnail.make(data: png))
        case .text(let text, let rich):
            return try captureText(text, richData: rich, sourceName: snapshot.sourceName, sourceBundleID: snapshot.sourceBundleID, now: snapshot.date)
        }
    }

    nonisolated static func captureText(_ plainText: String?, richData: Data?, sourceName: String, sourceBundleID: String?, now: Date = Date()) throws -> CapturedClipboard? {
        let richText = richData.flatMap { $0.count <= maximumTextBytes ? $0 : nil }
        // Avoid parsing an unbounded RTF document just to extract a small body.
        if plainText == nil, richData != nil, richText == nil { throw CaptureError.richTextTooLarge }
        let text = plainText
            ?? richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count <= maximumTextBytes else { throw CaptureError.textTooLarge }
        let rtf = richText
        let kind = ClipboardEntry.kind(for: text)
        let fingerprint = ClipboardEntry.digest(Data((kind.rawValue + ":" + text).utf8) + (rtf ?? Data()))
        return CapturedClipboard(entry: ClipboardEntry(kind: kind, text: text, richText: rtf,
            fingerprint: fingerprint, sourceName: sourceName, sourceBundleID: sourceBundleID, now: now))
    }

    func writeAsync(_ entry: ClipboardEntry, plainText: Bool) async throws {
        try Task.checkCancellation()
        guard entry.kind == .image && !plainText else {
            try Task.checkCancellation()
            try write(entry, plainText: plainText)
            return
        }
        store.flush()
        guard let name = entry.imageFileName, let url = store.repository.imageURL(named: name) else { throw CaptureError.missingImage }
        let prepared: ClipboardImageData = try await withCheckedThrowingContinuation { continuation in
            pasteQueue.async {
                continuation.resume(with: Result { try autoreleasepool { try Self.imageDataForPaste(url) } })
            }
        }
        try Task.checkCancellation()
        try write(entry, plainText: false, preparedImage: prepared)
    }

    nonisolated private static func imageDataForPaste(_ url: URL) throws -> ClipboardImageData {
        guard let png = try? Data(contentsOf: url) else { throw CaptureError.missingImage }
        return ClipboardImageData(png: png, tiff: NSBitmapImageRep(data: png)?.tiffRepresentation)
    }

    func write(_ entry: ClipboardEntry, plainText: Bool, preparedImage: ClipboardImageData? = nil) throws {
        let item = NSPasteboardItem()
        if plainText || entry.kind == .text || entry.kind == .link {
            guard entry.kind != .image else { throw CaptureError.noText }
            item.setString(entry.text, forType: .string)
            if !plainText, let rtf = entry.richText { item.setData(rtf, forType: .rtf) }
            if !plainText, entry.kind == .link { item.setString(entry.text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .URL) }
        } else if entry.kind == .image {
            store.flush()
            guard let name = entry.imageFileName, let url = store.repository.imageURL(named: name) else { throw CaptureError.missingImage }
            let data = try preparedImage ?? Self.imageDataForPaste(url)
            item.setData(data.png, forType: .png)
            if let tiff = data.tiff { item.setData(tiff, forType: .tiff) }
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
    case imageTooLarge, textTooLarge, richTextTooLarge, missingImage, missingFile, noText, writeFailed
    var errorDescription: String? {
        switch self {
        case .imageTooLarge: return "这张图片过大，未加入历史（上限 20 MB / 4000 万像素）"
        case .textTooLarge: return "这段文本超过 2 MB，未加入历史"
        case .richTextTooLarge: return "这段富文本超过 2 MB，未加入历史；可复制为纯文本后重试"
        case .missingImage: return "图片文件无法读取"
        case .missingFile: return "原文件已移动或删除，无法再次粘贴；仍可复制文件路径"
        case .noText: return "图片没有可粘贴的文本"
        case .writeFailed: return "无法写入系统剪贴板，请重试"
        }
    }
}
