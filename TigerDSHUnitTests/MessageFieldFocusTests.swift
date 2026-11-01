import XCTest
import SwiftUI
import UIKit
@testable import TigerDSH

/// The composer's field asked the window for first-responder status on EVERY SwiftUI pass instead of once per
/// change of intent.
///
/// t15's `testQueuePill` archived a chat whose run was still going. The "Archive this chat?" dialog appeared while
/// the reader's caret was still in the composer, and the query for the dialog's "Stop and archive" row then timed
/// out twice at 31 s and failed the test after 110 s. The spindump XCTest took for that stalled query (XCTest
/// Diagnostics, 14:58:29 PM) has 501 of 501 main-thread samples in one chain:
///
///     Mux.receive -> ChatModel.frame -> ChatModel.streamFrame -> streamError._modify
///       -> the SwiftUI update that write triggers -> UIViewRepresentable.updateUIView
///       -> MessageField.updateUIView (MessageField.swift:77) -> becomeFirstResponder
///
/// — the same chain reached about 250 times inside those five seconds. Asking is free only while it succeeds: with
/// the dialog owning the responder the request could not be granted, and the field asked again on the next streamed
/// chunk, and the next, ~25 times a second. The main thread never returned to the run loop the accessibility query
/// was waiting on, so the app stopped answering the test while still streaming happily.
///
/// This harness holds the rule the fix introduces: the responder is moved when the INTENT changes, and never
/// re-asserted afterwards. The field is hosted in a window whose first responder is a view that never gives it up —
/// which is what a presented dialog is to the field — with the intent held `true` and twenty updates driven through
/// the field's own input. Before the fix every one of those twenty updates asks again; after it, none of them does.
@MainActor
final class MessageFieldFocusTests: XCTestCase {
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

    /// The responder a presented dialog is, as far as the field is concerned: it holds the responder and refuses to
    /// give it up, so every `becomeFirstResponder()` the field makes has to fail.
    private final class StubbornResponder: UIView {
        override var canBecomeFirstResponder: Bool { true }
        override func resignFirstResponder() -> Bool { false }
    }

    private final class Ticker: ObservableObject {
        @Published var n = 0
        /// The field's own text, so one tick is unambiguously an update of the representable: a change to an input
        /// of the field is what `updateUIView` is for, while a change elsewhere in the body could be served without
        /// touching it. The body pass itself is counted too, so a run where nothing was driven cannot pass.
        @Published var text = ""
    }

    private struct FieldHost: View {
        @ObservedObject var ticker: Ticker
        var body: some View {
            let _ = Trace.body("field.host")
            VStack {
                Text("\(ticker.n)")
                // The intent is held `true` for the whole test: the reader's caret is in the composer and the
                // dialog takes the responder away from it.
                MessageField(text: $ticker.text, focused: .constant(true), placeholder: "Message", onSend: {}, onImage: { _ in })
                    .frame(height: 44)
            }
        }
    }

    private func field(in v: UIView) -> PasteTextView? {
        if let t = v as? PasteTextView, t.accessibilityIdentifier == "composer.field" { return t }
        for sub in v.subviews { if let f = field(in: sub) { return f } }
        return nil
    }

    func testTheFieldAsksForFocusOncePerIntentNotOncePerUpdate() {
        let ticker = Ticker()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        // The responder is taken — and held — BEFORE the field exists, so the field's very first update already
        // meets a request that cannot be granted. Taking it afterwards would not do: a field that had become first
        // responder once would be TOLD it resigned (`textViewDidEndEditing` writes `focused = false`), and the
        // composer would stop asking for a reason that has nothing to do with this test.
        let root = UIViewController()
        w.rootViewController = root
        w.makeKeyAndVisible()
        window = w
        let stubborn = StubbornResponder(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        root.view.addSubview(stubborn)
        XCTAssertTrue(stubborn.becomeFirstResponder(), "the harness could not take the responder")
        pump(0.5)
        XCTAssertTrue(stubborn.isFirstResponder, "the harness lost the responder it needs to hold")

        // Counted from the moment the field exists: the fixed field asks ONCE, on its first pass — resetting after
        // the setup pump would throw that one request away and read zero for the wrong reason.
        Trace.resetTotal("field.focus")
        Trace.resetTotal("field.host")
        let vc = UIHostingController(rootView: FieldHost(ticker: ticker))
        root.addChild(vc)
        vc.view.frame = root.view.bounds
        root.view.addSubview(vc.view)
        vc.didMove(toParent: root)
        pump(2)

        guard let f = field(in: vc.view) else { return XCTFail("the hosted composer has no field") }
        XCTAssertFalse(f.isFirstResponder, "the field took the responder, so no request in here can fail")

        // What the field did while it appeared. One request is the intent arriving; a second is SwiftUI building the
        // representable a second time, which is a request for a NEW view and not the re-assertion this test is about.
        let onAppearing = Trace.total("field.focus")
        Trace.resetTotal("field.focus")
        Trace.resetTotal("field.host")

        // Twenty updates, each one a change to the field's own input, with the focus intent held `true`.
        for i in 1...20 {
            ticker.n = i
            ticker.text = "draft \(i)"
            pump(0.1)
        }
        let passes = Trace.total("field.host")
        let reAsked = Trace.total("field.focus")
        print("field.focus: \(onAppearing) request(s) as the field appeared, then \(reAsked) over the next "
              + "\(passes) updates")
        XCTAssertGreaterThanOrEqual(onAppearing, 1, "the field never asked for the responder at all")
        XCTAssertGreaterThanOrEqual(passes, 20, "the harness drove \(passes) updates, so it never updated the field")
        XCTAssertEqual(reAsked, 0, "the field re-asked for focus on \(reAsked) of the next \(passes) updates")
    }
}
