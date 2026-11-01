import XCTest
import SwiftUI
import UIKit
@testable import TigerDSH

/// The jump arrow, both halves: the screen publishes the offer, and the button is drawn when the offer is on.
///
/// t10's `testJumpArrow` failed — six app-level swipes up and `chat.jump` never appeared, where t9 (one swipe)
/// found it at once. The screen recording of that run answers it: the chat the test had opened was the newest one,
/// three items long, and it FITS the screen — `chat-bottom.png` and `chat-scrolled-up.png` from the t10 bundle are
/// pixel-identical (mean difference 0.03 of 255), so the two swipes moved nothing at all. A chat with nothing to
/// scroll has no arrow to offer, and the app was right not to draw one.
///
/// What these tests hold is the app's own half of that: the real `ChatScreen`, scrolled away from the bottom in a
/// window, publishes the offer; and the button renders when — and only when — the readout carries it.
@MainActor
final class JumpArrowTests: XCTestCase {
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

    /// A short list of tall rows: every row materialises at once, so the content size stops changing — a lazy list
    /// that is still growing re-pins itself to the bottom through `.defaultScrollAnchor(…, for: .sizeChanges)`,
    /// because a programmatic offset never clears `stick` (only a real gesture's phase reports `.interacting`).
    ///
    /// 16 rows rather than 14: the chat screen reserves the policy band above the transcript now (Codex R11 P2), so
    /// the same list is about 30 pt shorter inside its viewport, and the 400 pt of slack this harness needs was
    /// down to 368.
    private func tallChat(_ rows: Int = 16) -> ChatModel {
        let chat = ChatModel(id: "session-arrow", app: nil)
        chat.items = (0..<rows).map { i in
            ChatItem(key: "a\(i)", kind: i % 2 == 0 ? .user : .assistant, seq: i,
                     text: "Row \(i): " + String(repeating: "some words in a message ", count: 6))
        }
        chat.firstSeq = 0
        chat.loading = false
        chat.hasMore = true
        return chat
    }

    // MARK: the screen's own half

    /// Away from the bottom, the real screen publishes the offer — the one write `JumpArrow` reads.
    func testTheRealScreenPublishesTheOfferAwayFromTheBottom() throws {
        let chat = tallChat()
        let app = AppModel()
        let w = host(NavigationStack { ChatScreen(chat: chat) }.environment(app))
        guard let scroll = chatScrollView(in: w) else { return XCTFail("the chat's scroll view never appeared") }
        pump(1)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 400,
                             "the harness list has to be scrollable")

