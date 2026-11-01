import SwiftUI
import UserNotifications
import VisionKit
#if DEBUG
import ActivityKit
#endif

/// Receives the phone's push address from iOS and hands it to the Mac, which sends the "a chat needs you" alerts
/// through Apple while the app is closed. Tapping one of those alerts opens the chat it names.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// A tapped alert's chat, kept until the root view is up to open it: on a cold launch iOS hands the tap over
    /// before any view is listening for `.openChat`.
    @MainActor static var pending: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if Notifier.enabled { application.registerForRemoteNotifications() }
        return true
    }

    /// Open in front of the reader: the app already shows the waiting chat's state, so no banner on top of it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([]) }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionId"] as? String, !id.isEmpty {
            Task { @MainActor in
                Self.pending = id
                NotificationCenter.default.post(name: .openChat, object: id)
            }
        }
        done()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Notifier.register(deviceToken)
    }
}

@main
struct TigerDSHApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            #if DEBUG || targetEnvironment(simulator)
            if let p = previewPhase {
                RunActivityPreview(phase: p)
            } else {
            RootView()
                .environment(app)
                .onAppear {
                    if UserDefaults.standard.bool(forKey: "perf.overlay") || ProcessInfo.processInfo.environment["DSH_PERF"] != nil { FrameMonitor.shared.start() }
                    Trace.startWatchdog()
                    #if DEBUG || targetEnvironment(simulator)
                    // Test builds only: sign in from Documents/dsh-link.txt (placed by the test script, deleted on read),
                    // so the Simulator can be driven unattended — in Release as well, which is what makes a Release
                    // build testable here. `targetEnvironment(simulator)` is the guard that matters: this can never
                    // be compiled into a build that runs on a phone. A file, not an environment variable: launch
                    // environments are written to the system log.
                    let linkFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dsh-link.txt")
                    // …and, when there is no such file, from a `review-link.txt` a design-review build can carry in
                    // its own bundle. Same sign-in path, same "a file, not an environment variable" rule; a normal
                    // build has no such resource and reads nothing. DEBUG only, like the rest of the review
                    // machinery: a Release simulator build is a test build, not a review build.
                    #if DEBUG
                    let bundleLink = Bundle.main.url(forResource: "review-link", withExtension: "txt")
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    #else
                    let bundleLink: String? = nil
                    #endif
                    if let link = (try? String(contentsOf: linkFile, encoding: .utf8)) ?? bundleLink {
                        try? FileManager.default.removeItem(at: linkFile)
                        Task { try? await DSHClient.shared.signIn(link: link); if DSHClient.shared.isSignedIn { app.signedIn() } }
                        return
                    }
                    #endif
                    app.start()
                }
                .onAppear {
                    AppModel.live = app
                    #if DEBUG
                    // Design-review hook: `-liveActivityDemo running|awaiting|completed` puts a canned run in the
                    // Dynamic Island so the three looks can be seen and photographed without staging a real approval.
                    // Debug builds only, and it touches nothing else.
                    if let demo = UserDefaults.standard.string(forKey: "liveActivityDemo") {
                        let phase: RunPhase = demo == "awaiting" ? .needsApproval : demo == "completed" ? .done : .running
                        Task {
                            // One at a time: a leftover from the previous launch would sit beside this one.
                            for a in Activity<RunActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
                            RunActivity.start(sessionID: "demo", state: RunActivityAttributes.ContentState(
                                phase: phase,
                                title: "Rewrite the retry ladder in the ingest worker",
                                step: phase == .needsApproval ? "Waiting for approval" : phase == .done ? "Finished in 12m" : "Running bash",
                                detail: phase == .needsApproval ? "rm -rf build && xcodebuild -scheme TigerDSH" : nil,
                                approvalId: phase == .needsApproval ? "demo-approval" : nil,
                                startedAt: Date().addingTimeInterval(phase == .running ? -193 : -742),
                                updatedAt: Date()))
                        }
                    }
                    #endif
                }
                .onChange(of: phase) { _, p in app.scenePhase(active: p == .active) }
            }
            #else
            RootView()
                .environment(app)
                .onAppear {
                    if UserDefaults.standard.bool(forKey: "perf.overlay") || ProcessInfo.processInfo.environment["DSH_PERF"] != nil { FrameMonitor.shared.start() }
                    app.start()
                }
                .onAppear { AppModel.live = app }
                .onChange(of: phase) { _, p in app.scenePhase(active: p == .active) }
            #endif
        }
    }

    /// Debug builds only: `-liveActivityPreview running|awaiting|approval|completed` opens straight into the activity
    /// render, so each state can be photographed without staging a real run. The shipped UI never reaches it.
    /// `awaiting` is the question card the operator's phone kept asking about (R21); approval has its own name.
    private var previewPhase: RunPhase? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "liveActivityPreview") {
        case "awaiting": return .needsYou
        case "approval": return .needsApproval
        case "completed": return .done
        case "running": return .running
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// Where a push inside a sheet goes. The main window pushes nothing: Settings, Plugins, Scheduled tasks and the
/// board open from the drawer as sheets, each with its own stack.
enum Route: Hashable {
    case plugins
    case plugin(String)
    case settings
    case models
    case scheduler
    case board
}

extension Notification.Name {
    /// The chat bar's own button: opens the drawer, or closes it when it is already open.
    static let toggleDrawer = Notification.Name("toggleDrawer")
    /// A screen that is done with itself asks for the chat list. Archiving the open chat lands here, which is where
    /// the pop back to the list used to land.
    static let openDrawer = Notification.Name("openDrawer")
    /// Debug test builds only: arm the next open to be reversed mid-spring (the motion capture's interrupt).
    static let armDrawerInterrupt = Notification.Name("armDrawerInterrupt")
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The drawer's state, and the only place a drag ever lives: a drag frame must never re-run the chat's body.
    @State private var drawerOpen = false
    /// Where the card actually is, in points, right now. This is the drawer's one moving value: a spring follows the
    /// finger while a pan is live and settles on 0 or the panel's width when it ends. It is read by the card's own
    /// leaf (`DrawerCardLayer`) and nowhere in this body — a display frame must invalidate that leaf, not this
    /// hierarchy (Codex R13 P1).
    @State private var motion: DrawerMotion
    /// The pan's own arithmetic: the recognizer reports translations from the touch-down point, so the card's
    /// position is the offset this recorded at grab plus that translation (Codex R13 P1). Written once per gesture.
    @State private var pan = DrawerPanState()
    /// The panel's width: the screen less the strip of chat the reference keeps visible.
    @State private var width: CGFloat = 320
    /// The main area's screen, replaced by identity like a chat swap — never a push.
    @State private var page: MainPage = .chat
    @State private var pageWorkspace: String?
    @State private var rootSheet: RootSheet?
    @State private var sheetPath: [Route] = []
    @State private var newChat = false
    /// Set by the drawer's search button, read by the Chats page when it appears: it names a visit, not a mode.
    @State private var chatsSearch = false
    @State private var launched = false
    @State private var keyboardDown = false
    /// VoiceOver's own focus: into the panel when it opens, back to the menu button when it closes.
    @AccessibilityFocusState private var focus: RootFocus?

    /// The chat the reference leaves visible at the right edge when the drawer is open: the panel is the screen less
    /// this strip (C seq 2522: `strip = 107`, `panelWidth = max(screen - strip, 1)`).
    private static let strip: CGFloat = 107

    /// The animator is made here. A unit test may hand in its own so it can watch the same instance the view drives
    /// — the frame budget is a countable property, and the count has to come from the real hierarchy — while the
    /// app never passes one.
    init(motion: DrawerMotion? = nil) {
        _motion = State(initialValue: motion ?? DrawerMotion())
    }

    var body: some View {
        Trace.body("root")
        #if DEBUG
        let _ = motion.countRootBody()
        #endif
        return Group {
            switch app.auth {
            case .signedOut: SignInView(expired: false)
            case .expired: SignInView(expired: true)
            case .ok: main
            }
        }
        // Signing out takes its sheet with it, or the sheet would outlive the screen that presented it; and a project
        // picked on one Mac means nothing on the next one, whose chats page showed "No chats" (Codex r145). Here, not
        // on `main`: that view is gone the moment sign-in ends, before it could see the change (Codex r146).
        .onChange(of: app.auth) { _, a in if a != .ok { rootSheet = nil; pageWorkspace = nil } }
        // One rounded face for the whole app; each view keeps the sizes and weights it chose.
        .fontDesign(.rounded)
        .overlay(alignment: .top) { ToastView() }
        .overlay(alignment: .topLeading) { PerfOverlay() }
    }

    /// The pan is off while a sheet is up, so it can never fight one for a touch.
    private var panOn: Bool { rootSheet == nil && app.approvals.isEmpty }

    private var main: some View {
        ZStack(alignment: .topLeading) {
            // The drawer is BEHIND the chat, which is opaque: opening is the chat sliding off it, closing is the
            // chat sliding back over it. Nothing fades, so no frame of the motion shows two layers at once.
            //
            // It used to be the other way round — the panel over the chat, its own `.opacity(progress <= 0.001 ? 0
            // : 1)` animated by the same spring as the slide, and the chat faded to 40 % UNDER it. The operator saw
            // what that is: a crossfade. For ~0.3 s the panel was half transparent, so its rows and the chat's text
            // were both legible through each other (the lead's capture, .tmp/drawer-flash/seq1.png), and the fade
            // ran against the chat's own fade — two moving alphas over one canvas, which reads as a flash. A panel
            // that never changes opacity cannot flash.
            //
            // Being covered is not the same as being gone, though (Codex R12): XCUITest reported `drawer.row …
            // hittable=true` while the panel was closed, because a sibling that merely paints on top does not take
            // a control out of hit testing OR out of the accessibility tree. The two gates are therefore explicit
            // and depend on the Boolean, not on the animated offset — they flip once, at the ends of the motion,
            // never on its frames. VoiceOver gets a way out as well: `.escape` on this panel, which is the only
            // dismiss control the reference's own header has room for (the visible X was the design review's, not
            // the photograph's, and it is gone).
            SideDrawer(width: width, pick: { pick($0) }, page: show, sheet: showSheet, search: { searchChats() },
                       close: { close() }, focused: $focus)
                .allowsHitTesting(drawerOpen)
                .accessibilityHidden(!drawerOpen)
                .accessibilityAction(.escape) { close() }
            // The chat, as the card the drawer moves: its offset, hairline and wash live in this leaf, so a frame
            // tick re-runs the leaf's body and never `RootView.body` (Codex R13 P1).
            DrawerCardLayer(motion: motion, width: width, strip: Self.strip, open: drawerOpen,
                            close: { close() }, content: pageShell)
        }
        // The page's own colour across the whole window (#670): the background here was `Color.clear`, so the
        // safe-area strips the app's content does not reach showed the WINDOW through them — pure black in dark, pure
        // white in light — both with the drawer open and with it closed. Everything else composes on top of this.
        .background { Tok.canvas(scheme).ignoresSafeArea() }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = panelWidth(g.size.width) }
                .onChange(of: g.size.width) { _, w in width = panelWidth(w) }
        })
        .gesture(DrawerPan(enabled: panOn, began: panBegan, moved: panMoved, ended: panEnded))
        .onChange(of: drawerOpen, initial: true) { _, open in dragFocus(open ? .drawer : .menu) }
        .onChange(of: width) { _, w in
            // A width change (rotation, a split view, a different device) re-aims a live drag at the new width, so
            // the card stays under the finger instead of jumping to a fraction of the old one. A clamp moves what
            // the finger's translation is measured from, so the pan's origin follows the card (Codex R13 P1).
            motion.rebase(open: drawerOpen, width: w)
            pan.rebase(to: motion.presented)
        }
        .onAppear { motion.setWidth(width) }
        .onDisappear { motion.shutdown() }
        .onAppear {
            // On every appearance, not only the first: a tap on the sign-in screen, after the main view had already
            // launched once, waits here and was lost to the guard below (Codex r132).
            if let id = PushDelegate.pending { PushDelegate.pending = nil; pick(id, "") }
            guard !launched else { return }
            launched = true
            #if DEBUG
            // Design-review hook: `-reviewScreen drawer|settings|newchat|empty` opens one screen straight away, so the
            // reference screens can be photographed from a shell that has no pty and therefore cannot run the UI
            // suite. It navigates, creates a throwaway session and archives it again — so it is DEBUG ONLY, not
            // "debug or simulator" (Codex R11 P1): a Release simulator build is what the UI suite runs, and it must
            // not carry session creation or archiving paths that only a design review should reach.
            if let s = UserDefaults.standard.string(forKey: "reviewScreen") {
                switch s {
                case "settings": rootSheet = .settings
                case "newchat": openReviewNewChat()
                case "chats": page = .chats
                // Through `open()`, not by setting the Boolean: the card's offset is the animator's, so a bare
                // `drawerOpen = true` leaves the panel covered and the review photographs a closed drawer.
                case "drawer": DispatchQueue.main.async { open() }
                case "empty": openReviewChat()
                case "chat": openNewestChat(matching: UserDefaults.standard.string(forKey: "reviewChatTitle") ?? "")
                // The same, and the chat screen itself also honours `-reviewScroll <pt>` (ChatView): the arrow only
                // exists mid-scroll, and this shell cannot drive a touch.
                case "chat-scrolled": openNewestChat(matching: UserDefaults.standard.string(forKey: "reviewChatTitle") ?? "")
                // Puts the Mac back as it was: archives the throwaway chat the review opened.
                case "archiveReview":
                    if let id = UserDefaults.standard.string(forKey: "reviewChat") {
                        UserDefaults.standard.removeObject(forKey: "reviewChat")
                        Task { _ = await app.setArchived(id, true) }
                    }
                default: break
                }
                return
            }
            #endif
            // The app opens to the last chat; with none to open, it opens to the list of them — through `open()`,
            // because the card's offset is the animator's: a bare `drawerOpen = true` would leave the panel
            // hittable and in VoiceOver's tree while the card still covers it.
            if app.currentChatID.isEmpty { DispatchQueue.main.async { open() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleDrawer)) { _ in
            if drawerOpen { close() } else { open() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDrawer)) { _ in open() }
        .onReceive(NotificationCenter.default.publisher(for: .armDrawerInterrupt)) { _ in
            #if DEBUG
            Self.armDrawerInterrupt()
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { n in
            if let id = n.object as? String {
                // The Scheduled screen's own "Open the conversation" row posts this from inside a sheet, and swapping
                // the page under that sheet leaves the reader looking at the scheduled task they came from. The sheet
                // and its stack go first, which is what that screen's own comment already promises.
                rootSheet = nil
                sheetPath.removeAll()
                newChat = false
                PushDelegate.pending = nil
                pick(id, "")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChild)) { n in
            if let ids = n.object as? [String], ids.count == 2 { pick(ids[0], ids[1]) }
        }
        .sheet(isPresented: $newChat) {
            NewChatSheet { id, text in
                if let text, !text.isEmpty { PendingOpen.shared.set(id, text) }
                pick(id)
            }
            .sheetCanvas()
        }
        .sheet(item: $rootSheet) { s in sheetView(s) }
        .sheet(item: Binding(get: { app.approvals.first.map(ApprovalBox.init) }, set: { _ in })) { box in
            ApprovalSheet(frame: box.frame)
                .sheetCanvas()
                // Large too: a long reason or big text pushed Allow and Reject below a half-height sheet.
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
    }

    /// The chat, as one opaque card on the warm canvas, moves in `DrawerCardLayer` below: its own background, the
    /// hairline at its leading edge, the wash that dims it while the drawer is open, and the strip that closes the
    /// drawer. They live in that leaf because they read the animator's per-frame offset, and this body must not.
    private var pageShell: some View { NavigationStack { pageContent } }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .chat:
            if app.currentChatID.isEmpty {
                ContentUnavailableView {
                    Label { Text("No chat open") } icon: { MascotPulse() }
                } description: { Text("Pick one from the list.") }
                    .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerMenuButton(focused: $focus) } }
            } else {
                ChatView(id: app.currentChatID, child: app.currentChild, focused: $focus)
                    .id(app.chatKey)
            }
        case .chats:
            ChatsPage(workspace: pageWorkspace, focusSearch: chatsSearch, pick: { pick($0) },
                      newChat: { newChat = true }, focused: $focus)
        case .projects:
            ProjectsPage(open: { id in pageWorkspace = id; page = .chats; close() }, focused: $focus)
        }
    }

    /// Settings, Plugins, Scheduled tasks and the Task board are sheets, each in its own stack: the main window
    /// still pushes nothing.
    @ViewBuilder private func sheetView(_ s: RootSheet) -> some View {
        NavigationStack(path: $sheetPath) {
            Group {
                switch s {
                case .settings: SettingsView(path: $sheetPath)
                case .plugins: PluginsView(path: $sheetPath)
                case .scheduler: SchedulerView(path: $sheetPath)
                case .board: BoardView()
                }
            }
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .plugins: PluginsView(path: $sheetPath)
                case .plugin(let name): PluginView(name: name, path: $sheetPath)
                case .settings: SettingsView(path: $sheetPath)
                case .models: ProvidersView()
                case .scheduler: SchedulerView(path: $sheetPath)
                case .board: BoardView()
                }
            }
        }
        .sheetCanvas()
    }

    private func panelWidth(_ screen: CGFloat) -> CGFloat { max(screen - Self.strip, 1) }

    #if DEBUG
    /// The empty-chat screen for a design review: a fresh session with nothing in it, which is what the reference's
    /// empty chat is. Its id is remembered so the next `-reviewArchive 1` launch can put the Mac back as it was.
    private func openReviewChat() {
        Task { @MainActor in
            // The workspace list arrives from the Mac after `app.start()`, so the first attempt can be too early.
            for _ in 0..<40 {
                if !app.workspaces.isEmpty || app.listAt > 0 { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let ws = app.defaultProject()?.id ?? ""
            let req: JSON = ws.isEmpty ? .obj([]) : .obj([("workspaceId", .string(ws))])
            guard let id = try? await DSHClient.shared.rpc("session/create", ["request": req])["sessionId"].str else { return }
            app.rows[id] = SessionRow(id: id, blank: true)
            UserDefaults.standard.set(id, forKey: "reviewChat")
            pick(id)
        }
    }

    /// The New chat sheet, once the workspace list is in: a sheet opened before it arrives leaves the project
    /// picker with no selection, and the Working folder row (which needs one) never appears.
    private func openReviewNewChat() {
        Task { @MainActor in
            for _ in 0..<40 where app.workspaces.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            newChat = true
        }
    }

    /// The newest chat, for the chat screen: the list arrives from the Mac after `app.start()`. `-reviewChatTitle`
    /// narrows it to the newest chat whose title starts with that text, so a screen that only some chats show (an
    /// error row, a tool fold) can be photographed deliberately.
    ///
    /// It waits for the roster the way `openReviewChat` does, and searches every row the app has — a title is an
    /// exact request, not a recency one. It used to poll only the newest 40 rows for 10 s and then give up in
    /// silence, which is what left "No chat open" on the photographed screen (lead R15 #8): the roster is a 14.6 MB
    /// `session/list` fetched after the link sign-in, and it can land after that deadline. Giving up is now loud.
    private func openNewestChat(matching title: String) {
        // `@MainActor` on the task, not only on the call that made it: `openNewestChat` is a nonisolated method, so
        // a bare `Task {}` made here runs off the main actor — and `pick` then writes the app's chat selection from
        // a background thread, which the screen never shows. That is the shape that made the hook look as if it did
        // nothing at all (measured: `-reviewChatTitle "Tailscale"` left the previous chat on screen).
        Task { @MainActor in
            for _ in 0..<120 {
                if let r = app.chats(limit: .max).first(where: { title.isEmpty || $0.displayTitle.hasPrefix(title) }) {
                    Trace.mark("review.chat", "opened \(r.id) for '\(title)'")
                    pick(r.id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            Trace.mark("review.chat", "no row matches '\(title)' after 30 s")
            print("review hook: no chat matches '\(title)' after 30 s")
        }
    }
    #endif

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The reference's motion: about a quarter second, critically damped, and only an offset and an opacity.
    ///
    /// The spring is driven per frame by `DrawerMotion`, not by `withAnimation`: the card's offset is one explicit
    /// number, so an interrupting gesture is measured from what is on screen rather than from the Boolean's
    /// destination — the defect Codex R12 found in the old `drag` delta. `slide` is kept for the Boolean's own
    /// changes (and for Reduce Motion, where the same state flips with no animation at all).
    private func slide(_ body: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1), body)
    }

    /// The drawer's target, as the animator wants it: where it is heading and how it looks on the way. Reduce
    /// Motion is carried on the call rather than folded into the spring, so there are no infinite constants to
    /// integrate. `velocity` is `nil` unless a pan is releasing: an open/close that lands mid-flight keeps the
    /// spring's own velocity instead of braking the card to a stop (Codex R13 P2).
    private func aim(_ open: Bool, from velocity: CGFloat? = nil) -> DrawerMotion.Target {
        DrawerMotion.Target(
            resting: open ? width : 0,
            stiffness: DrawerMotion.stiffness(response: 0.28, dampingFraction: 1),
            damping: DrawerMotion.damping(response: 0.28, dampingFraction: 1),
            velocity: velocity,
            immediate: reduceMotion)
    }

    /// VoiceOver, moved to the end of the drawer the reader just arrived at or left. `@AccessibilityFocusState` is
    /// the mechanism (`UIAccessibility.post(.layoutChanged)` cannot name a SwiftUI control); on the way in the
    /// panel is revealed by the card sliding off it, so the move waits for that slide to settle — a focus ring
    /// placed on a control still under the card is a ring around nothing. The wait is the animator's own
    /// completion, not a fixed delay: it fires exactly when the card comes to rest, and a new gesture replaces it
    /// (Codex R13 P2).
    private func dragFocus(_ target: RootFocus) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        if target == .drawer {
            motion.onRest = { [self] in
                guard drawerOpen else { return }
                focus = .drawer
            }
        } else {
            motion.onRest = { [self] in
                guard !drawerOpen else { return }
                focus = .menu
                UIAccessibility.post(notification: .layoutChanged, argument: nil)
            }
        }
    }

    /// Dismiss the keyboard once, when an open starts: its inset animation must not run on every drag frame.
    ///
    /// The Boolean and the motion are written together, and at the ENDS of the gesture rather than during it: the
    /// card's offset is the animator's, so a live drag simply aims it at the finger. Nothing is cleared outside a
    /// transaction any more — that was the second half of the R12 snap (a `drag = 0` on its own leaves the only
    /// changed value unanimated, and a half-open card jumps shut).
    private func open() {
        Trace.mark("drawer", "open")
        dismissKeyboard()
        keyboardDown = false
        slide { drawerOpen = true }
        motion.settle(aim(true))
        #if DEBUG
        if let ms = Self.takeScheduledInterrupt() {
            // The capture test's reversal: XCUITest's own tap synchronization measured ~1.35 s between taps where
            // the test asked for 0.12 s, so the interrupt is scheduled by the app and lands mid-spring. The mark
            // carries the actual delay so the test can prove it happened while the spring was running.
            Task { @MainActor [self] in
                try? await Task.sleep(for: .milliseconds(ms))
                Trace.mark("drawer.interrupt", "after \(ms) ms")
                close()
            }
        }
        #endif
    }

    /// Debug builds only: `-drawer.interrupt <ms>` closes the drawer that many milliseconds after it opens, ONCE.
    /// It is taken rather than read — the capture test opens the drawer several times, and only the gesture it
    /// labels `interrupt` may be reversed. A normal launch passes no such argument (`UserDefaults.standard.integer`
    /// is 0) and a release build does not compile the branch at all.
    #if DEBUG
    private static var interruptTaken = false
    private static func takeScheduledInterrupt() -> Int? {
        guard !interruptTaken else { return nil }
        let ms = UserDefaults.standard.integer(forKey: "drawer.interrupt")
        guard ms > 0 else { return nil }
        interruptTaken = true
        UserDefaults.standard.removeObject(forKey: "drawer.interrupt")
        return ms
    }

    /// Debug test builds only: arm that reversal for the NEXT open. The drawer button's long press posts here, so
    /// the capture can put the interrupt on the gesture it labels `interrupt` — a launch argument is one-shot and
    /// the capture's own setup consumes it long before that marker (Codex R13 P2).
    static func armDrawerInterrupt(ms: Int = 120) {
        interruptTaken = false
        UserDefaults.standard.set(ms, forKey: "drawer.interrupt")
        Trace.mark("drawer.arm", "next open reverses after \(ms) ms")
    }
    #endif

    private func close() {
        Trace.mark("drawer", "close")
        keyboardDown = false
        slide { drawerOpen = false }
        motion.settle(aim(false))
    }

    /// A pan has begun: the spring lets go and the card is handed to the finger, from exactly where it is — even if
    /// the spring was halfway through a slide. This is the rebase Codex R12 asked for, and it is why the offset is
    /// a presented value rather than a delta over the Boolean.
    ///
    /// The recognizer's own translation is measured from the touch-down point, so the card's position for the rest
    /// of the gesture is this recorded offset plus that translation (Codex R13 P1). Recording it here — once, off
    /// the drawn offset — is what keeps the first changed event of a closing drag from clamping the card to zero.
    private func panBegan() {
        motion.grab()
        pan.begin(at: motion.presented)
    }

    private func panMoved(_ x: CGFloat) {
        // `x` is the recognizer's translation, so the closed-end test is the same on the translation: 8 pt of
        // rightward finger travel.
        if !drawerOpen && x > 8 && !keyboardDown { keyboardDown = true; dismissKeyboard() }
        motion.drag(to: pan.position(translation: x, width: width))
    }

    private func panEnded(_ x: CGFloat, _ v: CGFloat) {
        // `x` is where the finger let go, in points from the touch-down; the destination is decided from THAT
        // rebased onto the card's position when the gesture began, not from the raw translation and not from a
        // Boolean plus a delta. Past halfway (or a fast flick) it keeps going; short of it, it springs back.
        let open = pan.release(translation: x, velocity: v, width: width)
        keyboardDown = false
        Trace.mark("drawer.pan", "x=\(Int(x)) v=\(Int(v)) open=\(open ? 1 : 0)")
        slide { drawerOpen = open }
        motion.settle(aim(open, from: v))
    }

    /// Swap the chat while the drawer still covers the main area, then close it: the new chat's first frame is
    /// never watched arriving, and there is no transition to freeze in.
    private func pick(_ id: String, _ child: String = "") {
        app.swapChat(id, child: child)
        page = .chat
        close()
    }

    private func show(_ p: MainPage) {
        chatsSearch = false
        if p == .chats { pageWorkspace = nil }
        page = p
        close()
    }

    /// The drawer's search button: the chat list, opened with its field already focused. The flag is set after
    /// `show` so that the nav row's own visit to the same page still opens without a keyboard.
    private func searchChats() {
        show(.chats)
        chatsSearch = true
    }

    private func showSheet(_ s: RootSheet) {
        sheetPath.removeAll()
        rootSheet = s
        close()
    }
}

/// The chat card as the drawer moves it: the offset, the hairline at its leading edge and the wash — and nothing
/// else.
///
/// This leaf exists so that a display frame has a cost with a bound (Codex R13 P1). `DrawerMotion.presented` changes
/// every frame of a slide; any view that reads it is invalidated every frame, and when that view is `RootView` the
/// whole main hierarchy — the navigation stack, the chat, every callback — is rebuilt for each of the ~17 frames a
/// 0.28 s spring takes. Here the only body a frame re-runs is this one: three modifiers over content the root built
/// once. The wipe the card needs while the drawer is open is the `.opacity(0.6 * progress)` wash INSIDE it, so the
/// card is never translucent and the panel behind it can never show through; the dim is the same 60 % the strip has
/// always had (the photographed strip is the chat at 0.53–0.6 of its contrast against the canvas,
/// `.tmp/oct9/drawer.png` against `.tmp/oct9/chat.png`, measured on the error card's own pink).
struct DrawerCardLayer<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    /// The animator — read HERE, and nowhere in the root.
    let motion: DrawerMotion
    let width: CGFloat
    /// The strip of chat the panel leaves visible, which is a tap target that closes the drawer.
    let strip: CGFloat
    /// The Boolean, not the offset: the hit-testing and accessibility gates flip once per transition.
    let open: Bool
    let close: () -> Void
    let content: Content

    private var draw: CGFloat { motion.presented }
    private var progress: CGFloat { min(1, max(0, draw / max(width, 1))) }

    var body: some View {
        Trace.body("drawer.card")
        #if DEBUG
        let _ = motion.countCardBody()
        #endif
        return ZStack(alignment: .topLeading) {
            content
                .background { Tok.canvas(scheme).ignoresSafeArea() }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Tok.hairline(scheme)).frame(width: 1).opacity(progress)
                }
                .overlay {
                    Tok.canvas(scheme).ignoresSafeArea().opacity(0.6 * progress).allowsHitTesting(false)
                }
                .offset(x: draw)
                // The card is the other half of the drawer's gate: while the panel is what is on screen, the chat
                // behind the wash is neither touchable nor in VoiceOver's traversal, so a swipe through it cannot
                // land on a control the reader cannot see. Boolean, not offset: it flips at the ends of the motion,
                // never on its frames.
                .allowsHitTesting(!open)
                .accessibilityHidden(open)
            // The strip of chat the panel leaves visible: a tap there closes the drawer, as the reference's does.
            // It is always in the tree — a view that came and went at a threshold was one more thing changing on
            // the motion's own frames — and it takes taps only while the panel is the thing on screen, which is the
            // one gate here that has to follow the offset.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: strip)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .onTapGesture { close() }
                .allowsHitTesting(progress > 0.001)
                .accessibilityHidden(true)
        }
    }
}

