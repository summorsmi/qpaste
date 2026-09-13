import SwiftUI
import AppKit
import QpasteCore
import ApplicationServices

// Qualify the property-wrapper type to avoid the same-named macro in newer SDKs.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Palette {
    static let accent = Color(red: 0.88, green: 0.38, blue: 0.22)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let subtle = Color.primary.opacity(0.035)
    static let line = Color.primary.opacity(0.075)
}

struct MainView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var settings: AppSettings
    let paste: (ClipboardEntry, Bool) -> Void
    let copy: (ClipboardEntry, Bool) -> Void
    @FocusState private var searchFocused: Bool
    @ViewState<ClipboardEntry?> private var previewImage = nil
    @ViewState<Bool> private var accessibilityEnabled = AXIsProcessTrusted()
    @StateObject private var hoverPreview = HoverPreviewController()
    @ViewState<Bool> private var showDateRange = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                searchBar
                if store.dateFilter.isActive { activeDateRange }
                Rectangle().fill(Palette.line).frame(height: 1)
                if settings.isCompact {
                    historyList.frame(maxWidth: .infinity, maxHeight: .infinity)
                    compactNotices
                } else {
                    HStack(spacing: 0) {
                        historyList.frame(width: 320)
                        Rectangle().fill(Palette.line).frame(width: 1)
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    footer
                }
            }
        }
        .background(Palette.surface)
        .tint(Palette.accent)
        .frame(minWidth: settings.isCompact ? 420 : 900, minHeight: settings.isCompact ? 360 : 540)
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .overlay(alignment: .bottom) {
            if !settings.isCompact, let toast = store.toast {
                Label(toast, systemImage: store.toastIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Palette.line))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .padding(.bottom, 50)
                    .accessibilityLabel(toast)
            }
        }
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store, settings: settings) }
        .sheet(item: $store.snippetDraft) { draft in
            SnippetEditor(draft: draft) { store.saveSnippet($0) }
        }
        .sheet(item: $previewImage) { entry in
            if let image = store.image(for: entry) { ImagePreview(image: image, entry: entry) }
        }
        .sheet(isPresented: $showDateRange) {
            DateRangeEditor(selection: store.dateFilter) { store.dateFilter = $0 }
        }
        .onChange(of: store.focusSearchToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true; accessibilityEnabled = AXIsProcessTrusted() }
        .onChange(of: settings.isCompact) { _, _ in accessibilityEnabled = AXIsProcessTrusted(); hoverPreview.dismiss() }
        .onChange(of: store.query) { _, _ in hoverPreview.dismiss() }
        .onChange(of: store.filter) { _, _ in hoverPreview.dismiss() }
        .onChange(of: store.dateFilter) { _, _ in hoverPreview.dismiss() }
        .onChange(of: store.showSettings) { _, _ in hoverPreview.dismiss() }
        .onChange(of: store.snippetDraft?.id) { _, _ in hoverPreview.dismiss() }
        .onDisappear { hoverPreview.dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityEnabled = AXIsProcessTrusted()
        }
    }

    @ViewBuilder private var sidebar: some View {
        if settings.isCompact { compactSidebar } else { regularSidebar }
    }

    private var compactSidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                sidebarItem(.all)
                sidebarItem(.favorites)
                sidebarItem(.snippets)
                Rectangle().fill(Palette.line).frame(width: 20, height: 1).padding(.vertical, 6)
                ForEach([HistoryFilter.text, .link, .image, .files]) { sidebarItem($0) }
            }
            Spacer(minLength: 4)
            Button { settings.isPaused.toggle() } label: {
                Image(systemName: settings.isPaused ? "play.fill" : "pause")
                    .font(.system(size: 13)).frame(width: 36, height: 30)
            }.buttonStyle(.plain).foregroundStyle(settings.isPaused ? Color.orange : Color.secondary)
                .help(settings.isPaused ? "继续记录" : "暂停记录")
                .accessibilityLabel(settings.isPaused ? "继续记录" : "暂停记录")
            Button { store.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 14)).frame(width: 36, height: 30)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("设置").accessibilityLabel("设置")
        }.padding(.vertical, 6).frame(width: 52).frame(maxHeight: .infinity).background(Palette.canvas)
    }

    private var regularSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Palette.accent.gradient)
                    Image(systemName: "clipboard").font(.system(size: 21, weight: .medium)).foregroundStyle(.white)
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Qpaste").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("随手复制，随时取用").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 42).padding(.bottom, 28)
            VStack(spacing: 5) {
                sidebarItem(.all)
                sidebarItem(.favorites)
                sidebarItem(.snippets)
            }.padding(.horizontal, 10)
            Text("内容类型").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                .padding(.leading, 23).padding(.top, 28).padding(.bottom, 10)
            VStack(spacing: 5) {
                ForEach([HistoryFilter.text, .link, .image, .files]) { sidebarItem($0) }
            }.padding(.horizontal, 10)
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(settings.isPaused ? Color.orange : Color.green).frame(width: 5, height: 5)
                    Text(settings.isPaused ? "记录已暂停" : "正在记录剪贴板").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { settings.isPaused.toggle() } label: {
                        Image(systemName: settings.isPaused ? "play.fill" : "pause.fill").font(.system(size: 10))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(settings.isPaused ? "继续记录" : "暂停记录")
                        .accessibilityLabel(settings.isPaused ? "继续记录" : "暂停记录")
                }
                HStack {
                    Button { store.showSettings = true } label: {
                        Label("设置", systemImage: "slider.horizontal.3").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("设置")
                    Spacer()
                    Text(settings.shortcut.label).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }.padding(20)
        }
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(Palette.canvas)
    }

    private func sidebarItem(_ filter: HistoryFilter) -> some View {
        let selected = store.filter == filter
        return Button { store.filter = filter } label: {
            HStack(spacing: 10) {
                Image(systemName: filter.symbol).font(.system(size: settings.isCompact ? 15 : 14)).frame(width: 20)
                if !settings.isCompact {
                    Text(filter.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    Spacer(minLength: 3)
                    Text("\(store.count(for: filter))").font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(selected ? Palette.accent : Color.secondary.opacity(0.7))
                }
            }
            .foregroundStyle(selected ? Palette.accent : Color.primary.opacity(0.72))
            .padding(.horizontal, settings.isCompact ? 0 : 12).padding(.vertical, settings.isCompact ? 0 : 11)
            .frame(width: settings.isCompact ? 36 : nil, height: settings.isCompact ? 32 : nil)
            .background(selected ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(filter.title).accessibilityLabel(filter.title).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchBar: some View {
        HStack(spacing: settings.isCompact ? 9 : 12) {
            Image(systemName: "magnifyingglass").font(.system(size: settings.isCompact ? 14 : 17, weight: .regular)).foregroundStyle(.tertiary)
            TextField(settings.isCompact ? "搜索\(store.filter.title)" : "搜索内容、文件名或应用…", text: $store.query)
                .textFieldStyle(.plain).font(.system(size: settings.isCompact ? 12 : 14))
                .focused($searchFocused).accessibilityLabel("搜索剪贴板历史")
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
            }
            if !settings.isCompact {
                KeyCap(text: "⌘ F")
                Rectangle().fill(Palette.line).frame(width: 1, height: 20).padding(.horizontal, 4)
            }
            Menu {
                ForEach([HistoryDateFilter.all, .today, .last7Days, .last30Days], id: \.title) { range in
                    Button { store.dateFilter = range } label: {
                        if store.dateFilter == range { Label(range.title, systemImage: "checkmark") }
                        else { Text(range.title) }
                    }
                }
                Divider()
                Button("自定义日期…") { showDateRange = true }
            } label: {
                Image(systemName: "calendar").font(.system(size: 14)).frame(width: 24, height: 26)
                    .foregroundStyle(store.dateFilter.isActive ? Palette.accent : Color.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("按日期筛选").accessibilityLabel("按日期筛选")
            Button { store.editSnippet() } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 24, height: 26)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help(settings.isCompact ? "新建文本片段" : "新建文本片段 · ⌘N").accessibilityLabel("新建文本片段")
            Button { settings.isCompact.toggle() } label: {
                Image(systemName: settings.isCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .medium)).frame(width: 24, height: 26)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help(settings.isCompact ? "完整模式" : "精简模式")
                .accessibilityLabel(settings.isCompact ? "切换为完整模式" : "切换为精简模式")
        }
        .padding(.horizontal, settings.isCompact ? 13 : 26)
        .padding(.top, 8).padding(.bottom, settings.isCompact ? 8 : 10)
    }

    private var activeDateRange: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar")
            Text(store.dateFilter.title).lineLimit(1)
            Spacer(minLength: 4)
            Button { store.dateFilter = .all } label: {
                Image(systemName: "xmark.circle.fill")
            }.buttonStyle(.plain).help("清除日期筛选").accessibilityLabel("清除日期筛选")
        }.font(.system(size: 11)).foregroundStyle(Palette.accent)
            .padding(.horizontal, settings.isCompact ? 13 : 26).padding(.bottom, 8)
    }

    private var historyList: some View {
        let entries = store.filteredEntries
        return VStack(spacing: 0) {
            if !settings.isCompact {
                HStack {
                    Text(store.filter.title).font(.system(size: 12, weight: .semibold))
                    Text("\(store.resultCount)").font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("最近优先").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 20).padding(.vertical, 17)
            }
            if entries.isEmpty {
                VStack(spacing: 10) {
                    if store.isLoading { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: store.query.isEmpty ? store.filter.symbol : "magnifyingglass")
                            .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                        Text(!store.query.isEmpty ? "没有找到相关内容" : store.dateFilter.isActive ? "这段时间没有记录" : "这里还没有内容")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if !settings.isCompact && !store.query.isEmpty {
                            Button("清除搜索") { store.query = "" }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: settings.isCompact ? 2 : 5) {
                            ForEach(store.dateSections) { section in
                                Section {
                                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { offset, entry in
                                        entryRow(entry, index: section.startIndex + offset).id(entry.id)
                                            .allowsHitTesting(!store.isLoading)
                                            .onAppear { store.loadMoreIfNeeded(entry) }
                                    }
                                } header: {
                                    HStack {
                                        Text(section.title).font(.system(size: 10, weight: .medium))
                                        Spacer()
                                    }.foregroundStyle(.secondary)
                                        .padding(.horizontal, settings.isCompact ? 10 : 12)
                                        .padding(.top, 8).padding(.bottom, 3)
                                        .accessibilityAddTraits(.isHeader)
                                }
                            }
                            if store.isLoadingMore { ProgressView().controlSize(.small).padding(8) }
                        }.padding(.horizontal, settings.isCompact ? 6 : 9)
                            .padding(.top, settings.isCompact ? 4 : 0).padding(.bottom, settings.isCompact ? 4 : 12)
                    }
                    .onChange(of: store.selectionScrollToken) { _, _ in
                        if let id = store.selectedID { proxy.scrollTo(id) }
                    }
                }
            }
        }.background(Palette.surface)
    }

    private func entryRow(_ entry: ClipboardEntry, index: Int) -> some View {
        let selected = store.selectedID == entry.id
        return HStack(alignment: .top, spacing: 11) {
            Group {
                if entry.kind == .image, let image = store.thumbnail(for: entry) {
                    if settings.isCompact {
                        ZStack {
                            Checkerboard()
                            Image(nsImage: image).resizable().scaledToFit().padding(3)
                        }.frame(width: 84, height: 56)
                            .accessibilityLabel("图片缩略预览")
                    } else {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 38, height: 42).clipped()
                    }
                } else {
                    Image(systemName: entry.isSnippet ? "text.badge.plus" : entry.looksLikeCode ? "chevron.left.forwardslash.chevron.right" : entry.kind.symbol)
                        .font(.system(size: 16, weight: .regular)).foregroundStyle(color(for: entry))
                        .frame(width: settings.isCompact ? 34 : 38, height: settings.isCompact ? 34 : 42)
                        .background(color(for: entry).opacity(0.07))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: settings.isCompact ? 4 : 7) {
                Text(entry.title).font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(2).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if store.filter == .all {
                        Text(entry.isSnippet ? "片段" : entry.isFavorite ? "收藏" : "历史")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(entry.isSnippet ? Color.purple : entry.isFavorite ? Palette.accent : Color.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Palette.subtle, in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                    }
                    Text(entry.sourceName).lineLimit(1)
                    Text("·")
                    Text((entry.isSnippet ? "修改于 " : "") + timeLabel(entry.displayDate)).lineLimit(1)
                    Spacer(minLength: 0)
                    if entry.isFavorite && store.filter != .all { Image(systemName: "star.fill").foregroundStyle(Palette.accent).font(.system(size: 9)) }
                    if !settings.isCompact && selected && index < 9 { Text("⌘\(index + 1)").font(.system(size: 9, design: .monospaced)) }
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, settings.isCompact ? 10 : 12).padding(.vertical, settings.isCompact ? 8 : 12)
        .frame(maxWidth: .infinity, minHeight: settings.isCompact ? 62 : 78, alignment: .leading)
        .background(selected ? Palette.accent.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Palette.accent.opacity(0.22) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .overlay {
            HistoryRowMouseSurface(select: {
                if store.selectedID != entry.id { store.selectedID = entry.id }
            }, activate: { paste(entry, false) }, hoverID: settings.isCompact ? entry.id : nil,
               hoverChanged: settings.isCompact ? { inside, view in
                   if inside { hoverPreview.enter(entry, from: view, image: { store.previewImage(for: entry) }) }
                   else { hoverPreview.leave(view) }
               } : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.selectedID = entry.id }
        .contextMenu {
            Button("粘贴") { paste(entry, false) }
            if entry.kind != .image { Button(entry.kind == .files ? "粘贴文件路径" : "粘贴为纯文本") { paste(entry, true) } }
            Button("复制") { copy(entry, false) }
            Divider()
            if !entry.isSnippet { Button(entry.isFavorite ? "取消收藏" : "加入收藏") { store.toggleFavorite(entry) } }
            if entry.kind == .text || entry.kind == .link { Button(entry.isSnippet ? "编辑文本片段" : "存为文本片段") { store.editSnippet(from: entry) } }
            Divider()
            Button("删除", role: .destructive) { store.delete(entry) }
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = store.selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: entry.isSnippet ? "text.badge.plus" : entry.kind.symbol)
                    Text(entry.isSnippet ? "文本片段" : entry.looksLikeCode ? "代码文本" : entry.kind.title)
                    Spacer()
                    if entry.kind == .text || entry.kind == .link {
                        iconButton(entry.isSnippet ? "square.and.pencil" : "text.badge.plus", help: entry.isSnippet ? "编辑文本片段" : "存为文本片段") { store.editSnippet(from: entry) }
                    }
                    if !entry.isSnippet {
                        iconButton(entry.isFavorite ? "star.fill" : "star", help: entry.isFavorite ? "取消收藏" : "加入收藏") { store.toggleFavorite(entry) }
                    }
                    iconButton("trash", help: "删除记录") { store.delete(entry) }
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 27).padding(.top, 19).padding(.bottom, 25)

                if entry.isSnippet {
                    Text(entry.title).font(.system(size: 20, weight: .semibold)).padding(.horizontal, 28).padding(.bottom, 18)
                }
                contentPreview(entry).id(entry.id).padding(.horizontal, 27)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 16) {
                    Text((entry.isSnippet ? "修改于 " : "复制于 ") + entry.displayDate.formatted(date: .numeric, time: .standard))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        Image(systemName: entry.isSnippet ? "text.badge.plus" : "app.dashed")
                        Text(entry.sourceName)
                        Spacer()
                        Text(entry.kind == .image ? ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file) : entry.kind == .files ? "\(entry.filePaths.count) 个文件" : "\(entry.text.count) 字符")
                    }.font(.system(size: 10)).foregroundStyle(.tertiary)
                    Rectangle().fill(Palette.line).frame(height: 1)
                    HStack(spacing: 9) {
                        Button { paste(entry, false) } label: {
                            HStack(spacing: 20) { Text("粘贴"); Text("↩").opacity(0.75) }
                                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 9)
                        }.buttonStyle(.plain).foregroundStyle(.white).background(Palette.accent, in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityLabel("粘贴选中内容")
                        if entry.kind != .image {
                            Button { paste(entry, true) } label: {
                                Text(entry.kind == .files ? "粘贴路径" : "纯文本粘贴").font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 9)
                            }.buttonStyle(.plain).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 7))
                                .help("⇧↩ · 去掉格式后粘贴")
                        }
                        Spacer(minLength: 0)
                        iconButton("doc.on.doc", help: "复制 · ⌘C") { copy(entry, false) }
                    }
                }.padding(27).padding(.top, 4)
            }
        } else {
            welcome
        }
    }

    @ViewBuilder private func contentPreview(_ entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .text, .link:
            VStack(alignment: .leading, spacing: 14) {
                if entry.kind == .link {
                    Label(URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "链接", systemImage: "globe")
                        .font(.system(size: 18, weight: .medium)).lineLimit(2)
                }
                NativeTextPreview(text: entry.text, monospaced: entry.looksLikeCode)
            }
        case .image:
            if let image = store.previewImage(for: entry) {
                VStack(spacing: 13) {
                    ZStack {
                        Checkerboard()
                        Image(nsImage: image).resizable().scaledToFit().padding(14)
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
                        .contentShape(Rectangle()).onTapGesture { previewImage = entry }
                        .accessibilityLabel("放大图片预览").accessibilityAddTraits(.isButton)
                        .accessibilityAction { previewImage = entry }
                    Button { previewImage = entry } label: {
                        Label("\(entry.imageWidth ?? 0) × \(entry.imageHeight ?? 0) · 点击放大", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            } else {
                ContentUnavailableView("图片无法读取", systemImage: "photo.badge.exclamationmark")
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entry.filePaths, id: \.self) { path in
                        let url = URL(fileURLWithPath: path)
                        HStack(alignment: .top, spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                                Text(path).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                                if !FileManager.default.fileExists(atPath: path) {
                                    Text("原文件已移动或删除").font(.system(size: 10)).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.subtle, in: RoundedRectangle(cornerRadius: 9))
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting(entry.filePaths.map { URL(fileURLWithPath: $0) }) } label: {
                        Label("在 Finder 中显示", systemImage: "folder").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.top, 4)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: store.filter == .snippets ? "text.badge.plus" : "square.on.square")
                .font(.system(size: 35, weight: .ultraLight)).foregroundStyle(Palette.accent).padding(.bottom, 23)
            Text(store.filter == .snippets ? "常用的话，\n不用再打一遍。" : "复制过的，\n都能再找到。")
                .font(.system(size: 28, weight: .semibold)).lineSpacing(6).padding(.bottom, 16)
            Text(store.query.isEmpty ? (store.filter == .snippets ? "把签名、常用回复和代码存成片段，随时取用。" : "复制一段文字、一张图片或一个文件，\n它就会出现在这里。") : "试试更短的关键词，或切换左侧的内容类型。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(6).padding(.bottom, 27)
            if store.filter == .snippets {
                Button("创建第一个片段") { store.editSnippet() }.buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 8) { KeyCap(text: settings.shortcut.label); Text("随时呼出 Qpaste").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding(30)
    }

    @ViewBuilder private var compactNotices: some View {
        if let issue = store.storageError { compactNotice(issue) }
        if let issue = store.shortcutError {
            compactNotice(issue)
        } else if !accessibilityEnabled {
            compactNotice("直接粘贴需要辅助功能权限")
        }
        if store.toastIsError, let issue = store.toast { compactNotice(issue) }
    }

    private func compactNotice(_ message: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }.background(Palette.surface)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1)
            if let issue = store.storageError ?? store.shortcutError {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(issue).lineLimit(2)
                    Spacer()
                }.font(.system(size: 10)).foregroundStyle(.orange).padding(.horizontal, 18).padding(.vertical, 7)
            }
            HStack(spacing: 17) {
                footerHint("↑↓", "选择")
                footerHint("↩", "粘贴")
                footerHint("⇧↩", "纯文本")
                footerHint("⌘C", "复制")
                Spacer()
                Text("仅存储在此 Mac").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 20).frame(height: 38)
        }.background(Palette.surface)
    }

    private func footerHint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, design: .monospaced))
            Text(text).font(.system(size: 10))
        }.foregroundStyle(.tertiary)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 25, height: 26) }
            .buttonStyle(.plain).foregroundStyle(symbol == "star.fill" ? Palette.accent : Color.secondary)
            .help(help).accessibilityLabel(help)
    }

    private func color(for entry: ClipboardEntry) -> Color {
        if entry.isSnippet { return .purple }
        if entry.looksLikeCode { return Color(red: 0.4, green: 0.5, blue: 0.68) }
        switch entry.kind {
        case .text: return Color(red: 0.53, green: 0.48, blue: 0.4)
        case .link: return Color(red: 0.32, green: 0.53, blue: 0.68)
        case .image: return .purple
        case .files: return Color(red: 0.67, green: 0.53, blue: 0.28)
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if minutes < 1440 { return "\(minutes / 60) 小时前" }
        return "\(minutes / 1440) 天前"
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Palette.subtle, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line))
    }
}

struct NativeTextPreview: NSViewRepresentable {
    let text: String
    let monospaced: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]))
            view.scrollToBeginningOfDocument(nil)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.subtle))
            for x in stride(from: 0, to: size.width, by: 12) {
                for y in stride(from: 0, to: size.height, by: 12) where (Int(x / 12) + Int(y / 12)) % 2 == 0 {
                    context.fill(Path(CGRect(x: x, y: y, width: 12, height: 12)), with: .color(Color.primary.opacity(0.025)))
                }
            }
        }
    }
}
