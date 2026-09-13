import AppKit
import SwiftUI
import Combine
import QpasteCore

/// A single non-key child panel lets users move from a row into scrollable details
/// without stealing search focus or changing the selected history record.
@MainActor
final class HoverPreviewController: ObservableObject {
    private(set) var panel: HoverDetailPanel?
    private weak var anchor: NSView?
    private var entryID: UUID?
    private var showWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private let showDelay: TimeInterval
    private let closeDelay: TimeInterval
    private let canPresent: @MainActor (NSWindow) -> Bool

    init(showDelay: TimeInterval = 0.35, closeDelay: TimeInterval = 0.25,
         canPresent: (@MainActor (NSWindow) -> Bool)? = nil) {
        self.showDelay = showDelay
        self.closeDelay = closeDelay
        self.canPresent = canPresent ?? { $0.isVisible && $0.isKeyWindow }
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.dismiss() }.store(in: &subscriptions)
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification] {
            center.publisher(for: name).sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.anchor?.window else { return }
                self.dismiss()
            }.store(in: &subscriptions)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown || event.window !== self.panel { self.dismiss() }
            return event
        }
    }

    deinit {
        showWork?.cancel()
        closeWork?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func enter(_ entry: ClipboardEntry, from view: NSView, image: @escaping () -> NSImage?) {
        closeWork?.cancel()
        if anchor === view && entryID == entry.id { return }
        dismiss()
        anchor = view
        entryID = entry.id
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, self.anchor === view,
                  let window = view.window, self.canPresent(window),
                  window.attachedSheet == nil, !view.visibleRect.isEmpty else { return }
            self.present(entry, from: view, image: image())
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    func leave(_ view: NSView) {
        guard anchor === view else { return }
        showWork?.cancel()
        scheduleClose()
    }

    func pointerEnteredPreview() { closeWork?.cancel() }
    func pointerLeftPreview() { scheduleClose() }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
    }

    func dismiss() {
        showWork?.cancel(); showWork = nil
        closeWork?.cancel(); closeWork = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        anchor = nil
        entryID = nil
    }

    private func present(_ entry: ClipboardEntry, from view: NSView, image: NSImage?) {
        guard let parent = view.window, let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let maximum = HoverPreviewLayout.maximumAvailable(parent: parent.frame, screen: screen)
        let text = Self.bodyText(for: entry)
        let layout: HoverPreviewLayout
        if entry.kind == .image, image != nil {
            layout = .image(width: entry.imageWidth ?? 1, height: entry.imageHeight ?? 1, maximum: maximum)
        } else { layout = .text(text, monospaced: entry.looksLikeCode, maximum: maximum) }
        let rect = parent.convertToScreen(view.convert(view.visibleRect, to: nil))
        let frame = HoverPreviewLayout.frame(size: layout.size, anchor: rect, parent: parent.frame, screen: screen)
        let panel = HoverDetailPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "条目详情"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.level = parent.level
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let hosting = HoverDetailHostingView(rootView: HoverDetailContent(entry: entry, text: text, image: image, layout: layout))
        hosting.sizingOptions = []
        hosting.entered = { [weak self] in self?.pointerEnteredPreview() }
        hosting.exited = { [weak self] in self?.pointerLeftPreview() }
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        self.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    static func bodyText(for entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .text, .link:
            return entry.isSnippet ? "\(entry.snippetName ?? "")\n\n\(entry.text)" : entry.text
        case .files:
            return entry.filePaths.map { path in
                let missing = FileManager.default.fileExists(atPath: path) ? "" : "\n原文件已移动或删除"
                return "\(URL(fileURLWithPath: path).lastPathComponent)\n\(path)\(missing)"
            }.joined(separator: "\n\n")
        case .image: return "图片无法读取"
        }
    }
}

final class HoverDetailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverDetailHostingView: NSHostingView<HoverDetailContent> {
    var entered: () -> Void = {}
    var exited: () -> Void = {}
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { entered() }
    override func mouseExited(with event: NSEvent) { exited() }
}

private struct HoverDetailContent: View {
    let entry: ClipboardEntry
    let text: String
    let image: NSImage?
    let layout: HoverPreviewLayout

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: entry.isSnippet ? "text.badge.plus" : entry.kind.symbol)
                Text(entry.isSnippet ? "文本片段" : entry.kind.title)
                if entry.isFavorite { Image(systemName: "star.fill").foregroundStyle(Palette.accent) }
                Spacer()
                Text(entry.kind == .image ? "\(entry.imageWidth ?? 0) × \(entry.imageHeight ?? 0)" : entry.kind == .files ? "\(entry.filePaths.count) 个文件" : "\(entry.text.count) 字符")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(Palette.line).frame(height: 1)
            if let image, let size = layout.imageSize {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .frame(minWidth: layout.size.width - 28, alignment: .center)
                        .accessibilityLabel("完整图片")
                }.background(Checkerboard()).padding(14)
            } else {
                NativeTextPreview(text: text, monospaced: entry.looksLikeCode).padding(14)
                    .accessibilityLabel(entry.kind == .files ? "完整文件信息" : "完整文字内容")
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 8) {
                Text(entry.sourceName).lineLimit(1).help(entry.sourceName)
                Spacer(minLength: 0)
                Text((entry.isSnippet ? "修改于 " : "复制于 ") + entry.displayDate.formatted(date: .numeric, time: .standard)).fixedSize()
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}
