import XCTest
import SwiftUI
import UIKit
@testable import TigerDSH

/// The drawer's motion, held to the properties Codex has found missing one round at a time: a released or
/// interrupted drag must be continuous; an interrupting pan must be measured from where the card IS rather than from
/// the Boolean's destination; a retarget must not brake a moving card; a long frame must not blow the spring up;
/// and a display frame must touch the card's own leaf and never the root's body.
///
/// The spring is stepped here at a fixed rate, exactly as the display link steps it on the device, so these are the
/// real numbers rather than a re-implementation of them. The pan tests feed the recognizer's own stream —
/// `begin`, then translations, then a release — because handing `drag(to:)` an absolute position is the shape that
/// let Codex R13's P1 through: it passed while the app clamped the card to the first translation.
@MainActor
final class DrawerMotionTests: XCTestCase {
    private let width: CGFloat = 295
    private let dt: CFTimeInterval = 1.0 / 60

    private func makeMotion(_ w: CGFloat? = nil) -> DrawerMotion {
        let m = DrawerMotion()
        m.setWidth(w ?? width)
        return m
    }

    /// Aim with a stated velocity — a pan's release, or a test saying "from rest".
    private func spring(_ motion: DrawerMotion, to resting: CGFloat, from velocity: CGFloat = 0) {
        motion.settle(DrawerMotion.Target(
            resting: resting,
            stiffness: DrawerMotion.stiffness(response: 0.28, dampingFraction: 1),
            damping: DrawerMotion.damping(response: 0.28, dampingFraction: 1),
            velocity: velocity))
    }

    /// The app's own aim: the velocity is not stated, so the spring keeps the one it has.
    private func retarget(_ motion: DrawerMotion, to resting: CGFloat) {
        motion.settle(DrawerMotion.Target(
            resting: resting,
            stiffness: DrawerMotion.stiffness(response: 0.28, dampingFraction: 1),
            damping: DrawerMotion.damping(response: 0.28, dampingFraction: 1),
            velocity: nil))
    }

    private func steps(_ motion: DrawerMotion, _ n: Int) { for _ in 0..<n { motion.step(dt: dt) } }

    /// One recognizer gesture, in the units UIKit reports: the touch goes down, `changes` arrive as translations
    /// measured from that point, and the finger lifts with its last translation and its own velocity. `RootView`'s
    /// `panBegan`/`panMoved`/`panEnded` are exactly this sequence.
    @discardableResult
    private func pan(_ motion: DrawerMotion, _ state: inout DrawerPanState,
                     changes: [CGFloat], velocity: CGFloat = 0, width panel: CGFloat? = nil) -> Bool {
        let w = panel ?? width
        motion.grab()
        state.begin(at: motion.presented)
        for t in changes { motion.drag(to: state.position(translation: t, width: w)) }
        return state.release(translation: changes.last ?? 0, velocity: velocity, width: w)
    }

    /// What each frame did to the card, in points.
    private func replay(_ motion: DrawerMotion, frames: Int) -> [CGFloat] {
        var previous = motion.presented
        var deltas: [CGFloat] = []
        for _ in 0..<frames {
            motion.step(dt: dt)
            deltas.append(motion.presented - previous)
            previous = motion.presented
        }
        return deltas
    }

    // MARK: the spring's own shape

    /// Critically damped at the reference's numbers: no overshoot past the target, open inside 0.4 s and closed
    /// again, and monotone the whole way — a critically damped spring never travels backwards.
    func testTheSpringSettlesWithoutOvershooting() {
        let motion = makeMotion()
        spring(motion, to: width)
        var series: [CGFloat] = [motion.presented]
        for _ in 0..<60 { motion.step(dt: dt); series.append(motion.presented) }
        let overshoot = (series.max() ?? 0) - width
        let reached = series.firstIndex { abs($0 - width) < 0.5 } ?? -1
        print(String(format: "drawer motion: open in %d frames (%.0f ms), overshoot %.2f pt, at 0.2 s %.1f of %.0f pt",
                     reached, Double(reached) * dt * 1000, overshoot, series[12], width))
        XCTAssertLessThanOrEqual(overshoot, 0.5, "the spring overshot the open end by \(overshoot) pt")
        XCTAssertGreaterThanOrEqual(reached, 0, "the spring did not reach the open end inside a second")
        // What the reader sees: 93 % of the travel inside 0.2 s. The tail — the last half point at ~0.45 s — is the
        // critically damped curve's own, not a slow spring: at response 0.28 the analytical solution is 0.14 pt from
        // the target at 0.45 s and the old explicit-Euler version only reached it sooner by overshooting.
        XCTAssertGreaterThan(series[12], width * 0.9, "at 0.2 s the drawer is only at \(series[12]) of \(width) pt")
        XCTAssertLessThan(reached, 30, "the drawer took longer than 0.5 s to reach the open end")
        for i in 1..<series.count {
            XCTAssertGreaterThanOrEqual(series[i], series[i - 1] - 0.001,
                                        "the open ran backwards at frame \(i): \(series[i - 1]) -> \(series[i])")
        }

        spring(motion, to: 0)
        steps(motion, 40)
        XCTAssertEqual(motion.presented, 0, accuracy: 0.5, "the drawer did not close again")
    }

