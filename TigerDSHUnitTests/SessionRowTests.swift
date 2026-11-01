import XCTest
import UIKit
@testable import TigerDSH

/// The chat-list row's own text: the snippet built from a turn's reply. Small enough to look like nothing, and it
/// runs once per session on every `session/control` frame, on the main actor (R8, item 6).
final class SessionRowTests: XCTestCase {
    /// The snippet is the first 120 characters of the stripped head of the reply, so everything past the head — the
    /// tens of kilobytes a real reply can run to — is not read at all.
    func testASnippetIgnoresEverythingPastTheHeadOfTheReply() {
        let head = String(repeating: "a", count: 300) + " yes"
        let long = head + String(repeating: " no", count: 5000)
        XCTAssertEqual(SessionRow.plain(long), SessionRow.plain(head))
        XCTAssertEqual(SessionRow.plain(head), String(repeating: "a", count: 120))
    }

    /// A link whose closing bracket falls past the first piece of the head still reads as its label: the URL never
    /// reaches a row. The text after the link is kept too — the snippet is bounded by VISIBLE characters now, not by
    /// raw ones, so a link no longer spends the whole budget and drops the summary behind it (Codex R7 P3).
    func testAMarkdownLinkCutByTheHeadStillReadsAsItsLabel() {
        let long = "and [a link that runs past the cut](https://example.com/" + String(repeating: "y", count: 400) + ") end"
        let snippet = SessionRow.plain(long)
        XCTAssertFalse(snippet.contains("https://"), "the URL never reaches a row")
        XCTAssertEqual(snippet, "and a link that runs past the cut end")
    }

    /// Leading whitespace is not text: four hundred raw characters of it used to strip to nothing, and the row showed
    /// an empty snippet where the reply had a summary.
    func testASnippetLooksPastLeadingWhitespace() {
        let reply = String(repeating: "\n   \n", count: 200) + "The summary is here."
        XCTAssertEqual(SessionRow.plain(reply), "The summary is here.")
    }

    /// A long link's URL is dropped and its label kept — and the summary AFTER the link is what the row is for. Four
    /// hundred raw characters spent the whole budget on the link and the summary never reached the row (Codex R7 P3).
    func testASnippetKeepsTheTextAfterALongLink() {
        let reply = "[diagram](https://example.com/" + String(repeating: "y", count: 500) + ")\n\nThe summary follows the link."
        let snippet = SessionRow.plain(reply)
        XCTAssertFalse(snippet.contains("https://"), "the URL never reaches a row")
        XCTAssertEqual(snippet, "diagram The summary follows the link.")
    }

    /// A short reply is returned exactly as before the head bound existed.
    func testAShortReplyIsUnchanged() {
        XCTAssertEqual(SessionRow.plain("Reply with the single word ready."), "Reply with the single word ready.")
        XCTAssertEqual(SessionRow.plain("**Hello** there, [see this](https://example.com/a). "), "Hello there, see this.")
        XCTAssertEqual(SessionRow.plain(""), "")
    }

    /// A label the hundred-and-twentieth visible character falls INSIDE is read to its closing bracket before the
    /// snippet is finalized. The old prefix version stopped mid-label and returned "[" plus 119 "x"s, because the
    /// piece it stripped had been cut through the label (Codex R8 P3).
    func testALinkLabelCutByTheBudgetIsNotFinalizedAsItsFragment() {
        let reply = String(repeating: " ", count: 1200)
            + "[" + String(repeating: "x", count: 500)
            + "](https://example.com) trailing"
        XCTAssertEqual(SessionRow.plain(reply), String(repeating: "x", count: 120))
    }

    /// A label that never closes is text, not a link: the row shows the "[" a markdown renderer would show.
    func testAnUnfinishedLinkLabelReadsAsText() {
        XCTAssertEqual(SessionRow.plain("see [the unfinished label"), "see [the unfinished label")
    }