/// The drawer's way in. It sits in the chat's own bar, always, so the bar's items never change when the drawer
/// opens or closes — which is the rule the chat's frame gate measures. `focused` is handed in by the root, which
/// puts VoiceOver back on this button when the drawer closes: the button is the way in, so it is the way back.
struct DrawerMenuButton: View {
    /// Handed in by the root through whichever page is on screen — the chat, the Chats list, the Projects list —
    /// so the focus return lands on the button the reader actually pressed to come back. A page that passed nothing
    /// would leave the return aimed at a binding nothing reads (Codex R13 P2).
    var focused: AccessibilityFocusState<RootFocus?>.Binding?
    /// Stands in when `focused` is nil, so the modifier below has a binding to write to that nothing else reads.
    /// A bare preview or a test constructs the button without a root; the app always passes one.
    @AccessibilityFocusState private var own: RootFocus?
    var body: some View {
        Button { NotificationCenter.default.post(name: .toggleDrawer, object: nil) } label: {
            Image(systemName: "line.3.horizontal")
        }
        .accessibilityIdentifier("chat.drawer")
        .accessibilityLabel("Chats")
        .accessibilityFocused(focused ?? $own, equals: .menu)
        .modifier(DrawerInterruptArm())
    }
}

/// Debug test builds only: a long press on the drawer's button arms the next open to be reversed 120 ms in — the
/// motion capture's interrupt, on the gesture the capture labels `interrupt` rather than on the launch's first open
/// (Codex R13 P2). The press and the open it starts are one gesture: the arm is taken by the `open()` the release
/// performs. In a release build this modifier is empty and no such gesture exists.
private struct DrawerInterruptArm: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            NotificationCenter.default.post(name: .armDrawerInterrupt, object: nil)
        })
        #else
        content
        #endif
    }
}

