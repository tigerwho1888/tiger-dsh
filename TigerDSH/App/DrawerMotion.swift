import Observation
import QuartzCore
import UIKit

/// The drawer's card offset, as a spring this app steps itself once per frame.
///
/// It exists for one reason: **the offset has to be readable**. The drawer used to be `withAnimation { drawerOpen =
/// true }` plus a `drag` delta, so the only number the code had was the Boolean's destination — the card on screen
/// was somewhere between there and the old value, and SwiftUI does not expose it. A pan that began while a spring
/// was still running therefore computed from the destination, and the card jumped by whatever the spring had left
/// to travel (Codex R12: a closed-to-full-width jump at 74.37 s in `.tmp/drawer-flash/after/motion.mov`).
///
/// Here the offset is a value this app owns:
///
/// * `presented` — where the card is drawn right now, in points, always;
/// * `settle(_:)` — aim the spring at a target and let it run;
/// * `grab()` — a finger is down: the spring stops and the card stays exactly where it was, so the gesture picks up
///   from the presented position and keeps the presented velocity;
/// * `drag(to:)` — follow the finger;
/// * `rebase(open:width:)` — the panel's width changed (rotation): a live gesture keeps its offset, a card at rest
///   is pinned to the end it was resting at.
///
/// The displayed value is read by ONE leaf (`DrawerCardLayer`), never by the root: a write here invalidates the
/// card's own body and nothing else. `rootBodyPasses` and `cardBodyPasses` count both sides of that promise on the
/// real hierarchy (Codex R13 P1).
///
/// Critically damped at the reference's own numbers — `response 0.28, dampingFraction 1` — integrated at the
/// display's own rate in slices short enough that a long frame cannot blow the spring up. The loop stops the
/// moment the card is at rest, so a drawer that is not moving costs nothing: no display link, no frame work.
@MainActor
@Observable
final class DrawerMotion {
    /// Where the card is drawn, in points from closed.
    private(set) var presented: CGFloat = 0

    /// The spring's shape, in the units the animation loop integrates in.
    struct Target {
        var resting: CGFloat
        var stiffness: CGFloat
        var damping: CGFloat
        /// A release velocity, in points per second. `nil` KEEPS the velocity the spring already has — a drawer
        /// aimed at a new end mid-flight must not be stopped dead (Codex R13 P2) — while an explicit number is a
        /// pan's own release velocity and replaces it.
        var velocity: CGFloat?
        /// Reduce Motion: put the card at `resting` in this same frame rather than running the spring.
        var immediate: Bool = false
    }

    /// `response` is the period of one oscillation and `dampingFraction` its fraction of critical damping — the
    /// same two numbers `Animation.spring(response:dampingFraction:)` takes.
    static func stiffness(response: Double, dampingFraction: Double) -> CGFloat {
        let w = 2 * Double.pi / max(response, 0.001)
        return CGFloat(w * w)
    }

    static func damping(response: Double, dampingFraction: Double) -> CGFloat {
        let w = 2 * Double.pi / max(response, 0.001)
        return CGFloat(2 * dampingFraction * w)
    }

    private var velocity: CGFloat = 0
    private var target: Target?
    /// The panel's own travel. One number, because the card's two bounds are always 0 and the panel's width.
    private var panelWidth: CGFloat = 0
    /// A finger is down: the spring is not running, but the card is not "at rest at an end" either — it is
    /// wherever the touch left it, and a width change must not move it.
    private var dragging = false
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    /// Runs once when the card next comes to rest: the drawer's own completion, which is what moves VoiceOver's
    /// focus and posts the layout change. A retarget REPLACES it and `grab()` clears it, so the move a later
    /// gesture supersedes can never fire late — a cancellable completion instead of an assignment followed by a
    /// fixed delay (Codex R13 P2).
    @ObservationIgnored var onRest: (() -> Void)?

