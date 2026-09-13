import AppKit

@MainActor
final class PanelFrameStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func frame(compact: Bool) -> NSRect? {
        if let values = defaults.dictionary(forKey: key(compact: compact)) as? [String: Double],
           let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"] {
            let frame = NSRect(x: x, y: y, width: width, height: height)
            if isValid(frame) { return frame }
        }
        // Preserve sizes saved by earlier Qpaste versions when migrating away
        // from NSWindow autosaving, which also saved transient layout changes.
        let oldKey = "NSWindow Frame " + (compact ? "QpasteCompactPanel" : "QpastePanel")
        guard let oldValue = defaults.string(forKey: oldKey) else { return nil }
        let parts = oldValue.split(whereSeparator: \.isWhitespace).prefix(4)
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        let frame = NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        guard isValid(frame) else { return nil }
        save(frame, compact: compact)
        return frame
    }

    func save(_ frame: NSRect, compact: Bool) {
        guard isValid(frame) else { return }
        defaults.set(["x": frame.origin.x, "y": frame.origin.y,
                      "width": frame.width, "height": frame.height], forKey: key(compact: compact))
    }

    private func key(compact: Bool) -> String { compact ? "panelFrame.compact" : "panelFrame.full" }

    private func isValid(_ frame: NSRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }
}
