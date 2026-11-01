import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let id: String
    let child: String
    /// The root's VoiceOver focus, carried by the chat's own menu button: when the drawer closes, that is the
    /// control the reader came from and the one the ring goes back to (Codex R13 P2). Nothing is passed by a test
    /// or a preview that renders the chat on its own.
    var focused: AccessibilityFocusState<RootFocus?>.Binding? = nil
    @State private var chat: ChatModel?

    var body: some View {
        Group {
            if let chat { ChatScreen(chat: chat, focused: focused, folds: app.folds(child.isEmpty ? id : id + "/" + child)) } else { Tok.canvas(scheme) }
        }
        .onAppear {
            let k = child.isEmpty ? id : id + "/" + child
            let kept = app.parked.removeValue(forKey: k)
            if chat == nil { let c = kept ?? ChatModel(id: id, child: child, app: app); chat = c; c.enter() }
            else if app.currentChat !== chat { chat?.enter() }
        }
        .onDisappear { chat?.leave() }
    }
}

enum ChatSheet: Identifiable {
    case menu, model, permissions, commands, todos, goal, jobs, subagents, files(String), file(String), changesList, changes(Int), diff(Int, Int)
    case team, feedback(String, String), edit(String), rename, deliverables, usage, transcript, turns, quote(String)
    var id: String {
        switch self {
        case .quote(let t): return "quote:\(t.hashValue)"
        case .files(let p): return "files:" + p
        case .file(let p): return "file:" + p
        case .changes(let s): return "changes:\(s)"
        case .diff(let s, let i): return "diff:\(s):\(i)"
        case .feedback(let k, let r): return "fb:\(k):\(r)"
        case .edit(let k): return "edit:" + k
        default: return String(describing: self)
        }
    }
}

