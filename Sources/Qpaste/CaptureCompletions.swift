import Foundation

/// Background writes may finish while the main thread is exiting the app.
/// Draining after the worker stops applies failures before HistoryStore.flush().
final class CaptureCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor () -> Void] = []

    func append(_ action: @escaping @MainActor () -> Void) {
        lock.lock(); defer { lock.unlock() }
        actions.append(action)
    }

    @MainActor func drain() {
        lock.lock()
        let completed = actions
        actions.removeAll()
        lock.unlock()
        completed.forEach { $0() }
    }
}
