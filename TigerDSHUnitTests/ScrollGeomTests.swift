import XCTest
import SwiftUI
import UIKit
@testable import TigerDSH

/// The chat's scroll geometry handler, driven inside the app's own process.
///
/// t9's `testChatScrollSmoothness` froze the app: the last line before it read `bodies: chat=1 geom=634`, and from
/// then on the geometry counter printed `geom=1068..1116` every two seconds — roughly 550 geometry callbacks a
/// second with no chat body pass and no CoreAnimation commit at all — while the main thread never serviced another
/// main queue block. That is a layout feedback loop: a write in the geometry callback invalidated a view whose
/// layout moved the scroll view (the reading covers the inset and the visible rect, so a hair of movement is a
/// reading), which fired the callback again.
///
/// The fix is that the callback publishes the arrow's OFFER, not the raw distance, and publishes it only when it
/// changes — so a reading that changes nothing the arrow draws writes nothing, and the cycle has nothing to feed it.
/// These tests hold both halves of that: the readout's own behaviour, and the real screen driven in a window.
@MainActor
final class ScrollGeomTests: XCTestCase {
    /// XCTest's report goes to the console, which a run started without a terminal does not have: `DSH_UNIT_LOG`
    /// names a file to copy stdout and stderr into (the same redirect the paging tests use).
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

    /// Runs the main run loop for a moment. UIKit and SwiftUI only lay out while it turns, and a test that slept
    /// instead would measure nothing.
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    /// A window of the app's OWN scene: a bare `UIWindow(frame:)` is attached to no scene, and SwiftUI then never
    /// renders into it (the hosting view came back with no subviews at all).
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

    private func longChat() -> ChatModel {
        let chat = ChatModel(id: "session-geom", app: nil)
        chat.items = (0..<160).map { i in
            ChatItem(key: "a\(i)", kind: i % 2 == 0 ? .user : .assistant, seq: i,
                     text: "Row \(i): " + String(repeating: "some words in a message ", count: 6))
        }
        chat.firstSeq = 0
        chat.loading = false
        chat.hasMore = true
        return chat
    }

    // MARK: the readout itself

    /// The freeze's own unit: a thousand readings that change nothing the arrow draws publish nothing. The raw
    /// distance moves every time — that is the point — and nothing re-renders for it.
    func testAThousandReadingsThatDoNotChangeTheArrowPublishNothing() {
        let readout = ScrollReadout()
        readout.read(distance: 300, zone: 120)          // the arrow is offered
        XCTAssertTrue(readout.arrow)
        Trace.resetTotal("readout")
        for i in 0..<1000 { readout.read(distance: 300 + CGFloat(i % 37), zone: 120) }
        XCTAssertEqual(Trace.total("readout"), 0, "a reading that changes nothing the arrow draws must write nothing")
        XCTAssertEqual(readout.distance, 300 + CGFloat(999 % 37), "the raw reading is still remembered for the decisions")
        XCTAssertTrue(readout.arrow)
    }

    /// And the crossings are still published, once each: down past the zone takes the offer away, back up past it
    /// brings it back. This is what the arrow is for — the fix must not silence it.
    func testOnlyTheCrossingsPublishTheArrow() {
        let readout = ScrollReadout()
        Trace.resetTotal("readout")
        readout.read(distance: 0, zone: 120)
        XCTAssertFalse(readout.arrow, "no arrow at the bottom")
        readout.read(distance: 121, zone: 120)
        XCTAssertTrue(readout.arrow, "past the zone the arrow is offered")
        for d in stride(from: 121, through: 400, by: 3) { readout.read(distance: CGFloat(d), zone: 120) }
        XCTAssertEqual(Trace.total("readout"), 1, "moving further away is not another offer")
        readout.read(distance: 60, zone: 120)
        XCTAssertFalse(readout.arrow)
        readout.read(distance: 0, zone: 120)
        XCTAssertEqual(Trace.total("readout"), 2, "the crossing back to the bottom is the second write, and the last")
    }

    /// `newBelow` is idempotent too: the content-size handler fires it on every size change while the reader is
    /// away, and only the first of those is a write.
    func testNewBelowIsWrittenOnceAndClearsOnlyWhenTheReaderReturns() {
        let readout = ScrollReadout()
        readout.read(distance: 300, zone: 120)
        Trace.resetTotal("readout")
        for _ in 0..<500 { readout.setNewBelow(true, zone: 120) }
        XCTAssertTrue(readout.newBelow)
        XCTAssertEqual(Trace.total("readout"), 0, "the arrow was already offered; nothing new below the second time")
        readout.setNewBelow(false, zone: 120)
        XCTAssertFalse(readout.newBelow)
        XCTAssertTrue(readout.arrow, "the reader is still away from the bottom")
    }

    // MARK: the real screen

    /// A flick produces callbacks, and once the list is still they stop — and the arrow was told about the offer
    /// twice at most, not once per reading.
    func testTheGeometryHandlerSettlesAfterAFlick() throws {
        let chat = longChat()
        let app = AppModel()
        let w = host(NavigationStack { ChatScreen(chat: chat) }.environment(app))
        guard let scroll = chatScrollView(in: w) else { return XCTFail("the chat's scroll view never appeared") }
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 200, "the harness list has to be scrollable")

