import AppKit
import Testing
import QpasteCore
@testable import Qpaste

@Suite("精简悬浮详情", .serialized)
@MainActor
struct HoverPreviewTests {
    @Test func shortAndLongTextRespectSizeBounds() {
        let small = HoverPreviewLayout.text("你好", monospaced: false)
        #expect(small.size == HoverPreviewLayout.minimumSize)
        let long = HoverPreviewLayout.text(String(repeating: "一段完整的长文字，需要换行后继续展示。\n", count: 1000), monospaced: false)
        #expect(long.size.height == HoverPreviewLayout.maximumSize.height)
        #expect(long.size.width >= HoverPreviewLayout.minimumSize.width)
        #expect(long.size.width <= HoverPreviewLayout.maximumSize.width)
        let oneLine = HoverPreviewLayout.text(String(repeating: "x", count: 10_000), monospaced: true)
        #expect(oneLine.size.width <= 560)
        #expect(oneLine.size.height == 480)
    }

    @Test func imagesKeepAspectRatioAndTallImagesExtendBeyondViewport() {
        let small = HoverPreviewLayout.image(width: 30, height: 20)
        #expect(small.size == HoverPreviewLayout.minimumSize)
        #expect(small.imageSize == NSSize(width: 30, height: 20))
        let wide = HoverPreviewLayout.image(width: 2000, height: 1000)
        #expect(wide.size.width == 560)
        #expect(wide.imageSize == NSSize(width: 532, height: 266))
        let tall = HoverPreviewLayout.image(width: 1000, height: 8000)
        #expect(tall.size.height == 480)
        #expect(tall.imageSize!.height > tall.size.height)
        #expect(tall.imageSize!.height / tall.imageSize!.width == 8)
    }

    @Test func previewStaysOnScreenAndUsesLeftSideNearRightEdge() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let parent = NSRect(x: -500, y: 30, width: 450, height: 600)
        let anchor = NSRect(x: -445, y: 550, width: 385, height: 70)
        let size = HoverPreviewLayout.maximumAvailable(parent: parent, screen: screen)
        let frame = HoverPreviewLayout.frame(size: size, anchor: anchor, parent: parent, screen: screen)
        #expect(screen.contains(frame))
        #expect(frame.maxX < parent.minX)
        let smallScreen = NSRect(x: 0, y: 0, width: 250, height: 120)
        let maximum = HoverPreviewLayout.maximumAvailable(parent: smallScreen, screen: smallScreen)
        let content = HoverPreviewLayout.text("example", monospaced: false, maximum: maximum)
        let constrained = HoverPreviewLayout.frame(size: content.size, anchor: smallScreen, parent: smallScreen, screen: smallScreen)
        #expect(smallScreen.contains(constrained))
    }

    @Test func previewContainsAllTextSnippetNameAndFilePaths() {
        let text = String(repeating: "完整正文\n", count: 10_000) + "结尾检查"
        let entry = ClipboardEntry(kind: .text, text: text, snippetName: "很长的片段名称")
        let body = HoverPreviewController.bodyText(for: entry)
        #expect(body == "很长的片段名称\n\n" + text)
        let paths = ["/qpaste-tests/nonexistent/一.txt", "/qpaste-tests/nonexistent/二.txt"]
        let files = HoverPreviewController.bodyText(for: ClipboardEntry(kind: .files, filePaths: paths))
        #expect(paths.allSatisfy { files.contains($0) })
        #expect(files.contains("原文件已移动或删除"))
    }

    @Test func trackingDoesNotSelectOrPaste() throws {
        let view = HistoryRowMouseView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        var hover = [Bool]()
        var actions = 0
        view.hoverChanged = { inside, _ in hover.append(inside) }
        view.select = { actions += 1 }
        view.activate = { actions += 1 }
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exited = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: entered)
        view.mouseExited(with: exited)
        #expect(hover == [true, false])
        #expect(actions == 0)
    }

    @Test func delayedPreviewIsNonKeyAndRemainsOpenForScrolling() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        window.contentView = anchor
        window.orderFront(nil)
        // The command-line test host cannot own desktop key focus. Inject only
        // that readiness boundary; keep real panels, layout and scrolling.
        let controller = HoverPreviewController(showDelay: 0.02, closeDelay: 0.03, canPresent: { $0.isVisible })
        defer { controller.dismiss(); window.orderOut(nil) }
        try #require(window.isVisible)
        var imageLoaded = false
        let text = String(repeating: "完整内容，需要滚动查看。\n", count: 100) + "最后一行"
        let entry = ClipboardEntry(kind: .text, text: text)
        controller.enter(entry, from: anchor, image: { imageLoaded = true; return nil })
        controller.leave(anchor)
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.panel == nil)
        #expect(!imageLoaded)

        controller.enter(entry, from: anchor, image: { nil })
        try await Task.sleep(for: .milliseconds(60))
        let preview = try #require(controller.panel)
        #expect(preview.isVisible)
        #expect(!preview.canBecomeKey && !preview.canBecomeMain)
        #expect(preview.parent === window)
        preview.contentView?.layoutSubtreeIfNeeded()
        let textView = try #require(descendants(of: preview.contentView!).compactMap { $0 as? NSTextView }.first)
        #expect(textView.string == text)
        let scroll = try #require(textView.enclosingScrollView)
        #expect(textView.frame.height > scroll.contentSize.height)
        try snapshot(preview, named: "text-top")
        textView.scrollToEndOfDocument(nil)
        #expect(scroll.contentView.bounds.minY > 0)
        try await Task.sleep(for: .milliseconds(60))
        try snapshot(preview, named: "text-bottom")

        controller.leave(anchor)
        controller.pointerEnteredPreview()
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.panel === preview)
        controller.pointerLeftPreview()
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.panel == nil)
        #expect(window.childWindows?.isEmpty != false)

        let image = NSImage(size: NSSize(width: 400, height: 1400), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            for index in 0..<7 {
                ("区域 \(index + 1)" as NSString).draw(at: NSPoint(x: 40, y: CGFloat(index * 200 + 80)),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.white])
            }
            return true
        }
        controller.enter(ClipboardEntry(kind: .image, imageWidth: 400, imageHeight: 1400), from: anchor, image: { image })
        try await Task.sleep(for: .milliseconds(60))
        let imagePanel = try #require(controller.panel)
        imagePanel.contentView?.layoutSubtreeIfNeeded()
        let imageScroll = try #require(descendants(of: imagePanel.contentView!).compactMap { $0 as? NSScrollView }.first)
        let imageDocument = try #require(imageScroll.documentView)
        #expect(imageDocument.frame.height > imageScroll.contentSize.height)
        try snapshot(imagePanel, named: "image-top")
        imageScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, imageDocument.bounds.maxY - imageScroll.contentSize.height)))
        imageScroll.reflectScrolledClipView(imageScroll.contentView)
        #expect(imageScroll.contentView.bounds.minY > 0)
        #expect(imageScroll.contentView.bounds.maxY <= imageDocument.bounds.maxY + 1)
        try await Task.sleep(for: .milliseconds(60))
        try snapshot(imagePanel, named: "image-bottom")
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func snapshot(_ panel: NSPanel, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["QPASTE_PREVIEW_SNAPSHOT_DIR"], let view = panel.contentView else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        for child in descendants(of: view) { child.needsDisplay = true }
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
