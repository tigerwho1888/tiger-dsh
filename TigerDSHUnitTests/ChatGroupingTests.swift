import XCTest
@testable import TigerDSH

/// R20: the drawer's chats are grouped under the project they belong to. What decides the list is `recentGroups`:
/// each project's newest few chats, the projects ordered by the chat they lead with, the pinned chats left to the
/// Pinned section above, and a project with nothing left after them not drawn at all.
@MainActor
final class RecentGroupsTests: XCTestCase {
    private func row(_ id: String, _ updated: Double, blank: Bool = false) -> SessionRow {
        SessionRow(id: id, updated: updated, running: false, blank: blank, isSub: false, cwd: "", title: id,
                   questions: 0, model: nil, snippet: "")
    }

    private func workspace(_ id: String, _ label: String, _ ids: [String]) -> Workspace {
        Workspace(.obj([("workspaceId", .string(id)), ("title", .string(label)), ("path", .string("/tmp/\(id)")),
                        ("createdAt", .string("2026-10-01T00:00:00.000Z")),
                        ("sessionIds", .array(ids.map { .string($0) }))]))
    }

    private func model(_ rows: [SessionRow], _ workspaces: [Workspace]) -> AppModel {
        let m = AppModel()
        m.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        m.workspaces = workspaces
        m.listReady = true
        return m
    }

    /// The projects lead with their newest chat, newest project first — and the stray chat is filed last even when
    /// it is the newest thing in the app, because "Other chats" is not a project.
    func testProjectsLeadWithTheirNewestChatAndTheStrayChatsComeLast() {
        let m = model([row("a-old", 100), row("a-new", 300), row("b-only", 200), row("stray", 999)],
                      [workspace("alpha", "Alpha", ["a-old", "a-new"]), workspace("beta", "Beta", ["b-only"])])

        let groups = m.recentGroups()

        XCTAssertEqual(groups.map(\.id), ["alpha", "beta", "_other"], "the projects are not in newest-chat order, or the stray chats are not last")
        XCTAssertEqual(groups.last?.label, "Other chats")
        XCTAssertEqual(groups.map { $0.rows.map(\.id) }, [["a-new", "a-old"], ["b-only"], ["stray"]],
                       "a project's own rows are not newest first")
    }

    /// A project shows its newest `perProject` chats and no more, and the projects past `projects` are not drawn.
    func testTheCapsKeepTheNewestAndDropTheRest() {
        let all = (1...7).map { row("a\($0)", Double($0) * 100) }
        let m = model(all, [workspace("alpha", "Alpha", all.map(\.id))])

        let groups = m.recentGroups(perProject: 5, projects: 6)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.map(\.id), ["a7", "a6", "a5", "a4", "a3"], "the cap kept the oldest chats, or more than five")
        XCTAssertEqual(groups[0].total, 7, "the header's chat count is what the project holds, capped or not")
    }

    /// More projects than the cap: the newest few are kept and the rest — "Other chats" included — are not drawn.
    func testTheProjectCapBoundsTheList() {
        var workspaces: [Workspace] = []
        var rows: [SessionRow] = []
        for i in 1...8 {
            rows.append(row("p\(i)", Double(i) * 100))
            workspaces.append(workspace("p\(i)", "Project \(i)", ["p\(i)"]))
        }
        let m = model(rows + [row("stray", 9999)], workspaces)

        let groups = m.recentGroups(perProject: 5, projects: 6)

        XCTAssertEqual(groups.map(\.id), ["p8", "p7", "p6", "p5", "p4", "p3"], "the cap did not keep the six newest projects")
    }

    /// A pinned chat is the Pinned section's, not its project's, and a project left with nothing after its pins is
    /// dropped rather than drawn as a header over no rows.
    func testPinnedChatsAreLeftToThePinnedSection() {
        let m = model([row("a-keep", 100), row("a-pin", 400), row("b-pin", 900)],
                      [workspace("alpha", "Alpha", ["a-keep", "a-pin"]), workspace("beta", "Beta", ["b-pin"])])
        m.pinned = ["a-pin", "b-pin"]

        let groups = m.recentGroups()

        XCTAssertEqual(groups.map(\.id), ["alpha"], "a project whose only chat is pinned is still drawn")
        XCTAssertEqual(groups[0].rows.map(\.id), ["a-keep"], "a pinned chat is in its project's rows")
    }

    /// A project with no chats at all, and one whose only chat is blank or archived, draw no header.
    func testEmptyProjectsDrawNoHeader() {
        let m = model([row("blank", 50, blank: true), row("gone", 60)],
                      [workspace("empty", "Empty", []), workspace("blank", "Blank", ["blank"]),
                       workspace("archived", "Archived", ["gone"])])
        m.archived = ["gone"]

        XCTAssertTrue(m.recentGroups().isEmpty, "a header was drawn over no rows: \(m.recentGroups().map(\.label))")
    }
}

/// R20, the other half: which project headers the reader has folded shut, as the comma-joined string the drawer
/// keeps in `@AppStorage("drawer.collapsed")`. A project's fold is its own — folding one must not unfold another —
/// and the round trip has to be stable, so a rewrite of the same set never reads as a change.
final class DrawerCollapseTests: XCTestCase {
    func testFoldingAProjectInAndOutLeavesTheOthersAlone() {
        XCTAssertEqual(SideDrawer.toggled("", "alpha"), "alpha", "a fold was not stored")
        XCTAssertEqual(SideDrawer.toggled("alpha", "beta"), "alpha,beta", "a second fold lost the first")
        XCTAssertEqual(SideDrawer.toggled("alpha,beta", "alpha"), "beta", "unfolding alpha took beta with it")
        XCTAssertEqual(SideDrawer.toggled("alpha", "alpha"), "", "the last fold was not taken back out")
        XCTAssertEqual(SideDrawer.toggled("alpha,beta", "alpha"), SideDrawer.toggled("beta,alpha", "alpha"),
                       "the stored string depends on the order the folds were made")
    }

    func testTheStoredStringReadsBackAsThoseIds() {
        XCTAssertEqual(SideDrawer.collapsedIDs(""), [], "an empty string folded something")
        XCTAssertEqual(SideDrawer.collapsedIDs("alpha"), ["alpha"])
        XCTAssertEqual(SideDrawer.collapsedIDs("alpha,beta"), ["alpha", "beta"])
        XCTAssertEqual(SideDrawer.collapsedIDs("ws-1,ws-12"), ["ws-1", "ws-12"], "one id read as another's prefix")
    }
}