    /// A hair over one frame's worth of movement at 60 Hz: below this the next step is a rounding error, so the
    /// loop stops rather than spending frames on 0.02 pt.
    private static let restDistance: CGFloat = 0.1
    private static let restVelocity: CGFloat = 0.5
    /// The longest single integration slice. A display link can hand back a 250 ms delta after a stall, and one
    /// explicit Euler step of that length does not approximate this spring — it explodes (Codex R13 P2 replayed
    /// 100 ms steps and got `0 → 0 → 1485 → −2210` for a 295 pt drawer). A long frame is therefore several small
    /// steps rather than one wrong one.
    private static let maxStep: CGFloat = 1.0 / 120

    #if DEBUG
    /// Body passes, counted rather than argued (Codex R13 P1): the claim is that a display frame touches the card's
    /// leaf and never the root's body, and a count is the evidence. `@ObservationIgnored` on both — counting a body
    /// pass must not itself invalidate one. Read by `testAFullOpenAndCloseNeverReRunsTheRootBody`.
    @ObservationIgnored private(set) var rootBodyPasses = 0
    @ObservationIgnored private(set) var cardBodyPasses = 0
    func countRootBody() { rootBodyPasses += 1 }
    func countCardBody() { cardBodyPasses += 1 }

    /// The spring's own velocity, in points per second. Continuity is what a retarget has to preserve, and a test
    /// that has to see it should not have to infer it from positions.
    var debugVelocity: CGFloat { velocity }
    #endif

    /// The panel's travel. Called on appearance and whenever the geometry reports a new width.
    func setWidth(_ width: CGFloat) { panelWidth = max(width, 1) }

    /// Aim at a target and run. `velocity` is the spring's own velocity in points per second — a pan's release
    /// velocity, so a flick carries into the motion. `immediate` (Reduce Motion) puts the card where it is going
    /// in this same frame: the drawer still opens and closes, the opaque card still slides, no frame animates.
    func settle(_ t: Target) {
        var v = t
        v.resting = min(max(t.resting, 0), panelWidth)
        target = v
        dragging = false
        // A programmatic retarget (an open/close notification, a rotation) passes no velocity and KEEPS the one the
        // spring has: repeating "open" while the card is still travelling must not brake it to a stop and start it
        // again. A pan's release velocity replaces it in whichever direction the finger threw the card — the spring
        // carries the card on and brings it back, which is geometry, not a kick in the state (Codex R13 P2).
        if let wanted = t.velocity { velocity = wanted }
        if v.immediate {
            finish(at: v.resting)
        } else if isAtRest {
            finish(at: v.resting)
        } else {
            start()
        }
    }

    /// A finger is down. The card stays exactly where it is drawn and the spring keeps the velocity it had, so an
    /// interrupting gesture inherits a continuous motion instead of jumping to the Boolean's destination.
    func grab() {
        target = nil
        dragging = true
        // The completion belongs to the motion the finger just took over; the reader is making a different move now.
        onRest = nil
        stop()
    }

    /// Follow the finger: the card is wherever the touch is, clamped to the panel's own travel.
    func drag(to x: CGFloat) { presented = min(max(x, 0), panelWidth) }

    /// The panel's width changed, so the card's travel did as well. A live drag keeps its offset (it is under the
    /// finger, and moving it would be the very jump this animator exists to prevent); a card at rest is pinned to
    /// the end it was resting at; a spring in flight is re-aimed at the same end at the new width.
    func rebase(open: Bool, width: CGFloat) {
        let hi = max(width, 1)
        let wasDragging = dragging
        // A settled spring KEEPS its last target (that is what `presented` was clamped to), so "at rest" is the
        // display link being stopped, not the target being absent.
        let wasAtRest = !dragging && link == nil
        setWidth(hi)
        if var t = target, !wasAtRest {
            t.resting = open ? hi : 0
            target = t
            clampToTravel()
        } else if wasDragging {
            presented = min(max(presented, 0), hi)
        } else {
            // At rest at one of the two ends, and the end just moved.
            presented = open ? hi : 0
        }
    }