    // MARK: the recognizer's own path (R13 P1)

    /// The defect Codex R13 P1 named, in its own numbers: the drawer is open at 295 pt, the finger moves 10 pt left,
    /// and the recognizer reports −10. That translation is measured from the touch-down point, so the card is at
    /// 285 pt — not at −10, which the clamp turns into 0.
    func testAClosingDragFromTheOpenEndIsRebasedOntoThePresentedOffset() {
        let motion = makeMotion()
        spring(motion, to: width)
        steps(motion, 60)
        XCTAssertEqual(motion.presented, width, accuracy: 0.5, "the harness drawer never opened")

        var state = DrawerPanState()
        // ...and the release is read from the same rebased position: at 285 pt of 295 the card is far past halfway,
        // so it stays open. Judged from the raw translation (-10, taken as a position) it would have closed the
        // drawer on a 10 pt nudge — which is the other half of what the recognizer's units cost the app.
        let open = pan(motion, &state, changes: [-10])
        XCTAssertEqual(motion.presented, width - 10, accuracy: 0.001,
                       "the first changed event of a closing drag clamped the card to \(motion.presented), not 285")
        XCTAssertTrue(open, "a 10 pt pull from the open end closed the drawer: the release used the translation as a position")
    }

    /// A release is selected from the REBASED position: from the open end, pulling back 160 pt leaves the card at
    /// 135 pt — short of halfway — so it springs shut; 120 pt leaves it at 175 pt and it stays open.
    func testAReleaseIsDecidedByTheRebasedPosition() {
        let motion = makeMotion()
        spring(motion, to: width)
        steps(motion, 60)

        var shut = DrawerPanState()
        XCTAssertFalse(pan(motion, &shut, changes: [-160]), "135 pt of 295 is short of halfway and must spring shut")

        spring(motion, to: width)
        steps(motion, 60)
        var stays = DrawerPanState()
        XCTAssertTrue(pan(motion, &stays, changes: [-120]), "175 pt of 295 is past halfway and must stay open")
    }

    /// A pan that interrupts a spring: the card stays exactly where it is drawn, keeps the velocity it had, and the
    /// finger's translations are measured from THAT. Handing the recognizer's −40 to `drag(to:)` as a position —
    /// the shape the old tests used — moved a card at 40 pt to 0.
    func testAnInterruptingPanIsMeasuredFromThePresentedOffset() {
        let motion = makeMotion()
        spring(motion, to: width)
        steps(motion, 3)
        let caught = motion.presented
        XCTAssertGreaterThan(caught, 5, "the spring had not moved yet")
        XCTAssertLessThan(caught, width * 0.4, "the spring was already most of the way open")

        var state = DrawerPanState()
        motion.grab()
        state.begin(at: motion.presented)
        XCTAssertEqual(motion.presented, caught, accuracy: 0.001,
                       "grabbing a moving card teleported it to \(motion.presented) from \(caught)")
        motion.drag(to: state.position(translation: -40, width: width))
        XCTAssertEqual(motion.presented, caught - 40, accuracy: 0.001,
                       "the finger pulled back 40 pt and the card moved to \(motion.presented)")

        // Released short of halfway with a small backwards flick: back to closed, one spring step at a time.
        XCTAssertFalse(state.release(translation: -40, velocity: -300, width: width))
        spring(motion, to: 0, from: -300)
        let afterOneFrame = motion.presented
        XCTAssertLessThan(abs(afterOneFrame - (caught - 40)), 30,
                          "the release jumped \(abs(afterOneFrame - (caught - 40))) pt in one frame")
        steps(motion, 40)
        XCTAssertEqual(motion.presented, 0, accuracy: 0.5, "the interrupted open did not come back to closed")
    }