    /// A destination cut by the end of the reply goes with its link rather than leaking into the row — the old
    /// pattern's `(url)` half was optional for exactly this.
    func testACutDestinationIsDropped() {
        XCTAssertEqual(SessionRow.plain("read [the note](https://example.com/very/long"), "read the note")
    }

    /// A newline inside a label means it was never a link (the old pattern could not cross one either), so the
    /// bracket stays and the label's words are ordinary text.
    func testALabelSpanningANewlineIsNotALink() {
        XCTAssertEqual(SessionRow.plain("see [one\ntwo] here"), "see [one two] here")
    }

    /// An image keeps its alt text and loses its destination, the same way a link does.
    func testAnImageKeepsItsAltText() {
        XCTAssertEqual(SessionRow.plain("![a diagram](https://example.com/d.png) and the rest"), "a diagram and the rest")
    }

    /// A label holding no visible character at all still gets its "[" back, and the insertion point is clamped: the
    /// bracket belongs after the pending space, which no visible character ever resolved.
    func testAnUnfinishedLabelWithNoVisibleCharactersKeepsItsBracket() {
        XCTAssertEqual(SessionRow.plain("see [***"), "see [")
    }

    /// A space pending INSIDE a label — after its words, before the newline that cancels it — is not the space the
    /// bracket goes behind; the label's own words already resolved that one.
    func testALabelWithATrailingSpaceBeforeANewlineKeepsOneSpace() {
        XCTAssertEqual(SessionRow.plain("see [one \ntwo] here"), "see [one two] here")
    }

    /// The bound counts CHARACTERS, so it can never fall inside one. Appending scalars and checking `String.count`
    /// after each did: 119 a's and "e\u{301}" stopped after the "e", and the row showed a bare letter where the
    /// reply had an accented one (Codex R9 P3).
    func testASnippetKeepsACombiningAccentAtTheBoundary() {
        let reply = String(repeating: "a", count: 119) + "e\u{301}" + String(repeating: " b", count: 50)
        let snippet = SessionRow.plain(reply)
        XCTAssertEqual(snippet.count, 120)
        XCTAssertEqual(snippet, String(repeating: "a", count: 119) + "e\u{301}",
                       "the accent belongs to the character it combines with")
        XCTAssertEqual(snippet.unicodeScalars.last, "\u{301}", "the accent was cut off the character it belongs to")
    }

    /// A ZWJ family is ONE character: the old walk appended its first scalar, saw 120, and stopped — a lone woman
    /// where the family belongs.
    func testASnippetKeepsAJoinedEmojiWholeAtTheBoundary() {
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let reply = String(repeating: "a", count: 119) + family + " and the rest of the sentence"
        let snippet = SessionRow.plain(reply)
        XCTAssertEqual(snippet, String(repeating: "a", count: 119) + family)
        XCTAssertEqual(snippet.count, 120, "the joined family counts as one character")
    }
}

/// Links in a reply: bare web addresses and file paths are tappable; ordinary code is not.
final class MarkdownLinkTests: XCTestCase {
    private func links(_ s: String) -> [URL] { Markdown.inline(s).runs.compactMap(\.link) }

    func testABareWebAddressIsLinked() {
        XCTAssertEqual(links("see https://example.com/a for more").first?.absoluteString, "https://example.com/a")
    }

    func testAPathInBackticksOpensTheFile() {
        let u = links("edit `TigerDSH/Views/ChatView.swift:42` next").first
        XCTAssertEqual(u.flatMap(Markdown.filePath), "TigerDSH/Views/ChatView.swift")
    }

    func testCodeThatIsNotAPathStaysPlain() {
        XCTAssertTrue(links("call `session/create` with `x.count`").isEmpty)
    }

    func testAMarkdownLinkToAFileOpensTheFile() {
        XCTAssertEqual(links("[notes](docs/notes.md)").first.flatMap(Markdown.filePath), "docs/notes.md")
    }
}