        // A flick toward older messages, the direction t9's first swipe took: the offsets a finger produces, applied
        // in order so every one of them is a geometry change the handler sees.
        Trace.resetTotal("geom"); Trace.resetTotal("readout")
        let start = scroll.contentOffset.y
        for step in 1...12 {
            scroll.setContentOffset(CGPoint(x: 0, y: start - CGFloat(step) * 40), animated: false)
            pump(0.02)
        }
        pump(1.5)
        let duringFlick = Trace.total("geom")
        let published = Trace.total("readout")
        XCTAssertGreaterThan(duringFlick, 0, "the handler never saw the scroll at all")

        // Nothing moves now. A handler that writes on every callback keeps the layout loop alive by itself; a
        // handler that writes only on a real change is silent.
        Trace.resetTotal("geom")
        pump(1.5)
        let whileStill = Trace.total("geom")
        print("geom callbacks: flick=\(duringFlick) still=\(whileStill) arrow publications=\(published)")
        XCTAssertLessThan(whileStill, 60,
                          "the geometry handler kept firing with nothing moving (\(whileStill) callbacks in 1.5 still seconds): the write in the callback is feeding layout")
        XCTAssertLessThan(published, 5,
                          "the arrow was re-told \(published) times during one flick: the readout is publishing readings, not offers")
    }

    // MARK: the mechanism itself, in a probe

    /// The A/B: the legacy shape runs away, the shipped one settles. This is the freeze's own mechanism, held
    /// still enough to assert on. The legacy probe stops writing after `legacyWrites` callbacks, so the run is
    /// bounded — and it also shows the loop is the WRITE's: the moment the writes stop, so does the churn.
    func testTheLegacyReadoutShapeLoopsAndTheShippedOneSettles() throws {
        Trace.resetTotal("probe.body"); Trace.resetTotal("probe.geom")
        let t0 = Date()
        _ = host(LegacyFeedbackProbe())
        pump(2)
        let legacyBodies = Trace.total("probe.body")
        let legacyGeom = Trace.total("probe.geom")
        let legacySeconds = Date().timeIntervalSince(t0)
        window?.isHidden = true; window = nil

        Trace.resetTotal("probe.shipped.body"); Trace.resetTotal("probe.shipped.geom")
        _ = host(ShippedFeedbackProbe())
        pump(2)
        let shippedBodies = Trace.total("probe.shipped.body")
        let shippedGeom = Trace.total("probe.shipped.geom")
        print("probe: legacy bodies=\(legacyBodies) geom=\(legacyGeom) in \(String(format: "%.1f", legacySeconds))s; shipped bodies=\(shippedBodies) geom=\(shippedGeom)")

        // The app's own signature, in miniature: the geometry churns until the writes stop, and not one body pass
        // happens while it does (t9 printed `geom=1104` every two seconds with no `chat=` beside it). Without the
        // write limit this probe hung the app for as long as it was left running — that is the freeze.
        XCTAssertGreaterThanOrEqual(legacyGeom, legacyWrites,
                                    "the legacy shape stopped before its own write limit: the churn is not the writes' doing")
        XCTAssertLessThan(legacyBodies, 5,
                          "the legacy loop re-ran the body \(legacyBodies) times: t9's freeze never did, so this is not its shape")
        XCTAssertLessThan(shippedGeom, 10,
                          "the shipped readout still churned the geometry \(shippedGeom) times for one static layout")
        XCTAssertGreaterThan(shippedGeom, 0, "the shipped probe never saw the geometry at all")
    }
}

/// The shape that froze, made deterministic: an observable RAW reading, written by the geometry callback and read
/// by the view's own layout. Each write re-runs the body, the layout pass that follows reports a reading a hair
/// different, and the callback writes again — t9's cycle, which printed `geom=1104` every two seconds for four
/// minutes with no chat body pass and no frame committed.
///
/// The writes stop after `legacyWrites` callbacks, so the loop is MEASURED rather than hung on — and that bound is
/// also the proof that the loop is the write's: the churn ends the moment the writes do.
@MainActor @Observable private final class LegacyReadout { var distance: CGFloat = 0 }

private let legacyWrites = 80

private struct LegacyFeedbackProbe: View {
    @State private var readout = LegacyReadout()
    var body: some View {
        Trace.body("probe.body")
        return GeometryReader { g in
            VStack(spacing: 0) {
                ScrollView { Color.clear.frame(height: 6000) }
                    .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.maxY } action: { _, maxY in
                        Trace.body("probe.geom")
                        guard Trace.total("probe.geom") <= legacyWrites else { return }
                        readout.distance = maxY
                    }
                Color.clear.frame(height: readout.distance > g.size.height - 0.5 ? 1 : 0)
            }
        }
    }
}

/// The same probe on the shipped readout: the callback publishes the arrow's OFFER (only on a change) and the raw
/// reading is not observable, so the layout that reads the offer is written once and the cycle has nothing to feed it.
private struct ShippedFeedbackProbe: View {
    @State private var readout = ScrollReadout()
    var body: some View {
        Trace.body("probe.shipped.body")
        return GeometryReader { g in
            VStack(spacing: 0) {
                ScrollView { Color.clear.frame(height: 6000) }
                    .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.maxY } action: { _, maxY in
                        Trace.body("probe.shipped.geom")
                        readout.read(distance: 6000 - maxY, zone: 120)
                    }
                Color.clear.frame(height: readout.arrow ? 1 : 0)
            }
        }
    }
}
