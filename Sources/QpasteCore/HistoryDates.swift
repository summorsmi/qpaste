import Foundation

public struct HistoryDateSection: Identifiable {
    public let id: String
    public let title: String
    public let startIndex: Int
    public var entries: [ClipboardEntry]
}

public enum HistoryDates {
    public static func sections(_ entries: [ClipboardEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDateSection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let week = calendar.date(byAdding: .day, value: -6, to: today)!
        let month = calendar.date(byAdding: .day, value: -29, to: today)!
        var result = [HistoryDateSection]()
        for (index, entry) in entries.enumerated() {
            let date = entry.displayDate
            let key: String
            let title: String
            if calendar.isDate(date, inSameDayAs: today) { key = "today"; title = "今天" }
            else if calendar.isDate(date, inSameDayAs: yesterday) { key = "yesterday"; title = "昨天" }
            else if date >= week && date < yesterday { key = "week"; title = "近 7 天" }
            else if date >= month && date < week { key = "month"; title = "近 30 天" }
            else {
                let parts = calendar.dateComponents([.era, .year, .month], from: date)
                key = "month-\(parts.era ?? 1)-\(parts.year ?? 0)-\(parts.month ?? 0)"
                title = "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月"
            }
            if result.last?.id == key { result[result.count - 1].entries.append(entry) }
            else { result.append(HistoryDateSection(id: key, title: title, startIndex: index, entries: [entry])) }
        }
        return result
    }
}