#if DEBUG
/// Test builds only: append scroll-geometry readings to Documents/geom.log when DSH_GEOM is set. A file, not NSLog:
/// the system log also carries launch environments, which must never hold a sign-in link.
enum GeomLog {
    static let on = ProcessInfo.processInfo.environment["DSH_GEOM"] != nil
    static func add(_ line: String) {
        guard on, let data = (line + "\n").data(using: .utf8) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("geom.log")
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Design-review hook (`-reviewScroll <pt>`): move the chat's transcript up by that many points once it exists, so a
/// screen that only exists mid-scroll can be photographed from a shell that cannot drive a touch. The jump arrow is
/// exactly that screen: it is offered 120 pt above the newest message, so no launch state can show it. Debug only,
/// like the rest of the hook — a Release build carries no such entry.
enum ReviewScroll {
    /// False when the chat's own scroll view is not on screen (yet).
    @discardableResult
    static func by(_ dy: CGFloat) -> Bool {
        guard let scroll = find() else { GeomLog.add("REVIEWSCROLL not found"); return false }
        // Clamped to the content the way a touch would be: a review that asks for more than there is should
        // photograph the top, not an over-scrolled bounce.
        let top = -scroll.adjustedContentInset.top
        let bottom = max(scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom, top)
        let y = min(max(scroll.contentOffset.y + dy, top), bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        GeomLog.add("REVIEWSCROLL y=\(Int(y)) of \(Int(top))...\(Int(bottom)) was=\(Int(scroll.contentOffset.y - dy))")
        Trace.mark("review.scroll", "y=\(Int(y)) of \(Int(top))...\(Int(bottom))")
        return true
    }

    private static func find() -> UIScrollView? {
        func walk(_ v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView, s.accessibilityIdentifier == "chat.scroll" { return s }
            for sub in v.subviews { if let f = walk(sub) { return f } }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { if let f = walk(w) { return f } }
        }
        return nil
    }
}
#endif

/// Raw scroll readings: the distance to the bottom plus the parts it is built from, so a wrong formula is visible
/// in geom.log rather than guessed at.
private struct ScrollGeom: Equatable {
    var offset: CGFloat, size: CGFloat, insetTop: CGFloat, insetBottom: CGFloat, container: CGFloat
    var visMinY: CGFloat, visMaxY: CGFloat
    /// How far the reader is ABOVE the newest message, in points: 0 at the bottom, larger the further up they are.
    ///
    /// Measured to the bottom of the part of the transcript the reader can actually see — the composer's inset is
    /// not visible area. SwiftUI's `containerSize` is the scroll view's own area LESS both content insets (measured
    /// on the Simulator: 600 pt on an 874 pt screen with a 138 pt top inset and a 136 pt dock), so the visible
    /// bottom in content coordinates is `offset + container + insetTop`. The old `size - visMaxY` used SwiftUI's
    /// `visibleRect`, which is the container outset by BOTH insets — the whole scroll view frame — and therefore
    /// counted the dock as visible area: at the bottom it read `−insetBottom` (clamped to 0, which is why it looked
    /// right) and 121 pt up it read `121 − insetBottom`. With the dock at 136 pt the arrow needed 256 pt of travel
    /// instead of 120, and the same number re-armed `stick`: the list was judged "at the bottom" while the reader
    /// was 130 pt above it, so the next lazy row's size change pinned them back down. That is the whole of t12's
    /// `testJumpArrow` — the offer never appeared because the reader was never far enough away to be offered it,
    /// and the recording shows every fling returning to the same place (Codex R15 #4).
    var distance: CGFloat { max(0, size - (offset + container + insetTop)) }
    /// The same figure without the clamp, for the geometry log and for the pull's own threshold.
    var shortBy: CGFloat { size - (offset + container + insetTop) }
}

/// What the scroll view reports. Kept out of the chat screen's own state so a scroll frame redraws the arrow rather
/// than the whole list: writing `@State` from the geometry callback re-ran the body, and the display list with it,
/// on every frame.
///
/// Only the arrow's own two facts are published, and only when they change. The raw reading is `@ObservationIgnored`
/// on purpose: the freeze t9 caught was a callback that wrote something a view read, which re-ran that view's body,
/// which moved the scroll view's geometry by a hair (the callback fires for an inset or visible-rect change as much
/// as for an offset), which fired the callback again — `geom=1104` every two seconds for four minutes, with no chat
/// body pass and not one frame committed. A reading that changes nothing the arrow draws now writes nothing, so the
/// cycle has nothing to feed it.
@MainActor @Observable final class ScrollReadout {
    /// Whether the arrow is offered at all, and whether what is below is NEW rather than merely further down. These
    /// are what `JumpArrow` reads; each is written only on a real change.
    private(set) var arrow = false
    private(set) var newBelow = false

    /// The last raw reading, for the decisions that are not the arrow's (the stick zone, the pull's threshold). Not
    /// observed: no view re-renders for it, which is the whole point.
    @ObservationIgnored private(set) var distance: CGFloat = 0
    /// What the arrow was last told, so a write that changes nothing is not a write.
    @ObservationIgnored private var shownArrow = false

    /// One geometry reading: remember it, and publish the arrow's state only if this reading changed it.
    func read(distance d: CGFloat, zone: CGFloat) {
        distance = d
        publish(newBelow || d > zone)
    }

    /// The "something arrived below" flag, from the content-size handler and the phase handler. Idempotent.
    func setNewBelow(_ v: Bool, zone: CGFloat) {
        if v != newBelow { newBelow = v }
        publish(newBelow || distance > zone)
    }

    private func publish(_ v: Bool) {
        guard v != shownArrow else { return }
        shownArrow = v
        arrow = v
        Trace.body("readout")
    }
}

/// How far past the top the reader has to pull for the previous page. The head of the list carries the affordance,
/// so the pull never covers the button it stands in for.
private let pullThreshold: CGFloat = 60

/// The head of the list: the button that asks for the previous page, which becomes the pull's own affordance while a
/// pull is armed and while a page is on its way. It is part of the content, so it moves with the pull — the capsule
/// that used to float over the list covered this very row, and the operator saw it.
private struct LoadEarlierRow: View {
    let chat: ChatModel
    let armed: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if chat.loadingMore {
                Label("Loading earlier messages", systemImage: "arrow.down")
            } else if armed {
                Label("Release to load earlier", systemImage: "arrow.down")
            } else {
                Button { Task { await chat.loadEarlier() } } label: {
                    Text("Load earlier messages").font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
        .font(Tok.meta)
        .foregroundStyle(Tok.secondaryText(scheme))
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tok.sp1)
        .animation(.snappy(duration: 0.2), value: armed)
        .animation(.snappy(duration: 0.2), value: chat.loadingMore)
    }
}

/// The round down-arrow: the one control for "there is more below". It is offered once the reader is past `zone`
/// from the newest message, or once one has arrived below them while they were reading — and never at the bottom,
/// which is the defect the C10 round fixed and this view has to keep fixed. Tapping it returns to the bottom and
/// takes the offer away.
///
/// Its own view on purpose (#517): it reads the scroll readout, so a scroll frame redraws this button rather than
/// the whole transcript. The readout publishes the OFFER, not the raw distance, so a reading that does not change
/// the offer redraws nothing at all (see `ScrollReadout`).
/// Internal, not private: `JumpArrowTests` renders it from a readout to hold the "drawn only while the offer is on"
/// half of the arrow, which is the half a UI test can only see through the accessibility tree.
struct JumpArrow: View {
    let readout: ScrollReadout
    let jump: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if readout.arrow {
            Button(action: jump) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    // The accent is what says "there is something new down there" rather than "you are scrolled up".
                    .foregroundStyle(readout.newBelow ? Tok.actionTint(scheme) : (scheme == .dark ? Tok.paper : Tok.ink))
                    .frame(width: 44, height: 44)
                    .floatingCircle()
                    // The finger's target is wider than the circle it sees: the operator found the 44 pt circle
                    // harder to hit than the reference's (2026-10-13).
                    .padding(10)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.jump")
            .accessibilityLabel("Jump to the newest message")
        }
    }
}

/// Design-review hook: `-reviewScroll <pt>` leaves the transcript that far above the newest message, so a screen
/// that only exists mid-scroll — the jump arrow is offered 120 pt above the newest message — can be photographed
/// from a shell that cannot drive a touch.
///
/// It is a modifier rather than an `.onAppear` appended to `ChatScreen`'s chain: a postfix `#if DEBUG` at the END of
/// a modifier chain compiles but is not attached to it (measured: the hook never ran while the chain grew around
/// it). Two things make the move more than one `setContentOffset`: `stick` has to be dropped — a programmatic offset
/// reports no scroll phase, so the bottom anchor would pull the list back on the next content change — and the move
/// is repeated for a moment, because scrolling up materialises lazy rows, each one a content-size change the anchor
/// answers while `stick` is being cleared. In a release build this is an empty modifier.
private struct ReviewScrollHook: ViewModifier {
    @Binding var stick: Bool

    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear {
            // Read as a STRING and converted: the argument domain hands `-reviewScroll 400` over as text.
            guard let text = UserDefaults.standard.string(forKey: "reviewScroll"), let dy = Double(text), dy != 0 else { return }
            Task { @MainActor in
                // The rows are laid out a beat after the screen appears; the offset has to find real content.
                try? await Task.sleep(for: .milliseconds(900))
                for _ in 0..<15 {
                    stick = false
                    _ = ReviewScroll.by(dy)
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if !ReviewScroll.by(0) { print("review hook: no chat scroll view to move") }
            }
        }
        #else
        content
        #endif
    }
}

/// Which folds are open, kept apart from the chat so opening one fold redraws only the rows that read it.
@MainActor @Observable final class FoldState {
    var open: Set<String> = []
    func toggle(_ k: String) { if open.contains(k) { open.remove(k) } else { open.insert(k) } }
}

/// The rows a process-group header folds, as a walk over the group's own run.
///
/// `ChatModel.display` builds a group as its header followed by its members, in order, so the members are the run
/// that follows the header — and the loop that draws the rows already knows the header's index. The version this
/// replaces filtered the whole conversation once per group (`d.filter { $0.groupId == it.groupId && $0.kind !=
/// .group }`), which on a chat of thousands of rows is O(rows) per header on every body pass. On a 4,400-row list
/// of 200 groups, one pass costs 184.8 ms that way and 0.71 ms this way — 259x (step 4 of
/// .tmp/list-speed-proposal.md, measured in GroupMembersTests).
enum GroupMembers {
    static func of(_ it: ChatItem, at i: Int, in d: [ChatItem]) -> [ChatItem] {
        guard it.kind == .group else { return [] }
        var out: [ChatItem] = []
        var j = i + 1
        while j < d.count, d[j].kind != .group, d[j].groupId == it.groupId {
            out.append(d[j])
            j += 1
        }
        return out
    }
}

/// A pull's hold: where the reader was when they asked for the previous page, and the signature of the page that/// answers it. The scroll cannot be issued in the turn the fetch returns — the list still has the old rows there, so
/// it finds the row exactly where it already is and does nothing, and the page lands under the reader's eyes (t8:
/// the head row stayed at 80 while the content below it moved from Round 82 to Round 76). So the hold is armed
/// BEFORE the fetch and spent in the list's own update, where the page's rows exist.
///
/// The frontier is the page's own signature: a page lowers `firstSeq`, a live message does not, so a message
/// arriving during the fetch cannot fire a hold. The count is the second half of that signature, and the reason a
/// page with no visible rows retires the hold instead of leaving it armed for a later live row (Codex R9 P2).
struct PullHold: Equatable {
    /// The DURABLE key of the reader's first row: an item's own key, or — when that row is a folded process group's
    /// header — the first member's key. A group header's key is synthetic (`gh` + the key of the item before it,
    /// `ChatModel.reduce`), and the merge rebuilds it when the page supplies that item, so a hold that named the
    /// header would scroll to a row that no longer exists — or to a different group that happens to reuse the key
    /// (Codex R9 P2).
    let row: String
    /// The frontier the pull was asked from.
    let frontier: Int
    /// The row count when the hold was armed. A metadata-only page lowers the frontier WITHOUT changing this.
    let count: Int

    static func armed(_ display: [ChatItem], frontier: Int) -> PullHold? {
        guard let first = display.first else { return nil }
        let row = first.kind == .group ? (first.groupMembers.first ?? first.key) : first.key
        return PullHold(row: row, frontier: frontier, count: display.count)
    }

    /// The row to put back at the top, when THIS update is the page's own: the frontier came down AND the count
    /// moved, so the page's rows are in the list. A live row arriving during the fetch changes the count without
    /// lowering the frontier, and must leave the hold armed for the page that is still on its way (Codex R9 P2).
    func rowToRestore(display: [ChatItem], frontier: Int, folds: Set<String>) -> String? {
        guard frontier < self.frontier, display.count != self.count else { return nil }
        return Self.rendered(row, in: display, folds: folds)
    }

    /// A page landed with no visible rows — the frontier came down and the count did not move. There is nothing to
    /// restore, and a hold left armed here would be spent by the next live row, scrolling the reader to a place
    /// they left long ago (Codex R9 P2).
    func isSpentByMetadata(frontier: Int, count: Int) -> Bool {
        frontier < self.frontier && count == self.count
    }

    /// The row a durable key renders as NOW: its own row, or the header of the process group it has been folded
    /// into. A member of a closed fold has no row of its own in the list — `rows()` draws the header instead — so
    /// the header's CURRENT key is what a scroll can find.
    static func rendered(_ key: String, in display: [ChatItem], folds: Set<String>) -> String {
        guard let it = display.first(where: { $0.key == key }) else { return key }
        if it.groupId.isEmpty || it.kind == .group || folds.contains("gh:" + it.groupId) { return it.key }
        return display.first { $0.kind == .group && $0.groupId == it.groupId }?.key ?? it.key
    }
}

struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var chat: ChatModel
    /// The root's VoiceOver focus: the bar's menu button is where the ring goes back to when the drawer closes.
    var focused: AccessibilityFocusState<RootFocus?>.Binding? = nil
    @State private var folds = FoldState()
    @State private var stick = true
    @State private var interacting = false
    @State private var readout: ScrollReadout
    @State private var sheet: ChatSheet?
    @State private var now = Date()
    @State private var jumpTo: Int?
    /// True from the moment a pull is armed until the reader lets go of it.
    @State private var armed = false
    /// True while the jump-to-newest animation owns the scroll, so the lazy list's follow-up does not fight it.
    @State private var jumping = false

    /// The reader's scroll reading is made here. A unit test may hand in its own, so the arrow's crossing can be
    /// asserted against the scroll view's OWN geometry — the offer is a threshold on a distance, and a test that
    /// cannot see the distance can only ask that something was published (Codex R15 #4) — while the app never
    /// passes one.
    init(chat: ChatModel, focused: AccessibilityFocusState<RootFocus?>.Binding? = nil, folds: FoldState? = nil, readout: ScrollReadout? = nil) {
        self._chat = Bindable(chat)
        self.focused = focused
        self._folds = State(initialValue: folds ?? FoldState())
        self._readout = State(initialValue: readout ?? ScrollReadout())
    }
    /// A pull's hold, armed before the fetch and spent in the list's own update — see `PullHold` for what the two
    /// signatures mean and why the anchor is a durable item key rather than the row's own.
    @State private var hold: PullHold?

    /// The bar's own ink: the warm near-black on the light canvas, paper on the charcoal one.
    private var barInk: Color { scheme == .dark ? Tok.paper : Tok.ink }

    /// The end of the list: what the arrow and the send button scroll to.
    private static let bottomId = "chat.bottom"
    /// Within this much of the bottom, new messages keep the reader pinned there.
    private static let stickZone: CGFloat = 60
    /// Past this, the reader is far enough away to be offered the jump arrow.
    private static let arrowZone: CGFloat = 120

    var body: some View {
        Trace.body("chat")
        let display = chat.display
        return transcript(display)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Always here, open or closed: the bar's items never change with the drawer, which is what the frame
            // gate measures.
            ToolbarItem(placement: .topBarLeading) { DrawerMenuButton(focused: focused) }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    // Ink, not the inherited `.primary`: on iOS 26 the bar draws its own labels with a vibrancy
                    // that came out white on the warm paper — the title was invisible against its own background.
                    // The token pair is the one the drawer already uses, so the bar follows the appearance.
                    Text(chat.title).font(.headline).foregroundStyle(barInk).lineLimit(1)
                    if !chat.subtitle.isEmpty {
                        Text(chat.subtitle).font(.caption2).foregroundStyle(Tok.secondaryText(scheme)).lineLimit(1)
                    }
                }
                .accessibilityIdentifier("chat.title")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { sheet = .menu } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("chat.menu")
                    .accessibilityLabel("Chat options")
            }
        }
        // D2: the clock area is the app's own canvas, not whatever is behind it. A static fill — the bar's size never
        // changes here, which is the rule this screen has to keep.
        // D6: one success haptic for the two decisions that leave the phone — an answer and an approval.
        .sensoryFeedback(.success, trigger: app.answeredTick)
        .toolbarBackground(Tok.canvas(scheme), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $sheet) { s in ChatSheetView(sheet: s, chat: chat, present: $sheet).sheetCanvas() }
        // A file path in a reply opens the file from the Mac here; web links go to the browser as before.
        .environment(\.openURL, OpenURLAction { url in
            guard let p = Markdown.filePath(url) else { return .systemAction }
            if app.can("files") { sheet = .file(p) } else { app.say("This Mac does not share files") }
            return .handled
        })
        .onReceive(NotificationCenter.default.publisher(for: .jumpToTurn)) { n in
            if let seq = n.object as? Int { jumpTo = seq }
        }
        // A notification for this same chat keeps this screen, and with it any sheet the reader left open over the
        // waiting conversation (Codex r158).
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { n in
            if (n.object as? String) == chat.sid { sheet = nil }
        }
        .sheet(isPresented: Binding(get: { app.showVoiceSetup }, set: { app.showVoiceSetup = $0 })) {
            NavigationStack { VoiceSetupView() }.presentationDetents([.medium])
        }
        .task(id: chat.id) {
            if let t = PendingOpen.shared.take(chat.sid) { chat.send(text: t, attachments: []) }
        }
        .modifier(ReviewScrollHook(stick: $stick))
    }

    /// The conversation itself: the scroll view, the rows in it, and every gesture, inset and status that moves them.
    /// Split out of `body` — this chain and the rows in it were one expression, which is more than the type checker
    /// will take in its stride ("unable to type-check this expression in reasonable time").
    private func transcript(_ display: [ChatItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                rows(display)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Named, so a test can fling THIS scroll view: the drawer's chips are a ScrollView of their own, and
            // `scrollViews.firstMatch` picked the panel's (off screen, 32 pt tall) instead.
            .accessibilityIdentifier("chat.scroll")
            // Keep the newest message in view while a reply streams, for a reader who is already at the bottom. The
            // anchor does that scrolling; a scroll request made from inside a layout pass was ignored.
            .defaultScrollAnchor(stick && !interacting ? .bottom : nil, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: ScrollGeom.self) { g in
                ScrollGeom(offset: g.contentOffset.y, size: g.contentSize.height, insetTop: g.contentInsets.top,
                           insetBottom: g.contentInsets.bottom, container: g.containerSize.height,
                           visMinY: g.visibleRect.minY, visMaxY: g.visibleRect.maxY)
            } action: { _, m in
                Trace.body("geom")
                // One reading: the arrow's offer is published only if this reading changed it. Every other write on
                // this path is conditional on the same rule, because a write that changes nothing still re-runs the
                // body it is read by — and a body pass inside the scroll's own layout is the loop t9 froze in.
                readout.read(distance: m.distance, zone: Self.arrowZone)
                // The pull: armed past the threshold, and asked for when the reader lets go so the list is not
                // rebuilt under their finger. Only the two crossings are written — an overscroll figure written per
                // frame re-evaluated a row on every frame of the drag, which is part of what felt rough.
                let over = max(0, -(m.offset + m.insetTop))
                if over > pullThreshold {
                    if !armed { armed = true }
                } else if armed, over < pullThreshold / 3 {
                    armed = false
                    if chat.hasMore, !chat.loadingMore {
                        // Hold the reader's place: the page lands above them instead of shifting the conversation
                        // under their eyes at the moment the finger lifts. The hold is armed BEFORE the fetch and
                        // consumed by the list's own update, when the page's rows exist (see `hold`).
                        hold = PullHold.armed(chat.display, frontier: chat.firstSeq)
                        Trace.count("pull.ask")
                        Task {
                            await chat.loadEarlier()
                            // Nothing landed below the frontier — no page came back, or the pull failed: disarm, so
                            // no later row can fire a hold nobody is waiting for.
                            if hold?.frontier == chat.firstSeq { hold = nil }
                        }
                    }
                }
                #if DEBUG
                GeomLog.add("GEOM d=\(Int(m.distance)) short=\(Int(m.shortBy)) off=\(Int(m.offset)) size=\(Int(m.size)) vMin=\(Int(m.visMinY)) vMax=\(Int(m.visMaxY)) iT=\(Int(m.insetTop)) iB=\(Int(m.insetBottom)) cont=\(Int(m.container)) stick=\(stick) inter=\(interacting)")
                #endif
                // The reader leaving the bottom is a GEOMETRY fact, not a phase: `.interacting` can arrive while the
                // list is still at the bottom — the finger has not moved yet — so clearing `stick` only on that
                // phase left it true through a whole flick. When the scroll then settled, line 223 re-enabled the
                // bottom anchor for size changes, and the lazy rows' own measurements pulled the reader back down
                // (Codex R8 P2). The distance decides here too, which is the same rule the phase handler uses.
                if interacting && m.distance > Self.stickZone {
                    if stick { stick = false }
                } else if !interacting && m.distance < Self.stickZone {
                    if !stick { stick = true }
                    readout.setNewBelow(false, zone: Self.arrowZone)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { g in g.contentSize.height } action: { old, new in
                #if DEBUG
                GeomLog.add("GEOM content \(Int(old)) -> \(Int(new)) stick=\(stick) inter=\(interacting)")
                #endif
                guard new != old else { return }
                // A pull's hold is spent HERE, on the content growing, and NOT on the count change that announced
                // the page. The count changes before the lazy list has laid the inserted rows out, so a scroll
                // issued there resolves against the pre-insert geometry — where the row the reader was on is
                // exactly where it already is — and nothing moves; the page then pushes the reader's place down by
                // its own height (Codex R15 P2). t12's own recording of the failed test shows it: after each page
                // the visible rows are the page's rows at the same screen positions, and no frame of the merge
                // moves the scroll view at all. No animation either way: the page appears and the place is
                // restored in the same, uninterpolated transaction, so there is no correction to watch.
                //
                // The hold is spent only when THIS change is the page's own. A live row arriving during the fetch
                // changes the count too, and consuming the hold for it lost the restoration the page still needed
                // (Codex R9 P2); `rowToRestore` asks for the frontier as well, which only a page lowers.
                //
                // The rows are read from the MODEL, not from the `display` this body was built with. Both of the two
                // handlers that run when the page lands run against the row list from the body pass BEFORE the merge:
                // measured on the hosted pull (PullToLoadTests, `pull.ask/spent/missed/retired`) the page's own
                // content-size change fires with the pre-merge list, so `display.count` still equals the hold's and
                // `rowToRestore` answered nil, and the frontier handler then RETIRED the hold as a metadata-only page
                // (spent=0 missed=3 retired=1). `chat.display` is the same cached row list the next body pass will
                // draw; asking for it here is what makes the page's own update recognisable.
                if let h = hold, let row = h.rowToRestore(display: chat.display, frontier: chat.firstSeq, folds: folds.open) {
                    hold = nil
                    Trace.count("pull.spent")
                    // Issued on the next main-actor turn rather than inside this update, which is the one thing the
                    // app's own working "scroll after a page" does: the Turns jump awaits its pages and then scrolls
                    // (one turn later than the merge), while a scroll asked for inside the update the page lands in
                    // has nothing to resolve against — the hosted pull measures the request being ISSUED and the
                    // offset never moving (PullToLoadTests). A turn is drained before the frame that carries the page
                    // is committed, so the reader still sees one uninterpolated update, not a slide.
                    Task { @MainActor in
                        var t = Transaction()
                        t.animation = nil
                        withTransaction(t) { proxy.scrollTo(row, anchor: .top) }
                    }
                    return
                }
                if hold != nil { Trace.count("pull.missed") }
                if !(stick && !interacting), new > old + 4, !chat.stale { readout.setNewBelow(true, zone: Self.arrowZone) }
            }
            // A lazy list materialises its rows as they scroll in, so the anchor above lands near the bottom and this
            // finishes the job once the last row exists. Only on a new row: the anchor already follows streaming text,
            // and scrolling on every token would lay the list out twenty times a second for nothing.
            //
            // A pull's hold is NOT spent here (see the content-size handler above): at this moment the page's rows
            // are in the model but not yet in the list, so a scroll from here cannot find them.
            .onChange(of: display.count) { _, _ in
                guard stick, !interacting, !jumping else { return }
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
            // A page that brought no visible rows (metadata only: `turn/start`, `turn/end`, a tool result) lowers
            // the frontier without changing the count, so the handler above never sees it. The hold cannot be spent
            // — there is no row to put back — and leaving it armed let the next live row scroll the reader to a
            // place they had left (Codex R9 P2). Both orders of the two handlers are safe: a page that DID bring
            // rows has already moved the count, so this one leaves that hold alone.
            //
            // The count is the MODEL's, for the reason above: this handler runs on the frontier change, which the
            // merge makes in the same mutation as the rows, and the row list this body was built with is still the
            // pre-merge one at that moment. Read from `display` it answered "the count did not move" for a page that
            // had just doubled the list, and retired the very hold the page was supposed to spend (t13's pull: the
            // page landed, the head row stayed at 152.0, nothing moved).
            .onChange(of: chat.firstSeq) { _, _ in
                if let h = hold, h.isSpentByMetadata(frontier: chat.firstSeq, count: chat.display.count) {
                    hold = nil
                    Trace.count("pull.retired")
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    if !interacting { interacting = true }
                    // Only a reader who has really moved away stops following. A phase can report itself while the
                    // list is still at the bottom — the arrow then appeared over a chat nobody had scrolled — so the
                    // distance decides, not the phase.
                    if readout.distance > Self.stickZone, stick { stick = false }
                case .tracking: if !interacting { interacting = true }
                case .decelerating: if !interacting { interacting = true }
                case .idle, .animating:
                    if interacting { interacting = false }
                    if readout.distance < Self.stickZone {
                        if !stick { stick = true }
                        readout.setNewBelow(false, zone: Self.arrowZone)
                    }
                @unknown default: if interacting { interacting = false }
                }
            }
            // A plain safe-area inset, not the iOS 26 bar: with `safeAreaBar` the keyboard covered the message field
            // (reproduced by testComposerAboveKeyboard), so the native-bar look loses to a composer you can reach.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomDock(chat: chat, sheet: $sheet, onSend: {
                    stick = true
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                })
                // The first messages arriving pin the reader to the bottom. Without this a chat that opens with its
                // run already going — every new chat — started at the top and stayed there: measured 949 to 965 pt
                // above the newest line after one run, which left the jump arrow showing while the reader believed
                // they were at the bottom. A `.sizeChanges` anchor cannot cover it, because the view opens on empty
                // content.
                .onChange(of: chat.display.isEmpty) { _, isEmpty in
                    guard !isEmpty, stick else { return }
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
                // The arrow floats just above the dock, centred, where the reference puts it. Its `top` guide is its
                // own bottom, so it clears the dock whatever height the composer has grown to, and the overlay's
                // closure reads no scroll state — the button's own body does that.
                .overlay(alignment: .top) {
                    JumpArrow(readout: readout) {
                        stick = true
                        readout.setNewBelow(false, zone: Self.arrowZone)
                        // No animation: an animated scroll across a lazy list walks estimated row heights, and the
                        // operator's phone showed the top of the chat for two seconds before it landed (2026-10-13).
                        // One instant jump, then a second once the rows near the bottom exist and have real heights.
                        var t = Transaction()
                        t.animation = nil
                        withTransaction(t) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                        Task { @MainActor in withTransaction(t) { proxy.scrollTo(Self.bottomId, anchor: .bottom) } }
                    }
                    // The 10 pt of hit padding already stands it off the dock.
                    .alignmentGuide(.top) { $0[.bottom] }
                }
            }
            // Build 8's item, held back then and reverted in 81fabc7: as a top safe-area inset this resized the
            // safe area whenever the run bar, a question, the queued cards or the connection banner came and went,
            // and that is the shape the freeze reports were caught in. As an overlay it cannot.
            .overlay(alignment: .top) { ChatTopStatus(chat: chat, sheet: $sheet) }
            // The policy caption is the one top line that is NOT part of that stack, because it needs space of its
            // own: as the first line of the overlay above, the transcript ran behind it (Codex R11 P2). A top inset
            // reserves the band, and it is safe to inset for exactly the reason the overlay exists — this band's
            // height follows the reader's text size and the chat's policy, never a run or a status update.
            .safeAreaInset(edge: .top, spacing: 0) { ChatPolicyBand(chat: chat) }
            .minimizingBar()
            // The canvas the reference sets the whole conversation on — the reader's own picture when they have
            // chosen one, the token canvas otherwise, in both cases with the reading content opaque above it.
            .background(Tok.canvas(scheme).ignoresSafeArea())
            // A turn the reader picked from the Turns list: fetch the one page that contains it, then go to it.
            .task(id: jumpTo) {
                guard let seq = jumpTo else { return }
                // The Turns list hands over `turnOutline.seq`, which is the TURN/START event's sequence — what
                // `chat.starts` is keyed by. A user message carries a sequence of its own, so the old lookup for
                // "u\(seq)" never matched the turn that was picked: it paged to the beginning and then reported the
                // turn gone. `loadThrough` asks the host for the page containing that turn in ONE request: the old
                // loop here paged up to twenty times, and each page was its own insert, so a jump in a long chat was
                // twenty list rebuilds and then a scroll across everything they had added.
                let began = Date()
                let outcome = await chat.loadThrough(seq)
                Trace.mark("jump.loaded", "seq=\(seq) outcome=\(outcome.rawValue) in \(Int(Date().timeIntervalSince(began) * 1000))ms")
                // A newer jump replaces this task — the task is keyed by `jumpTo` — so an old jump coming back late
                // must not clear the newer selection or scroll the list away from it.
                guard !Task.isCancelled else { return }
                let turn = chat.starts.first { $0.value == seq }?.key
                // The first item of a turn is often a tool or reasoning row, and those live inside a folded process
                // group: `display` carries the member while `rows()` renders only the group's header, so scrolling to
                // the member's key would silently do nothing. A group's header is keyed "gh" + its groupId
                // (ChatModel.reduce), and for the header itself that mapping is its own key.
                let key = turn.flatMap { t in chat.display.first { $0.turn == t } }
                    .map { $0.groupId.isEmpty ? $0.key : "gh" + $0.groupId }
                // Four outcomes, four different things to say — and the saying is the outcome's own (`message`), so
                // "the turn is gone" cannot drift onto a case that does not mean it (Codex R6 P2).
                switch outcome {
                case .found:
                    if let key {
                        stick = false
                        withAnimation(.snappy) { proxy.scrollTo(key, anchor: .center) }
                    } else {
                        // Loaded, but the turn has no row of its own to scroll to — its events are all metadata.
                        app.say("That turn has nothing to show.")
                    }
                case .exhausted, .interrupted, .failed:
                    if let m = outcome.message { app.say(m) }
                }
                jumpTo = nil
            }
        }
    }

    /// The rows: the paging head, then one row per item, with the group's own quiet timestamp above it.
    private func rows(_ display: [ChatItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            head(display.isEmpty)
            // The folded-away rows are dropped before the ForEach, so every element is exactly one row: a row that
            // could be empty makes the lazy stack build each one just to count them, which on a long chat is the
            // whole conversation at open.
            ForEach(shown(display), id: \.1.id) { i, it in
                let g = Self.group(at: i, in: display)
                VStack(alignment: .leading, spacing: 0) {
                    // One quiet timestamp per group, centred, instead of a caption under every bubble.
                    if g.startsGroup, it.time > 0 {
                        Text(Fmt.hhmm(it.time)).font(.caption2)
                            .foregroundStyle(Tok.secondaryText(scheme))
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, Tok.sp1)
                    }
                    ItemView(item: it, chat: chat, folds: folds, sheet: $sheet, groupMembers: members(of: it, at: i, in: display), group: g)
                }
                .padding(.top, g.startsGroup ? Tok.gapBetweenGroups : Tok.gapInGroup)
                .id(it.key)
            }
            // The quiet "still working" sign under the last row, as Claude for iOS shows it (operator, 2026-10-13).
            if chat.running { ThinkingDots().padding(.top, Tok.gapInGroup) }
            Color.clear.frame(height: 1).id(Self.bottomId)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: Tok.readingColumn)
        .frame(maxWidth: .infinity)
    }

    /// The rows on screen with their places in `display`: a folded group's members are left out, its header stays.
    private func shown(_ display: [ChatItem]) -> [(Int, ChatItem)] {
        display.enumerated().filter { _, it in it.groupId.isEmpty || it.kind == .group || folds.open.contains("gh:" + it.groupId) }
            .map { ($0.offset, $0.element) }
    }

    /// Which side a message is on: the reader's own, the assistant's, or neither (a chip, a note, an error row).
    private static func side(_ it: ChatItem) -> Int {
        switch it.kind {
        case .user, .pending: return 0
        case .assistant, .live: return 1
        default: return 2
        }
    }

    /// The rows a process-group header folds: the group's own items, the header aside. A function rather than a
    /// ternary in the row's argument list, where the type checker could not settle it.
    ///
    /// The members are the run that FOLLOWS the header — `ChatModel.display` builds a group as its header and then
    /// its members, in order — so this walks the group's own rows from the index the loop already has. The old
    /// version filtered the whole conversation once per group: on a chat of thousands of rows that is O(rows) per
    /// header on every body pass, which is the per-row cost step 4 of .tmp/list-speed-proposal.md is about.
    private func members(of it: ChatItem, at i: Int, in d: [ChatItem]) -> [ChatItem] {
        GroupMembers.of(it, at: i, in: d)
    }

    /// Where a message sits in its run of same-side messages. The bubble corners, the gaps and the quiet timestamp
    /// between groups are all read from this.
    private static func group(at i: Int, in d: [ChatItem]) -> MessageGroup {
        let s = side(d[i])
        guard s != 2 else { return .single }
        let prev = i > 0 && side(d[i - 1]) == s
        let next = i + 1 < d.count && side(d[i + 1]) == s
        switch (prev, next) {
        case (false, false): return .single
        case (false, true): return .first
        case (true, false): return .last
        case (true, true): return .middle
        }
    }

    @ViewBuilder private func head(_ empty: Bool) -> some View {
        if chat.loading {
            // A loading state says what it is doing and how far it has got, instead of a bare spinner: the counts
            // are the ones the chat already tracks, so nothing extra is asked of the Mac.
            VStack(spacing: Tok.sp2) {
                ProgressView().tint(Tok.actionTint(scheme)).controlSize(.large)
                Text("Opening the conversation").font(Tok.heading)
                Text(chat.items.isEmpty ? "Asking the Mac for the newest messages…" : "\(chat.items.count) messages loaded so far")
                    .font(Tok.meta).foregroundStyle(Tok.secondaryText(scheme))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if !chat.error.isEmpty {
            // Shown over loaded messages too: a failed follow stops live updates, and the reader needs a way back in.
            ContentUnavailableView {
                Label(chat.error, systemImage: "exclamationmark.bubble")
            } actions: {
                Button("Try again") { chat.error = ""; chat.enter() }.buttonStyle(.bordered)
            }
        } else if chat.hasMore {
            LoadEarlierRow(chat: chat, armed: armed)
        } else if empty {
            // The full-colour cub, not a symbol: the empty conversation is the one place the app shows its own face.
            ContentUnavailableView {
                Label { Text("No messages yet") } icon: {
                    Image("Mascot").resizable().scaledToFit().frame(width: 56, height: 56).accessibilityHidden(true)
                }
            } description: { Text("Say hello below.") }
        }
    }
}

