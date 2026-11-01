import XCTest
@testable import TigerDSH

/// The chat model's paging paths, in-process. A UI test drives the app and reads the rows on screen; these are the
/// two things it cannot see — the ORDER a batch of pages lands in, and which replies count as a page at all
/// (Codex R6 P1/P2). The pages are built the way `fetchBatch` builds them: rows in sequence order, the page's own
/// frontier, and the host's own `hasMore`.
@MainActor
final class ChatModelPagingTests: XCTestCase {
    /// XCTest's own report goes to the console, which a run started without a terminal does not have: `DSH_UNIT_LOG`
    /// names a file to copy stdout and stderr into, so the same run can be read afterwards. Unset — every run
    /// xcodebuild starts — nothing is redirected and the console output is exactly as it was.
    override class func setUp() {
        super.setUp()
        guard let path = ProcessInfo.processInfo.environment["DSH_UNIT_LOG"] else { return }
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
    }

    private func page(_ seqs: [Int], hasMore: Bool = true) -> ChatModel {
        let p = ChatModel(id: "session-test", app: nil)
        p.items = seqs.map { ChatItem(key: "a\($0)", kind: .assistant, seq: $0) }
        p.firstSeq = seqs.min() ?? .max
        p.hasMore = hasMore
        return p
    }

    private func model(_ existing: [Int]) -> ChatModel {
        let m = ChatModel(id: "session-test", app: nil)
        m.items = existing.map { ChatItem(key: "a\($0)", kind: .assistant, seq: $0) }
        m.firstSeq = existing.min() ?? .max
        return m
    }

    /// Three pages, an overlap and rows already loaded. The pages arrive NEWEST-first — the order `pageChain`
    /// fetches them in — and the merged transcript has to read oldest-first all the way through: the old
    /// page-by-page merge produced `[80, 81, 60, 61, 40, 41, 100, 101]` here.
    func testBatchMergeLandsInSequenceOrder() {
        let m = model([100, 101])
        m.merge([page([80, 81]), page([60, 61, 80]), page([40, 41])])
        XCTAssertEqual(m.items.map(\.seq), [40, 41, 60, 61, 80, 81, 100, 101])
        XCTAssertEqual(m.items.count, 8, "the row two pages both carry is deduplicated")
        XCTAssertEqual(m.firstSeq, 40, "the frontier is the oldest page's")
    }

    /// The deliverables come from the same pages and keep the same order; they were reversed by the same loop.
    func testBatchMergeKeepsDeliverablesInPageOrder() {
        let m = model([])
        let older = page([40]); older.deliverables = [.init(path: "old.txt", description: "")]
        let newer = page([60]); newer.deliverables = [.init(path: "new.txt", description: "")]
        m.merge([newer, older])
        XCTAssertEqual(m.deliverables.map(\.path), ["old.txt", "new.txt"])
    }

    /// Whether the list can still pull is the OLDEST page's frontier, not the page nearest the reader.
    func testBatchMergeTakesHasMoreFromTheOldestPage() {
        let m = model([100])
        m.merge([page([80], hasMore: true), page([40], hasMore: false)])
        XCTAssertFalse(m.hasMore)
        XCTAssertEqual(m.items.map(\.seq), [40, 80, 100])
    }

    /// A page of nothing but metadata — turn/end, tool/result — has no rows and is still a page. It carries the
    /// turn's frontier and the state the rows are read against; dropping it ended a walk mid-history (Codex R6 P2).
    func testAMetadataOnlyPageIsStillAPage() {
        let m = model([])
        let reply: JSON = ["records": [
            ["event": ["seq": 7, "type": "turn/end", "data": ["turn": 1, "reason": ["kind": "done"]]]],
            ["event": ["seq": 9, "type": "tool/result", "data": ["message": ["toolCallId": "c1", "isError": false,
                "content": [["type": "text", "text": "ok"]]]]]]
        ], "hasMore": true]
        guard let p = m.page(from: reply) else { return XCTFail("a metadata-only page is a page") }
        XCTAssertTrue(p.items.isEmpty, "no rows — which is exactly what the old guard dropped it for")
        XCTAssertEqual(p.firstSeq, 7, "the frontier is the lowest EVENT sequence, rows or not")
        XCTAssertEqual(p.ends[1], 7, "the turn's own end survived")
        XCTAssertEqual(p.results["c1"]?.text, "ok", "and so did the tool result the row is rendered from")
        XCTAssertTrue(p.hasMore)
    }