    /// One integration step, exposed for the unit tests so the whole spring can be replayed with no display link.
    func step(dt: CFTimeInterval) {
        guard let t = target else { return }
        var remaining = CGFloat(max(0, min(dt, 0.25)))
        while remaining > 0 {
            let h = min(remaining, Self.maxStep)
            remaining -= h
            // Semi-implicit Euler, in the order that makes it stable: the velocity is advanced from the position at
            // the START of the slice, and the position then moves on the NEW velocity. The other order — the
            // position on the old velocity, which this file used to call semi-implicit — is explicit Euler.
            velocity += (-t.stiffness * (presented - t.resting) - t.damping * velocity) * h
            presented += velocity * h
            clampToTravel()
        }
        if isAtRest { finish(at: t.resting) }
    }

    /// The travel is `0...panelWidth`, whatever the spring would like. A release at 280 pt with a +1500 pt/s flick
    /// reached 314 pt on paper (Codex R13 P2), and a card drawn past the panel's edge is the one place this
    /// animator could be seen doing the wrong thing. Outward velocity is cleared at the boundary so the spring does
    /// not spend frames pressing against it.
    private func clampToTravel() {
        if presented <= 0 {
            presented = 0
            if velocity < 0 { velocity = 0 }
        } else if presented >= panelWidth {
            presented = panelWidth
            if velocity > 0 { velocity = 0 }
        }
    }

    private var isAtRest: Bool {
        guard let t = target else { return true }
        return abs(presented - t.resting) < Self.restDistance && abs(velocity) < Self.restVelocity
    }

    /// The card is at an end: pin it exactly and tell whoever is waiting for the motion that it is over.
    private func finish(at resting: CGFloat) {
        presented = resting
        velocity = 0
        stop()
        let done = onRest
        onRest = nil
        done?()
    }

    /// The view went away. Nothing else releases the display link, so this is not optional: the link retains the
    /// animator and the animator retains the link.
    func shutdown() {
        onRest = nil
        stop()
    }

    private func start() {
        guard link == nil else { return }
        last = 0
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        // .common: a drawer opened from inside a scroll view must not pause while that view is being dragged.
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate()
        link = nil
        last = 0
    }

    @objc private func frame(_ l: CADisplayLink) {
        let dt = last == 0 ? l.targetTimestamp - l.timestamp : l.timestamp - last
        last = l.timestamp
        // A first frame can arrive with no usable delta (a paused link, a debugger stop, a screen wake): one
        // frame's worth at 60 Hz is the safe assumption, and it never compounds.
        step(dt: dt > 0 && dt < 0.25 ? dt : 1.0 / 60)
    }
}

/// The pan recognizer's own arithmetic, in the units a `UIPanGestureRecognizer` reports.
///
/// `translation(in:)` is measured from the point the touch went down, NOT from the drawer's closed end. Treating it
/// as a position is the defect Codex R13 P1 caught: the first changed event of a closing drag that started at the
/// open end reports about −10 pt, and the old code called `drag(to: −10)` — which clamps the card to zero and jumps
/// it by the panel's whole width. The position is therefore the presented offset AT GRAB plus the translation, and
/// the same rebased number decides which end a release goes to.
///
/// The tests drive exactly this type with the stream a recognizer produces (began, changed, ended), so the
/// translation-to-position step is under test rather than bypassed by an absolute position.
struct DrawerPanState {
    /// Where the card was when the finger landed: what this gesture's translations are measured from. Written once
    /// per gesture and once per width change, never per frame.
    private(set) var origin: CGFloat = 0

    /// A touch has won the gesture. `presented` is where the card is drawn at that moment.
    mutating func begin(at presented: CGFloat) { origin = presented }

    /// The card's position for the recognizer's translation, clamped to the panel's travel.
    func position(translation: CGFloat, width: CGFloat) -> CGFloat {
        min(max(origin + translation, 0), max(width, 1))
    }

    /// A width change clamped the card (a rotation, a split view): the finger's mapping moves with it, or the next
    /// changed event would jump the card by the amount the clamp took off.
    mutating func rebase(to presented: CGFloat) { origin = presented }

    /// Where the drawer goes when the finger lifts: a fast flick decides by its own direction, otherwise by the
    /// rebased position — past halfway keeps going, short of it springs back.
    func release(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        if velocity > 300 { return true }
        if velocity < -300 { return false }
        return position(translation: translation, width: width) > width / 2
    }
}
