import Foundation

public struct HistoryQuery: Sendable, Equatable {
    public var filter: HistoryFilter
    public var text: String
    public var interval: DateInterval?
    public init(filter: HistoryFilter = .all, text: String = "", interval: DateInterval? = nil) {
        self.filter = filter; self.text = text; self.interval = interval
    }
}

public struct HistoryPage: Sendable {
    public let entries: [ClipboardEntry]
    public let totalCount: Int
}

public struct HistorySummary: Sendable {
    public var counts: [HistoryFilter: Int] = [:]
    public var usage = HistoryUsage()
    public init() {}
}