    /// A width change under a live finger clamps the card (a 295 pt panel becomes a 200 pt one) and the pan's
    /// origin moves with it — otherwise the next changed event, a translation of 0, would drag the card back to
    /// where the finger grabbed it.
    func testAWidthChangeMovesWhatTheFingerIsMeasuredFrom() {
        let motion = makeMotion()
        spring(motion, to: width)
        steps(motion, 60)

        var state = DrawerPanState()
        motion.grab()
        state.begin(at: motion.presented)
        XCTAssertEqual(motion.presented, width, accuracy: 0.5)

        motion.rebase(open: true, width: 200)
        state.rebase(to: motion.presented)
        XCTAssertEqual(motion.presented, 200, accuracy: 0.001, "the shrink did not clamp the card")
        motion.drag(to: state.position(translation: 0, width: 200))
        XCTAssertEqual(motion.presented, 200, accuracy: 0.001,
                       "the next unchanged event dragged the card back to the old origin")

        motion.drag(to: state.position(translation: -50, width: 200))
        XCTAssertEqual(motion.presented, 150, accuracy: 0.001, "the finger's own travel was lost after the clamp")
    }

    // MARK: retargeting (R13 P2)

    /// A programmatic retarget states no velocity, so the spring keeps the one it has. Repeating "open" while the
    /// card is travelling — a second tap, a notification — must not brake it to a stop and start it again; and a
    /// release velocity from a pan still replaces it.
    func testARetargetKeepsTheSpringsVelocity() {
        let motion = makeMotion()
        spring(motion, to: width)
        steps(motion, 7)
        let travelling = motion.debugVelocity
        XCTAssertGreaterThan(travelling, 500, "the harness never got the card moving")

        retarget(motion, to: width)
        XCTAssertEqual(motion.debugVelocity, travelling, accuracy: 1,
                       "re-aiming at the same end braked the card to \(motion.debugVelocity) from \(travelling)")

        retarget(motion, to: 0)
        XCTAssertEqual(motion.debugVelocity, travelling, accuracy: 1,
                       "turning the card round braked it to \(motion.debugVelocity) from \(travelling)")

        spring(motion, to: width, from: -300)
        XCTAssertEqual(motion.debugVelocity, -300, accuracy: 1, "a pan's release velocity did not replace the spring's")
    }

    /// The capture test's reversal — `-drawer.interrupt <ms>` on a debug build — turns the drawer round while the
    /// opening spring is still running. What it must NOT do is jump: the turn happens at the presented offset with
    /// the presented velocity, every frame of it is a fraction of the travel, and the card comes back to closed.
    func testAnInterruptWhileOpeningReversesWithoutAJump() {
        let motion = makeMotion()
        spring(motion, to: width)
        // 0.12 s of spring, the delay the capture test schedules: about 7 frames at 60 Hz. The card is a good way
        // out by then and still travelling.
        steps(motion, 7)
        let atInterrupt = motion.presented
        XCTAssertGreaterThan(atInterrupt, width * 0.2, "the harness reversed before the drawer had opened at all")
        XCTAssertLessThan(atInterrupt, width, "the harness reversed after the drawer had already settled")

        retarget(motion, to: 0)
        XCTAssertEqual(motion.presented, atInterrupt, accuracy: 0.001, "the reversal jumped in its first frame")
        let deltas = replay(motion, frames: 40)
        XCTAssertTrue(deltas.contains { $0 < 0 }, "the interrupted open did not turn round")
        let biggest = deltas.map(abs).max() ?? 0
        print(String(format: "drawer interrupt: reversed at %.0f pt, frames %@",
                     atInterrupt, deltas.prefix(6).map { String(format: "%.0f", $0) }.joined(separator: " ")))
        // The old shape's tell was a first frame that swallowed the WHOLE remaining travel (237 pt of 295 here);
        // the momentum carried into the turn is the card's own velocity, one frame of it, not a jump.
        XCTAssertLessThanOrEqual(biggest, width / 4,
                                 "one frame of the reversal took \(biggest) pt of \(width) — that is a snap, not a spring")
        XCTAssertEqual(motion.presented, 0, accuracy: 0.5, "the interrupted open did not come back to closed")
    }

