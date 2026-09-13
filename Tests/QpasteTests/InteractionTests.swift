import AppKit
import Testing
@testable import Qpaste

@Suite("窗口尺寸与鼠标选择", .serialized)
@MainActor
struct InteractionTests {
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
