import AppKit
import SwiftUI

/// Select on mouse-down; use AppKit's click count on mouse-up to activate.
/// There is no single-click recognizer waiting for a double-click to fail.
struct HistoryRowMouseSurface: NSViewRepresentable {
    let select: () -> Void
    let activate: () -> Void
    var hoverID: UUID? = nil
    var hoverChanged: ((Bool, NSView) -> Void)? = nil

    func makeNSView(context: Context) -> HistoryRowMouseView { HistoryRowMouseView() }

    func updateNSView(_ view: HistoryRowMouseView, context: Context) {
        view.select = select
        view.activate = activate
        let trackingChanged = view.hoverID != hoverID
        if trackingChanged { view.hoverChanged?(false, view) }
        view.hoverID = hoverID
        view.hoverChanged = hoverChanged
        if trackingChanged { view.updateTrackingAreas() }
    }

    static func dismantleNSView(_ view: HistoryRowMouseView, coordinator: ()) {
        view.hoverChanged?(false, view)
    }
}

final class HistoryRowMouseView: NSView {
    var select: () -> Void = {}
    var activate: () -> Void = {}
    var hoverID: UUID?
    var hoverChanged: ((Bool, NSView) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var pressedAt: NSPoint?
    private var pressedClickCount = 0
    private var wasDragged = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard hoverChanged != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true, self) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false, self) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        pressedAt = point
        pressedClickCount = event.clickCount
        wasDragged = false
        select()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - pressedAt.x, point.y - pressedAt.y) > 4 { wasDragged = true }
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = pressedAt != nil && pressedClickCount == 2 && !wasDragged
            && bounds.contains(convert(event.locationInWindow, from: nil))
        pressedAt = nil
        pressedClickCount = 0
        wasDragged = false
        if shouldActivate { activate() }
    }
}