    // MARK: integration and travel (R13 P2)

    /// A stalled display link hands the spring a 100 ms delta. Replayed with explicit Euler that produced
    /// `0 → 0 → 1485 → −2210` for a 295 pt drawer (Codex R13 P2); integrated in slices short enough, it is the same
    /// critically damped curve at a coarser rate.
    func testALongFrameIsIntegratedInSubsteps() {
        let motion = makeMotion()
        spring(motion, to: width)
        let first = { motion.step(dt: 0.1); return motion.presented }()
        print(String(format: "drawer long frame: one 100 ms step → %.1f pt of %.0f", first, width))
        XCTAssertLessThanOrEqual(first, width, "a 100 ms frame put the card at \(first) pt of a \(width) pt panel")
        XCTAssertGreaterThanOrEqual(first, 0, "a 100 ms frame sent the card to \(first) pt")
        var previous = motion.presented
        for i in 0..<12 {
            motion.step(dt: 0.1)
            XCTAssertGreaterThanOrEqual(motion.presented, previous - 0.001,
                                        "the coarse replay ran backwards at step \(i): \(previous) -> \(motion.presented)")
            XCTAssertLessThanOrEqual(motion.presented, width + 0.001, "the coarse replay left the travel at step \(i)")
            previous = motion.presented
        }
        XCTAssertEqual(motion.presented, width, accuracy: 0.5, "the coarse replay never settled")
    }

    /// The travel is `0...panelWidth` whatever the flick: released at 280 pt with +1500 pt/s the unclamped spring
    /// reached 314 pt of a 295 pt panel, and a −1500 pt/s flick at the closed end reached −31 pt.
    func testAFlickCannotDrawTheCardPastThePanel() {
        let out = makeMotion()
        out.grab()
        out.drag(to: 280)
        spring(out, to: width, from: 1500)
        for _ in 0..<60 {
            out.step(dt: dt)
            XCTAssertLessThanOrEqual(out.presented, width + 0.001, "the flick drew the card past the panel's edge")
        }
        XCTAssertEqual(out.presented, width, accuracy: 0.5, "the flick never settled at the open end")

        let back = makeMotion()
        back.grab()
        back.drag(to: 4)
        spring(back, to: 0, from: -1500)
        for _ in 0..<60 {
            back.step(dt: dt)
            XCTAssertGreaterThanOrEqual(back.presented, -0.001, "the backward flick drew the card past the closed end")
        }
        XCTAssertEqual(back.presented, 0, accuracy: 0.5)
    }

    /// A width change during an active spring: a shrink of the travel leaves the card inside the new one, and a
    /// velocity still pushing outward is spent.
    func testAShrinkingPanelKeepsALiveSpringInsideIt() {
        let motion = makeMotion()
        spring(motion, to: width, from: 1200)
        steps(motion, 3)
        XCTAssertGreaterThan(motion.presented, 20, "the harness spring never left the closed end")
        motion.rebase(open: true, width: 60)
        XCTAssertLessThanOrEqual(motion.presented, 60, "the shrink left the card at \(motion.presented) on a 60 pt panel")
        steps(motion, 60)
        XCTAssertEqual(motion.presented, 60, accuracy: 0.5, "the re-aimed spring did not settle at the new width")
    }

    // MARK: the frame budget (R13 P1)

    /// The body-pass count, on the real view: `RootView` is hosted, the drawer opened and closed through the app's
    /// own door bell, and both sides of the promise counted — the card's leaf runs for every frame of the spring,
    /// the root's body runs for none of them.
    ///
    /// The display link drives the spring exactly as it does on the device. If this process had no live link the
    /// card's count would stay at zero and the test fails on its own first assertion rather than passing vacuously.
    func testAFullOpenAndCloseNeverReRunsTheRootBody() {
        let app = AppModel()
        app.auth = .ok
        app.currentChatID = ""            // the cheapest page: "No chat open", no network, no chat body
        let motion = DrawerMotion()
        let host = UIHostingController(rootView: RootView(motion: motion).environment(app))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let key = scene?.windows.first { $0.isKeyWindow }
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            key?.makeKey()
        }

