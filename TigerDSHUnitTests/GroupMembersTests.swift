import XCTest
@testable import TigerDSH

/// Step 4 of `.tmp/list-speed-proposal.md`: the per-row cost of a body pass.
///
/// A process-group header's row reads its members on every pass. That read used to filter the WHOLE conversation
/// once per group — O(rows) per header, so O(groups × rows) per pass — while `ChatModel.display` builds a group as
/// its header followed by its members, which makes the members a walk over the group's own run. This holds both
/// answers equal and measures them on a list the size of the chats that stalled t3 and t4.
@MainActor
final class GroupMembersTests: XCTestCase {
    /// A chat of `groups` process groups of `members` tool steps each, with a reply between them: the shape
    /// `ChatModel.display` folds.
    private func longDisplay(groups: Int, members: Int) -> [ChatItem] {
        let m = ChatModel(id: "session-speed", app: nil)
        var items: [ChatItem] = []
        for g in 0..<groups {
            for i in 0..<members {
                let key = "t\(g)-\(i)"
                items.append(ChatItem(key: key, kind: .assistant, seq: g * (members + 1) + i,
                                      blocks: [.tool(callId: key, name: "read", args: "{}")]))
            }
            items.append(ChatItem(key: "a\(g)", kind: .assistant, seq: g * (members + 1) + members, text: "Round \(g) is done."))
        }
        m.items = items
        return m.display
    }

    /// The old read, kept here as the baseline it is: the whole list, filtered per group.
    private func filterMembers(_ it: ChatItem, in d: [ChatItem]) -> [ChatItem] {
        it.kind == .group ? d.filter { $0.groupId == it.groupId && $0.kind != .group } : []
    }

    private func cost(_ passes: Int, _ display: [ChatItem], _ read: (ChatItem, Int, [ChatItem]) -> [ChatItem]) -> (ms: Double, count: Int) {
        let headers = display.enumerated().filter { $0.element.kind == .group }
        var count = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<passes {
            for (i, it) in headers { count += read(it, i, display).count }
        }
        return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, count)
    }

    func testTheGroupWalkAnswersWhatTheFilterAnswered() {
        let display = longDisplay(groups: 12, members: 5)
        for (i, it) in display.enumerated() where it.kind == .group {
            XCTAssertEqual(GroupMembers.of(it, at: i, in: display).map(\.key), filterMembers(it, in: display).map(\.key),
                           "the walk and the filter have to agree, group by group")
        }
    }

    /// The numbers step 4 asked for: 200 groups over 4,400 rows, ten passes, both reads.
    func testTheGroupWalkCostsLessThanTheFilterOnALongList() {
        let display = longDisplay(groups: 200, members: 20)
        XCTAssertEqual(display.count, 4400, "200 groups of 20 members plus their replies")

        let old = cost(10, display) { it, _, d in filterMembers(it, in: d) }
        let new = cost(10, display) { it, i, d in GroupMembers.of(it, at: i, in: d) }
        XCTAssertEqual(old.count, new.count, "both reads answer the same number of members")
        print(String(format: "group members: filter %.2f ms vs walk %.2f ms per pass (%.0fx), %d members",
                     old.ms / 10, new.ms / 10, old.ms / max(new.ms, 0.0001), new.count / 10))
        XCTAssertLessThan(new.ms, old.ms, "the walk over the group's own run has to be cheaper than filtering the list per group")
    }

    /// A section opened in one chat is still open after a trip to another chat and back: the chat screen is rebuilt
    /// on every switch, so its folds come from the app, one set per chat and per subagent.
    func testOpenFoldsSurviveSwitchingChats() {
        let app = AppModel()
        app.folds("a").toggle("gh:g1")
        XCTAssertTrue(app.folds("a").open.contains("gh:g1"))
        XCTAssertTrue(app.folds("a") === app.folds("a"))
        XCTAssertFalse(app.folds("a/sub").open.contains("gh:g1"), "a subagent keeps folds of its own")
        XCTAssertFalse(app.folds("b").open.contains("gh:g1"))
    }
}
