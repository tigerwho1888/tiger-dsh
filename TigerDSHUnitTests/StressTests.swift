import XCTest
import UIKit
@testable import TigerDSH

/// Stress before every ship (operator, 2026-10-15): the paths a big chat, a long list or a big file pushes hardest,
/// at sizes well past normal use, each with a time bound so a slowdown fails here and not on the phone.
@MainActor
final class StressTests: XCTestCase {
    private func timed(_ limit: TimeInterval, _ what: String, _ body: () -> Void) {
        let t = Date(); body()
        XCTAssertLessThan(Date().timeIntervalSince(t), limit, "\(what) took too long")
    }

    func testLinksInAHugeReply() {
        let line = "See https://example.com/a?b=1 and `Sources/App/Main.swift` and [doc](./notes/plan.md) here.\n"
        let text = String(repeating: line, count: 2_000)
        timed(10, "linking a 2,000-line reply") { _ = Markdown.inline(text) }
    }

    func testFiveThousandChatsThroughEveryFilter() {
        let app = AppModel()
        let saved = (app.doneUnseen, app.currentChatID)
        defer { app.currentChatID = saved.1; app.doneUnseen = saved.0 }
        var rows: [String: SessionRow] = [:]
        for i in 0..<5_000 {
            rows["s\(i)"] = SessionRow(id: "s\(i)", updated: Double(i), running: i % 7 == 0, blank: false, isSub: false, cwd: "",
                                       title: "Chat \(i)", questions: i % 11 == 0 ? 1 : 0, model: nil, snippet: "")
        }
        app.rows = rows
        timed(20, "filtering 5,000 chats") {
            for round in 0..<20 {
                app.doneUnseen = Set((0..<500).map { "s\($0 * 10 + round % 10)" })
                for f in AppModel.Filter.allCases { _ = app.chats(filter: f, query: round % 2 == 0 ? "" : "9") }
            }
        }
        XCTAssertFalse(app.chats(filter: .unread).contains { $0.running })
    }

    func testHugeFileText() {
        let wide = String(repeating: "{\"k\":1},", count: 50_000)
        let text = String(repeating: "short line\n", count: 20_000) + wide
        timed(10, "clipping a huge file") {
            let out = FileViewer.clipLines(String(text.prefix(FileViewer.textCap)))
            XCTAssertLessThanOrEqual(out.count, FileViewer.textCap + 1)
        }
    }

    func testManyBigPhotos() {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 8000, height: 6000), format: f)
            .image { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 8000, height: 6000)) }
            .jpegData(compressionQuality: 0.3)!
        timed(30, "decoding ten 48-megapixel photos") {
            for _ in 0..<10 { autoreleasepool { XCTAssertNotNil(FileViewer.downsample(data)) } }
        }
    }

    func testQuotingOverAndOver() {
        let chat = ChatModel(id: "session-stress", app: nil)
        let part = String(repeating: "quoted words ", count: 200)
        timed(10, "quoting 300 times") { for _ in 0..<300 { chat.quote(part) } }
        XCTAssertFalse(chat.draft.isEmpty)
    }
}