        // The view appears; with no chat to open, the app opens the drawer itself. That settle is not measured.
        spin(0.9)
        // Close it, so the measured pair is a real open and a real close.
        NotificationCenter.default.post(name: .toggleDrawer, object: nil)
        spin(0.7)
        let root0 = motion.rootBodyPasses
        let card0 = motion.cardBodyPasses

        NotificationCenter.default.post(name: .toggleDrawer, object: nil)
        spin(0.7)
        NotificationCenter.default.post(name: .toggleDrawer, object: nil)
        spin(0.9)

        let root = motion.rootBodyPasses - root0
        let card = motion.cardBodyPasses - card0
        print("drawer budget: one open/close ran the root body \(root) times and the card's leaf \(card) times")
        XCTAssertGreaterThan(card, 10,
                             "the spring never ran under a display link: the card's leaf had \(card) body passes")
        XCTAssertLessThanOrEqual(root, 6,
                                 "RootView.body ran \(root) times across one open/close: the motion is still inside its observation scope")
    }

    /// One run-loop slice, so the display link and SwiftUI's own updates get the main thread they need.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: the rest of the motion's contract

    /// Reduce Motion: the card is put at the new end in the same frame, with no frames in between.
    func testReduceMotionPutsTheCardThereAtOnce() {
        let motion = makeMotion()
        for (resting, name) in [(width, "open"), (0, "closed")] as [(CGFloat, String)] {
            motion.settle(DrawerMotion.Target(
                resting: resting,
                stiffness: DrawerMotion.stiffness(response: 0.28, dampingFraction: 1),
                damping: DrawerMotion.damping(response: 0.28, dampingFraction: 1),
                velocity: 0, immediate: true))
            XCTAssertEqual(motion.presented, resting, accuracy: 0.001, "Reduce Motion still animated the draw \(name)")
        }
    }

    /// The animator's own completion fires once the card has come to rest, and a new gesture replaces it rather
    /// than leaving the old one to fire late (Codex R13 P2: the focus move used to be a fixed 0.35 s delay).
    func testTheCompletionFiresAtRestAndAGrabCancelsIt() {
        let motion = makeMotion()
        var fired: [String] = []
        motion.onRest = { fired.append("open") }
        spring(motion, to: width)
        steps(motion, 60)
        XCTAssertEqual(fired, ["open"], "the completion did not fire exactly once when the spring settled")

        motion.onRest = { fired.append("close") }
        spring(motion, to: 0)
        steps(motion, 5)
        motion.grab()
        steps(motion, 5)
        XCTAssertEqual(fired, ["open"], "the completion fired after the gesture it belonged to was taken over")
    }

    /// A width change re-aims the motion: a live drag keeps its offset instead of jumping, and a card at rest is
    /// pinned to the end it was resting at, at the new width.
    func testAWidthChangeRebasesLiveAndRestingCards() {
        let motion = makeMotion()
        spring(motion, to: width)
        motion.grab()
        motion.drag(to: width / 2)
        motion.rebase(open: true, width: 402)
        XCTAssertEqual(motion.presented, width / 2, accuracy: 0.001,
                       "a width change moved a card that was under the finger")
        spring(motion, to: 402)
        steps(motion, 60)
        XCTAssertEqual(motion.presented, 402, accuracy: 0.5, "the card did not settle at the new width")

        let resting = makeMotion()
        spring(resting, to: width)
        steps(resting, 60)
        XCTAssertEqual(resting.presented, width, accuracy: 0.5, "the harness card never settled open")
        resting.rebase(open: true, width: 402)
        XCTAssertEqual(resting.presented, 402, accuracy: 0.5, "a card resting open kept the old width after a rotation")

        let closed = makeMotion()
        spring(closed, to: width)
        steps(closed, 60)
        spring(closed, to: 0)
        steps(closed, 60)
        closed.rebase(open: false, width: 402)
        XCTAssertEqual(closed.presented, 0, accuracy: 0.001, "a closed card left the closed end when the width changed")
    }

    /// A flick's velocity is carried into the spring: let go at 800 pt/s with the card barely moved and it still
    /// ends up fully open.
    func testAFlickCarriesIntoTheSpring() {
        let motion = makeMotion()
        spring(motion, to: width, from: 800)
        steps(motion, 60)
        XCTAssertEqual(motion.presented, width, accuracy: 0.5, "a flick did not carry the drawer open")
    }
}
