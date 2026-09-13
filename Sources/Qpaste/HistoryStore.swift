import AppKit
import Combine
import QpasteCore

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = [] {
        didSet { usage = HistoryUsage(entries: entries) }
    }
    @Published private(set) var usage = HistoryUsage()
    @Published private(set) var referenceDate = Date()
    @Published var query = "" { didSet { reconcileSelection(); selectionScrollToken += 1 } }
    @Published var filter: HistoryFilter = .all { didSet { reconcileSelection(); selectionScrollToken += 1 } }
    @Published var selectedID: UUID?
    @Published private(set) var selectionScrollToken = 0
    @Published var toast: String?
    @Published private(set) var toastIsError = false
    @Published var storageError: String?
    @Published var shortcutError: String?
    @Published var showSettings = false
    @Published var snippetDraft: SnippetDraft?
    @Published var focusSearchToken = 0

    let settings: AppSettings
    let repository: HistoryRepository
    private let ioQueue = DispatchQueue(label: "app.qpaste.persistence", qos: .utility)
    private let images = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var toastTask: Task<Void, Never>?
    private var canSave = true
    private var dateSubscriptions = Set<AnyCancellable>()

    var policy: HistoryPolicy { HistoryPolicy(maximumCount: settings.maximumCount, retentionDays: settings.retentionDays) }
    var filteredEntries: [ClipboardEntry] {
        entries.filter { filter.includes($0) && $0.matches(query) }.sorted {
            $0.displayDate == $1.displayDate ? $0.id.uuidString > $1.id.uuidString : $0.displayDate > $1.displayDate
        }
    }
    var dateSections: [HistoryDateSection] { HistoryDates.sections(filteredEntries, now: referenceDate) }
    var selected: ClipboardEntry? { filteredEntries.first { $0.id == selectedID } ?? filteredEntries.first }
    var historyCount: Int { entries.filter { !$0.isSnippet }.count }
    var snippetCount: Int { entries.filter(\.isSnippet).count }

    init(settings: AppSettings, directory: URL) throws {
        self.settings = settings
        repository = try HistoryRepository(directory: directory)
        images.totalCostLimit = 60 * 1_024 * 1_024
        thumbnails.totalCostLimit = 12 * 1_024 * 1_024
        do {
            entries = policy.applying(to: try repository.load())
            selectedID = entries.first?.id
            persist()
        } catch {
            do {
                try repository.preserveUnreadableArchive()
                storageError = "旧历史无法读取，已保留备份。新的记录仍可正常保存。"
            } catch {
                canSave = false
                storageError = "无法读取或备份历史文件，暂时仅在内存中记录。请检查存储目录权限。"
            }
        }
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] date in self?.refreshDates(now: date) }.store(in: &dateSubscriptions)
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refreshDates() }.store(in: &dateSubscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refreshDates() }.store(in: &dateSubscriptions)
    }

    func refreshDates(now: Date = Date()) { referenceDate = now }

    func count(for filter: HistoryFilter) -> Int { entries.filter(filter.includes).count }

    func add(_ entry: ClipboardEntry, imageData: Data? = nil) {
        if let imageData, let name = entry.imageFileName, let thumbnail = ImageThumbnail.make(data: imageData) {
            cacheThumbnail(thumbnail, named: name)
        }
        if let imageData, let name = entry.imageFileName, let image = NSImage(data: imageData) {
            images.setObject(image, forKey: name as NSString, cost: (entry.imageWidth ?? 1) * (entry.imageHeight ?? 1) * 4)
        }
        entries = policy.inserting(entry, into: entries)
        reconcileSelection()
        let retained = entries.first { $0.fingerprint == entry.fingerprint }
        let event = retained.map { CopyEvent(entryID: $0.id, copiedAt: entry.lastCopiedAt, sourceName: entry.sourceName, sourceBundleID: entry.sourceBundleID) }
        persist(imageData: imageData, copyEvent: event)
    }

    func toggleFavorite(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), !entry.isSnippet else { return }
        entries[index].isFavorite.toggle()
        let saved = entries[index].isFavorite
        applyRetention()
        notify(saved ? "已加入收藏" : "已取消收藏")
    }

    func delete(_ entry: ClipboardEntry) {
        let index = filteredEntries.firstIndex { $0.id == entry.id } ?? 0
        entries.removeAll { $0.id == entry.id }
        let remaining = filteredEntries
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        selectionScrollToken += 1
        persist()
        notify(entry.isSnippet ? "片段已删除" : "记录已删除")
    }

    func clearHistory(includeFavorites: Bool = false) {
        entries.removeAll { !$0.isSnippet && (includeFavorites || !$0.isFavorite) }
        reconcileSelection()
        persist()
        notify(includeFavorites ? "历史和收藏已清空，文本片段已保留" : "历史已清空，收藏和文本片段已保留")
    }

    func applyRetention() {
        entries = policy.applying(to: entries)
        reconcileSelection()
        persist()
    }

    func saveSnippet(_ draft: SnippetDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !draft.body.isEmpty else { return }
        let savedID: UUID
        if let index = entries.firstIndex(where: { $0.id == draft.entryID && $0.isSnippet }) {
            entries[index].text = draft.body
            entries[index].snippetName = name
            entries[index].byteCount = draft.body.utf8.count
            entries[index].updatedAt = Date()
            savedID = entries[index].id
        } else {
            let entry = ClipboardEntry(kind: .text, text: draft.body,
                                       fingerprint: "snippet:\(UUID().uuidString)",
                                       sourceName: "文本片段", snippetName: name)
            entries.insert(entry, at: 0)
            savedID = entry.id
        }
        query = ""
        filter = .snippets
        selectedID = savedID
        selectionScrollToken += 1
        persist()
        notify("文本片段已保存")
    }

    func editSnippet(from entry: ClipboardEntry? = nil) {
        snippetDraft = SnippetDraft(entryID: entry?.isSnippet == true ? entry?.id : nil,
                                    name: entry.map { String($0.title.prefix(40)) } ?? "",
                                    body: entry?.text ?? "")
    }

    func moveSelection(by delta: Int) {
        let values = filteredEntries
        guard !values.isEmpty else { return }
        let current = values.firstIndex { $0.id == selectedID } ?? 0
        selectedID = values[min(max(current + delta, 0), values.count - 1)].id
        selectionScrollToken += 1
    }

    func reconcileSelection() {
        if !filteredEntries.contains(where: { $0.id == selectedID }) {
            selectedID = filteredEntries.first?.id
            selectionScrollToken += 1
        }
    }

    func image(for entry: ClipboardEntry) -> NSImage? {
        guard let name = entry.imageFileName else { return nil }
        if let cached = images.object(forKey: name as NSString) { return cached }
        guard let url = repository.imageURL(named: name), let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: name as NSString, cost: (entry.imageWidth ?? 1) * (entry.imageHeight ?? 1) * 4)
        return image
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard let name = entry.imageFileName else { return nil }
        if let cached = thumbnails.object(forKey: name as NSString) { return cached }
        guard let url = repository.imageURL(named: name), let image = ImageThumbnail.make(url: url) else { return nil }
        cacheThumbnail(image, named: name)
        return image
    }

    private func cacheThumbnail(_ image: NSImage, named name: String) {
        thumbnails.setObject(image, forKey: name as NSString, cost: Int(image.size.width * image.size.height) * 4)
    }

    func notify(_ message: String, isError: Bool = false) {
        toastTask?.cancel()
        toastIsError = isError
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func persist(imageData: Data? = nil, copyEvent: CopyEvent? = nil) {
        guard canSave else { return }
        let snapshot = entries
        let repository = repository
        ioQueue.async { [weak self] in
            do {
                if let imageData { _ = try repository.saveImage(imageData) }
                try repository.save(snapshot, copyEvent: copyEvent)
                try repository.removeUnreferencedImages(keeping: snapshot)
            } catch {
                Task { @MainActor [weak self] in
                    self?.storageError = "保存失败：\(error.localizedDescription)。当前记录仍在内存中，请检查磁盘空间。"
                }
            }
        }
    }

    func flush() { ioQueue.sync {} }
}

struct SnippetDraft: Identifiable {
    let id = UUID()
    var entryID: UUID?
    var name: String
    var body: String
}
