import AppKit
import SwiftUI
import Testing
@testable import Qpaste

@Suite("窗口尺寸与鼠标选择", .serialized)
@MainActor
struct InteractionTests {
    @Test func hostingKeepsMinimumBoundsAcrossAttachmentAndModeChanges() async throws {
        _ = NSApplication.shared
        let name = "qpaste-minimum-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.isCompact = true
        let store = try HistoryStore(settings: settings, directory: directory, synchronousQueries: true)
        let panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = PanelSizing.minimumContentSize(compact: true)
        let hosting = PanelSizing.hostingView(rootView: MainView(store: store, settings: settings, paste: { _, _ in }, copy: { _, _ in }))
        panel.contentView = hosting
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }
        panel.contentView?.layoutSubtreeIfNeeded()
        try await waitForMinimum(panel, compact: true)
        panel.setFrame(PanelSizing.restoredFrame(panel.frame,
            minimum: PanelSizing.minimumFrameSize(for: panel, compact: true), visibleFrame: nil), display: false)
        let compactSize = PanelSizing.minimumFrameSize(for: panel, compact: true)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: compactSize), display: true)
        try await snapshot(panel, named: "compact")

        settings.isCompact = false
        panel.contentView?.layoutSubtreeIfNeeded()
        try await waitForMinimum(panel, compact: false)
        let fullSize = PanelSizing.minimumFrameSize(for: panel, compact: false)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: fullSize), display: true)
        try await snapshot(panel, named: "full")
        let userSize = panel.frame.size
        settings.isCompact = true
        panel.contentView?.layoutSubtreeIfNeeded()
        try await waitForMinimum(panel, compact: true)
        #expect(panel.frame.size == userSize) // Minimum bounds must not force an ideal size.
    }

    @Test func undersizedSavedFramesAreCorrectedAndBothModesStillRememberSizes() throws {
        try withDefaults { defaults in
            let frames = PanelFrameStore(defaults: defaults)
            let screen = NSRect(x: 0, y: 0, width: 1440, height: 1000)
            for compact in [true, false] {
                let tooSmall = NSRect(x: 100, y: 700, width: 100, height: 100)
                frames.save(tooSmall, compact: compact)
                let stored = try #require(frames.frame(compact: compact))
                let restored = PanelSizing.restoredFrame(stored,
                    minimum: PanelSizing.minimumContentSize(compact: compact), visibleFrame: screen)
                #expect(restored.size == PanelSizing.minimumContentSize(compact: compact))
                #expect(restored.maxY == tooSmall.maxY)
                frames.save(restored, compact: compact)
            }
            let nextRun = PanelFrameStore(defaults: defaults)
            #expect(nextRun.frame(compact: true)?.size == NSSize(width: 480, height: 380))
            #expect(nextRun.frame(compact: false)?.size == NSSize(width: 960, height: 660))
            let tinyScreen = NSRect(x: 0, y: 0, width: 800, height: 600)
            let minimum = PanelSizing.minimumContentSize(compact: false)
            let constrained = PanelSizing.restoredFrame(NSRect(origin: .zero, size: minimum), minimum: minimum, visibleFrame: tinyScreen)
            #expect(constrained.size == minimum)
            #expect(constrained.minX == tinyScreen.minX && constrained.maxY == tinyScreen.maxY)
        }
    }

    @Test func resizeDelegateEnforcesMinimumEvenIfNativeLimitsWereCleared() {
        let panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                                   styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.contentMinSize = .zero
        let delegate = AppDelegate()
        let requested = NSSize(width: 100, height: 100)
        #expect(delegate.windowWillResize(panel, to: requested) == PanelSizing.minimumFrameSize(for: panel, compact: false))
    }

    private func waitForMinimum(_ panel: NSPanel, compact: Bool) async throws {
        let size = PanelSizing.minimumContentSize(compact: compact)
        for _ in 0..<100 {
            if panel.contentMinSize.width == size.width && panel.contentMinSize.height >= size.height { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(panel.contentMinSize.width == size.width && panel.contentMinSize.height >= size.height)
    }

    private func snapshot(_ panel: NSPanel, named name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["QPASTE_MINIMUM_SNAPSHOTS"], let view = panel.contentView else { return }
        try await Task.sleep(for: .milliseconds(60))
        view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "qpaste-window-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func bothModesKeepTheirOwnFrameAcrossStoreRecreation() throws {
        try withDefaults { defaults in
            let compact = NSRect(x: 110, y: 220, width: 610, height: 480)
            let full = NSRect(x: 40, y: 70, width: 1180, height: 740)
            let firstRun = PanelFrameStore(defaults: defaults)
            firstRun.save(compact, compact: true)
            firstRun.save(full, compact: false)
            let nextRun = PanelFrameStore(defaults: defaults)
            #expect(nextRun.frame(compact: true) == compact)
            #expect(nextRun.frame(compact: false) == full)
            let resized = NSRect(x: 140, y: 250, width: 650, height: 510)
            nextRun.save(resized, compact: true)
            #expect(firstRun.frame(compact: true) == resized)
            #expect(firstRun.frame(compact: false) == full)
        }
    }

    @Test func legacyFramesMigrateWithoutMixingModes() throws {
        try withDefaults { defaults in
            defaults.set("100 200 544 568 0 0 1710 1073", forKey: "NSWindow Frame QpasteCompactPanel")
            defaults.set("408 350 1040 680 0 0 1710 1073", forKey: "NSWindow Frame QpastePanel")
            let store = PanelFrameStore(defaults: defaults)
            #expect(store.frame(compact: true) == NSRect(x: 100, y: 200, width: 544, height: 568))
            #expect(store.frame(compact: false) == NSRect(x: 408, y: 350, width: 1040, height: 680))
            defaults.set("0 0 200 200 0 0 1710 1073", forKey: "NSWindow Frame QpasteCompactPanel")
            #expect(store.frame(compact: true)?.width == 544)
        }
    }

    @Test func invalidFramesDoNotReplaceUsablePreferences() throws {
        try withDefaults { defaults in
            let store = PanelFrameStore(defaults: defaults)
            let frame = NSRect(x: -100, y: 50, width: 600, height: 400)
            store.save(frame, compact: true)
            store.save(NSRect(x: 0, y: 0, width: 0, height: 400), compact: true)
            store.save(NSRect(x: CGFloat.infinity, y: 0, width: 600, height: 400), compact: true)
            #expect(store.frame(compact: true) == frame)
        }
    }

    @Test func mouseDownSelectsImmediatelyAndOnlySecondMouseUpActivates() throws {
        let view = HistoryRowMouseView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        var selected = 0
        var activated = 0
        view.select = { selected += 1 }
        view.activate = { activated += 1 }
        view.mouseDown(with: try event(.leftMouseDown, count: 1))
        #expect(selected == 1) // Before mouse-up or any double-click timeout.
        #expect(activated == 0)
        view.mouseUp(with: try event(.leftMouseUp, count: 1))
        #expect(activated == 0)
        view.mouseDown(with: try event(.leftMouseDown, count: 2))
        #expect(selected == 2)
        #expect(activated == 0)
        view.mouseUp(with: try event(.leftMouseUp, count: 2))
        #expect(activated == 1)
        view.mouseDown(with: try event(.leftMouseDown, count: 3))
        view.mouseUp(with: try event(.leftMouseUp, count: 3))
        #expect(activated == 1)
    }

    @Test func draggingOrReleasingOutsideDoesNotPaste() throws {
        let view = HistoryRowMouseView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        var activated = 0
        view.activate = { activated += 1 }
        view.mouseDown(with: try event(.leftMouseDown, count: 2))
        view.mouseDragged(with: try event(.leftMouseDragged, count: 2, point: NSPoint(x: 40, y: 20)))
        view.mouseUp(with: try event(.leftMouseUp, count: 2))
        #expect(activated == 0)
        view.mouseDown(with: try event(.leftMouseDown, count: 2))
        view.mouseUp(with: try event(.leftMouseUp, count: 2, point: NSPoint(x: 300, y: 20)))
        #expect(activated == 0)
    }

    private func event(_ type: NSEvent.EventType, count: Int, point: NSPoint = NSPoint(x: 20, y: 20)) throws -> NSEvent {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 1,
                                      clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)
        return try #require(event)
    }
}
