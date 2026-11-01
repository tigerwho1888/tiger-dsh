import XCTest
@testable import TigerDSH

/// A provider that hits its limit must not leave a red card when the Mac's fallback provider answers (operator,
/// 2026-10-13: "If all providers ran out of service, I'm fine with the warning").
@MainActor
final class ProviderFallbackTests: XCTestCase {
    private func ev(_ seq: Int, _ type: String, _ data: [(String, JSON?)]) -> JSON {
        .obj([("seq", .number(Double(seq))), ("type", .string(type)), ("data", .obj(data))])
    }

    private func failedAttempt(_ seq: Int) -> JSON {
        let finish: JSON = .obj([("type", .string("finish")), ("reason", .obj([("kind", .string("error")),
            ("failure", .obj([("message", .string("429: {\"message\":\"weekly limit\"}"))]))]))])
        return ev(seq, "assistant/attempt", [("turn", .number(1)), ("step", .number(1)),
            ("stream", .array([.obj([("type", .string("chunk")), ("chunk", finish)])]))])
    }

    private func errors(_ m: ChatModel) -> Int { m.items.filter { $0.kind == .error }.count }

    func testFallbackThatAnswersShowsNoCard() {
        let m = ChatModel(id: "session-test", app: nil)
        m.reduce(ev(1, "turn/start", [("turn", .number(1))]), live: false)
        m.reduce(failedAttempt(2), live: false)
        m.reduce(ev(3, "request/header", [("header", .obj([]))]), live: false)
        XCTAssertEqual(errors(m), 1, "the card waits for the next provider's outcome")
        m.reduce(ev(4, "assistant/message", [("turn", .number(1)), ("step", .number(1)),
            ("message", .obj([("content", .array([.obj([("type", .string("text")), ("text", .string("hi"))])]))]))]), live: false)
        m.reduce(ev(5, "turn/end", [("turn", .number(1)), ("reason", .obj([("kind", .string("completed"))]))]), live: false)
        XCTAssertEqual(errors(m), 0, "the answer from the next provider clears the card")
    }

    func testEveryProviderFailingStillShowsOneCard() {
        let m = ChatModel(id: "session-test", app: nil)
        m.reduce(ev(1, "turn/start", [("turn", .number(1))]), live: false)
        m.reduce(failedAttempt(2), live: false)
        m.reduce(ev(3, "request/header", [("header", .obj([]))]), live: false)
        m.reduce(failedAttempt(4), live: false)
        m.reduce(ev(5, "turn/end", [("turn", .number(1)), ("reason", .obj([("kind", .string("error")),
            ("error", .obj([("message", .string("429"))]))]))]), live: false)
        XCTAssertEqual(errors(m), 2, "every provider's failure shows once all of them failed, and turn/end adds none")
    }

    func testFailedAttemptIsHiddenWhileTheTurnRuns() {
        let m = ChatModel(id: "session-test", app: nil)
        m.reduce(ev(1, "turn/start", [("turn", .number(1))]), live: true)
        m.reduce(failedAttempt(2), live: true)
        XCTAssertFalse(m.display.contains { $0.kind == .error }, "no 429 card between the attempt and the fallback")
        m.reduce(ev(3, "turn/end", [("turn", .number(1)), ("reason", .obj([("kind", .string("error")),
            ("error", .obj([("message", .string("429"))]))]))]), live: true)
        XCTAssertEqual(m.display.filter { $0.kind == .error }.count, 1, "the card shows once the turn ends on it")
    }

    /// Operator, 2026-10-15: "hide warning/error of end points in the middle of fallback chain. Reveal them all
    /// together when all end points in the chain fail".
    func testRetryWarningsHideUntilTheChainFails() {
        let m = ChatModel(id: "session-test", app: nil)
        m.reduce(ev(1, "turn/start", [("turn", .number(1))]), live: true)
        m.reduce(ev(2, "llm/retry", [("turn", .number(1)), ("step", .number(1)), ("retryId", .string("x")),
            ("retry", .number(1)), ("failure", .obj([("message", .string("503"))]))]), live: true)
        m.reduce(failedAttempt(3), live: true)
        XCTAssertFalse(m.display.contains { $0.kind == .retry || $0.kind == .error }, "a warning showed mid-chain")
        m.reduce(ev(4, "turn/end", [("turn", .number(1)), ("reason", .obj([("kind", .string("error")),
            ("error", .obj([("message", .string("429"))]))]))]), live: true)
        XCTAssertEqual(m.display.filter { $0.kind == .retry || $0.kind == .error }.count, 2, "all of them show together")
    }

    func testRetryWarningGoesWhenTheChainAnswers() {
        let m = ChatModel(id: "session-test", app: nil)
        m.reduce(ev(1, "turn/start", [("turn", .number(1))]), live: false)
        m.reduce(ev(2, "llm/retry", [("turn", .number(1)), ("step", .number(1)), ("retryId", .string("x")),
            ("failure", .obj([("message", .string("503"))]))]), live: false)
        m.reduce(ev(3, "assistant/message", [("turn", .number(1)), ("step", .number(1)),
            ("message", .obj([("content", .array([.obj([("type", .string("text")), ("text", .string("hi"))])]))]))]), live: false)
        XCTAssertFalse(m.items.contains { $0.kind == .retry }, "a recovered retry left its warning behind")
    }

    func testAnsweredTurnDropsCardsFromEarlierSteps() {
        let m = ChatModel(id: "session-test", app: nil)
        m.reduce(ev(1, "turn/start", [("turn", .number(1))]), live: false)
        m.reduce(failedAttempt(2), live: false)
        m.reduce(ev(3, "turn/end", [("turn", .number(1)), ("reason", .obj([("kind", .string("completed"))]))]), live: false)
        XCTAssertEqual(errors(m), 0, "a turn that answered still showed an endpoint's failure")
    }
}
