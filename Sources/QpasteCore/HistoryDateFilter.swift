import Foundation

public enum HistoryDateFilter: Equatable, Sendable {
    case all, today, last7Days, last30Days
    case custom(start: Date, end: Date)

    public var isActive: Bool { self != .all }
    public var title: String {
        switch self {
        case .all: return "全部时间"
        case .today: return "今天"
        case .last7Days: return "近 7 天"
        case .last30Days: return "近 30 天"
        case .custom(let start, let end):
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/M/d"
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
    }

    /// Custom endpoints are inclusive calendar dates; database intervals are [start, end).
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch self {
        case .all: return nil
        case .today: return DateInterval(start: today, end: tomorrow)
        case .last7Days: return DateInterval(start: calendar.date(byAdding: .day, value: -6, to: today)!, end: tomorrow)
        case .last30Days: return DateInterval(start: calendar.date(byAdding: .day, value: -29, to: today)!, end: tomorrow)
        case .custom(let start, let end):
            let lower = calendar.startOfDay(for: start)
            let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
            return DateInterval(start: lower, end: max(lower, upper))
        }
    }
}
