import XCTest
import SwiftUI
@testable import TigerDSH

/// The island must stop asking for an answer that has been given (operator's screenshot, R21: "Count from 1 to 400"
/// still said "Waiting for your answer" after the answer).
///
/// Two things decide what the island says: which waiting request wins (`AppModel.islandPlan`, pure so it can be
/// asserted without ActivityKit), and whether a request is still in `waterQuestions` at all. The answer path, a run
/// that ends, and a return to the foreground are the three ways an entry can outlive its question, and each is
/// pinned here.
@MainActor
final class QuestionLifecycleTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        guard let path = ProcessInfo.processInfo.environment["DSH_UNIT_LOG"] else { return }
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
    }

    // MARK: fixtures

    private func row(_ id: String, running: Bool, title: String = "Count from 1 to 400") -> SessionRow {
        SessionRow(id: id, updated: 0, running: running, blank: false, isSub: false, cwd: "", title: title,
                   questions: 0, model: nil, snippet: "")
    }

    /// A `user-questions/request` waterfall, in the shape the host sends it.
    private func question(event: String, sid: String, call: String, text: String) -> JSON {
        .obj([("eventId", .string(event)), ("agentId", .string(sid)),
              ("request", .obj([("wait", .obj([("callId", .string(call))])),
                                ("questions", .array([.obj([("id", .string("q1")), ("question", .string(text))])]))]))])
    }

    private func approval(event: String, sid: String) -> JSON {
        .obj([("eventId", .string(event)), ("agentId", .string(sid)), ("summary", .string("rm -rf build"))])
    }

    private func open(_ sid: String, running: Bool, title: String) -> (sid: String, title: String, running: Bool, turnStart: Date?, step: String) {
        (sid: sid, title: title, running: running, turnStart: Date(timeIntervalSince1970: 1_000), step: "Working")
    }

    // MARK: (a) the answer the phone gave itself

    /// The card answered through `userQuestions/answer` — the door that has no waterfall of its own — and the island
    /// must go back to the chat's run rather than keep asking. The entry leaves, the answer is counted, and the plan
    /// the island reads is `.running`.
    func testAnsweringFromTheCardClearsThatChatsQuestionAndLeavesTheIslandRunning() {
        let app = AppModel()
        let sid = "session-a"
        app.rows[sid] = row(sid, running: true)
        app.listReady = true
        app.waterQuestions["ev-1"] = question(event: "ev-1", sid: sid, call: "call-1", text: "Keep counting past 400?")
        let before = app.answeredTick

        app.questionAnswered(sid: sid, callId: "call-1")

        print("question lifecycle: answer via userQuestions/answer — waterQuestions \(app.waterQuestions.count), tick \(app.answeredTick - before)")
        XCTAssertTrue(app.waterQuestions.isEmpty, "the answered question is still in the app's list")
        XCTAssertEqual(app.answeredTick, before + 1, "the answer was not counted as given")

        let plan = AppModel.islandPlan(questions: app.waterQuestions, approvals: app.approvals,
                                       open: open(sid, running: true, title: "Count from 1 to 400"),
                                       title: { _ in "Count from 1 to 400" })
        XCTAssertEqual(plan?.phase, .running, "the island is still waiting after the answer was given")
        XCTAssertEqual(plan?.sid, sid)
    }

    /// The match is the request's own callId: an answer for another call — or another chat — must not take a
    /// question that is still waiting off the island.
    func testAnAnswerForAnotherCallLeavesTheWaitingQuestionAlone() {
        let app = AppModel()
        app.rows["session-a"] = row("session-a", running: true)
        app.waterQuestions["ev-1"] = question(event: "ev-1", sid: "session-a", call: "call-1", text: "Keep counting?")
        app.waterQuestions["ev-2"] = question(event: "ev-2", sid: "session-b", call: "call-2", text: "Which branch?")

        app.questionAnswered(sid: "session-a", callId: "call-2")
        XCTAssertEqual(app.waterQuestions.count, 2, "an answer for another chat's call removed a waiting question")

        app.questionAnswered(sid: "session-a", callId: "call-1")
        XCTAssertEqual(Array(app.waterQuestions.keys), ["ev-2"], "the answered chat's entry survived, or another's went")
    }

    /// A waterfall frame with no `wait.callId` cannot be matched, so the chat's questions all go: a stranded entry
    /// is the lie this path exists to prevent.
    func testAnAnswerWithNoCallIdClearsEveryQuestionThatChatHasWaiting() {
        let app = AppModel()
        app.waterQuestions["ev-1"] = question(event: "ev-1", sid: "session-a", call: "", text: "Keep counting?")
        app.waterQuestions["ev-2"] = question(event: "ev-2", sid: "session-b", call: "call-2", text: "Which branch?")
        app.waterQuestions["ev-3"] = question(event: "ev-3", sid: "session-a", call: "call-3", text: "And this one?")

        app.questionAnswered(sid: "session-a", callId: nil)

        XCTAssertEqual(Array(app.waterQuestions.keys), ["ev-2"], "a no-callId answer did not clear its chat's questions")
    }

    // MARK: (b) a run that is no longer there

    /// A chat the host no longer reports as running has nothing pending: the question died with the run, and the host
    /// sends no cancel for it. The running chat's question stays.
    func testAStoppedChatsPendingQuestionIsDropped() {
        let app = AppModel()
        app.rows["session-a"] = row("session-a", running: true)
        app.rows["session-b"] = row("session-b", running: false)
        app.listReady = true
        app.waterQuestions["ev-1"] = question(event: "ev-1", sid: "session-a", call: "call-1", text: "Keep counting?")
        app.waterQuestions["ev-2"] = question(event: "ev-2", sid: "session-b", call: "call-2", text: "Which branch?")
        app.approvals = [approval(event: "ap-1", sid: "session-a"), approval(event: "ap-2", sid: "session-b")]

        app.prunePendingNotRunning()

        print("question lifecycle: stopped chat — questions \(app.waterQuestions.keys.sorted()), approvals \(app.approvals.count)")
        XCTAssertEqual(Array(app.waterQuestions.keys), ["ev-1"], "a stopped chat's question was kept, or a running chat's was dropped")
        XCTAssertEqual(app.approvals.map { $0["eventId"].str }, ["ap-1"], "a stopped chat's approval was kept")
    }

    /// A run that started while the phone was away is missing from a list fetched before it: its question must survive
    /// until a list newer than the question says the run has ended (Codex r18 P1).
    func testAListOlderThanTheQuestionDoesNotDropIt() {
        let app = AppModel()
        app.rows["session-a"] = row("session-a", running: false)
        app.listReady = true
        app.listAt = 1_000
        app.waterQuestions["ev-1"] = question(event: "ev-1", sid: "session-a", call: "call-1", text: "Keep counting?")
        app.pendingSeen["ev-1"] = 2_000

        app.prunePendingNotRunning()
        XCTAssertEqual(app.waterQuestions.count, 1, "a list older than the question dropped it")

        app.listAt = 3_000
        app.prunePendingNotRunning()
        XCTAssertEqual(app.waterQuestions.count, 0, "a newer list that says the run ended did not drop it")
    }

    /// A list that has not arrived yet is not an authority: pruning on it would wipe a question that had just come in.
    func testNothingIsPrunedBeforeTheRunListIsHere() {
        let app = AppModel()
        app.waterQuestions["ev-1"] = question(event: "ev-1", sid: "session-a", call: "call-1", text: "Keep counting?")

        app.prunePendingNotRunning()

        XCTAssertEqual(app.waterQuestions.count, 1, "a question was dropped against a list that had not loaded")
    }

    /// Stopping a run and archiving a chat both take that chat's waiting requests with them, and leave other chats'
    /// requests alone.
    func testStoppingOrArchivingAChatTakesItsWaitingRequestsWithIt() {
        let app = AppModel()
        app.waterQuestions["ev-1"] = question(event: "ev-1", sid: "session-a", call: "call-1", text: "Keep counting?")
        app.waterQuestions["ev-2"] = question(event: "ev-2", sid: "session-b", call: "call-2", text: "Which branch?")
        app.approvals = [approval(event: "ap-1", sid: "session-a")]

        app.pendingDropped(sid: "session-a")

        XCTAssertEqual(Array(app.waterQuestions.keys), ["ev-2"])
        XCTAssertTrue(app.approvals.isEmpty, "the stopped chat's approval stayed on the island")
    }

    // MARK: (c) which waiting chat the island speaks for

    /// Two chats waiting, and the reader is looking at one of them: that chat's question is the one on the island.
    func testWithTwoChatsWaitingTheOpenChatsQuestionWins() {
        let questions = ["ev-a": question(event: "ev-a", sid: "session-a", call: "call-a", text: "Which branch?"),
                         "ev-b": question(event: "ev-b", sid: "session-b", call: "call-b", text: "Which checks?")]

        let plan = AppModel.islandPlan(questions: questions, approvals: [],
                                       open: open("session-b", running: true, title: "Checks"),
                                       title: { "Chat " + $0 })

        print("question lifecycle: two waiting — island speaks for \(plan?.sid ?? "nobody"), detail \(plan?.detail ?? "-")")
        XCTAssertEqual(plan?.sid, "session-b", "the island asked about a chat the reader was not looking at")
        XCTAssertEqual(plan?.phase, .needsYou)
        XCTAssertEqual(plan?.detail, "Which checks?", "the island showed the wrong chat's question")
    }

    /// With no chat open the choice is stable, not whatever order the dictionary happened to have: the questions are
    /// ordered by event id, so the same two waiting chats give the same island twice.
    func testWithNoChatOpenTheChoiceIsStable() {
        let questions = ["ev-b": question(event: "ev-b", sid: "session-b", call: "call-b", text: "Which checks?"),
                         "ev-a": question(event: "ev-a", sid: "session-a", call: "call-a", text: "Which branch?")]

        let first = AppModel.islandPlan(questions: questions, approvals: [], open: nil, title: { "Chat " + $0 })
        let second = AppModel.islandPlan(questions: questions, approvals: [], open: nil, title: { "Chat " + $0 })

        XCTAssertEqual(first?.sid, "session-a")
        XCTAssertEqual(first, second, "the island's choice moved between two identical passes")
    }

    /// The open chat's approval is the thing its run cannot go on without, so it beats another chat's question.
    func testTheOpenChatsApprovalWinsOverAnotherChatsQuestion() {
        let plan = AppModel.islandPlan(questions: ["ev-a": question(event: "ev-a", sid: "session-a", call: "call-a", text: "Which branch?")],
                                       approvals: [approval(event: "ap-b", sid: "session-b")],
                                       open: open("session-b", running: true, title: "Build"),
                                       title: { "Chat " + $0 })

        XCTAssertEqual(plan?.phase, .needsApproval)
        XCTAssertEqual(plan?.sid, "session-b")
        XCTAssertEqual(plan?.approvalId, "ap-b")
    }

    // MARK: the update budget never swallows a phase change

    /// The island must stop saying "Waiting for your answer" the moment it is answered, so a phase change is never
    /// deduped; a state whose words are the same is, `updatedAt` and `startedAt` included in neither.
    func testAPhaseChangeIsNeverDeduped() {
        var waiting = RunActivityAttributes.ContentState(
            phase: .needsYou, title: "Count from 1 to 400", step: "Waiting for your answer",
            detail: "Keep counting past 400?", approvalId: nil, startedAt: Date(timeIntervalSince1970: 1_000))
        var running = waiting
        running.phase = .running
        running.step = "Working"
        running.detail = nil

        XCTAssertTrue(RunActivity.shouldSend(running, after: waiting), "the change out of needsYou was swallowed")

        // The same words, a moment later: the dates move, the island does not.
        var again = waiting
        again.updatedAt = Date()
        again.startedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(RunActivity.shouldSend(again, after: waiting), "a state whose words are unchanged was sent again")

        // A second approval keeps the phase but must reach the island's own buttons.
        var second = waiting
        second.phase = .needsApproval
        second.approvalId = "ap-2"
        XCTAssertTrue(RunActivity.shouldSend(second, after: waiting), "a new approval never reached the island's buttons")
    }

    // MARK: the card says it once

    /// The waiting card's second line is the question itself, and the mono tile is not drawn — that is the shape
    /// that made the operator's card read "Waiting for your answer" three times over. A card with nothing to put in
    /// the tile does not draw an empty one.
    func testTheWaitingCardShowsTheQuestionOnItsSecondLineAndNoTiles() {
        let waiting = RunActivityAttributes.ContentState(
            phase: .needsYou, title: "Count from 1 to 400", step: "Waiting for your answer",
            detail: "Should I keep counting past 400?", approvalId: nil, startedAt: Date())
        let plain = RunActivityAttributes.ContentState(
            phase: .running, title: "Count from 1 to 400", step: "Running bash", detail: nil,
            approvalId: nil, startedAt: Date())
        let command = RunActivityAttributes.ContentState(
            phase: .running, title: "Count from 1 to 400", step: "Running bash", detail: "xcodebuild test",
            approvalId: nil, startedAt: Date())

        print("question lifecycle: card lines — waiting \"\(RunCard.secondLine(waiting))\", running \"\(RunCard.secondLine(plain))\"")
        XCTAssertEqual(RunCard.secondLine(waiting), "Should I keep counting past 400?")
        XCTAssertFalse(RunCard.showsOperation(waiting), "the question was drawn a third time in the mono tile")
        XCTAssertEqual(RunCard.secondLine(plain), "Running bash")
        XCTAssertFalse(RunCard.showsOperation(plain), "an empty mono tile was drawn")
        XCTAssertTrue(RunCard.showsOperation(command), "the command a run is on lost its tile")
    }

    /// "Ready to read" lists only chats that finished unseen, and a chat drops out of it once opened.
    func testReadyToReadFilterFollowsDoneUnseen() {
        let app = AppModel()
        let saved = (app.doneUnseen, app.currentChatID)
        defer { app.currentChatID = saved.1; app.doneUnseen = saved.0 }
        app.rows["r1"] = row("r1", running: false)
        app.rows["r2"] = row("r2", running: false)
        app.rows["r3"] = row("r3", running: true)
        app.doneUnseen = ["r1", "r3"]
        XCTAssertEqual(app.chats(filter: .unread).map(\.id), ["r1"], "a chat that started running again is not ready to read")
        app.currentChatID = "r1"
        XCTAssertTrue(app.chats(filter: .unread).isEmpty)
    }
}
