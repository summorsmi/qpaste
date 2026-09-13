import Foundation

/// Recognizes two complete, standalone Command presses. Intervening input cancels the gesture.
public struct CommandDoubleTap: Sendable {
    private let interval: TimeInterval
    private let maximumPressDuration: TimeInterval
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var isDown = false

    public init(interval: TimeInterval = 0.5, maximumPressDuration: TimeInterval = 0.5) {
        self.interval = max(0.1, interval)
        self.maximumPressDuration = max(0.1, maximumPressDuration)
    }

    public mutating func reset() {
        pressedAt = nil
        releasedAt = nil
        isDown = false
    }

    public mutating func commandChanged(isDown down: Bool, at time: TimeInterval) -> Bool {
        if down {
            // Both Command keys held together (or duplicate key-down) are not a tap.
            if isDown {
                reset()
                isDown = true
                return false
            }
            isDown = true
            pressedAt = time
            if let releasedAt, time < releasedAt || time - releasedAt > interval { self.releasedAt = nil }
            return false
        }
        guard isDown else { return false }
        isDown = false
        guard let pressedAt, time >= pressedAt, time - pressedAt <= maximumPressDuration else {
            reset()
            return false
        }
        self.pressedAt = nil
        if let releasedAt, time >= releasedAt, time - releasedAt <= interval {
            self.releasedAt = nil
            return true
        }
        releasedAt = time
        return false
    }
}
