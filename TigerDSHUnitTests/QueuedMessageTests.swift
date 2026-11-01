import XCTest
@testable import TigerDSH

/// The queued card's data path.
///
/// t13's `testQueuePill` typed and sent "queue this one" into a running turn, waited twenty seconds, and never saw
/// `queue.sendnow`. The host's own session log says the message really was queued — `agent/inbox/spliced` into
/// `next-turn` at 13:55:09.7 and spliced out at 13:55:18.6 — so the card's window was nine seconds wide, and the app
/// drew nothing in it. The card is drawn from the host's `inbox` projection, which the host pushes like any other;
/// this pins the app's half: after the host accepts a prompt the app also ASKS for the session's projections once, so
/// the card does not depend on a push landing inside that window.
///
/// `DSHClient.rpcStub` is the Debug-only door to a host answer (`ChatModel.pageCall`'s `fetchPage` is the same idea
/// for `session/page`), because "the push was late" cannot be asked of a real Mac on cue.
@MainActor
final class QueuedMessageTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        guard let path = ProcessInfo.processInfo.environment["DSH_UNIT_LOG"] else { return }
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
    }

    override func tearDown() {
        DSHClient.shared.rpcStub = nil
        super.tearDown()
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what)
    }

    /// One inbox item in the shape the host's projection carries it: the message the reader queued, with the
    /// `rpcId` the prompt was sent under — that is what ties the card to the app's own record of the send.
    private func item(_ text: String, rpc: String) -> JSON {
        .obj([
            ("id", .string("m-" + rpc)),
            ("role", .string("user")),
            ("content", .array([.obj([("type", .string("text")), ("text", .string(text))])])),
            ("source", .obj([("kind", .string("user")), ("rpcId", .string(rpc))]))])
    }

    private func inbox(_ items: [JSON]) -> JSON {
        .obj([("next-turn", .array(items)), ("next-step", .array([]))])
    }

    /// The send path asks, and the answer draws the card with its pill — and the message is NOT drawn twice, as a
    /// pending bubble under a card.
    func testASentMessageReadsTheSessionsInboxSoTheCardAppears() async {
        let client = DSHClient.shared
        var methods: [String] = []
        var sentUnder = ""
        client.rpcStub = { method, args in
            methods.append(method)
            switch method {
            case "session/prompt":
                sentUnder = args["request"]["requestId"].str
                return .object(["accepted": .bool(true)])
            case "session/projections":
                XCTAssertEqual(args["request"]["sessionId"].str, "session-queue",
                               "the read has to name the chat the prompt was sent to")
                return .object(["kind": .string("sequenced"), "asOfSeq": .number(20),
                                "values": .object(["inbox": self.inbox([self.item("queue this one", rpc: sentUnder)])])])
            default:
                return .null
            }
        }

        let chat = ChatModel(id: "session-queue", app: nil)
        chat.running = true
        chat.send(text: "queue this one", attachments: [])
        await waitUntil("the app never read the session's projections after the send") {
            methods.contains("session/projections")
        }

        XCTAssertEqual(methods, ["session/prompt", "session/projections"],
                       "the inbox is read once, after the host accepted the prompt")
        let cards = QueueCards.cards(chat)
        XCTAssertEqual(cards.count, 1, "the queued message is not drawn as a card")
        XCTAssertEqual(cards.first?.item["content"][0]["text"].str, "queue this one")
        XCTAssertEqual(cards.first?.item["id"].str, "m-" + sentUnder,
                       "the card has to carry the host's own item id: Send now steers that item")
        XCTAssertEqual(cards.first?.kind, "next-turn")
        XCTAssertTrue(QueueCards.offersSendNow(cards[0].kind, running: chat.running),
                      "a queued message in a running chat has no Send now pill")
        XCTAssertFalse(chat.display.contains { $0.kind == .pending },
                       "the queued message is drawn twice: once as the card and once as a pending bubble")
    }

    /// The Mac's busy-send choice decides how a message sent into a running turn travels (operator, 2026-10-14: the
    /// Mac was set to steer, and the phone still queued). Steer only while the agent works; an idle chat always queues.
    func testTheMacsSteerChoiceSteersARunningTurn() async {
        let client = DSHClient.shared
        var modes: [String] = []
        client.rpcStub = { method, args in
            if method == "session/prompt" { modes.append(args["request"]["mode"].str) }
            return .object(["accepted": .bool(true)])
        }
        let app = AppModel()
        let chat = ChatModel(id: "session-steer", app: app)

        app.busyEnter = "steer"
        chat.running = true
        chat.send(text: "steer this", attachments: [])
        await waitUntil("the steer was never sent") { modes.count == 1 }
        chat.running = false
        chat.send(text: "idle chat", attachments: [])
        await waitUntil("the idle send was never sent") { modes.count == 2 }
        app.busyEnter = "queue"
        chat.running = true
        chat.send(text: "queue this", attachments: [])
        await waitUntil("the queued send was never sent") { modes.count == 3 }

        XCTAssertEqual(modes, ["steer", "queue", "queue"],
                       "steer goes into a running turn only when the Mac is set to steer")
    }

    /// A host that cannot answer the read — an older DSH, a dropped socket — must not turn a sent message into a
    /// failed one, and the push the host does send still draws the card. The read is a repair, not the mechanism.
    func testAReadThatFailsLeavesTheSendAndThePushAlone() async {
        let client = DSHClient.shared
        var methods: [String] = []
        client.rpcStub = { method, _ in
            methods.append(method)
            if method == "session/prompt" { return .object(["accepted": .bool(true)]) }
            throw RPCError(kind: .missing, code: "missing", message: "Not available in this DSH version")
        }

        let chat = ChatModel(id: "session-queue", app: nil)
        chat.running = true
        chat.send(text: "queue this one", attachments: [])
        await waitUntil("the send never finished") { methods.contains("session/projections") }

        XCTAssertEqual(chat.pending.first?.state, "sent",
                       "a read that failed marked the message itself as failed")
        XCTAssertTrue(QueueCards.cards(chat).isEmpty, "nothing was pushed, so there is no card to draw")

        // The push, the way the app gets it when everything is well: a control frame for this session.
        let rpc = chat.pending.first?.rpc ?? ""
        chat.projectionFromControl(sessionId: "session-queue", key: "inbox", value: inbox([item("queue this one", rpc: rpc)]))
        XCTAssertEqual(QueueCards.cards(chat).count, 1, "the pushed inbox no longer draws the card")
    }

    /// The read's reply lands after an `await`, and the host keeps pushing `inbox` while it is in flight. The push
    /// that matters here is a REMOVAL — the running turn ended and the host spliced the queued message out. A reply
    /// describing the inbox from before that push must not put the card back and offer Send now for an item that is
    /// no longer queued (Codex R15 P1).
    func testADelayedReplyDoesNotResurrectACardTheHostRemoved() async {
        let client = DSHClient.shared
        let queued = item("queue this one", rpc: "r-queued")
        var asked = 0
        var gateOpen = false
        client.rpcStub = { method, _ in
            guard method == "session/projections" else { return .null }
            asked += 1
            while !gateOpen { try? await Task.sleep(for: .milliseconds(10)) }
            return .object(["values": .object(["inbox": self.inbox([queued])])])
        }

        let chat = ChatModel(id: "session-queue", app: nil)
        chat.running = true
        chat.projectionFromControl(sessionId: "session-queue", key: "inbox", value: inbox([queued]))
        XCTAssertEqual(QueueCards.cards(chat).count, 1, "the pushed card is not drawn")
        XCTAssertTrue(QueueCards.offersSendNow(QueueCards.cards(chat)[0].kind, running: chat.running),
                      "a queued message in a running chat has no Send now pill")

        let read = Task { await chat.refreshInbox() }
        await waitUntil("the read never reached the host") { asked == 1 }

        // The turn ends, the host splices the message out, and the push is what the app sees.
        chat.projectionFromControl(sessionId: "session-queue", key: "inbox", value: inbox([]))
        XCTAssertTrue(QueueCards.cards(chat).isEmpty, "the removal push did not clear the card")

        // Only now does the read's answer — an inbox holding the message — come back.
        gateOpen = true
        await read.value

        XCTAssertTrue(QueueCards.cards(chat).isEmpty,
                      "the delayed reply resurrected a card the host had already removed")
    }

    /// Two reads in flight, the second asked while the first is still out. The second holds the newer inbox and
    /// answers first; the first's late answer must not overwrite it, or a card the app has already replaced comes
    /// back (Codex R15 P1).
    func testTheNewerOfTwoOverlappingRefreshesWins() async {
        let client = DSHClient.shared
        let older = item("the older answer", rpc: "r-old")
        let newer = item("the newer answer", rpc: "r-new")
        var asked = 0
        var gateOpen = false
        client.rpcStub = { method, _ in
            guard method == "session/projections" else { return .null }
            asked += 1
            if asked == 1 {
                // The first read is the slow one: it is still out when the second is asked and answered.
                while !gateOpen { try? await Task.sleep(for: .milliseconds(10)) }
                return .object(["values": .object(["inbox": self.inbox([older])])])
            }
            return .object(["values": .object(["inbox": self.inbox([newer])])])
        }

        let chat = ChatModel(id: "session-queue", app: nil)
        let first = Task { await chat.refreshInbox() }
        await waitUntil("the first read never reached the host") { asked == 1 }

        await chat.refreshInbox()
        XCTAssertEqual(QueueCards.cards(chat).map { $0.item["id"].str }, ["m-r-new"],
                       "the newer of two overlapping reads did not land")

        gateOpen = true
        await first.value

        XCTAssertEqual(QueueCards.cards(chat).map { $0.item["id"].str }, ["m-r-new"],
                       "the earlier read's late reply overwrote the newer inbox")
    }
}
