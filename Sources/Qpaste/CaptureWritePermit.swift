import Foundation
import QpasteCore

/// Only in-flight captures retain permits. Later user deletions/clears must win
/// over a snapshot still being decoded, without dropping unrelated captures.
final class CaptureWritePermit: @unchecked Sendable {
    let reservedBytes: Int
    private let lock = NSLock()
    private var deletedFingerprints = Set<String>()
    private var clearedHistory = false
    private var clearedFavorites = false

    init(reservedBytes: Int) { self.reservedBytes = reservedBytes }

    func deleted(_ fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        deletedFingerprints.insert(fingerprint)
    }
    func cleared(includeFavorites: Bool) {
        lock.lock(); defer { lock.unlock() }
        clearedHistory = true
        clearedFavorites = clearedFavorites || includeFavorites
    }
    func allows(_ entry: ClipboardEntry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !deletedFingerprints.contains(entry.fingerprint)
            && !(clearedHistory && !entry.isSnippet && (!entry.isFavorite || clearedFavorites))
    }
}
