import Foundation
import Testing
@testable import QpasteCore

@Suite("日期分组与自然日边界")
struct HistoryDateTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    @Test func groupingUsesDisjointRangesAndContinuousRowIndices() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12))!
        let entries = [0, 1, 2, 6, 7, 29, 30, 60].map { days in
            ClipboardEntry(kind: .text, text: "\(days)", now: calendar.date(byAdding: .day, value: -days, to: now)!)
        }
        let sections = HistoryDates.sections(entries, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["今天", "昨天", "近 7 天", "近 30 天", "2026 年 8 月", "2026 年 7 月"])
        #expect(sections.map(\.startIndex) == [0, 1, 2, 4, 6, 7])
        #expect(sections.flatMap(\.entries).map(\.id) == entries.map(\.id))
    }

    @Test func midnightAndTimezoneChangesRegroupWithoutChangingTimestamps() {
        let date = ISO8601DateFormatter().date(from: "2026-09-12T16:10:00Z")!
        let entry = ClipboardEntry(kind: .text, text: "sample", now: date)
        let now = ISO8601DateFormatter().date(from: "2026-09-13T04:00:00Z")!
        #expect(HistoryDates.sections([entry], now: now, calendar: calendar).first?.title == "今天")
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(HistoryDates.sections([entry], now: now, calendar: utc).first?.title == "昨天")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        #expect(HistoryDates.sections([entry], now: tomorrow, calendar: calendar).first?.title == "昨天")
        #expect(entry.lastCopiedAt == date)
    }

    @Test func daylightSavingUsesCalendarDaysInsteadOf86400Seconds() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 15))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 5))!
        #expect(now.timeIntervalSince(yesterday) < 86400)
        #expect(HistoryDates.sections([ClipboardEntry(kind: .text, text: "DST", now: yesterday)], now: now, calendar: cal).first?.title == "昨天")
    }

    @Test func snippetGroupingUsesModificationTimeAndFutureDatesAreNotToday() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12))!
        let old = calendar.date(byAdding: .day, value: -40, to: now)!
        var snippet = ClipboardEntry(kind: .text, text: "hello", now: old, snippetName: "snippet")
        snippet.updatedAt = now
        #expect(HistoryDates.sections([snippet], now: now, calendar: calendar).first?.title == "今天")
        #expect(snippet.lastCopiedAt == old)
        let future = ClipboardEntry(kind: .text, text: "future", now: now.addingTimeInterval(86400))
        #expect(HistoryDates.sections([future], now: now, calendar: calendar).first?.title != "今天")
    }

    @Test func dateFiltersIncludeWholeEndpointDaysAcrossDST() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let custom = HistoryDateFilter.custom(start: day, end: day).interval(now: day, calendar: cal)!
        #expect(custom.duration == 23 * 3600)
        #expect(custom == HistoryDateFilter.today.interval(now: day, calendar: cal))
        let seven = HistoryDateFilter.last7Days.interval(now: day, calendar: cal)!
        #expect(cal.dateComponents([.day], from: seven.start, to: seven.end).day == 7)
        #expect(HistoryDateFilter.all.interval(now: day, calendar: cal) == nil)
        let invalid = HistoryDateFilter.custom(start: day.addingTimeInterval(86400 * 3), end: day).interval(now: day, calendar: cal)!
        #expect(invalid.duration == 0)
    }
}