    /// A metadata-only page merges its state and its frontier and leaves the rows alone.
    func testAMetadataOnlyPageMergesItsFrontierAndTurnState() {
        let m = model([100])
        guard let meta = m.page(from: ["records": [["event": ["seq": 7, "type": "turn/start", "data": ["turn": 3]]]],
                                       "hasMore": false]) else { return XCTFail("no page") }
        m.merge([meta])
        XCTAssertEqual(m.starts[3], 7)
        XCTAssertEqual(m.firstSeq, 7, "the walk advanced by the page's lowest event sequence")
        XCTAssertFalse(m.hasMore)
        XCTAssertEqual(m.items.map(\.seq), [100], "and no rows were invented")
    }

    /// Only a reply with no event records at all ends a walk.
    func testAReplyWithNoEventRecordsIsNotAPage() {
        let m = model([])
        XCTAssertNil(m.page(from: ["records": [], "hasMore": false]))
        XCTAssertNil(m.page(from: ["records": [["event": .null]], "hasMore": false]))
    }

    /// A turn the model already knows about is `found` without a walk at all — and without leaving the paging flag
    /// set for the next reader of `loadingMore`.
    func testAJumpToALoadedTurnIsFound() async {
        let m = model([])
        m.starts[3] = 4
        let outcome = await m.loadThrough(4)
        XCTAssertEqual(outcome, .found)
        XCTAssertFalse(m.loadingMore)
    }

    /// A jump the reader has replaced is `interrupted`, NOT "that turn is no longer in this chat": the walk stops
    /// before it fetches anything, and the outcome must not be readable as the history having ended (Codex R6 P2).
    func testACancelledJumpIsInterruptedRatherThanGone() async {
        let m = model([])
        let t = Task { await m.loadThrough(4) }
        t.cancel()
        let outcome = await t.value
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertFalse(m.loadingMore)
    }

    /// A negative sequence is not a turn this chat can have: it is a failure, never an exhaustion.
    func testANegativeSequenceFailsRatherThanEndingTheHistory() async {
        let m = model([])
        let outcome = await m.loadThrough(-1)
        XCTAssertEqual(outcome, .failed)
    }

    /// "That turn is no longer in this chat" belongs to ONE outcome. The cap and a request that did not come back
    /// both leave the turn possibly one page further down, and an interrupted jump is a newer jump's business —
    /// reporting either as gone is the defect Codex R6 P2 named.
    func testOnlyAnExhaustedHistorySaysTheTurnIsGone() {
        XCTAssertEqual(ChatModel.JumpOutcome.exhausted.message, "That turn is no longer in this chat.")
        XCTAssertNil(ChatModel.JumpOutcome.found.message)
        XCTAssertNil(ChatModel.JumpOutcome.interrupted.message, "a replaced jump says nothing")
        let failed = ChatModel.JumpOutcome.failed.message
        XCTAssertNotNil(failed, "a jump that could not reach the turn has to say something")
        XCTAssertFalse(failed!.contains("no longer"), "and it must not read as the turn being gone")
    }

    /// A gesture's rebuild count survives a flush. Sixty-four rebuilds is exactly what makes `rebuilt` write its own
    /// log line — and that flush clears the counts the line is built from, so a count kept there came back as a
    /// fraction of the work (Codex R6 P3).
    func testAFlushDoesNotEraseTheRebuildCount() {
        _ = Trace.takeRebuilds()
        Trace.rebuildCost(2.5)
        for _ in 0..<64 { Trace.rebuilt("display") }
        let taken = Trace.takeRebuilds()
        XCTAssertGreaterThanOrEqual(taken.count, 64, "the 64th rebuild's own flush must not eat the count")
        XCTAssertGreaterThanOrEqual(taken.ms, 2.5, "and the cost was already kept apart from the flush")
        XCTAssertEqual(Trace.takeRebuilds().count, 0, "only takeRebuilds resets it")
    }

    // MARK: the walk's ownership (Codex R7 P2)

