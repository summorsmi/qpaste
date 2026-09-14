import Foundation
import Testing
@testable import QpasteCore

@Suite("搜索执行与取消")
struct SearchExecutionTests {
    @Test func sharedMatchPassKeepsCountsEmptyPagesAndSubstringSemantics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qpaste-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(directory: directory)
        let entries = ["Café 中文片段 👩🏽‍💻", "cafe 中文另一个", "中文 unrelated"].map { ClipboardEntry(kind: .text, text: $0) }
        try repository.save(entries)
        for query in ["cafe 中文", "片", "👩🏽‍💻", "不存在", "CAFÉ", "中"] {
            let expected = entries.filter { $0.matches(query) }.count
            let page = try repository.listPage(HistoryQuery(text: query), limit: 1)
            #expect(page.totalCount == expected)
            #expect(page.entries.count == min(1, expected))
            let empty = try repository.listPage(HistoryQuery(text: query), offset: 100)
            #expect(empty.entries.isEmpty && empty.totalCount == expected)
        }
        let token = HistoryQueryCancellation()
        token.cancel()
        #expect(throws: CancellationError.self) { try repository.listPage(HistoryQuery(text: "cafe"), cancellation: token) }
        #expect(try repository.listPage(HistoryQuery(text: "cafe")).totalCount == 2)
    }

    @Test func cancellationInterruptsExecutingSQLAndLeavesConnectionUsable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qpaste-interrupt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = HistoryQueryCancellation()
        let started = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let db = try SQLiteDatabase(url: directory.appendingPathComponent("test.sqlite"))
            do {
                _ = try db.withCancellation(token) {
                    try db.transaction(readOnly: true) {
                        started.signal()
                        return try db.rows("WITH RECURSIVE numbers(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM numbers WHERE n<10000000) SELECT SUM(n) FROM numbers")
                    }
                }
                return false
            } catch is CancellationError {
                return try db.rows("SELECT 42").first?.first?.double == 42
            }
        }
        #expect(started.wait(timeout: .now() + 2) == .success)
        try await Task.sleep(for: .milliseconds(10))
        token.cancel()
        #expect(try await task.value)
    }
}
