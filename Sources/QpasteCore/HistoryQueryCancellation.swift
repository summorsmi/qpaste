import Foundation

/// Cancellation is scoped to one query, including its running SQLite statements.
public final class HistoryQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws { if isCancelled { throw CancellationError() } }
}
