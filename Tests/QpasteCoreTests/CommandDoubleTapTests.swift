import Testing
@testable import QpasteCore

@Suite("双击 Command 手势")
struct CommandDoubleTapTests {
    @Test func firesOnlyAfterTheSecondCompleteTap() {
        var detector = CommandDoubleTap()
        let results = [
            detector.commandChanged(isDown: true, at: 0),
            detector.commandChanged(isDown: false, at: 0.05),
            detector.commandChanged(isDown: true, at: 0.18),
            detector.commandChanged(isDown: false, at: 0.23),
            detector.commandChanged(isDown: true, at: 0.3),
            detector.commandChanged(isDown: false, at: 0.35)
        ]
        #expect(results == [false, false, false, true, false, false])
    }

    @Test func commandChordThenOneTapDoesNotFire() {
        var detector = CommandDoubleTap()
        _ = detector.commandChanged(isDown: true, at: 0)
        detector.reset() // A key or mouse button was pressed while Command was held.
        let results = [
            detector.commandChanged(isDown: false, at: 0.05),
            detector.commandChanged(isDown: true, at: 0.15),
            detector.commandChanged(isDown: false, at: 0.2),
            detector.commandChanged(isDown: true, at: 0.3),
            detector.commandChanged(isDown: false, at: 0.35)
        ]
        #expect(results == [false, false, false, false, true])
    }

    @Test func inputBetweenTapsCancelsTheGesture() {
        var detector = CommandDoubleTap()
        _ = detector.commandChanged(isDown: true, at: 0)
        _ = detector.commandChanged(isDown: false, at: 0.05)
        detector.reset()
        _ = detector.commandChanged(isDown: true, at: 0.2)
        let fired = detector.commandChanged(isDown: false, at: 0.25)
        #expect(!fired)
    }

    @Test func tapsOutsideTheConfiguredIntervalDoNotFire() {
        var detector = CommandDoubleTap(interval: 0.3)
        _ = detector.commandChanged(isDown: true, at: 0)
        _ = detector.commandChanged(isDown: false, at: 0.05)
        _ = detector.commandChanged(isDown: true, at: 0.4)
        let fired = detector.commandChanged(isDown: false, at: 0.45)
        #expect(!fired)
    }

    @Test func holdingCommandIsNotATap() {
        var detector = CommandDoubleTap()
        let results = [
            detector.commandChanged(isDown: true, at: 0),
            detector.commandChanged(isDown: false, at: 2),
            detector.commandChanged(isDown: true, at: 2.1),
            detector.commandChanged(isDown: false, at: 2.15)
        ]
        #expect(results == [false, false, false, false])
    }

    @Test func overlappingCommandKeysAndUnmatchedReleasesDoNotFire() {
        var detector = CommandDoubleTap()
        let results = [
            detector.commandChanged(isDown: false, at: 0),
            detector.commandChanged(isDown: true, at: 0.1),
            detector.commandChanged(isDown: true, at: 0.15),
            detector.commandChanged(isDown: false, at: 0.2),
            detector.commandChanged(isDown: true, at: 0.3),
            detector.commandChanged(isDown: false, at: 0.35)
        ]
        #expect(results == [false, false, false, false, false, false])
    }
}