    /// A fetch a test can hold open. The stand-in `fetchPage` marks that it has started and then suspends until the
    /// test releases it — the only way to have a walk in flight while other callers arrive, which is exactly the
    /// interleaving the caller-side merge got wrong.
    private actor FetchGate {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            started = true
            for w in startWaiters { w.resume() }
            startWaiters = []
        }
        func waitStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }
        func release() {
            released = true
            for w in releaseWaiters { w.resume() }
            releaseWaiters = []
        }
        func waitReleased() async {
            if released { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    /// One `session/page` reply, in the shape the host answers with.
    private func pageReply(_ records: [JSON], hasMore: Bool = true) -> JSON {
        .obj([("records", .array(records)), ("hasMore", .bool(hasMore))])
    }

    /// One event record of that reply.
    private func record(seq: Int, _ type: String, data: JSON = [:]) -> JSON {
        .obj([("event", .obj([("seq", .number(Double(seq))), ("type", .string(type)), ("data", data)]))])
    }

    /// One suspended fetch, several waiters. A caller that arrives while a walk is fetching waits for THAT walk and
    /// asks its own question against what the walk merged — the merge belongs to the registered task, not to the
    /// caller that started it. The version this replaces merged in the caller, so the task completed and unregistered
    /// first: the waiter found nothing loaded, registered a walk of its own, and the reader's one gesture became two
    /// fetches (Codex R7 P2).
    func testWaitersShareOneWalkAndSeeItsMerge() async {
        let m = model([100])
        m.hasMore = true
        let gate = FetchGate()
        var fetches = 0
        m.fetchPage = { _, _ in
            fetches += 1
            await gate.markStarted()
            await gate.waitReleased()
            return self.pageReply([self.record(seq: 60, "turn/start", data: ["turn": 3])])
        }
        let pull = Task { await m.loadEarlier() }
        await gate.waitStarted()
        XCTAssertTrue(m.loadingMore, "the registered walk owns the loading flag while it is in flight")
        let jump = Task { await m.loadThrough(60) }
        await gate.release()
        await pull.value
        let outcome = await jump.value
        XCTAssertEqual(outcome, .found, "the waiter's question is asked against what the walk merged, not before it")
        XCTAssertEqual(fetches, 1, "one walk, not two")
        XCTAssertFalse(m.loadingMore, "and the flag is cleared when the walk is done")
        XCTAssertEqual(m.starts[3], 60, "the page the walk fetched is in the model")
    }

    /// A walk that hits the cap leaves history behind, and the retry the cap advertises has to start BELOW the oldest
    /// event the capped walk loaded — `throughSeq: firstSeq - 1`, `beforeSeq: firstSeq`. Starting at the cursor named
    /// a window the walk had already fetched, so a target beyond the cap could never be reached (Codex R7 P2).
    func testARetryAfterTheCapStartsBelowWhatIsAlreadyLoaded() async {
        let m = model([1000])
        var asked: [(Int, Int?)] = []
        m.fetchPage = { through, before in
            asked.append((through, before))
            return self.pageReply([self.record(seq: through, "turn/end", data: ["turn": 1, "reason": ["kind": "done"]])])
        }
        let first = await m.loadThrough(10)
        XCTAssertEqual(first, .failed, "the cap is retryable, not an exhausted history")
        XCTAssertEqual(asked.count, 80, "the walk stops at the page cap")
        XCTAssertEqual(asked.first?.0, 999, "the first page is the one just below the loaded frontier")

        let second = await m.loadThrough(10)
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(asked.count, 160, "the retry walks on, page by page")
        XCTAssertEqual(asked[80].0, 919, "it starts below everything the capped walk loaded, not at the cursor")
    }

    /// The retry's window is explicit: the first page of a walk under the loaded frontier passes its own `beforeSeq`,
    /// because the host's default (`throughSeq + 1`) names an empty window when the two are adjacent.
    func testAJumpUnderTheFrontierPassesItsOwnBoundary() async {
        let m = model([1000])
        var asked: [(Int, Int?)] = []
        m.fetchPage = { through, before in
            asked.append((through, before))
            return self.pageReply([], hasMore: false)
        }
        _ = await m.loadThrough(10)
        XCTAssertEqual(asked.first?.0, 999)
        XCTAssertEqual(asked.first?.1, 1000, "the boundary is the frontier itself, exclusive")
    }

    /// A fetch cancelled mid-flight is not a failure to report. Replacing a jump cancels its request, and the error
    /// path used to put "No connection to the Mac" on screen over the newer selection the reader had moved to
    /// (Codex R7 P2). The same failure WITHOUT cancellation is the one that has to be said out loud.
    func testACancelledFetchSaysNothing() async {
        let app = AppModel()
        let m = model([100])
        m.app = app
        let gate = FetchGate()
        m.fetchPage = { _, _ in
            await gate.markStarted()
            await gate.waitReleased()
            throw RPCError(kind: .network, code: "network", message: "No connection to the Mac")
        }
        let jump = Task { await m.loadThrough(50) }
        await gate.waitStarted()
        jump.cancel()
        await gate.release()
        let outcome = await jump.value
        XCTAssertEqual(outcome, .interrupted, "a replaced jump is interrupted, not failed")
        XCTAssertNil(app.toast, "and it says nothing at all")

        let plain = model([100])
        plain.app = app
        plain.fetchPage = { _, _ in throw RPCError(kind: .network, code: "network", message: "No connection to the Mac") }
        let failure = await plain.loadThrough(50)
        XCTAssertEqual(failure, .failed)
        XCTAssertEqual(app.toast?.text, "No connection to the Mac", "a real failure is still reported")
    }
}
