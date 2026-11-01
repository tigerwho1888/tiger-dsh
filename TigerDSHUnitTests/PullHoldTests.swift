import XCTest
@testable import TigerDSH

/// The pull's hold: what row it names, when it is spent, and when it is retired.
///
/// Codex R9 P2, both halves. A live row arriving during the fetch changes the display count, and the old code
/// consumed the hold on ANY count change — so the page that landed afterwards lost its restoration. A metadata-only
/// page lowers the frontier without changing the count, and the old cleanup left that hold armed, so a later live
/// row spent it. And the anchor was the first display row's key, which for a folded process group is the synthetic
/// `gh` + key-of-the-item-before header that the merge rebuilds.
///
/// These drive the real `ChatModel.display` (the fold and the synthetic keys are its own) and the decisions the
/// view makes on it.
@MainActor
final class PullHoldTests: XCTestCase {
    private func assistant(_ key: String, _ seq: Int, text: String = "") -> ChatItem {
        ChatItem(key: key, kind: .assistant, seq: seq, text: text)
    }

    /// A tool-only step: `ChatModel.processOnly` folds a run of these into one group row.
    private func process(_ key: String, _ seq: Int) -> ChatItem {
        ChatItem(key: key, kind: .assistant, seq: seq, blocks: [.tool(callId: key, name: "read", args: "{}")])
    }

    /// The display list a model would build for these rows. A fresh model each time, because `display` is cached
    /// against the model's own version and a test that wrote `items` behind its back would read the cache.
    private func display(_ items: [ChatItem], stream: String? = nil) -> [ChatItem] {
        let m = ChatModel(id: "session-hold", app: nil)
        m.items = items
        if let stream { m.stream = [.text(stream)] }
        return m.display
    }

    // MARK: the live row during the fetch

    /// A live row changes the count and not the frontier: the hold must survive it, because the page it is waiting
    /// for has not landed yet.
    func testALiveRowDuringTheFetchDoesNotSpendTheHold() {
        let items = [assistant("a100", 100), assistant("a101", 101, text: "hi")]
        guard let hold = PullHold.armed(display(items), frontier: 100) else { return XCTFail("no hold was armed") }
        XCTAssertEqual(hold.row, "a100")

        let withLive = display(items, stream: "working on it")
        XCTAssertNotEqual(withLive.count, hold.count, "the fixture has to move the count, or this is not the case under test")
        XCTAssertNil(hold.rowToRestore(display: withLive, frontier: 100, folds: []),
                     "a live row is not the page: the hold has to survive it")
        XCTAssertFalse(hold.isSpentByMetadata(frontier: 100, count: withLive.count),
                       "nothing landed at all, so there is nothing to retire")
    }

    /// And the page that lands afterwards still restores the reader's place — the whole point of the hold.
    func testThePageThatLandsAfterALiveRowStillRestoresTheReader() {
        let items = [assistant("a100", 100), assistant("a101", 101, text: "hi")]
        guard let hold = PullHold.armed(display(items), frontier: 100) else { return XCTFail("no hold was armed") }

        let merged = display([assistant("a60", 60), assistant("a80", 80)] + items, stream: "working on it")
        XCTAssertEqual(hold.rowToRestore(display: merged, frontier: 60, folds: []), "a100")
    }

    // MARK: the metadata-only page

    /// A page of `turn/start`, `turn/end` and tool results lowers the frontier and pushes no row: there is nothing
    /// to restore, and the hold must be retired rather than left for the next live row to spend.
    func testAMetadataOnlyPageRetiresTheHold() {
        let items = [assistant("a100", 100), assistant("a101", 101, text: "hi")]
        guard let hold = PullHold.armed(display(items), frontier: 100) else { return XCTFail("no hold was armed") }
        let sameCount = display(items).count

        XCTAssertTrue(hold.isSpentByMetadata(frontier: 60, count: sameCount),
                      "a page that lowered the frontier without moving the count has nothing to restore")
        XCTAssertNil(hold.rowToRestore(display: display(items), frontier: 60, folds: []),
                     "no rows landed, so there is no row to put back")
        XCTAssertFalse(hold.isSpentByMetadata(frontier: 100, count: sameCount),
                       "a live row does not retire the hold — the page is still on its way")
        XCTAssertFalse(hold.isSpentByMetadata(frontier: 60, count: sameCount + 1),
                       "a page WITH rows is spent by the count handler, not retired here")
    }

    // MARK: the durable anchor

    /// The anchor is a durable item key. A folded process group's header key is synthetic and is rebuilt when the
    /// page supplies what came before it, so a hold that named the header would scroll to a row that is gone.
    func testAHoldOnAGroupHeaderNamesAMemberNotTheSyntheticHeader() {
        let grouped = display([process("t1", 10), assistant("a2", 11, text: "answer")])
        XCTAssertEqual(grouped.first?.key, "ghstart", "the fixture has to start on a synthetic group header")
        guard let hold = PullHold.armed(grouped, frontier: 50) else { return XCTFail("no hold was armed") }
        XCTAssertEqual(hold.row, "t1", "the hold names the group's durable member, not its synthetic header")

        // The page supplies the message that came before the group: the same members, a new header key.
        let after = display([assistant("a5", 5, text: "earlier"), process("t1", 10), assistant("a2", 11, text: "answer")])
        XCTAssertFalse(after.contains { $0.key == "ghstart" },
                       "the synthetic key is gone — a hold that named it would scroll nowhere")
        XCTAssertEqual(hold.rowToRestore(display: after, frontier: 5, folds: []), "gha5",
                       "the group containing the member is found by its CURRENT header")
    }

    /// A member whose fold is open has a row of its own, and that is what the scroll should find.
    func testAFoldThatIsOpenRestoresTheMemberItself() {
        let grouped = display([process("t1", 10), assistant("a2", 11, text: "answer")])
        guard let hold = PullHold.armed(grouped, frontier: 50) else { return XCTFail("no hold was armed") }
        // The page landed (an older message, which is now what the group hangs off), and the reader opened the fold.
        let after = display([assistant("a5", 5, text: "earlier"), process("t1", 10), assistant("a2", 11, text: "answer")])
        XCTAssertEqual(hold.rowToRestore(display: after, frontier: 5, folds: ["gh:a5"]), "t1",
                       "an open fold draws the member's own row")
        XCTAssertEqual(hold.rowToRestore(display: after, frontier: 5, folds: []), "gha5",
                       "closed, the group's own row is the one that exists")
    }
}
