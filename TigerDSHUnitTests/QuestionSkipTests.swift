import XCTest
import SwiftUI
import UIKit
@testable import TigerDSH

/// Skipping the agent's questions (operator request, R19).
///
/// The card used to have one button and one refusal: every question had to carry a pick, or "Send answer" said
/// "Pick an answer first" and nothing left the phone. The host has always accepted the other answer —
/// `dsh-tool-ask-user` reads `selected: []` with no `custom` as "the user explicitly skipped this question" — so
/// the shape of a skip is part of the contract, and it is asserted here rather than left to a live run.
@MainActor
final class QuestionSkipTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        guard let path = ProcessInfo.processInfo.environment["DSH_UNIT_LOG"] else { return }
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
    }

    /// Two questions in the shape the host asks them: ids, a multi-select and a single one.
    private func twoQuestions() -> [JSON] {
        let branch: JSON = .obj([("id", .string("q1")),
                                 ("question", .string("Which branch?")),
                                 ("options", .array([.obj([("label", .string("main"))])]))])
        let checks: JSON = .obj([("id", .string("q2")),
                                 ("question", .string("Which checks?")),
                                 ("multiSelect", .bool(true)),
                                 ("options", .array([.obj([("label", .string("unit"))]),
                                                     .obj([("label", .string("ui"))])]))])
        return [branch, checks]
    }

    /// (a) Skip: every answer is a skip, even for a question the reader had picked before tapping it, and the
    /// `custom` key is absent rather than empty — the host reads a present-but-empty custom as an answer.
    func testSkipSendsEveryQuestionAsASkip() {
        let answers = QuestionDock.answers(questions: twoQuestions(),
                                           selected: ["q1": ["main"], "q2": ["ui"]],
                                           custom: ["q1": "release/2.1"],
                                           skipAll: true)
        print("question skip: skipAll — \(answers.map(\.compact).joined(separator: " | "))")
        XCTAssertEqual(answers.count, 2, "a skip must still answer every question, or the host waits")
        for (i, a) in answers.enumerated() {
            XCTAssertEqual(a["id"].string, "q\(i + 1)", "the skip lost the question's id")
            XCTAssertEqual(a["selected"].array.count, 0, "a skip carried a selection: \(a.compact)")
            XCTAssertTrue(a["custom"].isNull, "a skip carried a custom answer: \(a.compact)")
            XCTAssertFalse(a.object.keys.contains("custom"), "a skip sent an empty `custom` key: \(a.compact)")
        }
    }

    /// (b) A partial answer: one of two questions picked, the other left alone. The picked one travels whole and
    /// the untouched one travels as the skip the host reads as "asked and skipped".
    func testOneAnsweredQuestionSendsTheOtherAsASkip() {
        let answers = QuestionDock.answers(questions: twoQuestions(),
                                           selected: ["q1": ["main"]],
                                           custom: [:],
                                           skipAll: false)
        print("question skip: partial — \(answers.map(\.compact).joined(separator: " | "))")
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers[0]["selected"].array.map(\.str), ["main"], "the picked question lost its pick")
        XCTAssertTrue(answers[0]["custom"].isNull, "an untouched Other field became a custom answer")
        XCTAssertEqual(answers[1]["selected"].array.count, 0, "the unanswered question was not sent as a skip")
        XCTAssertFalse(answers[1].object.keys.contains("custom"), "the unanswered question sent a `custom` key")
    }

    /// The custom text is trimmed and carried only when there is something to carry — the other half of the same
    /// contract, and the reason the refusal can be dropped for a question that has only text.
    func testCustomTextIsTrimmedAndCarriedWithoutAPick() {
        let answers = QuestionDock.answers(questions: twoQuestions(),
                                           selected: [:],
                                           custom: ["q1": "  release/2.1  "],
                                           skipAll: false)
        print("question skip: custom only — \(answers[0].compact)")
        XCTAssertEqual(answers[0]["custom"].string, "release/2.1", "the custom answer was not trimmed")
        XCTAssertEqual(answers[0]["selected"].array.count, 0)
    }

    /// The row the operator asked for: Skip is really drawn beside Send answer, at the platform's 44 pt, and the
    /// send button is still the one filled control. Read from the render because SwiftUI builds its accessibility
    /// nodes only for a client that asks, so `question.skip` cannot be read off a hosted view (measured for
    /// `queue.sendnow` in `ComposerLayoutTests`).
    ///
    /// The filled send button is the only solid block of accent on the screen, so its own bounding box is its
    /// frame: if it stops short of the dock's right content edge and there is ink beyond it in the same band,
    /// a second control is beside it — and Skip's height is that block's height.
    func testSkipIsDrawnBesideTheFilledSendButton() {
        let dock = QuestionDock(question: ChatTopStatus.LiveQuestion(id: "call-1", callId: "call-1", eventId: nil, questions: twoQuestions()),
                                chat: ChatModel(id: "session-skip", app: nil))
            .environment(AppModel())
            .frame(width: 374)
            .background(Color.white)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: dock)
        renderer.scale = 2
        guard let cg = renderer.cgImage, let data = cg.dataProvider?.data as Data? else {
            return XCTFail("the dock did not render")
        }
        let bpp = max(1, cg.bitsPerPixel / 8)
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * cg.width + x) * bpp
            return (Int(data[data.startIndex + i]), Int(data[data.startIndex + i + 1]), Int(data[data.startIndex + i + 2]))
        }
        /// The accent slate: the fill of the one prominent button.
        func filled(_ x: Int, _ y: Int) -> Bool { let c = px(x, y); return c.0 < 120 && c.1 < 120 && c.2 < 120 }
        /// Anything that is not the warm paper: labels, borders, the fill.
        func inked(_ x: Int, _ y: Int) -> Bool { let c = px(x, y); return c.0 < 235 || c.1 < 235 || c.2 < 235 }

        let fillRows = (0..<cg.height).filter { y in (0..<cg.width).filter { filled($0, y) }.count > cg.width / 4 }
        guard let top = fillRows.first, let bottom = fillRows.last else {
            return XCTFail("no filled send button was drawn")
        }
        var fillMaxX = 0, fillMinX = cg.width
        for y in fillRows {
            for x in 0..<cg.width where filled(x, y) { fillMaxX = max(fillMaxX, x); fillMinX = min(fillMinX, x) }
        }
        // The dock's own 14 pt padding, at the renderer's 2×.
        let contentRight = cg.width - 28
        let beside = fillMaxX + 4 < contentRight
            ? (fillMaxX + 4..<contentRight).filter { x in fillRows.contains { inked(x, $0) } }
            : []
        print("question skip: render \(cg.width)x\(cg.height) px — fill \(fillMinX)..\(fillMaxX) of \(contentRight), rows \(top)..\(bottom) (\(bottom - top + 1) px tall), ink beside it: \(beside.count) cols")

        XCTAssertGreaterThanOrEqual(bottom - top + 1, 88, "the send button is under 44 pt tall: \(bottom - top + 1) px")
        XCTAssertGreaterThanOrEqual(fillMinX, 24, "the send button does not start at the dock's left padding: \(fillMinX)")
        XCTAssertLessThanOrEqual(fillMaxX, contentRight - 40, "the send button still fills the whole row: no Skip beside it")
        XCTAssertGreaterThan(beside.count, 8, "nothing is drawn beside the send button")
    }
}
