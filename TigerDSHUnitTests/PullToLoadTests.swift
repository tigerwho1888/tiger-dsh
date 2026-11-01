import XCTest
import SwiftUI
import UIKit
@testable import TigerDSH

/// The pull at the top of a chat, driven through the REAL scroll view with the host stubbed out.
///
/// `testPullToLoadEarlier` failed on t13 with the head row at exactly the same y before and after three real pull
/// gestures (152.0 → 152.0), which says nothing moved — but not whether the gesture armed, whether the page was
/// fetched, or whether the restore ran. Only the app can tell those three apart, so this harness asks it directly:
/// a `ChatModel` whose `fetchPage` is a stub (the DEBUG door `ChatModelPagingTests` uses), hosted in the real
/// `ChatScreen` inside a window, with the real `chat.scroll` scroll view driven over the pull threshold and back.
///
/// What it holds: the threshold was crossed, the page was asked for the window below the frontier, the page merged,
/// and the hold was SPENT on the page's own update rather than retired as a metadata-only one. That last pair is the
/// whole of t13's failure — the pull fetched and merged and did nothing, because both handlers that run when a page
/// lands read the row list the body had captured BEFORE the merge (`spent=0 missed=3 retired=1`), and the fix is
/// that they read the model's own list (`chat.display`).
///
/// What it CANNOT hold: the movement itself. `ScrollViewReader.scrollTo` does not move a scroll view hosted this
/// way — measured, including the app's own follow-the-bottom scroll fired in the same update (`stick=true
/// inter=false` in Documents/geom.log, offset unmoved), and a deferred issue one turn later is inert too. The
/// decisions are therefore the harness's evidence, and the smoke test's head-row y is the only place the movement
/// can be judged.
@MainActor
final class PullToLoadTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        guard let path = ProcessInfo.processInfo.environment["DSH_UNIT_LOG"] else { return }
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
    }

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    private func host<V: View>(_ view: V) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        w.rootViewController = UIHostingController(rootView: view)
        w.makeKeyAndVisible()
        window = w
        pump(2)
        return w
    }

    private func allScrollViews(in v: UIView, _ out: inout [UIScrollView]) {
        if let s = v as? UIScrollView { out.append(s) }
        for sub in v.subviews { allScrollViews(in: sub, &out) }
    }

    private func chatScrollView(in v: UIView) -> UIScrollView? {
        var found: [UIScrollView] = []
        allScrollViews(in: v, &found)
        return found.first { $0.accessibilityIdentifier == "chat.scroll" } ?? found.first
    }

    /// The pull's own decision counts, zeroed before each gesture. Read as counts rather than as a printed line
    /// because the app must not print in a shipping path: `Trace` is the Simulator/Debug channel already in use.
    private func resetPullCounters() {
        Trace.resetTotal("pull.ask")
        Trace.resetTotal("pull.spent")
        Trace.resetTotal("pull.missed")
        Trace.resetTotal("pull.retired")
    }

    private var pullCounters: String {
        "ask=\(Trace.total("pull.ask")) spent=\(Trace.total("pull.spent")) "
        + "missed=\(Trace.total("pull.missed")) retired=\(Trace.total("pull.retired"))"
    }

    // MARK: the fixture

    /// A reader's own message, which is drawn from `text` alone: an assistant row renders its BLOCKS, so a fixture
    /// that sets only `text` on one draws an empty row about 20 pt tall — the first version of this harness had 24 of
    /// those and a "scrollable" list 475 pt tall, which UIKit then clamped every offset into.
    private func messageRow(_ seq: Int) -> ChatItem {
        ChatItem(key: "a\(seq)", kind: .user, seq: seq, time: 1_700_000_000_000 + Double(seq) * 1_000,
                 text: "Row \(seq): " + String(repeating: "some words in a message ", count: 8))
    }

    /// One `session/page` record, in the shape the host sends it: a durable event wrapped in a record. `page(from:)`
    /// reduces exactly this.
    private func record(_ seq: Int) -> JSON {
        let text = "Earlier \(seq): " + String(repeating: "older words ", count: 4)
        let json = """
        {"event": {"type": "assistant/message", "seq": \(seq), "time": \(1_700_000_000_000 + seq * 1_000),
                   "data": {"message": {"id": "m\(seq)", "content": [{"type": "text", "text": "\(text)"}]}}}}
        """
        return (try? JSON.parse(Data(json.utf8))) ?? .null
    }

    /// What the app asked the host for. A class because `fetchPage` is a stored closure: it escapes, so it cannot
    /// write into an `inout` array.
    private final class PageStub {
        var calls: [(through: Int, before: Int?)] = []
        var hasMore = true
    }

    /// A chat at the top of its history with an earlier page behind it, and a stub that answers for the window the
    /// pull asks about. `stub.calls` is the whole point of the first assertion: it is only written when the app
    /// really asked the host for a page.
    private func pullableChat(stub: PageStub, rows: Int = 24, pageRows: Int = 8) -> ChatModel {
        let chat = ChatModel(id: "session-pull", app: nil)
        chat.items = (0..<rows).map { messageRow(100 + $0) }
        chat.firstSeq = 100
        chat.loading = false
        chat.hasMore = true
        chat.fetchPage = { [weak self] through, before in
            stub.calls.append((through, before))
            let records = (0..<pageRows).map { self?.record(through - $0) ?? .null }
            return .object(["records": .array(records), "hasMore": .bool(stub.hasMore)])
        }
        return chat
    }

    // MARK: the pull

    /// The pull's three steps on the real view: asked → landed → the hold spent on the page's own update.
    func testThePullAsksForThePageLandsItAndSpendsTheHold() throws {
        let stub = PageStub()
        let chat = pullableChat(stub: stub)
        resetPullCounters()
        let w = host(NavigationStack { ChatScreen(chat: chat) }.environment(AppModel()))
        guard let scroll = chatScrollView(in: w) else { return XCTFail("the chat's scroll view never appeared") }
        pump(1)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 400,
                             "the harness list has to be scrollable, or the pull has no overscroll to cross the threshold with")

        // One assignment does not make the top stick: `stick` is still on (only a finger clears it), so while the
        // lazy rows near the top are measured for the first time the bottom anchor pulls the list back down. On a
        // freshly booted simulator that takes longer than one pump, so the top is re-asserted until the offset and
        // the content size both hold still (Codex r54).
        var top = -scroll.adjustedContentInset.top
        var lastSize: CGFloat = -1
        for _ in 0..<20 {
            top = -scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            pump(0.3)
            if abs(scroll.contentOffset.y - top) < 1, scroll.contentSize.height == lastSize { break }
            lastSize = scroll.contentSize.height
        }
        XCTAssertEqual(scroll.contentOffset.y, top, accuracy: 1, "the list never settled at the top")
        XCTAssertEqual(stub.calls.count, 0, "a page was asked for before the pull")
        let sizeBefore = scroll.contentSize.height
        print("pull: at the top offset=\(Int(scroll.contentOffset.y)) size=\(Int(sizeBefore)) "
              + "bounds=\(Int(scroll.bounds.height)) insetTop=\(Int(scroll.adjustedContentInset.top)) stack=\(chat.items.count)")

        // The gesture, in the two numbers the app's own threshold reads: past 60 pt over the top, then let go. A real
        // finger drags through the whole range and settles back; the geometry callback sees the same two crossings.
        // A real pull has a finger down, which is what turns the bottom anchor off (`interacting`); without it the
        // head's own resize as it arms lets the anchor yank the list to the bottom and fire the pull early. The
        // delegate calls are the ones a drag makes, so the scroll phase reads as interacting until the release.
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        pump(0.2)
        scroll.setContentOffset(CGPoint(x: 0, y: top - 140), animated: false)
        pump(0.5)
        var target = CGPoint(x: 0, y: top)
        scroll.delegate?.scrollViewWillEndDragging?(scroll, withVelocity: .zero, targetContentOffset: &target)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        print("pull: armed offset=\(Int(scroll.contentOffset.y)) over=\(Int(-(scroll.contentOffset.y + scroll.adjustedContentInset.top)))")
        scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        pump(3)

        let after = scroll.contentOffset.y
        let grew = scroll.contentSize.height - sizeBefore
        print("pull: fetched=\(stub.calls) rows=\(chat.items.count) firstSeq=\(chat.firstSeq) hasMore=\(chat.hasMore) "
              + "offset \(Int(top)) → \(Int(after)) size \(Int(sizeBefore)) → \(Int(scroll.contentSize.height)) "
              + pullCounters)

        XCTAssertEqual(stub.calls.count, 1, "the pull never asked for a page (the threshold was crossed in the harness)")
        XCTAssertEqual(stub.calls.first?.through, 99, "the page was asked for the window below the frontier")
        XCTAssertEqual(stub.calls.first?.before, 100, "beforeSeq has to name the frontier, not the empty window next to it")
        XCTAssertEqual(chat.firstSeq, 92, "the page's oldest record did not become the frontier")
        XCTAssertEqual(chat.items.count, 32, "the page's rows are not in the model")
        XCTAssertEqual(Trace.total("pull.spent"), 1,
                       "the page landed and the hold was not spent on it — this is t13's failure: the reader's place "
                       + "is never restored")
        XCTAssertEqual(Trace.total("pull.retired"), 0,
                       "the hold was retired as a metadata-only page while the page's own rows were in the model")
    }
}