        Trace.resetTotal("readout")
        let start = scroll.contentOffset.y
        for step in 1...10 {
            scroll.setContentOffset(CGPoint(x: 0, y: start - CGFloat(step) * 40), animated: false)
            pump(0.05)
        }
        pump(1)
        let published = Trace.total("readout")
        print("arrow probe: offset=\(scroll.contentOffset.y) content=\(scroll.contentSize.height) "
              + "bounds=\(scroll.bounds.height) offer publications=\(published)")
        XCTAssertLessThan(scroll.contentOffset.y, start - 300, "the harness scroll did not stay away from the bottom")
        XCTAssertGreaterThan(published, 0,
                             "scrolling 400 pt away from the bottom published no offer: the arrow could never appear")
    }

    // MARK: the crossing, against the scroll view's own numbers

    /// Where the offer comes on and goes off, measured the way the reader experiences it: 0 at the newest message,
    /// 120 pt above it is the offer's edge. The scroll view is placed with its OWN arithmetic
    /// (`contentSize − bounds + adjustedContentInset.bottom`), never with a hand-fed offset.
    ///
    /// The older test scrolled 400 pt and required only that SOMETHING was published, so a distance that understated
    /// the reader's position by the dock's inset passed it while the real arrow was never offered inside 300 pt of
    /// travel — t12's `testJumpArrow` (Codex R15 #4). The readout is handed in so the crossing itself is visible
    /// here.
    func testTheOfferCrossesWhereTheReaderActuallyIs() throws {
        let chat = tallChat(24)
        let app = AppModel()
        let readout = ScrollReadout()
        let w = host(NavigationStack { ChatScreen(chat: chat, readout: readout) }.environment(app))
        guard let scroll = chatScrollView(in: w) else { return XCTFail("the chat's scroll view never appeared") }
        pump(1)
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 400,
                             "the harness list has to be scrollable")

        /// `dy` points above the newest message.
        func place(_ dy: CGFloat) {
            scroll.setContentOffset(CGPoint(x: 0, y: bottom - dy), animated: false)
            pump(0.4)
            print("arrow crossing: dy=\(Int(dy)) uikit offset=\(Int(scroll.contentOffset.y)) size=\(Int(scroll.contentSize.height)) "
                  + "bounds=\(Int(scroll.bounds.height)) adjTop=\(Int(scroll.adjustedContentInset.top)) "
                  + "adjBottom=\(Int(scroll.adjustedContentInset.bottom)) → distance=\(Int(readout.distance)) arrow=\(readout.arrow)")
        }
        place(0)
        XCTAssertLessThan(readout.distance, 1,
                          "at the newest message the reading was \(readout.distance): the bottom is not being measured")
        XCTAssertFalse(readout.arrow, "the arrow is offered while the reader is at the newest message")

        place(60)
        XCTAssertFalse(readout.arrow, "the arrow is offered inside its own 120 pt zone")

        place(121)
        XCTAssertGreaterThan(readout.distance, 120, "121 pt above the bottom read as \(readout.distance)")
        XCTAssertTrue(readout.arrow, "the arrow is not offered 121 pt above the newest message")

        // The lazy list materialises rows as the offset moves, and the content-size handler reports that growth as
        // "something arrived below" — a flag the real phase handler clears when the reader settles back inside the
        // stick zone, and a programmatic offset has no phase. The return leg therefore starts from "nothing new
        // below", which is the state this test is about: the distance crossing itself.
        readout.setNewBelow(false, zone: 120)
        place(60)
        XCTAssertFalse(readout.arrow, "the offer did not clear on the way back into the zone")
        place(0)
        XCTAssertFalse(readout.arrow, "the offer is still on at the newest message")
    }

    /// The offer, rendered by the REAL screen: the chat is placed 121 pt above the newest message and the window is
    /// written to `Documents/arrow-shot.png`, so the arrow can be seen rather than inferred. The app's own review
    /// hook (`-reviewScroll`) is how a shell photographs the running app; this is the same state reached from a
    /// test, which is what a shell without touch input can hold still.
    func testTheOfferedArrowIsOnTheRealScreen() throws {
        let chat = tallChat(24)
        let app = AppModel()
        let readout = ScrollReadout()
        let w = host(NavigationStack { ChatScreen(chat: chat, readout: readout) }.environment(app))
        guard let scroll = chatScrollView(in: w) else { return XCTFail("the chat's scroll view never appeared") }
        pump(1)
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: bottom - 121), animated: false)
        pump(0.6)
        XCTAssertTrue(readout.arrow, "the harness did not reach the state this shot is of (distance \(readout.distance))")

        let renderer = UIGraphicsImageRenderer(bounds: w.bounds)
        let image = renderer.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        guard let data = image.pngData() else { return XCTFail("the window did not render to a PNG") }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("arrow-shot.png")
        try data.write(to: url)
        print("arrow shot: distance=\(Int(readout.distance)) arrow=\(readout.arrow) → \(url.path)")
    }

    // MARK: the button's own half

    /// The button is drawn when the readout carries the offer, and nothing is drawn when it does not. `ScrollReadout`
    /// is the only input, so this is the whole of the view's behaviour.
    func testTheButtonIsDrawnOnlyWhileTheOfferIsOn() throws {
        let atBottom = ScrollReadout()
        atBottom.read(distance: 0, zone: 120)
        let away = ScrollReadout()
        away.read(distance: 400, zone: 120)
        XCTAssertFalse(atBottom.arrow, "the readout offered the arrow at the bottom")
        XCTAssertTrue(away.arrow, "the readout did not offer the arrow 400 pt away")

        let off = ink(JumpArrow(readout: atBottom) {})
        let on = ink(JumpArrow(readout: away) {})
        print("arrow probe: rendered ink off=\(off) on=\(on)")
        XCTAssertEqual(off, 0, "the arrow drew something while it was not offered")
        XCTAssertGreaterThan(on, 0, "the arrow drew nothing while it was offered")
    }

    /// The non-transparent pixels of a rendered view, as a coarse "was anything drawn".
    private func ink<V: View>(_ view: V) -> Int {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage, let data = cg.dataProvider?.data as Data? else { return 0 }
        let bpp = max(1, cg.bitsPerPixel / 8)
        var n = 0
        var i = 0
        while i + bpp <= data.count {
            if data[data.startIndex + i + bpp - 1] > 8 { n += 1 }
            i += bpp
        }
        return n
    }
}