/// The file preview must survive a huge file or photo (operator, 2026-10-15).
final class FileViewerSafetyTests: XCTestCase {
    func testLongLinesAreClipped() {
        let wide = String(repeating: "x", count: 50_000)
        let out = FileViewer.clipLines("short\n" + wide + "\nend")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "short"); XCTAssertEqual(lines[2], "end")
        XCTAssertLessThanOrEqual(lines[1].count, FileViewer.lineWidthCap + 1)
        XCTAssertEqual(FileViewer.clipLines("a\nb"), "a\nb")
    }

    func testBigPhotoIsDecodedSmall() {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 6000, height: 4000), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000)) }
        let data = big.jpegData(compressionQuality: 0.5)!
        let img = FileViewer.downsample(data)
        XCTAssertNotNil(img)
        XCTAssertLessThanOrEqual(max(img!.size.width * img!.scale, img!.size.height * img!.scale), 3000)
        XCTAssertNil(FileViewer.downsample(Data("not a picture".utf8)))
    }
}

/// The sign-in QR code is trusted only inside the Tailscale network: a swapped code must not send this phone's chats
/// to an outside address (operator, 2026-10-15: "still within tailscale network").
final class QRSignInTests: XCTestCase {
    func testOnlyATailnetLinkIsAccepted() {
        XCTAssertTrue(QRScanner.isTailnetLink("https://my-mac.tail1234.ts.net/?token=abc"))
        XCTAssertTrue(QRScanner.isTailnetLink("https://100.101.102.103:3080/?token=abc"))
        XCTAssertFalse(QRScanner.isTailnetLink("https://evil.example.com/?token=abc"))
        XCTAssertFalse(QRScanner.isTailnetLink("https://ts.net.evil.com/?token=abc"))
        XCTAssertFalse(QRScanner.isTailnetLink("https://100.200.1.1/?token=abc"))
        XCTAssertFalse(QRScanner.isTailnetLink("https://100.64.1.2.evil.com/?token=abc"))
        XCTAssertFalse(QRScanner.isTailnetLink("https://100.64.1.999/?token=abc"))
        XCTAssertFalse(QRScanner.isTailnetLink("not a link"))
    }
}

