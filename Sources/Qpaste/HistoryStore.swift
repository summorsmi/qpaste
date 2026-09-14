import AppKit
import Combine
import QpasteCore

private typealias HistoryQueryToken = HistoryQueryCancellation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryListItem] = []
    @Published private(set) var usage = HistoryUsage()
    @Published private(set) var resultCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var referenceDate = Date()
    @Published var query = "" { didSet { if oldValue != query { reload(reset: true, debounce: true, refreshSummary: false) } } }
    @Published var filter: HistoryFilter = .all { didSet { if oldValue != filter { reload(reset: true, refreshSummary: false) } } }
    @Published var dateFilter: HistoryDateFilter = .all { didSet { if oldValue != dateFilter { reload(reset: true, refreshSummary: false) } } }
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { refreshSelectedContent() } } }
    @Published private(set) var selectedContent: ClipboardEntry?
    @Published private(set) var isLoadingContent = false
    @Published private(set) var contentError: String?
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
    private let queryRepository: HistoryRepository
    private let contentRepository: HistoryRepository
    private let contentQueue = DispatchQueue(label: "app.qpaste.content", qos: .userInitiated)
    private var contentCache = EntryContentCache()
    private var contentGeneration = 0
    private var selectedContentKey: HistoryListItem?
    private var selectedContentTask: Task<Void, Never>?
    private var editContentTask: Task<Void, Never>?
    var cachedContentCount: Int { contentCache.count }
    var cachedContentBytes: Int { contentCache.byteCount }
    private let ioQueue = DispatchQueue(label: "app.qpaste.persistence", qos: .utility)
    private let queryQueue = DispatchQueue(label: "app.qpaste.queries", qos: .userInitiated)
    private let imageQueue = DispatchQueue(label: "app.qpaste.images", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "app.qpaste.thumbnails", qos: .utility)
    private struct ImageRequest: Hashable { let name: String; let pixels: Int; let kind: String }
    private var imageTasks: [ImageRequest: Task<NSImage?, Never>] = [:]
    private var imageFailures = Set<ImageRequest>()
    @Published private var imageRefresh = 0
    private let images = ImageMemoryCache(maximumBytes: 60 * 1_024 * 1_024)
    private let previews = ImageMemoryCache(maximumBytes: 32 * 1_024 * 1_024)
    private let thumbnails = ImageMemoryCache(maximumBytes: 12 * 1_024 * 1_024)
    private var displayedFullImage: (name: String, image: NSImage)?
    private var fullImageRequestName: String?
    private var toastTask: Task<Void, Never>?
    private var dateSubscriptions = Set<AnyCancellable>()
    private var summary = HistorySummary()
    private var summaryGeneration = 0
    private var loadedSummaryGeneration = 0
    private var capturePermits: [UUID: CaptureWritePermit] = [:]
    private var databaseEntries: [HistoryListItem] = []
    private var databaseCount = 0
    private var loadedQuery = HistoryQuery()
    private var queryToken: HistoryQueryToken?
    private let synchronousQueries: Bool
    static let pageSize = 80

    private struct PendingSave {
        var entry: ClipboardEntry
        var imageData: Data?
        var event: CopyEvent?
        let item: HistoryListItem
        init(entry: ClipboardEntry, imageData: Data? = nil, event: CopyEvent? = nil) {
            self.entry = entry; self.imageData = imageData; self.event = event
            item = HistoryListItem(entry)
        }
    }
    private var pendingSaves = [PendingSave]()
    private var hadPendingWriteError = false

    var policy: HistoryPolicy { HistoryPolicy(maximumCount: settings.maximumCount, retentionDays: settings.retentionDays) }
    var filteredEntries: [HistoryListItem] { entries }
    var dateSections: [HistoryDateSection<HistoryListItem>] { HistoryDates.sections(entries, now: referenceDate) }
    var selected: ClipboardEntry? { selectedItem?.id == selectedContent?.id ? selectedContent : nil }
    var selectedItem: HistoryListItem? { entries.first { $0.id == selectedID } ?? entries.first }
    var historyCount: Int { count(for: .all) - count(for: .snippets) }
    var snippetCount: Int { count(for: .snippets) }
    var hasMore: Bool { databaseEntries.count < databaseCount }
    private var currentQuery: HistoryQuery { HistoryQuery(filter: filter, text: query, interval: dateFilter.interval(now: referenceDate)) }

    init(settings: AppSettings, directory: URL, synchronousQueries: Bool = false) throws {
        self.settings = settings
        self.synchronousQueries = synchronousQueries
        repository = try HistoryRepository(directory: directory)
        queryRepository = try HistoryRepository(directory: directory)
        contentRepository = try HistoryRepository(directory: directory)
        do { _ = try repository.summary() }
        catch {
            guard repository.legacyImportFailed else { throw error }
            try repository.preserveUnreadableArchive()
            _ = try repository.summary()
            storageError = "旧历史无法读取，已保留备份。新的记录仍可正常保存。"
        }
        try repository.saveChanges(policy: policy)
        let page = try queryRepository.listPage(limit: Self.pageSize)
        apply(page, summary: try queryRepository.summary(), query: currentQuery, append: false, preferredID: nil)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] date in self?.refreshDates(now: date) }.store(in: &dateSubscriptions)
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refreshDates() }.store(in: &dateSubscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refreshDates() }.store(in: &dateSubscriptions)
    }

    func count(for filter: HistoryFilter) -> Int { summary.counts[filter, default: 0] }

    func refreshDates(now: Date = Date()) {
        referenceDate = now
        if loadedQuery.interval != currentQuery.interval { reload(reset: true, refreshSummary: false) }
    }

    func add(_ entry: ClipboardEntry, imageData: Data? = nil, thumbnail: NSImage? = nil) {
        var incoming = entry
        let previous = pendingSaves.last { $0.entry.fingerprint == entry.fingerprint }?.entry
            ?? (try? repository.entry(fingerprint: entry.fingerprint))
        if let previous {
            incoming.id = previous.id
            incoming.createdAt = previous.createdAt
            incoming.isFavorite = previous.isFavorite
        }
        if let imageData, let name = incoming.imageFileName {
            if let thumbnail = thumbnail ?? ImageThumbnail.make(data: imageData) { cacheThumbnail(thumbnail, named: name) }
        }
        let event = incoming.isSnippet ? nil : CopyEvent(entryID: incoming.id, copiedAt: incoming.lastCopiedAt, sourceName: incoming.sourceName, sourceBundleID: incoming.sourceBundleID)
        invalidateContent()
        pendingSaves.append(PendingSave(entry: incoming, imageData: imageData, event: event))
        _ = drainPending()
        reload()
    }

    /// Captures are decoded serially off-main, then use the same persistence queue
    /// as edits/deletes. No unreferenced image is exposed between its write and row.
    func makeCaptureWriter() -> (CapturedClipboard?) -> (@MainActor () -> Void) {
        let canWrite = drainPending()
        let permitID = UUID(), permit = CaptureWritePermit()
        capturePermits[permitID] = permit
        let repository = repository, queue = ioQueue, policy = policy
        return { [weak self] captured in
            guard let captured else { return { self?.capturePermits.removeValue(forKey: permitID) } }
            var pending = PendingSave(entry: captured.entry, imageData: captured.imageData,
                event: CopyEvent(entryID: captured.entry.id, copiedAt: captured.entry.lastCopiedAt,
                                 sourceName: captured.entry.sourceName, sourceBundleID: captured.entry.sourceBundleID))
            var writeError: Error?
            if canWrite {
                do {
                    try queue.sync {
                        var entry = captured.entry
                        if let previous = try repository.entry(fingerprint: entry.fingerprint) {
                            entry.id = previous.id; entry.createdAt = previous.createdAt; entry.isFavorite = previous.isFavorite
                        }
                        pending = PendingSave(entry: entry, imageData: captured.imageData,
                            event: CopyEvent(entryID: entry.id, copiedAt: entry.lastCopiedAt,
                                             sourceName: entry.sourceName, sourceBundleID: entry.sourceBundleID))
                        guard permit.allows(entry) else { return }
                        if let data = captured.imageData { _ = try repository.saveImage(data) }
                        let removed = try repository.saveChanges(upserting: [entry], copyEvents: pending.event.map { [$0] } ?? [], policy: policy)
                        if removed { try repository.removeUnreferencedImages() }
                    }
                } catch { writeError = error }
            } else {
                pending.event = CopyEvent(entryID: pending.entry.id, copiedAt: pending.entry.lastCopiedAt,
                                          sourceName: pending.entry.sourceName, sourceBundleID: pending.entry.sourceBundleID)
            }
            let saved = pending, error = writeError
            return {
                guard let self else { return }
                self.capturePermits.removeValue(forKey: permitID)
                guard permit.allows(saved.entry) else { return }
                if let name = saved.entry.imageFileName, let thumbnail = captured.thumbnail { self.cacheThumbnail(thumbnail, named: name) }
                self.invalidateContent()
                if !canWrite || error != nil {
                    var retry = saved
                    if let previous = self.pendingSaves.last(where: { $0.entry.fingerprint == saved.entry.fingerprint }) {
                        var entry = saved.entry
                        entry.id = previous.entry.id; entry.createdAt = previous.entry.createdAt; entry.isFavorite = previous.entry.isFavorite
                        retry = PendingSave(entry: entry, imageData: saved.imageData, event: saved.event.map {
                            CopyEvent(entryID: entry.id, copiedAt: $0.copiedAt, sourceName: $0.sourceName, sourceBundleID: $0.sourceBundleID, id: $0.id)
                        })
                    }
                    self.pendingSaves.append(retry)
                }
                if let error {
                    self.hadPendingWriteError = true
                    self.storageError = "保存失败，内容暂存在内存中，将自动重试：\(error.localizedDescription)"
                }
                if self.policy.maximumCount != policy.maximumCount || self.policy.retentionDays != policy.retentionDays {
                    self.applyRetention()
                }
                self.reload()
            }
        }
    }

    func toggleFavorite(_ entry: ClipboardEntry) { toggleFavorite(id: entry.id, isSnippet: entry.isSnippet) }
    func toggleFavorite(_ item: HistoryListItem) { toggleFavorite(id: item.id, isSnippet: item.isSnippet) }

    private func toggleFavorite(id: UUID, isSnippet: Bool) {
        guard !isSnippet, drainPending() else { return }
        do {
            let policy = policy
            let changed: ClipboardEntry? = try ioQueue.sync {
                guard var current = try repository.entry(id: id) else { return nil }
                current.isFavorite.toggle()
                try repository.saveChanges(upserting: [current], policy: policy)
                try repository.removeUnreferencedImages()
                return current
            }
            guard let current = changed else { return }
            invalidateContent()
            reload()
            notify(current.isFavorite ? "已加入收藏" : "已取消收藏")
        } catch { reportWriteError(error) }
    }

    func delete(_ entry: ClipboardEntry) { delete(id: entry.id, isSnippet: entry.isSnippet) }
    func delete(_ item: HistoryListItem) { delete(id: item.id, isSnippet: item.isSnippet) }

    private func delete(id: UUID, isSnippet: Bool) {
        guard drainPending() else { return }
        let index = entries.firstIndex { $0.id == id } ?? 0
        let remaining = entries.filter { $0.id != id }
        let preferred = selectedID != id ? selectedID
            : remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        do {
            let permits = Array(capturePermits.values)
            try ioQueue.sync {
                let fingerprint = try repository.entry(id: id)?.fingerprint
                try repository.saveChanges(deleting: [id])
                if let fingerprint { permits.forEach { $0.deleted(fingerprint) } }
                try repository.removeUnreferencedImages()
            }
            // Publish the surviving selection before the asynchronous refresh.
            // Other entries' bodies are still valid and can stay in the cache.
            contentCache.remove(id)
            entries = remaining
            databaseEntries.removeAll { $0.id == id }
            databaseCount = max(0, databaseCount - 1)
            resultCount = max(0, resultCount - 1)
            selectedID = preferred
            reconcileSelection()
            reload()
            notify(isSnippet ? "片段已删除" : "记录已删除")
        } catch { reportWriteError(error) }
    }

    func clearHistory(includeFavorites: Bool = false) {
        guard drainPending() else { return }
        do {
            let permits = Array(capturePermits.values)
            try ioQueue.sync {
                try repository.clearHistory(includeFavorites: includeFavorites)
                permits.forEach { $0.cleared(includeFavorites: includeFavorites) }
                try repository.removeUnreferencedImages()
            }
            invalidateContent()
            reload(reset: true)
            notify(includeFavorites ? "历史和收藏已清空，文本片段已保留" : "历史已清空，收藏和文本片段已保留")
        } catch { reportWriteError(error) }
    }

    func applyRetention() {
        let hadPendingSaves = !pendingSaves.isEmpty
        guard drainPending() else { return }
        let policy = policy
        do {
            let removed = try ioQueue.sync {
                let removed = try repository.saveChanges(policy: policy)
                try repository.removeUnreferencedImages()
                return removed
            }
            if removed || hadPendingSaves { invalidateContent(); reload() }
        } catch { reportWriteError(error) }
    }

    func saveSnippet(_ draft: SnippetDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !draft.body.isEmpty else { return }
        var saved = draft.entryID.flatMap { id in pendingSaves.last { $0.entry.id == id }?.entry ?? (try? repository.entry(id: id)) }
        if saved?.isSnippet != true { saved = nil }
        var entry = saved ?? ClipboardEntry(kind: .text, fingerprint: "snippet:\(UUID())", sourceName: "文本片段", snippetName: name)
        entry.text = draft.body
        entry.snippetName = name
        entry.byteCount = draft.body.utf8.count
        entry.updatedAt = Date()
        invalidateContent()
        pendingSaves.append(PendingSave(entry: entry))
        let savedToDisk = drainPending()
        query = ""
        dateFilter = .all
        filter = .snippets
        reload(preferredID: entry.id)
        if savedToDisk { notify("文本片段已保存") }
    }

    func editSnippet(from item: HistoryListItem) {
        editContentTask?.cancel()
        editContentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.content(for: item)
                try Task.checkCancellation()
                self.editSnippet(from: entry)
            } catch is CancellationError {} catch { self.notify(error.localizedDescription, isError: true) }
        }
    }

    func editSnippet(from entry: ClipboardEntry? = nil) {
        editContentTask?.cancel()
        snippetDraft = SnippetDraft(entryID: entry?.isSnippet == true ? entry?.id : nil,
                                   name: entry.map { String($0.title.prefix(40)) } ?? "", body: entry?.text ?? "")
    }

    func moveSelection(by delta: Int) {
        guard !isLoading, !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selectedID } ?? 0
        if delta > 0, current == entries.count - 1, hasMore {
            loadMore(selectNext: true)
            return
        }
        selectedID = entries[min(max(current + delta, 0), entries.count - 1)].id
        selectionScrollToken += 1
    }

    func reconcileSelection() {
        if !entries.contains(where: { $0.id == selectedID }) { selectedID = entries.first?.id; selectionScrollToken += 1 }
    }

    func loadMoreIfNeeded(_ entry: HistoryListItem) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), index >= entries.count - 12 else { return }
        loadMore()
    }

    func loadMore(selectNext: Bool = false) {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        fetch(append: true, preferredID: selectNext ? nil : selectedID, selectNext: selectNext)
    }

    private func reload(reset: Bool = false, debounce: Bool = false, preferredID: UUID? = nil, refreshSummary: Bool = true) {
        if refreshSummary { summaryGeneration &+= 1 }
        fetch(append: false, reset: reset, debounce: debounce, preferredID: preferredID ?? selectedID)
    }

    private func fetch(append: Bool, reset: Bool = false, debounce: Bool = false, preferredID: UUID?, selectNext: Bool = false) {
        queryToken?.cancel()
        let token = HistoryQueryToken()
        queryToken = token
        let criteria = currentQuery
        let selectionAtRequest = selectedID
        let offset = append ? databaseEntries.count : 0
        let limit = append || reset ? Self.pageSize : max(Self.pageSize, databaseEntries.count)
        if append { isLoadingMore = true }
        else { isLoading = true; isLoadingMore = false; if reset { entries = []; databaseEntries = []; resultCount = 0 } }
        if !append { refreshSelectedContent() }
        let reader = queryRepository
        let generation = summaryGeneration
        let needsSummary = generation != loadedSummaryGeneration
        let work = { () throws -> (HistoryListPage, HistorySummary?) in
            let page = try reader.listPage(criteria, limit: limit, offset: offset, cancellation: token)
            try token.check()
            return (page, needsSummary ? try reader.summary() : nil)
        }
        let accept: (Result<(HistoryListPage, HistorySummary?), Error>) -> Void = { [weak self] result in
            guard let self, !token.isCancelled else { return }
            self.isLoading = false; self.isLoadingMore = false
            switch result {
            case .success(let (page, summary)):
                let selectionChanged = self.selectedID != selectionAtRequest
                if summary != nil { self.loadedSummaryGeneration = generation }
                self.apply(page, summary: summary ?? self.summary, query: criteria, append: append,
                           preferredID: selectionChanged ? self.selectedID : (selectNext ? page.entries.first?.id : preferredID))
                if selectNext && !selectionChanged { self.selectionScrollToken += 1 }
            case .failure(let error): self.storageError = "历史读取失败：\(error.localizedDescription)"
            }
        }
        if synchronousQueries { accept(Result { try work() }) }
        else {
            queryQueue.asyncAfter(deadline: .now() + (debounce ? 0.12 : 0)) {
                guard !token.isCancelled else { return }
                let result = Result { try work() }
                Task { @MainActor in accept(result) }
            }
        }
    }

    private func apply(_ page: HistoryListPage, summary: HistorySummary, query: HistoryQuery, append: Bool, preferredID: UUID?) {
        self.summary = summary
        usage = summary.usage
        loadedQuery = query
        databaseCount = page.totalCount
        if append { databaseEntries += page.entries } else { databaseEntries = page.entries }
        var visible = Dictionary(databaseEntries.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for pending in pendingSaves {
            let entry = pending.entry
            let dateMatches = query.interval.map { entry.displayDate >= $0.start && entry.displayDate < $0.end } ?? true
            if dateMatches && query.filter.includes(entry) && entry.matches(query.text) { visible[entry.id] = pending.item }
        }
        entries = visible.values.sorted { $0.displayDate == $1.displayDate ? $0.id.uuidString > $1.id.uuidString : $0.displayDate > $1.displayDate }
        resultCount = max(page.totalCount, entries.count)
        if let preferredID { selectedID = preferredID }
        reconcileSelection()
        refreshSelectedContent()
    }

    @discardableResult
    private func drainPending() -> Bool {
        let policy = policy
        do {
            while let pending = pendingSaves.first {
                try ioQueue.sync {
                    if let data = pending.imageData { _ = try repository.saveImage(data) }
                    let removed = try repository.saveChanges(upserting: [pending.entry], copyEvents: pending.event.map { [$0] } ?? [], policy: policy)
                    if removed { try repository.removeUnreferencedImages() }
                }
                pendingSaves.removeFirst()
            }
            if hadPendingWriteError { storageError = nil; hadPendingWriteError = false }
            return true
        } catch {
            hadPendingWriteError = true
            storageError = "保存失败，内容暂存在内存中，将自动重试：\(error.localizedDescription)"
            return false
        }
    }

    private func reportWriteError(_ error: Error) {
        storageError = "操作未完成：\(error.localizedDescription)"
        notify("操作未保存，请检查存储空间", isError: true)
    }

    private func invalidateContent() {
        contentGeneration += 1
        contentCache.removeAll()
        selectedContentKey = nil
    }

    func content(for item: HistoryListItem) async throws -> ClipboardEntry {
        try Task.checkCancellation()
        if let pending = pendingSaves.last(where: { $0.entry.id == item.id && $0.item.revision == item.revision }) {
            return item.displaying(pending.entry)
        }
        if let cached = contentCache.value(for: item) { return cached }
        let reader = contentRepository
        let queue = contentQueue
        let generation = contentGeneration
        let token = HistoryQueryToken()
        let entry: ClipboardEntry = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !token.isCancelled else { throw CancellationError() }
                        guard let entry = try reader.content(for: item) else { throw HistoryContentError.changed }
                        guard !token.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: entry)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { token.cancel() }
        try Task.checkCancellation()
        guard generation == contentGeneration else { throw HistoryContentError.changed }
        contentCache.insert(entry, for: item)
        return entry
    }

    private func refreshSelectedContent() {
        let item = selectedItem
        if selectedContentKey == item, selectedContent != nil || isLoadingContent { return }
        selectedContentTask?.cancel()
        selectedContent = nil; selectedContentKey = item
        contentError = nil; isLoadingContent = false
        guard let item else { return }
        if let pending = pendingSaves.last(where: { $0.item == item }) { selectedContent = item.displaying(pending.entry); return }
        if let cached = contentCache.value(for: item) { selectedContent = cached; return }
        if synchronousQueries {
            do {
                guard let entry = try contentRepository.content(for: item) else { throw HistoryContentError.changed }
                contentCache.insert(entry, for: item); selectedContent = entry
            } catch { contentError = error.localizedDescription }
            return
        }
        isLoadingContent = true
        selectedContentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.content(for: item)
                guard !Task.isCancelled, self.selectedItem == item else { return }
                self.selectedContent = entry
                self.isLoadingContent = false
            } catch {
                guard !Task.isCancelled, self.selectedItem == item else { return }
                self.contentError = error.localizedDescription
                self.isLoadingContent = false
            }
        }
    }

    func image<Entry: HistoryImageReference>(for entry: Entry) -> NSImage? {
        fullImageRequestName = entry.imageFileName
        if let displayedFullImage, displayedFullImage.name == entry.imageFileName { return displayedFullImage.image }
        return requestImage(entry, pixels: 0, kind: "original", cache: images)
    }

    func releaseFullImage() { fullImageRequestName = nil; displayedFullImage = nil }

    func previewImage<Entry: HistoryImageReference>(for entry: Entry) -> NSImage? {
        let pixels = ImageThumbnail.previewPixelSize(width: entry.imageWidth ?? 1, height: entry.imageHeight ?? 1)
        return requestImage(entry, pixels: pixels, kind: "preview", cache: previews)
    }

    func thumbnail<Entry: HistoryImageReference>(for entry: Entry) -> NSImage? {
        requestImage(entry, pixels: ImageThumbnail.maximumPixelSize, kind: "thumbnail", cache: thumbnails)
    }

    func isLoadingPreview<Entry: HistoryImageReference>(for entry: Entry) -> Bool {
        guard let name = entry.imageFileName else { return false }
        return imageTasks.keys.contains { $0.name == name && $0.kind == "preview" }
    }

    func loadPreviewImage<Entry: HistoryImageReference>(for entry: Entry) async throws -> NSImage? {
        try Task.checkCancellation()
        if let image = previewImage(for: entry) { return image }
        guard let name = entry.imageFileName,
              let task = imageTasks.first(where: { $0.key.name == name && $0.key.kind == "preview" })?.value else { return nil }
        let image = await task.value
        try Task.checkCancellation()
        return image
    }

    private func requestImage<Entry: HistoryImageReference>(_ entry: Entry, pixels: Int, kind: String,
                                                             cache: ImageMemoryCache) -> NSImage? {
        guard let name = entry.imageFileName, let url = repository.imageURL(named: name) else { return nil }
        if let image = cache.value(for: name) { return image }
        let key = ImageRequest(name: name, pixels: pixels, kind: kind)
        guard !imageFailures.contains(key), imageTasks[key] == nil else { return nil }
        let data = pendingSaves.last(where: { $0.entry.imageFileName == name })?.imageData
        let load = {
            autoreleasepool {
                if pixels == 0 { return ImageThumbnail.fullImage(data: data, url: url) }
                if let data { return ImageThumbnail.make(data: data, maximumPixelSize: pixels) }
                return ImageThumbnail.make(url: url, maximumPixelSize: pixels)
            }
        }
        if synchronousQueries {
            guard let image = load() else { return nil }
            cache.insert(image, for: name)
            return image
        }
        let queue = kind == "thumbnail" ? thumbnailQueue : imageQueue
        imageTasks[key] = Task { [weak self] in
            let image: NSImage? = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: load()) }
            }
            guard let self else { return image }
            self.imageTasks.removeValue(forKey: key)
            if let image {
                cache.insert(image, for: name)
                if kind == "original", self.fullImageRequestName == name { self.displayedFullImage = (name, image) }
            }
            else { self.imageFailures.insert(key) }
            self.imageRefresh &+= 1
            return image
        }
        return nil
    }

    private func cacheThumbnail(_ image: NSImage, named name: String) {
        imageFailures = imageFailures.filter { $0.name != name }
        thumbnails.insert(image, for: name)
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

    func flush() { _ = drainPending(); ioQueue.sync {} }
}

private enum HistoryContentError: LocalizedError {
    case changed
    var errorDescription: String? { "这条记录已更新或删除，请重新选择。" }
}

struct SnippetDraft: Identifiable {
    let id = UUID()
    var entryID: UUID?
    var name: String
    var body: String
}
