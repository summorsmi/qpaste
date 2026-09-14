import AppKit
import QpasteCore

struct HoverPreviewLayout {
    static let minimumSize = NSSize(width: 280, height: 140)
    static let maximumSize = NSSize(width: 560, height: 480)
    static let contentPadding: CGFloat = 28
    static let chromeHeight: CGFloat = 92

    let size: NSSize
    let imageSize: NSSize?

    private struct TextKey: Hashable {
        let sample: String
        let truncated: Bool
        let monospaced: Bool
        let width: CGFloat
        let height: CGFloat
    }
    @MainActor private static var textLayouts: [TextKey: (layout: Self, used: UInt64)] = [:]
    @MainActor private static var clock: UInt64 = 0

    @MainActor static func text(_ text: String, monospaced: Bool, maximum: NSSize = maximumSize) -> Self {
        let maxWidth = max(1, min(maximum.width, maximumSize.width))
        let maxHeight = max(1, min(maximum.height, maximumSize.height))
        let prefix = text.prefix(2_000)
        let sample = String(prefix)
        let truncated = prefix.endIndex != text.endIndex
        let key = TextKey(sample: sample, truncated: truncated, monospaced: monospaced, width: maxWidth, height: maxHeight)
        clock &+= 1
        if let cached = textLayouts[key] {
            textLayouts[key] = (cached.layout, clock)
            return cached.layout
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14),
            .paragraphStyle: paragraph
        ]
        // Only sizing is bounded. The preview's scroll view receives the full text.
        let measured = (sample as NSString).boundingRect(
            with: NSSize(width: max(1, maxWidth - contentPadding), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let width = min(maxWidth, max(minimumSize.width, ceil(measured.width) + contentPadding))
        let height: CGFloat
        if truncated { height = maxHeight }
        else {
            let wrapped = (sample as NSString).boundingRect(
                with: NSSize(width: max(1, width - contentPadding), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            height = ceil(wrapped.height) + chromeHeight + 8
        }
        let layout = Self(size: NSSize(width: width, height: min(maxHeight, max(minimumSize.height, height))), imageSize: nil)
        if textLayouts.count >= 32, let oldest = textLayouts.min(by: { $0.value.used < $1.value.used })?.key {
            textLayouts.removeValue(forKey: oldest)
        }
        textLayouts[key] = (layout, clock)
        return layout
    }

    static func image(width: Int, height: Int, maximum: NSSize = maximumSize) -> Self {
        let availableWidth = max(1, min(maximum.width, maximumSize.width))
        let availableHeight = max(1, min(maximum.height, maximumSize.height))
        let source = NSSize(width: max(1, width), height: max(1, height))
        let scale = min(1, max(1, availableWidth - contentPadding) / source.width)
        let image = NSSize(width: source.width * scale, height: source.height * scale)
        return Self(size: NSSize(width: min(availableWidth, max(minimumSize.width, image.width + contentPadding)),
                                 height: min(availableHeight, max(minimumSize.height, image.height + chromeHeight))),
                    imageSize: image)
    }

    static func maximumAvailable(parent: NSRect, screen: NSRect) -> NSSize {
        let sideSpace = max(screen.maxX - parent.maxX - 8, parent.minX - screen.minX - 8)
        let width = sideSpace >= minimumSize.width ? sideSpace : screen.width - 24
        return NSSize(width: max(1, min(maximumSize.width, width)),
                      height: max(1, min(maximumSize.height, screen.height - 24)))
    }

    static func frame(size: NSSize, anchor: NSRect, parent: NSRect, screen: NSRect) -> NSRect {
        let size = NSSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        var x = parent.maxX + 8
        var y = anchor.maxY - size.height
        if x + size.width > screen.maxX {
            if parent.minX - 8 - size.width >= screen.minX { x = parent.minX - 8 - size.width }
            else {
                x = anchor.maxX - size.width
                // When neither side has room, keep the hovered row unobscured if possible.
                y = anchor.minY - 8 - size.height
                if y < screen.minY { y = anchor.maxY + 8 }
            }
        }
        x = max(screen.minX, min(x, screen.maxX - size.width))
        y = max(screen.minY, min(y, screen.maxY - size.height))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}