/// The list decoder steps over every turn but the last (Codex r88): the snippet must still come from the last one,
/// whatever the earlier turns hold, and an empty or missing outline must leave the row with no snippet.
final class SessionListDecodeTests: XCTestCase {
    private func rows(_ items: String) throws -> [SessionRow] {
        try JSONDecoder().decode(SessionListValue.self, from: Data(#"{"items":[\#(items)]}"#.utf8)).rows
    }

    func testTheSnippetComesFromTheLastTurn() throws {
        let r = try rows(#"{"sessionId":"a","projections":{"values":{"turnOutline":[{"prompt":"old","response":"first"},{"prompt":"new","response":"latest"}]}}}"#)
        XCTAssertEqual(r.map(\.snippet), ["latest"])
    }

    func testAnEarlierTurnOfAnotherShapeDoesNotDropTheRow() throws {
        let r = try rows(#"{"sessionId":"a","projections":{"values":{"turnOutline":[{"prompt":7},null,{"prompt":"ask","response":""}]}}}"#)
        XCTAssertEqual(r.map(\.snippet), ["ask"])
    }

    func testAnEmptyOrMissingOutlineHasNoSnippet() throws {
        let r = try rows(#"{"sessionId":"a","projections":{"values":{"turnOutline":[]}}},{"sessionId":"b","projections":{"values":{"turnOutline":null}}},{"sessionId":"c"}"#)
        XCTAssertEqual(r.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(r.map(\.snippet), ["", "", ""])
    }
}

/// A saved message's menu row: its first line, cut at 40 characters.
final class SavedPromptTitleTests: XCTestCase {
    func testFirstLineAndCut() {
        XCTAssertEqual(ComposerControls.title("Review this diff\nand list risks"), "Review this diff")
        XCTAssertEqual(ComposerControls.title(String(repeating: "a", count: 45)), String(repeating: "a", count: 40) + "…")
        XCTAssertEqual(ComposerControls.title("short"), "short")
    }
}


/// The plugin icons are SVG drawn by WebKit off to the side; a blank picture is how this broke the first time.
@MainActor
final class PluginArtworkTests: XCTestCase {
    /// The share of the picture's pixels that are more than half opaque.
    private func ink(_ ui: UIImage) throws -> Double {
        let cg = try XCTUnwrap(ui.cgImage)
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Double(stride(from: 3, to: px.count, by: 4).filter { px[$0] > 128 }.count) / Double(w * h)
    }

    func testDefaultArtworkHasInk() async throws {
        let drawn = await PluginArtwork.image(PluginArtwork.fallback)
        let ui = try XCTUnwrap(drawn, "no picture came back")
        XCTAssertGreaterThan(try ink(ui), 0.05, "the picture is blank")
    }

    /// The plugin list draws a run of SVG icons back to back; on 2026-10-15 most of the first ones came back as
    /// empty tiles while a later one drew.
    func testSVGIconsComeBackInked() async throws {
        for color in ["#4D6BFE", "#F2AF63", "#45D9E7", "#7CB7FF"] {
            let svg = "<svg width='36' height='36' viewBox='0 0 36 36' xmlns='http://www.w3.org/2000/svg'><rect x='4' y='4' width='28' height='28' fill='\(color)'/></svg>"
            let src = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
            let drawn = await PluginArtwork.image(src)
            let ui = try XCTUnwrap(drawn, "no picture came back")
            XCTAssertTrue(PluginArtwork.cached(src) === ui, "the \(color) square fell back to the default")
            XCTAssertGreaterThan(try ink(ui), 0.5, "the \(color) square came back blank")
        }
    }

    func testSourceRejectsAnythingButBase64Images() {
        XCTAssertEqual(PluginArtwork.source(["meta": ["icon": "data:image/svg+xml;base64,PHN2Zz4="]]), "data:image/svg+xml;base64,PHN2Zz4=")
        XCTAssertEqual(PluginArtwork.source(["meta": ["icon": "data:image/svg+xml;base64,x' onerror='y"]]), PluginArtwork.fallback)
        XCTAssertEqual(PluginArtwork.source(["name": "x"]), PluginArtwork.fallback)
    }
}

/// The host empties the task list whenever a turn starts, and a background job finishing starts one mid-task.
@MainActor
final class TodoCarryTests: XCTestCase {
    private func write(_ m: ChatModel, _ statuses: [String], seq: Int) {
        let todos = JSON.array(statuses.enumerated().map { ["content": .string("step \($0.offset)"), "status": .string($0.element)] })
        m.reduce(["type": "todo/write", "seq": .number(Double(seq)), "data": ["todos": todos]], live: true)
    }

    func testUnfinishedListSurvivesTurnStart() {
        let m = ChatModel(id: "session-todo", app: nil)
        write(m, ["completed", "in_progress", "pending"], seq: 1)
        m.projectionFromControl(sessionId: m.sid, key: "todos", value: .null)
        XCTAssertEqual(m.todos.count, 3, "an unfinished list vanished when a turn started")
        write(m, ["completed", "completed", "completed"], seq: 2)
        m.projectionFromControl(sessionId: m.sid, key: "todos", value: .null)
        XCTAssertTrue(m.todos.isEmpty, "a finished list should still clear on the next turn")
    }

    func testStoppedRunEndsTheCarry() {
        let m = ChatModel(id: "session-todo", app: nil)
        write(m, ["in_progress"], seq: 1)
        m.reduce(["type": "turn/end", "seq": 2, "data": ["turn": 1, "reason": ["kind": "aborted"]]], live: true)
        XCTAssertTrue(m.todos.isEmpty, "a stopped run left its task list behind")
    }

    func testReplayedListShowsOnReopen() {
        let m = ChatModel(id: "session-todo", app: nil)
        let todos = JSON.array([["content": "a", "status": "in_progress"]])
        m.reduce(["type": "todo/write", "seq": 5, "data": ["todos": todos]], live: false)
        XCTAssertEqual(m.todos.count, 1)
    }
}
