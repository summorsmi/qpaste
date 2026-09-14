import AppKit
import SwiftUI

enum PanelSizing {
    static func minimumContentSize(compact: Bool) -> NSSize {
        compact ? NSSize(width: 480, height: 380) : NSSize(width: 960, height: 660)
    }

    @MainActor
    static func hostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: rootView)
        // Empty options reset the window's minimum to zero when attached.
        // Keep minimum bounds, without imposing an ideal size on user resizing.
        view.sizingOptions = [.minSize]
        return view
    }

    @MainActor
    static func minimumFrameSize(for window: NSWindow, compact: Bool) -> NSSize {
        window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize(compact: compact))).size
    }

    static func constrainedSize(_ proposed: NSSize, minimum: NSSize) -> NSSize {
        NSSize(width: max(proposed.width, minimum.width), height: max(proposed.height, minimum.height))
    }

    static func restoredFrame(_ desired: NSRect, minimum: NSSize, visibleFrame: NSRect?) -> NSRect {
        var frame = desired
        frame.size = constrainedSize(desired.size, minimum: minimum)
        frame.origin.y = desired.maxY - frame.height
        if let visible = visibleFrame {
            // A small screen must not silently remove the UI's minimum bounds.
            frame.size.width = max(minimum.width, min(frame.width, visible.width))
            frame.size.height = max(minimum.height, min(frame.height, visible.height))
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = frame.height > visible.height ? visible.maxY - frame.height
                : max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        return frame
    }
}
