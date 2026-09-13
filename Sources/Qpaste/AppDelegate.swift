import AppKit
import SwiftUI
import Combine
import ApplicationServices
import QpasteCore

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: ClipboardPanel!
    private var store: HistoryStore!
    private var monitor: ClipboardMonitor!
    private var shortcut: GlobalShortcut!
    private var settings: AppSettings!
    private var subscriptions = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var workspaceObserver: Any?
    private var previousApp: NSRunningApplication?
    private var pasteTask: Task<Void, Never>?
    private var isDemo = false
    private var displayedCompactMode = false
    private var pendingCompactMode: Bool?
    private var panelFrames: PanelFrameStore!
    private var isPanelReady = false
    private var isRestoringFrame = false
    private var frameBeforeSheet: NSRect?
    private var frameSaveWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A --demo instance uses isolated sample data and never reads the system clipboard.
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if !isDemo, let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let preferences = isDemo ? UserDefaults(suiteName: "app.qpaste.demo")! : UserDefaults.standard
        settings = AppSettings(defaults: preferences)
        panelFrames = PanelFrameStore(defaults: preferences)
        do {
            let directory = isDemo
                ? FileManager.default.temporaryDirectory.appendingPathComponent("Qpaste-demo-\(UUID().uuidString)")
                : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Qpaste", isDirectory: true)
            store = try HistoryStore(settings: settings, directory: directory)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Qpaste 无法创建历史存储目录"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        monitor = ClipboardMonitor(store: store, pasteboard: isDemo ? NSPasteboard(name: .init("Qpaste-demo")) : .general)
        setupMenu()
        setupPanel()
        setupKeyboard()
        shortcut = GlobalShortcut()
        shortcut.onPress = { [weak self] in self?.togglePanel() }
        shortcut.onStatusChange = { [weak self] error in self?.store.shortcutError = error }
        settings.$shortcut.sink { [weak self] choice in
            self?.shortcut.register(choice)
        }.store(in: &subscriptions)
        settings.$isPaused.dropFirst().sink { [weak self] paused in
            DispatchQueue.main.async {
                self?.monitor.resetBaseline()
                self?.statusItem.button?.image = NSImage(systemSymbolName: paused ? "pause.rectangle" : "clipboard", accessibilityDescription: "Qpaste")
            }
        }.store(in: &subscriptions)
        settings.$isCompact.dropFirst().sink { [weak self] compact in
            // Published emits before the view changes its layout, so capture the
            // user's outgoing frame here rather than after the transition.
            self?.requestDisplayMode(compact)
        }.store(in: &subscriptions)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.previousApp = app }
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        if isDemo { seedDemo() } else { monitor.start() }
        showPanel()
    }

    private func setupPanel() {
        displayedCompactMode = settings.isCompact
        panel = ClipboardPanel(contentRect: NSRect(origin: .zero, size: defaultPanelSize(compact: settings.isCompact)),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        panel.title = "Qpaste"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        configurePanelChrome(compact: settings.isCompact)
        panel.delegate = self
        let hostingView = NSHostingView(rootView: MainView(store: store, settings: settings,
            paste: { [weak self] entry, plain in self?.paste(entry, plainText: plain) },
            copy: { [weak self] entry, plain in self?.copy(entry, plainText: plain) }))
        // Window geometry belongs to the user, not the changing SwiftUI layout.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        if let frame = panelFrames.frame(compact: displayedCompactMode) {
            restorePanelFrame(frame)
        } else { panel.center() }
        isPanelReady = true
        rememberPanelFrame()
    }

    private func defaultPanelSize(compact: Bool) -> NSSize {
        compact ? NSSize(width: 560, height: 430) : NSSize(width: 1040, height: 680)
    }

    private func configurePanelChrome(compact: Bool) {
        panel.minSize = compact ? NSSize(width: 420, height: 360) : NSSize(width: 900, height: 570)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = compact
        }
    }

    private func requestDisplayMode(_ compact: Bool) {
        guard compact != displayedCompactMode || pendingCompactMode != nil else { return }
        frameSaveWork?.cancel()
        rememberPanelFrame()
        pendingCompactMode = compact
        DispatchQueue.main.async { [weak self] in self?.applyPendingDisplayMode() }
    }

    private func applyPendingDisplayMode() {
        guard let compact = pendingCompactMode, panel.attachedSheet == nil else { return }
        let oldFrame = frameBeforeSheet ?? panelFrames.frame(compact: displayedCompactMode) ?? panel.frame
        displayedCompactMode = compact
        isRestoringFrame = true
        configurePanelChrome(compact: compact)
        let size = defaultPanelSize(compact: compact)
        let desired = panelFrames.frame(compact: compact)
            ?? NSRect(x: oldFrame.minX, y: oldFrame.maxY - size.height, width: size.width, height: size.height)
        restorePanelFrame(desired)
        pendingCompactMode = nil
        isRestoringFrame = false
        panelFrames.save(panel.frame, compact: compact)
        store.focusSearchToken += 1
    }

    private func restorePanelFrame(_ desired: NSRect) {
        isRestoringFrame = true
        defer { isRestoringFrame = false }
        var frame = desired
        frame.size.width = max(frame.width, panel.minSize.width)
        frame.size.height = max(frame.height, panel.minSize.height)
        let matchingScreen = NSScreen.screens.first { $0.visibleFrame.intersects(desired) }
        if let screen = matchingScreen ?? panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        panel.setFrame(frame, display: true)
    }

    private var canRememberFrame: Bool {
        isPanelReady && !isRestoringFrame && pendingCompactMode == nil
            && frameBeforeSheet == nil && panel.attachedSheet == nil
    }

    private func rememberPanelFrame() {
        guard canRememberFrame else { return }
        panelFrames.save(panel.frame, compact: displayedCompactMode)
    }

    private func scheduleFrameSave() {
        guard canRememberFrame else { return }
        frameSaveWork?.cancel()
        let mode = displayedCompactMode
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.displayedCompactMode == mode else { return }
            self.rememberPanelFrame()
        }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidEndLiveResize(_ notification: Notification) {
        frameSaveWork?.cancel()
        rememberPanelFrame()
    }

    func windowWillBeginSheet(_ notification: Notification) {
        guard frameBeforeSheet == nil else { return }
        frameSaveWork?.cancel()
        rememberPanelFrame()
        frameBeforeSheet = panelFrames.frame(compact: displayedCompactMode) ?? panel.frame
    }

    func windowDidEndSheet(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.attachedSheet == nil else { return }
            let oldFrame = self.frameBeforeSheet
            self.frameBeforeSheet = nil
            if self.pendingCompactMode != nil { self.applyPendingDisplayMode() }
            else if let oldFrame { self.restorePanelFrame(oldFrame) }
        }
    }

    private func setupMenu() {
        let main = NSMenu()
        let root = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Qpaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        main.addItem(root)
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                     ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                     ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editRoot.submenu = edit
        main.addItem(editRoot)
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Qpaste 剪贴板")
        statusItem.button?.toolTip = "Qpaste · 剪贴板与文本片段"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开 Qpaste", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: settings.isPaused ? "继续记录" : "暂停记录", action: #selector(toggleRecording), keyEquivalent: "").target = self
            menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Qpaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { togglePanel() }
    }

    @objc private func openPanel() { showPanel() }
    @objc private func openSettings() { showPanel(); store.showSettings = true }
    @objc private func toggleRecording() { settings.isPaused.toggle() }

    private func togglePanel() {
        if panel.isVisible && panel.isKeyWindow { panel.orderOut(nil) } else { showPanel() }
    }

    private func showPanel() {
        store.refreshDates()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store.focusSearchToken += 1
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        rememberPanelFrame()
        sender.orderOut(nil)
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        // Sheets briefly take the key-window role from their parent. Wait for AppKit
        // to finish that transition before deciding whether focus left the panel.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel,
                  panel.isVisible, !panel.isKeyWindow, panel.attachedSheet == nil,
                  !self.store.showSettings, self.store.snippetDraft == nil else { return }
            panel.orderOut(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }

    private func copy(_ entry: ClipboardEntry, plainText: Bool) {
        do {
            try monitor.write(entry, plainText: plainText)
            store.notify(plainText ? "已复制为纯文本" : "已复制，可用 ⌘V 粘贴")
        } catch { store.notify(error.localizedDescription, isError: true) }
    }

    private func paste(_ entry: ClipboardEntry, plainText: Bool) {
        do { try monitor.write(entry, plainText: plainText) }
        catch { store.notify(error.localizedDescription, isError: true); return }
        if isDemo { store.notify("演示内容已写入独立测试剪贴板"); return }
        guard let target = previousApp, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            store.notify("内容已复制，未找到可粘贴的目标应用。", isError: true)
            return
        }
        guard AXIsProcessTrusted() else {
            showAccessibilityHelp()
            return
        }
        pasteTask?.cancel()
        panel.orderOut(nil)
        target.activate()
        pasteTask = Task { [weak self] in
            // Wait for focus and for the user's shortcut modifiers to be released.
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                let modifiers = CGEventSource.flagsState(.combinedSessionState)
                    .intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                   modifiers.isEmpty {
                    let source = CGEventSource(stateID: .privateState)
                    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { break }
                    down.flags = .maskCommand
                    up.flags = .maskCommand
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                    return
                }
            }
            self?.showPanel()
            self?.store.notify("内容已复制，但目标应用未就绪，未自动粘贴。", isError: true)
        }
    }

    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.messageText = "让 Qpaste 帮你直接粘贴"
        alert.informativeText = "内容已复制。开启系统的「辅助功能」权限后，Qpaste 就能把内容粘贴回刚才的应用。现在也可以切回原应用按 ⌘V。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "先手动粘贴")
        alert.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            } else {
                self?.panel.orderOut(nil)
                self?.previousApp?.activate()
            }
        }
    }

    private func setupKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKey(event) == nil
            }
            return consumed ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Also cancel before this monitor consumes shortcuts such as Command-C.
        shortcut?.cancelDoubleTap()
        guard panel.isKeyWindow, !store.showSettings, store.snippetDraft == nil, panel.attachedSheet == nil else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let editing = panel.firstResponder as? NSTextView
        if editing?.hasMarkedText() == true { return event }
        if event.keyCode == 53 { panel.orderOut(nil); return nil }
        if command, event.charactersIgnoringModifiers == "f" { store.focusSearchToken += 1; return nil }
        if command, event.charactersIgnoringModifiers == "n" { store.editSnippet(); return nil }
        if command, event.charactersIgnoringModifiers == "w" { panel.orderOut(nil); return nil }
        if event.keyCode == 125 && !command { store.moveSelection(by: 1); return nil }
        if event.keyCode == 126 && !command { store.moveSelection(by: -1); return nil }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let entry = store.selected { paste(entry, plainText: shift) }
            return nil
        }
        if command, event.charactersIgnoringModifiers == "c", editing?.selectedRange().length ?? 0 == 0 {
            if let entry = store.selected { copy(entry, plainText: shift) }
            return nil
        }
        if command, event.charactersIgnoringModifiers == "d", let entry = store.selected {
            store.toggleFavorite(entry); return nil
        }
        if command, event.keyCode == 51, let entry = store.selected { store.delete(entry); return nil }
        if command, let character = event.charactersIgnoringModifiers, let number = Int(character), (1...9).contains(number),
           store.filteredEntries.count >= number {
            paste(store.filteredEntries[number - 1], plainText: shift); return nil
        }
        return event
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameSaveWork?.cancel()
        rememberPanelFrame()
        pasteTask?.cancel()
        monitor?.stop()
        store?.flush()
        shortcut?.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    private func seedDemo() {
        store.add(ClipboardEntry(kind: .text, text: "把灵感留住，把重复交给快捷键。\n\n选中一条记录，按回车就能粘贴回刚才的应用。常用的文字，也可以收藏或存成文本片段。", sourceName: "备忘录", sourceBundleID: "com.apple.Notes", isFavorite: true))
        store.add(ClipboardEntry(kind: .link, text: "https://developer.apple.com/swift/", sourceName: "Safari", sourceBundleID: "com.apple.Safari"))
        store.add(ClipboardEntry(kind: .text, text: "const greeting = (name) => {\n  return `Hello, ${name}!`;\n};\n\nconsole.log(greeting('Qpaste'));", sourceName: "Visual Studio Code", sourceBundleID: "com.microsoft.VSCode"))
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            monitor.pasteboard.clearContents()
            monitor.pasteboard.setData(png, forType: .png)
            if let captured = try? ClipboardMonitor.capture(from: monitor.pasteboard, sourceName: "预览", sourceBundleID: "com.apple.Preview") {
                store.add(captured.entry, imageData: captured.imageData)
            }
        }
        let sampleFile = store.repository.directory.appendingPathComponent("项目笔记.md")
        try? Data("# Qpaste\n随手复制，随时取用。".utf8).write(to: sampleFile)
        store.add(ClipboardEntry(kind: .files, text: sampleFile.path, filePaths: [sampleFile.path], sourceName: "Finder", sourceBundleID: "com.apple.finder"))
        store.saveSnippet(SnippetDraft(name: "会议后跟进", body: "你好，感谢今天的交流。\n\n我整理了讨论中的关键事项，稍后发给你确认。如有补充，随时告诉我。"))
        store.filter = .all
        store.selectedID = store.filteredEntries.last?.id
    }
}