/// The two ends of the drawer's own VoiceOver focus: inside the panel while it is open, on the chat's menu button
/// once it is closed again. `.drawer` no longer names a visible close button — the panel's own way out is the
/// `.escape` action, which draws nothing — so it is carried by the panel's first control, the search button.
enum RootFocus: Hashable { case menu, drawer }

/// The orca at 56 pt, breathing between half and full opacity over 1.2 s: the first screen with no chat open is the
/// one place the mascot moves, so the empty window says "waiting for you" rather than "nothing here". Core Animation
/// runs the breathing, as it does the dots: a SwiftUI repeat-forever woke the app every frame the screen sat idle.
struct MascotPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        PulseDot(color: .clear, low: 0.5, period: 1.2, animate: !reduceMotion, image: "Mascot")
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
    }
}

/// Live frame-rate and hitch counter (Settings › Diagnostics).
struct PerfOverlay: View {
    @AppStorage("perf.overlay") private var on = false
    var body: some View {
        if on {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(FrameMonitor.shared.summary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.leading, 8)
            .allowsHitTesting(false)
            .onAppear { FrameMonitor.shared.start() }
        }
    }
}

struct ApprovalBox: Identifiable { let frame: JSON; var id: String { frame["eventId"].str } }

struct ToastView: View {
    @Environment(AppModel.self) private var app
    /// 0 for the screen's own capsule, a sheet's depth for a sheet's: only the topmost one draws.
    var level = 0
    @State private var shown: AppModel.Toast?
    var body: some View {
        Group {
            if let t = shown, app.sheetDepth == level {
                Text(t.text)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.top, 6).padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("toast")
            }
        }
        .animation(.spring(duration: 0.3), value: shown)
        .onChange(of: app.toast) { _, t in
            guard let t else { return }
            shown = t
            Task { try? await Task.sleep(for: .seconds(2.6)); if shown == t { shown = nil } }
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var app
    let expired: Bool
    @State private var link = ""
    @State private var busy = false
    @State private var error = ""
    @State private var scanning = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "terminal.fill").font(.system(size: 40)).foregroundStyle(.tint)
                        Text(expired ? "Sign in again" : "Connect to your Mac").font(.title2.bold())
                        Text(expired
                             ? "Your Mac no longer accepts this phone's sign-in. Scan or paste a fresh DSH link to continue."
                             : "This app controls DSH running on your own Mac, through Tailscale. Scan the Mac's sign-in QR code, or paste the link that dsh web prints. It looks like your-mac.your-tailnet.ts.net/?token=…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                if QRScanner.available {
                    Section {
                        Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                            .disabled(busy)
                            .accessibilityIdentifier("signin.scan")
                    } footer: { Text("Only a code for a Mac on your Tailscale network is accepted.") }
                }
                Section {
                    TextField("https://your-mac.tailnet.ts.net/?token=…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("signin.link")
                    if UIPasteboard.general.hasStrings {
                        Button("Paste from clipboard") { link = UIPasteboard.general.string ?? "" }
                    }
                } header: { Text("DSH link") } footer: {
                    Text("Tailscale must be on, on this phone and on the Mac. The sign-in lasts a year; the link itself changes every time DSH restarts.")
                }
                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await go() }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Connect").bold() }; Spacer() }
                    }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .accessibilityIdentifier("signin.connect")
                }
            }
            .navigationTitle(expired ? "Signed out" : "Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    guard QRScanner.isTailnetLink(code) else {
                        error = "That code is not a DSH link on your Tailscale network."
                        return
                    }
                    link = code
                    Task { await go() }
                } onCancel: { scanning = false }
                .ignoresSafeArea()
            }
        }
    }

    private func go() async {
        // One attempt at a time: a second Mac scanned while the first was connecting could win and overwrite it (Codex r160).
        guard !busy else { return }
        busy = true; error = ""
        defer { busy = false }
        do {
            try await DSHClient.shared.signIn(link: link)
            app.signedIn()
        } catch { self.error = error.localizedDescription }
    }
}

/// The Mac's sign-in QR code (`~/.dsh/scripts/dsh-pair-qr.sh` draws it from the link `dsh web` prints), read with
/// the camera. A scanned code is only trusted when it points inside the Tailscale network: a QR code is easy to
/// swap, and an outside address would get this phone's chats.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    @MainActor static var available: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    /// A `*.ts.net` name or a Tailscale address (100.64.0.0/10).
    nonisolated static func isTailnetLink(_ s: String) -> Bool {
        guard let host = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") { return true }
        // Exactly four numbers: `100.64.1.2.evil.com` is a public name, not a Tailscale address (Codex r86).
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = labels.compactMap { Int($0) }.filter { (0...255).contains($0) }
        return labels.count == 4 && parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        scanner.navigationItem.title = "Scan the Mac's code"
        scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { _ in onCancel() })
        // Started once the scanner is on screen: before that the camera session has nothing to show into.
        DispatchQueue.main.async { try? scanner.startScanning() }
        return UINavigationController(rootViewController: scanner)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScanner
        private var done = false
        init(_ p: QRScanner) { parent = p }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let b) in items {
                guard let code = b.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                parent.onCode(code)
                return
            }
        }
    }
}
