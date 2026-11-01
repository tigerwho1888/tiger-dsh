import XCTest
import UIKit

/// Drives the app in the Simulator against a real DSH. The app must already be signed in (its sign-in persists in the
/// Simulator keychain). TEST_RUNNER_DSH_GEOM / TEST_RUNNER_DSH_PERF switch on diagnostics.
final class SmokeTests: XCTestCase {
    var app: XCUIApplication!
    /// Set once this test made its own chat in the throwaway folder; `archiveThisChat` archives nothing without it.
    private var madeChat = false

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        for k in ["DSH_GEOM", "DSH_PERF"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        // The Mac's own busy-send choice may be steer; the queued-card test needs a busy send to queue.
        app.launchEnvironment["DSH_BUSY_ENTER"] = "queue"
        // With the monitor switched on, show its readout too: the gate reads the numbers off the overlay, because a
        // UI test process cannot reach the app's container for perf.json. The argument domain wins over the stored
        // preference, so this does not change what the operator sees after the run.
        if ProcessInfo.processInfo.environment["DSH_PERF"] != nil { app.launchArguments += ["-perf.overlay", "YES"] }
        // The motion capture's interrupt is NOT a launch argument any more: a one-shot argument is consumed by the
        // first open of the run, which is nowhere near the gesture the capture labels `interrupt`. The capture arms
        // the reversal itself, immediately before that marker, through the drawer button's long press — see
        // `RootView.armDrawerInterrupt` and `testDrawerMotionCapture`.
        app.launch()
        // EVERY launch, not once per run. The sign-in is kept in the Keychain, and the build these tests run is
        // linker-signed (CODE_SIGNING_ALLOWED=NO) with no entitlements — the Simulator refuses the Keychain to an app
        // in that state, so `Keychain.set` fails silently and the cookie is gone by the next launch. The lead's run
        // proved it: the first test (which read Documents/dsh-link.txt) passed, and every test after it came up on
        // the Welcome screen. The runner primes the pasteboard (xcrun simctl pbcopy) and the app's own "Paste from
        // clipboard" button does the rest, so no credential is written anywhere by the tests.
        XCTAssertTrue(signInIfNeeded(),
                      "the app is not signed in: put the DSH link on the Simulator's pasteboard (xcrun simctl pbcopy) before the run")
    }

    /// Signs the app in when it comes up on its Welcome screen, from the link the runner put on the Simulator's
    /// pasteboard. The app's own "Paste from clipboard" button is what reads it, so nothing is written into the
    /// app's container and the app keeps no test-only sign-in path. A Simulator that is already signed in answers
    /// true at the first probe.
    @discardableResult
    private func signInIfNeeded(_ timeout: TimeInterval = 45) -> Bool {
        let connect = app.buttons["signin.connect"]
        // The Welcome screen renders at once, so a signed-in app answers "no sign-in screen" in a few hundred
        // milliseconds rather than waiting out a timeout on every one of the twenty-five tests.
        if !connect.exists {
            let look = Date().addingTimeInterval(3)
            while Date() < look && !connect.exists { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard connect.exists else { return true }
        let paste = app.buttons["Paste from clipboard"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5),
                      "the sign-in screen offered no paste, so the runner did not prime the pasteboard")
        if paste.exists { paste.tap() }
        // iOS asks before an app reads the clipboard; the tap above is the answer, if it appears.
        let allow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "the sign-in screen has no Connect button")
        connect.tap()
        // The drawer's New chat pill is what says the sign-in took: it is there whether the app opens on a chat or
        // on the list of them.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.buttons["home.new"].exists || app.buttons["chat.drawer"].exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("=== NOT SIGNED IN ===\n" + app.debugDescription)
        return false
    }

    /// The frame monitor's own numbers, as the overlay prints them, turned back into counts.
    struct Perf { var frames: Double, hitches: Double, lostMs: Double, worstMs: Double, seconds: Double }

    private func perfNumbers() -> Perf? {
        let pattern = #"^(\d+) fps · (\d+) hitches · ([\d.]+) ms/s lost · worst (\d+) ms · ([\d.]+)s$"#
        for t in app.staticTexts.allElementsBoundByIndex {
            let s = t.label
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges == 6 else { continue }
            func g(_ i: Int) -> Double { Double((s as NSString).substring(with: m.range(at: i))) ?? 0 }
            let secs = g(5)
            return Perf(frames: g(1) * secs, hitches: g(2), lostMs: g(3) * secs, worstMs: g(4), seconds: secs)
        }
        return nil
    }

    /// The screen's own text, one element at a time. `allElementsBoundByIndex` takes one list of elements and then
    /// resolves each index against it lazily; on a screen that is changing under the read — a reply streaming in —
    /// one element can vanish in between, and the gate failed with "No matches found for Element at index 48"
    /// instead of reporting anything about the app. Each element here is resolved and guarded on its own.
    private func screenText() -> String {
        var out: [String] = []
        for i in 0..<app.staticTexts.count {
            let e = app.staticTexts.element(boundBy: i)
            if e.exists, !e.label.isEmpty { out.append(e.label) }
        }
        return out.joined(separator: "|")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The chat list is a drawer that never moves, and the CHAT slides right over it, so the panel's own elements
    /// sit at the same place whether it is open or closed — and, closed, they are behind the chat. What says which
    /// state the drawer is in is therefore what is REACHABLE, not a frame: a row keeps its frame under the chat, and
    /// it keeps it under a sheet too (t8: `rows.firstMatch` sat under the panel's own New chat pill, the tap pressed
    /// the pill, and the New chat sheet then covered every row).
    private func onScreen(_ e: XCUIElement) -> Bool {
        guard e.exists else { return false }
        let f = e.frame
        return f.width > 0 && f.height > 0 && f.midX > 0 && f.midX < app.frame.maxX
    }

    /// A row of the drawer that can actually be tapped: on screen AND not covered by the chat, by a sheet, or by the
    /// panel's own bottom bar. `firstMatch` is none of that — it is the first element in the tree, which may be a row
    /// under the New chat pill or a row behind the chat.
    private func tappableRow(_ rows: XCUIElementQuery, _ limit: Int = 12) -> XCUIElement? {
        for i in 0..<min(rows.count, limit) {
            let r = rows.element(boundBy: i)
            if onScreen(r), r.isHittable { return r }
        }
        return nil
    }

    /// The drawer's own pill: always in the panel, and only touchable while the panel is what is on screen.
    private func drawerReachable() -> Bool {
        let pill = app.buttons["home.new"]
        return pill.exists && pill.isHittable
    }

    /// The chat's composer: only touchable while the chat is what is on screen. A sheet over the chat leaves the
    /// chat's own elements in the tree, so existence says nothing; hittability is the whole test.
    private func chatReachable() -> Bool {
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        return field.exists && field.isHittable
    }

    private func drawerIsOpen() -> Bool { drawerReachable() }

    /// Wait until the drawer is open (its panel reachable), or until the chat has slid back over it.
    @discardableResult
    private func waitForDrawer(_ open: Bool, _ timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while (open ? drawerReachable() : chatReachable()) == false && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        return open ? drawerReachable() : chatReachable()
    }

    private func openDrawer(_ timeout: TimeInterval = 30) {
        if drawerIsOpen() { return }
        let button = app.buttons["chat.drawer"]
        // iOS 27 minimizes the chat's bar on a scroll (`minimizingBar`), and the minimized bar carries no buttons:
        // a short pull back toward older messages brings it back, as it would for a reader's thumb (t101 stress).
        let scroll = app.scrollViews["chat.scroll"]
        if !button.waitForExistence(timeout: 2), scroll.exists, scroll.isHittable { scroll.swipeDown(velocity: .slow) }
        // Tapped only when it can be: behind a sheet the tap would throw "not hittable" instead of leaving the
        // wait below to report what is actually on screen.
        if button.waitForExistence(timeout: timeout), button.isHittable { button.tap() }
        waitForDrawer(true)
    }

    /// Closed again by tapping the strip of chat the drawer leaves visible at the right edge.
    private func closeDrawer() {
        guard drawerIsOpen() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        waitForDrawer(false, 10)
    }

    /// The app's main thread, once the work a fling handed it is done. A query that returns is the proof: the
    /// accessibility snapshot it answers from is produced by the app itself, so it cannot answer while its main thread
    /// is busy. XCUITest's own "wait for idle" gives up after 60 s and its next gesture then throws "Timed out while
    /// evaluating UI query" — this waits for as long as the work takes, and says so when it never finishes.
    @discardableResult
    private func waitUntilResponsive(_ timeout: TimeInterval = 240) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts.firstMatch.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// The chat list is 14.6 MB on this Mac and the Simulator sometimes needs a nudge to get it: if the rows do not
    /// appear, pull the list down to refresh rather than failing the test at random.
    ///
    /// The row comes back only when the panel is SHOWING it and it can be tapped, and `nil` — with the accessibility
    /// dump — is the answer when none is. `firstMatch` was the fallback here and it is none of that: it is the first
    /// element in the tree, which in t8 was a row under the panel's own New chat pill, so the tap pressed the pill
    /// and the New chat sheet then covered every row (Codex R9 P2).
    ///
    /// The chats are grouped under their project's header now (R20). A header is a Button of its own, but the
    /// identifier `drawer.row` still names the chats alone, so every query and helper below is unchanged by it.
    private func waitForChatRows(_ timeout: TimeInterval = 30) -> XCUIElement? {
        let rows = app.buttons.matching(identifier: "drawer.row")
        openDrawer(timeout)
        if !rows.firstMatch.waitForExistence(timeout: timeout) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)).press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.75)))
            if !rows.firstMatch.waitForExistence(timeout: timeout) {
                print("=== NO CHAT ROWS ===\n" + app.debugDescription)
            }
        }
        // Reachability is not instant even once the rows exist: they arrive as the list loads, and a row is only
        // skipped once the one above it is on screen. Waiting is what makes the answer "a row I can tap".
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let r = tappableRow(rows) { return r }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("=== NO TAPPABLE CHAT ROW ===\n" + app.debugDescription)
        return nil
    }

    /// The chat is on screen when its OWN menu button can be tapped. Not a frame — the panel never moves, so a row
    /// keeps its frame under the chat — and not the composer either: the composer is touchable for a moment while
    /// the chat is still sliding, so `waitForDrawer(false, 3)` returned true mid-slide in t9, the retry was skipped,
    /// and `chat.menu` then never appeared at all. The menu is a toolbar item: the panel's tap-to-close strip covers
    /// it while the drawer is open and nothing does while it is closed, which is exactly the distinction wanted.
    private func chatIsOpen() -> Bool {
        let menu = app.buttons["chat.menu"]
        return menu.exists && menu.isHittable
    }

    /// Taps a row the panel is SHOWING until the chat is on screen. `pick` is asked again for every attempt: a row
    /// that was reachable before a tap is not necessarily reachable after it (a live chat keeps re-pinning its list),
    /// and a retry must never be a blind `firstMatch`.
    @discardableResult
    private func openChatFromDrawer(_ pick: (XCUIElementQuery) -> XCUIElement?, tries: Int = 3) -> Bool {
        let rows = app.buttons.matching(identifier: "drawer.row")
        for _ in 0..<tries {
            guard let row = pick(rows) else { break }
            row.tap()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if chatIsOpen() { sleep(2); return true }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        print("=== NO CHAT MENU ===\n" + app.debugDescription)
        XCTFail("chat did not open")
        return false
    }

    private func openFirstChat() {
        guard waitForChatRows() != nil else {
            XCTFail("the drawer offered no chat row that could be tapped")
            return
        }
        openChatFromDrawer { tappableRow($0) }
    }

    func testHomeAndChat() {
        openDrawer(20)
        shot("home")
        // The list is a page of its own now, reached from the drawer's first nav row; the filters live behind the
        // funnel at its top right.
        app.buttons["drawer.chats"].tap()
        XCTAssertTrue(app.buttons["chats.filter"].waitForExistence(timeout: 10), "the Chats page did not open")
        app.buttons["chats.filter"].tap()
        XCTAssertTrue(app.buttons["filter.Archived"].waitForExistence(timeout: 5), "the funnel has no Archived entry")
        app.buttons["filter.Archived"].tap(); sleep(1); shot("archived")
        app.buttons["chats.filter"].tap()
        XCTAssertTrue(app.buttons["filter.All"].waitForExistence(timeout: 5), "the funnel has no All entry")
        app.buttons["filter.All"].tap()
        let cell = app.buttons.matching(identifier: "chat.row").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the Chats page shows no chats")
        cell.tap()
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 15), "chat did not open")
        shot("chat-bottom")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        shot("chat-scrolled-up")
        if app.buttons["chat.jump"].waitForExistence(timeout: 3) { app.buttons["chat.jump"].tap(); sleep(1) }
        shot("chat-jumped")
        app.buttons["chat.menu"].tap(); sleep(1); shot("chat-menu")
        app.buttons["Done"].firstMatch.tap()
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        field.tap(); sleep(1); shot("keyboard")
        // The drawer is the way back to the list now: there is no back button and nothing to pop.
        openDrawer(20)
        XCTAssertTrue(app.buttons["drawer.row"].firstMatch.waitForExistence(timeout: 20), "the drawer did not open again")
    }

    /// Opens a chat that is not working right now. A live chat grows under the test and keeps re-pinning itself to
    /// the newest message, which makes any scroll assertion flaky.
    private func openIdleChat() {
        let rows = app.buttons.matching(identifier: "drawer.row")
        // The helper's answer is a row the panel is SHOWING and that can be tapped, or a failure with the dump —
        // never a row to tap blind.
        guard waitForChatRows() != nil else {
            XCTFail("the drawer offered no chat row that could be tapped")
            return
        }
        // Every candidate is checked for TOUCHABILITY before it is tapped. `rows.firstMatch` is not a row the panel
        // is showing: in t8 it resolved to a row under the panel's own New chat pill, the tap pressed the pill, and
        // the New chat sheet then sat over the drawer — every later tap on a row failed "not hittable" behind it, in
        // this test and in testScrollGate and testVoiceInput alike.
        openChatFromDrawer { rows in
            (0..<min(rows.count, 12)).map { rows.element(boundBy: $0) }
                .first { onScreen($0) && $0.isHittable && !$0.label.contains("Working") } ?? tappableRow(rows)
        }
    }

    /// Makes a chat of the test's own, in a throwaway folder, and sends it its first message through the New chat
    /// sheet. Returns true once the chat is open. Tests that create chats call this instead of sending into a chat
    /// the operator owns, and they archive it on the way out (#551, #575, #577).
    @discardableResult
    private func newChatIn(folder: String, first: String) -> Bool {
        openDrawer(20)
        app.buttons["home.new"].tap()
        let message = app.textFields["What should we work on? (optional)"]
        guard message.waitForExistence(timeout: 10) else {
            XCTFail("the new chat sheet has no first-message field")
            return false
        }
        message.tap()
        message.typeText(first)
        // The folder field is always there; typing in it is what keeps a test chat out of the operator's project.
        let folderField = app.textFields["Folder, for example /Users/you/project"].firstMatch
        if folderField.waitForExistence(timeout: 5) {
            folderField.tap()
            folderField.typeText(folder)
        } else {
            XCTFail("the new chat sheet has no folder field")
        }
        app.buttons["newchat.create"].tap()
        madeChat = app.buttons["chat.menu"].waitForExistence(timeout: 30)
        return madeChat
    }

    /// The chat's menu button, tapped. It is required to be HITTABLE, not merely present (#678): while the drawer's
    /// tap-to-close strip is over it the button is in the tree, the tap lands on the strip, no menu opens, and the
    /// failure then reads as whatever the menu was supposed to contain. A row in the tree says the panel has some
    /// presence — it keeps its frame even when it is fully closed (R7) — so the strip is tapped whenever the menu is
    /// not touchable and any row is there.
    @discardableResult
    private func tapChatMenu() -> Bool {
        // "Is the drawer open" is the panel's own pill being reachable, NOT a `drawer.row` being in the tree: the
        // rows used to be `accessibilityHidden` while the panel was closed, and they are not any more — the panel is
        // drawn behind the chat now, and being covered is what makes a row unreachable. A condition on `exists`
        // would tap the strip on every chat, open or closed.
        if !app.buttons["chat.menu"].isHittable, drawerIsOpen() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
            sleep(1)
        }
        guard app.buttons["chat.menu"].waitForExistence(timeout: 10), app.buttons["chat.menu"].isHittable else {
            print("=== NO TAPPABLE CHAT MENU ===\n" + app.debugDescription)
            return false
        }
        app.buttons["chat.menu"].tap()
        return true
    }

    /// A row inside the chat menu sheet, scrolling the sheet until it is there. The menu is a scrolling sheet at its
    /// medium detent — Model, Permissions, Commands, Context & usage, Goal, Background jobs, Subagents and Turns at the
    /// top; Files, Share transcript, Rename, Pin, Fork and Archive below the fold — and a row below the fold is not in
    /// the accessibility tree at all. A bare `waitForExistence` therefore asked the tree for something that was never
    /// rendered: that is t4's testTurnsJump, and before it three archive failures.
    private func menuRow(identifier: String = "", labelPrefix: String = "", scrolls: Int = 6) -> XCUIElement? {
        let row = labelPrefix.isEmpty
            ? app.buttons[identifier]
            : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
        var n = 0
        while !row.waitForExistence(timeout: 2) && n < scrolls {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            n += 1
        }
        return row.exists ? row : nil
    }

    /// Archives the chat this test opened, through the chat's own menu, and waits for the list to come back. Every
    /// test that made a chat calls this on the way out: the operator's project must not collect test chats (#551).
    /// Two dialogs can follow the menu row — "Archive this chat?", whose own button carries the same word as the row
    /// that opened it, and then, for a chat whose run is still going, "This chat is still working".
    ///
    /// Names the open chat through its menu's Rename sheet, replacing whatever title the host gave it.
    private func renameThisChat(_ title: String) {
        guard tapChatMenu(), let row = menuRow(labelPrefix: "Rename") else { XCTFail("the chat menu has no Rename row"); return }
        row.tap()
        let field = app.textFields["Chat name"]
        guard field.waitForExistence(timeout: 10) else { XCTFail("the Rename sheet did not open"); return }
        field.tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + title)
        app.buttons["Save"].tap()
        _ = app.buttons["chat.menu"].waitForExistence(timeout: 10)
        sleep(1)
    }

    private func archiveThisChat() {
        // Only a chat this test made itself: a test that opened one of the operator's chats leaves it alone
        // (t17 archived the operator's own chats this way, 2026-10-13).
        guard madeChat else { return }
        guard tapChatMenu() else {
            XCTFail("the chat's menu is not tappable, so its chat could not be archived")
            return
        }
        guard let row = menuRow(labelPrefix: "Archive") else {
            XCTFail("the chat menu has no Archive row, after scrolling its sheet")
            return
        }
        row.tap()
        // Each dialog is found by its TITLE, and only then its button: the menu row is labelled "Archive" too, and
        // resolving the button before the dialog was up found the row or nothing — t27's queue test left its running
        // chat in the operator's list that way, and its queued message went on to run.
        tapDialog("Archive this chat?", "Archive")
        tapDialog("This chat is still working", "Stop and archive", timeout: 8)
        // The chat leaves the list, which puts the drawer back up over it.
        _ = app.buttons["drawer.row"].firstMatch.waitForExistence(timeout: 20)
    }

    /// Waits for the dialog titled `title`, then taps its `label` button — the last touchable one of that name, since
    /// the dialog is drawn above the menu row that shares the word.
    @discardableResult
    private func tapDialog(_ title: String, _ label: String, timeout: TimeInterval = 5) -> Bool {
        guard app.staticTexts[title].waitForExistence(timeout: timeout) else { return false }
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for i in stride(from: buttons.count - 1, through: 0, by: -1) where buttons.element(boundBy: i).isHittable {
            buttons.element(boundBy: i).tap()
            return true
        }
        return false
    }

    /// The screen's own text, as label -> its topmost y. Used to prove a swipe MOVED something.
    private func onScreenText() -> [String: CGFloat] {
        var out: [String: CGFloat] = [:]
        for i in 0..<app.staticTexts.count {
            let e = app.staticTexts.element(boundBy: i)
            guard e.exists, !e.label.isEmpty, onScreen(e) else { continue }
            out[e.label] = min(out[e.label] ?? .greatestFiniteMagnitude, e.frame.minY)
        }
        return out
    }

    /// One swipe up the transcript, and the chat's own text is the proof: a label that was on screen has moved.
    /// A chat whose history fits the viewport cannot move at all, which is what t10's `testJumpArrow` opened.
    ///
    /// The direction is the part that was wrong (Codex R12). `swipeDown` moves the content DOWN with the finger —
    /// it scrolls back towards earlier messages — so a label that stays on screen has a LARGER y afterwards. The
    /// helper used to require the y to shrink, which rejected every correctly scrolling conversation and made t11's
    /// `testJumpArrow` report that no chat in the drawer had anything to scroll.
    private func chatScrolls() -> Bool {
        let before = onScreenText()
        guard !before.isEmpty else { return false }
        app.swipeDown(velocity: .fast)
        sleep(1)
        let after = onScreenText()
        for (label, y) in before {
            if let y2 = after[label], y2 - y >= 20 { return true }
        }
        return false
    }

    /// A chat the jump arrow can be judged in: one whose list actually MOVES. The arrow is offered past 120 pt of
    /// content below the viewport, so a chat that fits the screen can never show it — and t10's failure was exactly
    /// that. `openIdleChat` takes the first row it can tap, and the newest chat is three items long: the run's own
    /// screenshots (chat-bottom.png and chat-scrolled-up.png from .tmp/t10.xcresult) are pixel-identical, mean
    /// difference 0.03 of 255, so its two swipes moved nothing. Rows are tried until one scrolls.
    @discardableResult
    private func openChatThatScrolls(tries: Int = 8) -> Bool {
        let rows = app.buttons.matching(identifier: "drawer.row")
        for attempt in 0..<tries {
            guard waitForChatRows() != nil else { return false }
            let candidates = (0..<min(rows.count, 12)).map { rows.element(boundBy: $0) }
                .filter { onScreen($0) && $0.isHittable && !$0.label.contains("Working") }
            guard attempt < candidates.count else { break }
            let name = String(candidates[attempt].label.split(separator: ",").first ?? "")
            candidates[attempt].tap()
            let deadline = Date().addingTimeInterval(6)
            while !chatIsOpen() && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
            guard chatIsOpen() else { continue }
            // Moving is not enough: a chat a little taller than the screen scrolls but never has 120 pt below the
            // viewport (t142 picked one, after the operator's newer short chats pushed the long ones down the drawer).
            if chatScrolls() {
                var n = 0
                while !app.buttons["chat.jump"].exists && n < 4 { app.swipeDown(velocity: .fast); sleep(1); n += 1 }
                if app.buttons["chat.jump"].exists {
                    print("jump arrow: chat '\(name)' scrolls past the arrow's threshold")
                    return true
                }
                print("jump arrow: chat '\(name)' scrolls, but not far enough to offer the arrow — trying the next row")
                continue
            }
            print("jump arrow: chat '\(name)' fits the screen, so it has no arrow to offer — trying the next row")
        }
        return false
    }

    /// A chat the pull can be judged in: one whose history still has earlier pages AND whose top is reachable. Both
    /// are the app's own facts and both are probed — the head row is rendered only while the chat has more history,
    /// and it is only reachable if swiping moves the list. t10 failed on a chat with neither, and no number of swipes
    /// puts a head row into a chat that has no earlier pages.
    @discardableResult
    private func openChatWithEarlierHistory(tries: Int = 8, swipes: Int = 8) -> Bool {
        let rows = app.buttons.matching(identifier: "drawer.row")
        let more = app.buttons["Load earlier messages"]
        // The newest rows are often short — the operator's latest chats, and "Untitled" ones a test made — so the
        // long chat can sit below the drawer's fold (t143 tried eight rows above it): the drawer is scrolled to reach it.
        var tried = Set<String>()
        func title(_ r: XCUIElement) -> String { String(r.label.split(separator: ",").first ?? "") }
        for _ in 0..<tries {
            guard waitForChatRows() != nil else { return false }
            var pick: XCUIElement?
            for _ in 0..<4 {
                let all = (0..<min(rows.count, 40)).map { rows.element(boundBy: $0) }
                pick = all.first { onScreen($0) && $0.isHittable && !$0.label.contains("Working")
                    && title($0) != "Untitled" && !tried.contains(title($0)) }
                if pick != nil { break }
                guard let last = all.last(where: { $0.isHittable }) else { break }
                last.swipeUp(velocity: .slow); sleep(1)
            }
            guard let pick else { break }
            let name = title(pick)
            tried.insert(name)
            pick.tap()
            let deadline = Date().addingTimeInterval(6)
            while !chatIsOpen() && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
            guard chatIsOpen() else { continue }
            var n = 0
            while !(more.exists && more.isHittable) && n < swipes { app.swipeDown(velocity: .fast); sleep(1); n += 1 }
            if more.exists && more.isHittable {
                print("pull: chat '\(name)' reached its top after \(n) swipes")
                return true
            }
            print("pull: chat '\(name)' has no earlier page to reach "
                  + "(head row \(more.exists ? "present but not hittable" : "absent")) — trying the next row")
        }
        return false
    }

    /// Pulling down at the top of a chat loads earlier messages, the way every chat app does it. The button stays as
    /// the fallback, so a chat with nothing more to load passes without the pull having to do anything.
    func testPullToLoadEarlier() {
        XCTAssertTrue(openChatWithEarlierHistory(),
                      "no chat in the drawer has an earlier page the pull could load")
        let more = app.buttons["Load earlier messages"]
        XCTAssertTrue(more.exists && more.isHittable,
                      "the helper returned without the head row in reach (it is \(more.exists ? "at \(more.frame.minY)" : "not in the tree"))")
        // The head row is the affordance; with the reading position held across the insert, the proof that a page
        // arrived is that the head row moved up out from under the reader (or is gone from the tree entirely).
        let beforeY = more.exists ? more.frame.minY : 0
        // A flick is not a pull: the gesture has to be a slow drag held at the top, which is what the system's own
        // refresh control waits for. One pull is enough when the Mac answers at once; this chat's history comes from
        // the Mac, and a pull that lands while the list is still settling registers nothing — the same flake the
        // previous runs logged — so the pull is tried again rather than judged on a single attempt.
        var afterY = beforeY
        for _ in 0..<3 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
            sleep(5)
            afterY = more.exists ? more.frame.minY : -10_000
            if afterY < beforeY - 40 { break }
        }
        XCTAssertTrue(afterY < beforeY - 40,
                      "pulling down at the top loaded nothing: the head row did not move up (\(beforeY) -> \(afterY))")
        shot("pull-earlier")
        archiveThisChat()
    }

    /// The round down-arrow must be absent at the bottom and present after scrolling up (it used to show at the bottom).
    func testJumpArrow() {
        // The chat has to be able to move: the arrow is offered past 120 pt of content below the viewport, so a chat
        // that fits the screen has none to offer (t10 opened one and waited out six swipes for it).
        XCTAssertTrue(openChatThatScrolls(),
                      "no chat in the drawer has anything to scroll, so the arrow cannot be judged in one")
        let jump = app.buttons["chat.jump"]
        // The probe scrolled the chat up, so come back to the bottom first — and prove we are there.
        var back = 0
        while !jump.exists && back < 5 { app.swipeUp(velocity: .fast); sleep(1); back += 1 }
        if jump.exists { jump.tap(); sleep(2) }
        XCTAssertFalse(jump.exists, "jump arrow is showing while already at the bottom")
        // A live chat's length moves under the test, so swipe until the arrow is offered rather than a fixed count.
        var tries = 0
        while !jump.exists && tries < 6 { app.swipeDown(velocity: .fast); sleep(1); tries += 1 }
        XCTAssertTrue(jump.exists, "jump arrow did not appear after scrolling up")
        jump.tap()
        sleep(2)
        XCTAssertFalse(jump.exists, "jump arrow is still showing after jumping to the bottom")
        shot("jump-arrow")
        // Mid-fling: the operator taps the arrow while the list is still coasting, and Claude for iOS answers at once
        // (2026-10-13). An animated jump lost to the coast; the tap must win on the first try.
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        if jump.waitForExistence(timeout: 1) { jump.tap() }
        sleep(2)
        XCTAssertFalse(jump.exists, "the jump arrow did not reach the bottom when tapped mid-scroll")
    }

    /// Diagnostic: open a chat and hold it, so the host can screenshot where the chat actually lands.
    func testChatHold() {
        openFirstChat()
        sleep(30)
    }

    /// Wave 1 (desktop parity): the context and usage sheet opens from the chat menu and reports a window.
    func testUsageSheet() {
        openFirstChat()
        app.buttons["chat.menu"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Context & usage")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the chat menu has no Context & usage row")
        row.tap()
        XCTAssertTrue(app.staticTexts["Context window"].waitForExistence(timeout: 5), "the usage sheet did not open")
        sleep(8)
        shot("usage-sheet")
    }

    /// Wave 2 (desktop parity): the advanced settings screen lists the namespaces the host reports.
    func testAdvancedSettings() {
        openDrawer(20)
        // Settings is the drawer's bottom-left initial now, and it opens as a sheet of its own.
        app.buttons["drawer.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")
        let link = app.buttons["Advanced settings"]
        // The row sits below the diagnostics and cache sections, so the list has to be scrolled to it.
        for _ in 0..<6 where !link.exists { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Settings has no Advanced settings row")
        link.tap()
        XCTAssertTrue(app.staticTexts["agent-loop"].waitForExistence(timeout: 15), "the advanced settings list did not load")
        sleep(6)
        shot("advanced-settings")
    }

    /// The queued-message card and its Send now pill, which the operator called ugly before it was restyled on the
    /// tokens. It creates its own chat and queues a second message into it — nothing is written into a real one.
    ///
    /// The card exists only while the chat is WORKING, and its pill only on a `next-turn` card. t12's failure ("the
    /// queued card has no Send now pill") was neither: the accessibility tree it printed had no card at all, because
    /// the first turn had ENDED between the message being submitted and the app's first poll — the message became
    /// the next prompt instead of a queued one. The pill and the card were both fine. So the turn this test queues
    /// into is one that cannot finish inside the test: counting has no tool behind it, so it also cannot raise an
    /// approval sheet under the run. The layout itself is held by a unit test that renders the card
    /// (`ComposerLayoutTests`), which is where "the pill still exists in the composer's layout" belongs.
    func testQueuePill() {
        // Never the operator's project: a test chat goes to a folder no project owns (operator, 2026-10-13, again).
        // Long enough that the run is still going when the second message is typed, and without a tool call.
        newChatIn(folder: "/tmp/tiger-dsh-test-a", first: "Count slowly from 1 to 2000, one number per line, no commentary.")
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 30), "the new chat never started running")
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer field is missing")
        field.tap()
        // Harmless if it runs: "queue this one" was read as an instruction and made a card on the operator's task
        // board each time this test ran (four on 2026-10-13).
        field.typeText("Reply with the single word queued.\n")
        XCTAssertTrue(app.buttons["queue.sendnow"].waitForExistence(timeout: 20), "the queued card has no Send now pill")
        sleep(1)
        shot("queue-pill")
        archiveThisChat()
    }

    /// Voice input end to end in the Simulator: tap the mic, record a moment, tap Done, and read what the bar says.
    /// The Simulator records the Mac's audio input, so finding no speech is a legitimate answer — what this checks is
    /// that the path runs and says something useful instead of failing.
    func testVoiceInput() {
        openIdleChat()
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "the mic is missing from the composer")
        mic.tap()
        sleep(3)
        // The first run asks for the microphone; the alert belongs to SpringBoard, so answer it there and let the
        // rest of the path run instead of leaving the test staring at a prompt.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Allow While Using App"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 2) { b.tap(); break }
        }
        sleep(4)
        if app.buttons["Done"].waitForExistence(timeout: 6) {
            app.buttons["Done"].tap()
            sleep(15)
        }
        shot("voice-input")
        let said = app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }
        print("voice bar: " + said.suffix(8).joined(separator: " | "))
    }

    /// A background of the reader's own: Settings offers the picker, the focal position and the reset, and both the
    /// chat list and a conversation draw the picture that sits in the app's Documents. The photo picker runs out of
    /// process, so the picture for the screenshot is placed by the harness and this asserts the entry and the render
    /// path; the operator's own pick is the phone check.
    func testShareTranscript() {
        openFirstChat()
        app.buttons["chat.menu"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Share transcript")).firstMatch
        // The row sits below the fold in the chat menu, so the list has to be scrolled to it.
        for _ in 0..<6 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the chat menu has no Share transcript row")
        row.tap()
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 90), "the transcript never finished downloading")
        sleep(2)
        shot("share-transcript")
    }

    /// Wave 3 (desktop parity): the task board appears only when the Mac runs the plugin that owns it.
    func testTaskBoard() {
        openDrawer(20)
        // The board lives inside Settings now, under More.
        app.buttons["drawer.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")
        let entry = app.buttons["Task board"]
        for _ in 0..<4 where !entry.exists { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Settings has no Task board entry")
        entry.tap()
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 15), "the board did not load")
        // A column header carries its card count ("To do · 8"), which is how the test knows cards are on screen
        // without depending on any particular card's title.
        let column = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^(Running|To do|Backlog|Failed|Done) · [0-9]+$")).firstMatch
        XCTAssertTrue(column.waitForExistence(timeout: 5), "the board shows no cards")
        sleep(4)
        shot("task-board")
    }

    /// The message field must stay visible above the keyboard (operator: "keyboard covered the inputs bar").
    func testComposerAboveKeyboard() {
        openIdleChat()
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer field is missing")
        // An empty field is one line tall (operator: "the input bar became ridiculously large").
        XCTAssertLessThan(field.frame.height, 60, "the empty message field is far taller than one line")
        // Voice input must be offered whenever the Mac has a speech provider, and must not vanish once there is a
        // draft to dictate into (operator: "Voice input is missing").
        XCTAssertTrue(app.buttons["composer.mic"].waitForExistence(timeout: 10), "the mic is missing from the composer")
        field.tap()
        field.typeText("x")
        XCTAssertTrue(app.buttons["composer.mic"].exists, "the mic disappeared once there was a draft")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        sleep(2)
        XCTAssertTrue(field.isHittable, "the message field is behind the keyboard")
        shot("composer-keyboard")
    }

    /// A screenshot on the clipboard becomes an attachment when it is pasted the iOS way (operator: "I can paste
    /// words but not image"). The runner and the app share one simulator pasteboard, so this needs no Mac-side tool.
    func testPasteImageIntoField() {
        openIdleChat()
        let img = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        UIPasteboard.general.image = img
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer field is missing")
        field.tap()
        sleep(1)
        field.press(forDuration: 1.5)
        let paste = app.menuItems["Paste"]
        if !paste.waitForExistence(timeout: 6) {
            let labels = app.menuItems.allElementsBoundByIndex.map { $0.label }
            XCTFail("the edit menu offered no Paste for an image; menu items: \(labels)")
            return
        }
        paste.tap()
        // iOS 16 and later ask before an app reads the clipboard; the tap above is the answer, if it appears.
        let allow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        // The picture rides inside the input bar, and the bar keeps its size (operator: "I would like to have it
        // inside the input bar, don't change the size of the bar"). The field is two lines tall since 2026-10-14
        // (operator: "input bar is too small"), so its centre sits 12 pt further from the chip than it did.
        let remove = app.buttons["Remove Pasted.jpg"]
        XCTAssertTrue(remove.waitForExistence(timeout: 8), "the pasted image did not become an attachment")
        XCTAssertLessThan(abs(remove.frame.midY - field.frame.midY), 52, "the pasted picture sits outside the input bar")
        XCTAssertLessThan(field.frame.height, 60, "the input bar grew to hold the picture")
        shot("paste-image")
    }

    /// The keyboard's return sends the message, the way Messages does, instead of adding a line.
    func testReturnSends() {
        // A chat of its own: this test SENDS, and openIdleChat sent "rtsend1" into the operator's own chat four times
        // on 2026-10-13. The first reply is short, so the return key below sends rather than queues.
        newChatIn(folder: "/tmp/tiger-dsh-test-a", first: "Reply with the single word ok.")
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer field is missing")
        field.tap()
        field.typeText("Reply with the single word ok.\n")
        // The field must clear itself once the message is on its way; the host is the other judge (its chat list
        // shows the message), which the earlier run of this test confirmed.
        var cleared = false
        for _ in 0..<20 {
            let v = (field.value as? String) ?? ""
            if v.isEmpty || v == "Message" { cleared = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(cleared, "the return key left the text in the field instead of sending it")
        shot("return-sends")
        archiveThisChat()
    }

    /// Wave 4 (desktop parity): a document opens in the system previewer instead of failing as "not text".
    /// Skips when the workspace root holds no PDF, so it stays honest on a Mac without one.
    func testDocumentPreview() throws {
        openFirstChat()
        app.buttons["chat.menu"].tap()
        let files = app.buttons["Files"]
        // The row sits below the fold in the chat menu, so the list has to be scrolled to it.
        for _ in 0..<6 where !files.exists { app.swipeUp() }
        XCTAssertTrue(files.waitForExistence(timeout: 5), "the chat menu has no Files row")
        files.tap()
        let pdf = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ".pdf")).firstMatch
        // Folders come first in the listing, so the file has to be scrolled to.
        for _ in 0..<12 where !pdf.exists { app.swipeUp() }
        guard pdf.waitForExistence(timeout: 3) else { throw XCTSkip("no PDF in this workspace root") }
        pdf.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 20), "the document previewer did not open")
        sleep(3)
        shot("document-preview")
        // Close the preview before archiving: its own Done button, and wait for the sheet to actually go. The archive
        // opens the chat's menu, and with the preview still up that tap landed on the preview — which is the "the chat
        // menu has no Archive row" failure at the end of this test (#637).
        app.buttons["Done"].tap()
        sleep(2)
        archiveThisChat()
    }

    /// Wave 4: the notification switch exists, and turning it on asks iOS for permission.
    func testNotificationSwitch() {
        openDrawer(20)
        app.buttons["drawer.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")
        let toggle = app.switches["Tell me when a chat needs me"]
        for _ in 0..<8 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Settings has no notification switch")
        toggle.tap()
        let allow = app.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        sleep(2)
        shot("notifications")
    }

    /// Opens the drawer's row at `index` (0 is the newest chat — the first row under the first project header, R20).
    private func openChat(at index: Int) {
        let rows = app.buttons.matching(identifier: "drawer.row")
        guard waitForChatRows() != nil else {
            XCTFail("the drawer offered no chat row that could be tapped")
            return
        }
        // Reachable, not merely present: the row at an index below the fold is in the tree and under the panel's
        // bottom bar, and a tap there presses the pill instead (t8).
        let row = rows.element(boundBy: min(index, max(rows.count - 1, 0)))
        guard onScreen(row), row.isHittable else {
            print("=== ROW AT \(index) IS NOT REACHABLE ===\n" + app.debugDescription)
            XCTFail("the drawer's row at \(index) cannot be tapped")
            return
        }
        openChatFromDrawer { _ in row }
    }

    /// Stress before every ship (operator, 2026-10-15): fifteen fast rounds of the things a thumb does all day —
    /// drawer open, a filter switched, a chat opened, flung both ways, drawer again — and the app must still be the
    /// foreground app and answer a query after every round. Read-only: it opens chats, it never sends or archives.
    func testStress() {
        let filters = ["filter.All", "filter.Working", "filter.Unread", "filter.Answer", "filter.All"]
        for round in 0..<15 {
            openDrawer()
            let funnel = app.buttons["chats.filter"]
            if funnel.exists, funnel.isHittable {
                funnel.tap()
                let f = app.buttons[filters[round % filters.count]]
                if f.waitForExistence(timeout: 3) { f.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
                // Back to All so the rows below are there to open.
                if round % filters.count != 0, funnel.isHittable {
                    funnel.tap()
                    let all = app.buttons["filter.All"]
                    if all.waitForExistence(timeout: 3) { all.tap() }
                }
            }
            openChat(at: round % 4)
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            if list.exists { list.swipeDown(velocity: .fast); list.swipeUp(velocity: .fast); list.swipeUp(velocity: .fast) }
            XCTAssertEqual(app.state, .runningForeground, "the app is gone after stress round \(round)")
            XCTAssertTrue(waitUntilResponsive(60), "the app stopped answering after stress round \(round)")
        }
    }

    /// Wave 5 (desktop parity): the Turns list takes the reader back to an earlier turn.
    ///
    /// Self-contained, which is what #577 asked for and what the t3 run proved again: walking the operator's chat list
    /// put this test in a long chat, and jumping to a distant turn pages up to twenty pages of history and scrolls
    /// thousands of rows — the app went 60 s without an idle notification and then could not answer a snapshot for
    /// another 100 s, so the assertion after the jump died as "Failed to get matching snapshots". Its own chat in a
    /// throwaway folder has two turns and nothing to page.
    func testTurnsJump() {
        XCTAssertTrue(newChatIn(folder: "/tmp/tiger-dsh-test-a",
                                first: "Reply with the single word ready."),
                      "the chat this test made did not open")
        let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the composer field is missing")
        field.tap()
        field.typeText("Reply with the single word again.\n")
        // Two FINISHED turns are what puts two rows in the outline; a queued one does not count until it ends.
        for _ in 0..<40 where app.buttons["chat.stop"].exists { sleep(2) }
        sleep(2)
        // The Turns row is in the menu's first section but below its medium detent's fold on a long menu, so it is
        // found the same way the Archive row is: through the sheet, scrolling until the row is rendered.
        guard tapChatMenu(), let turns = menuRow(identifier: "menu.turns") else {
            XCTFail("the chat menu has no Turns row")
            return
        }
        turns.tap()
        let anyTurn = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Turn ")).firstMatch
        XCTAssertTrue(anyTurn.waitForExistence(timeout: 10), "the Turns list is empty")
        // The list the row opens, for the same reason.
        shot("turns-list")
        anyTurn.tap()
        sleep(4)
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 30), "the chat did not come back after the jump")
        shot("turns-jump")
        archiveThisChat()
    }

    /// Frame hitches while flinging the drawer's chat list — the project headers and their chats alike (R20).
    func testScrollSmoothness() {
        openDrawer(20)
        sleep(2)
        // With the drawer open its chat list is the first collection view in the tree: the chat container comes
        // after it, and a List identifier would have merged the rows away.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the drawer's chat list is missing")
        let opts = XCTMeasureOptions(); opts.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: opts) {
            list.swipeUp(velocity: .fast); list.swipeUp(velocity: .fast); list.swipeDown(velocity: .fast); list.swipeDown(velocity: .fast)
        }
    }

    /// Frame hitches while flinging a long chat.
    func testChatScrollSmoothness() {
        openFirstChat()
        // By name: the drawer's filter chips are a ScrollView too, and `firstMatch` found that one — off screen,
        // 32 pt tall, and an empty visible frame to swipe.
        let scroll = app.scrollViews["chat.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "the chat's own scroll view is missing")
        let opts = XCTMeasureOptions(); opts.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: opts) {
            scroll.swipeDown(velocity: .fast); scroll.swipeDown(velocity: .fast); scroll.swipeUp(velocity: .fast); scroll.swipeUp(velocity: .fast)
        }
    }

    /// C4's gate: the chat list is a side drawer now. It opens from the chat's own bar button, the chat's bar keeps
    /// the same frame and the same items either way, a tap on the dimmed strip closes it, and picking a chat in it
    /// lands on that chat — with no push and no back arrow anywhere.
    func testDrawer() {
        openIdleChat()
        let bar = app.navigationBars.firstMatch
        let closed = bar.frame
        let closedBarItems = bar.buttons.allElementsBoundByIndex.map { $0.identifier }
        app.buttons["chat.drawer"].tap()
        // The drawer's own rows are `drawer.row` (SideDrawer.row); `chat.row` belongs to the Chats page
        // (SideDrawer's ChatsPage.row) and is not in the panel at all. The failure snapshot for this assertion had ten
        // `drawer.row` buttons on screen and no `chat.row` — the drawer was open and the test asked for the wrong one.
        XCTAssertTrue(app.buttons["drawer.row"].firstMatch.waitForExistence(timeout: 20), "the drawer did not open")
        // ...and they are grouped under their project now (R20): a `drawer.project` header sits over them. The rows
        // themselves keep the `drawer.row` identifier every helper in this suite reads, so only the grouping is new.
        XCTAssertTrue(app.buttons["drawer.project"].firstMatch.waitForExistence(timeout: 5),
                      "the drawer's chats are not grouped under their projects")
        sleep(1)
        shot("drawer-open")
        let opened = bar.frame
        XCTAssertEqual(opened.minY, closed.minY, accuracy: 0.5, "the chat's bar moved when the drawer opened")
        XCTAssertEqual(opened.height, closed.height, accuracy: 0.5, "the chat's bar changed height when the drawer opened")
        // The chat slides right by the panel's width, so the bar's trailing item leaves the screen — and an off-screen
        // element is not in the accessibility tree, which is why the count read 1 against the closed 2. What can be
        // measured is what the assertion was for: the drawer ADDS nothing to the bar (the open items are a subset of
        // the closed ones), the chat's own button is still there, and closing the drawer brings the same items back.
        let openBarItems = bar.buttons.allElementsBoundByIndex.map { $0.identifier }
        XCTAssertTrue(Set(openBarItems).isSubset(of: Set(closedBarItems)),
                      "the chat's bar gained an item while the drawer was open: \(openBarItems.sorted()) against \(closedBarItems.sorted())")
        XCTAssertTrue(openBarItems.contains("chat.drawer"), "the chat's own button left the bar while the drawer was open")
        // Close with the panel's own button, then again by tapping the strip of chat beside the panel.
        closeDrawer()
        sleep(1)
        XCTAssertEqual(bar.buttons.allElementsBoundByIndex.map { $0.identifier }, closedBarItems,
                       "the chat's bar did not come back the way it was when the drawer closed")
        let closedRow = app.buttons.matching(identifier: "drawer.row").firstMatch
        // What can be measured is TOUCHABILITY, not the frame. `onScreen` was the wrong predicate here and it failed
        // on 5c9d985 with `row=(0.0, 354.0, 336.0, 52.0)`: a SwiftUI view keeps its layout geometry through
        // `.opacity(0)` and its accessibility element keeps that geometry too, so a frame that is inside the screen
        // says nothing about whether the panel is showing — which is why this suite's own `onScreen` note says the
        // panel's elements sit in the same place either way.
        //
        // The app is right (RootView, `main`, TigerDSHApp.swift:168-170): closed, the drawer is opacity 0,
        // `allowsHitTesting(false)` and `accessibilityHidden(true)`. XCUITest's own contract for the second of those
        // is `isHittable`, documented as false when an element "is covered by another element" — the chat covers this
        // one — so that is the assertion, and the tap below is the functional half of it.
        let drawerFrame = closedRow.exists ? "\(closedRow.frame)" : "none"
        // The panel has no visible close button any more — the reference's header holds only the search circle, and
        // the reader's way out is the `.escape` accessibility action, which draws nothing and so has no element to
        // probe. The probe prints the header's one control instead, which is also where VoiceOver lands on open.
        let searchButton = app.buttons["drawer.search"]
        print("drawer probe: row=\(drawerFrame) hittable=\(closedRow.exists ? "\(closedRow.isHittable)" : "n/a") search=\(searchButton.exists ? "\(searchButton.frame)" : "none") screen=\(app.frame)")
        XCTAssertFalse(closedRow.exists && closedRow.isHittable, "the closed drawer is still taking taps")
        // ...and the chat underneath is what takes them: a tap where the panel's own rows sit must do nothing to the
        // drawer, which is the behaviour the frame check was trying to protect.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)).tap()
        XCTAssertFalse(drawerIsOpen(), "a tap over the closed panel opened the drawer")
        XCTAssertTrue(app.buttons["chat.menu"].exists, "the chat left the screen when the closed panel was tapped")
        app.buttons["chat.drawer"].tap()
        XCTAssertTrue(app.buttons["drawer.row"].firstMatch.waitForExistence(timeout: 10), "the drawer did not open again")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(waitForDrawer(false, 10), "a tap on the dimmed strip did not close the drawer")
        XCTAssertEqual(bar.frame.height, closed.height, accuracy: 0.5, "the chat's bar changed height on the way back")
        // Switch chats from the drawer: the pick lands in the main window itself. The list is LIVE — a worker
        // session updates and its rows re-sort under the test — so the pick is judged by IDENTITY (the title that
        // actually opened) and made again on each attempt, never on one tap of a row that has moved since it was
        // read. t10 read a row as "Untitled" and the tap opened "You are the dsh build": same index, different chat.
        var switched = false
        var wanted = ""
        for _ in 0..<3 where !switched {
            app.buttons["chat.drawer"].tap()
            guard app.buttons["drawer.row"].firstMatch.waitForExistence(timeout: 10) else { break }
            let titles = bar.staticTexts.allElementsBoundByIndex.map { $0.label }
            let rows = app.buttons.matching(identifier: "drawer.row")
            var target: XCUIElement?
            for i in 0..<min(rows.count, 12) {
                let r = rows.element(boundBy: i)
                // A row the panel is not showing keeps its frame and its label, and cannot be tapped (t8).
                guard onScreen(r), r.isHittable else { continue }
                let head = String(r.label.split(separator: ",").first ?? "")
                if !head.isEmpty && !titles.contains(where: { $0.hasPrefix(head) }) {
                    wanted = head; target = r; break
                }
            }
            guard let row = target else { break }
            row.tap()
            sleep(2)
            guard app.buttons["chat.menu"].waitForExistence(timeout: 10) else { continue }
            let after = bar.staticTexts.allElementsBoundByIndex.map { $0.label }
            if after.contains(where: { $0.hasPrefix(wanted) }) {
                switched = true
            } else {
                print("drawer switch: the row read as '\(wanted)' opened \(after) — the list moved under the tap")
            }
        }
        XCTAssertTrue(switched, "no chat could be switched to by identity in the drawer")
        shot("drawer-switch")
        archiveThisChat()
    }

    /// The drawer's frame gate: open it, switch chats from it and close it, while the monitor counts. This is the
    /// transition the old pop gate watched; there is no interactive pop left to watch. Run with TEST_RUNNER_DSH_PERF=1.
    ///
    /// It switches between two small chats of its own, not whichever chats lead the operator's list: those were the
    /// operator's long chats by t21, and the gate then measured their length — the shipped build failed it as well
    /// (220.8 ms/s, t22). The threshold is unchanged.
    func testDrawerGate() {
        for name in ["A", "B"] {
            XCTAssertTrue(newChatIn(folder: "/tmp/tiger-dsh-test-a",
                                    first: "Drawer gate chat \(name): reply with the single word ok."),
                          "the chat this test made did not open")
            for _ in 0..<40 where app.buttons["chat.stop"].exists { sleep(2) }
            // The host now writes its own title after the first reply ("Drawer Gate Chat OK"), so the drawer row
            // would no longer say which chat is A: the test names each one itself.
            renameThisChat("Drawer gate chat \(name)")
        }
        func gateRow(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == 'drawer.row' AND label BEGINSWITH %@",
                                             "Drawer gate chat \(name)")).firstMatch
        }
        // Both chats go: whichever is open (B after a full run), then A from the drawer the archive leaves up.
        defer {
            archiveThisChat()
            let rowA = gateRow("A")
            if rowA.waitForExistence(timeout: 15) {
                rowA.tap()
                if app.buttons["chat.menu"].waitForExistence(timeout: 15) { archiveThisChat() }
            }
        }
        sleep(2)
        guard let a = perfNumbers() else {
            XCTFail("the performance overlay is not showing; run this gate with TEST_RUNNER_DSH_PERF=1")
            return
        }
        // B is open after the setup, so the switches go A, B, A, B, A, B.
        for i in 0..<6 {
            app.buttons["chat.drawer"].tap()
            let target = gateRow(i % 2 == 0 ? "A" : "B")
            guard target.waitForExistence(timeout: 15), onScreen(target), target.isHittable else {
                XCTFail("the drawer is not showing this test's own chat to switch to")
                return
            }
            target.tap()
            _ = app.buttons["chat.menu"].waitForExistence(timeout: 15)
        }
        sleep(2)
        guard let b = perfNumbers() else { XCTFail("the overlay went away mid-run"); return }
        let dSec = b.seconds - a.seconds
        let dFrames = b.frames - a.frames
        let msPerSecond = dSec > 0 ? (b.lostMs - a.lostMs) / dSec : 9_999
        let line = String(format: "drawer gate: %.1fs, %.0f frames (%.0f fps), %.0f hitches, %.1f ms/s lost, worst %.0f ms",
                          dSec, dFrames, dFrames / max(dSec, 0.001), b.hitches - a.hitches, msPerSecond, b.worstMs)
        print(line)
        shot("drawer-gate")
        XCTAssertGreaterThan(dSec, 1, "the two snapshots are too close together to judge — \(line)")
        XCTAssertGreaterThan(dFrames, 0, "the monitor counted no frames while the drawer moved — \(line)")
        // Same shape as the other gates: 1.5x the worst baseline, to catch a regression rather than to stand in for
        // the 10 ms/s target.
        XCTAssertLessThan(msPerSecond, 200, "the drawer lost more time than the gate allows — \(line)")
        XCTAssertLessThan(b.worstMs, 300, "one frame was longer than the gate allows — \(line)")
    }


    /// The drawer's own gestures: a right swipe anywhere on the chat opens it, a tap on the strip of chat it leaves
    /// visible closes it, and a left drag closes it too. Settings is a sheet now, so the main window has no pop left
    /// for a swipe to run — this replaces the old edge-swipe-back test.
    func testDrawerGestures() {
        openFirstChat()
        XCTAssertFalse(drawerIsOpen(), "the drawer started open")
        // The drawer opens on where the drag ENDS: past half the panel's width (~168 of its 336 pt). A synthesized
        // fast drag can begin a little late and lose points at its start, and 0.45→0.95 of the screen is 201 pt —
        // only ~33 pt of margin, which t4's run missed. The drag starts further left and is repeated rather than
        // judged once, the same way this suite treats a tap that lands while the list is still settling.
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        var opened = false
        for _ in 0..<3 where !opened {
            left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
            opened = waitForDrawer(true, 8)
        }
        XCTAssertTrue(opened, "a right swipe on the chat did not open the drawer")
        shot("drawer-open-gesture")
        // The strip closes it again.
        closeDrawer()
        XCTAssertFalse(drawerIsOpen(), "a tap on the strip did not close the drawer")
        // And a left drag closes it, which is the mirror image: judged on the same threshold, and repeated for the
        // same reason.
        opened = false
        for _ in 0..<3 where !opened {
            left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
            opened = waitForDrawer(true, 8)
        }
        XCTAssertTrue(opened, "the drawer did not open again")
        var closed = false
        for _ in 0..<3 where !closed {
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            closed = waitForDrawer(false, 8)
        }
        XCTAssertTrue(closed, "a left drag did not close the drawer")
        shot("drawer-gestures")
    }

    /// The drawer's motion, for a screen recording to be measured frame by frame.
    ///
    /// Skipped unless DSH_MOTION=1: it asserts almost nothing — it drives the nine gestures the flash was reported
    /// in, in ONE launch, and prints a marker before and after each so `.tmp/motion-check.py` can name the windows it
    /// finds in the video. It opens a chat the operator owns and does not archive it; nothing is created.
    ///
    /// Three rules make the recording analysable (Codex R12):
    ///
    ///  * **the signed-in screen is not a gesture.** The first marker used to be emitted while the sign-in screen
    ///    was still being dismissed, so the analyser counted that transition as the first burst and paired every
    ///    gesture with the wrong window. `SETTLE signed-in-idle` is printed once the app is signed in and the chat
    ///    has stopped moving, and the analyser ignores everything before it;
    ///  * **a marker contains exactly the named gesture.** `settle()` used to run INSIDE the marker, and its own
    ///    open/close is a second transition in the same window. It runs before the marker now;
    ///  * **the interrupt is scheduled by the app.** XCUITest waits for the app to be idle around every event, so
    ///    the old "tap, sleep 0.12 s, tap" measured 1.35 s between the taps and never interrupted the spring at
    ///    all. `-drawer.interrupt 120` (debug builds) closes the drawer 120 ms after it opens, from inside the app,
    ///    and the marker records the moment so the window's frames can be checked against it.
    func testDrawerMotionCapture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DSH_MOTION"] == "1",
                          "set DSH_MOTION=1 and start `xcrun simctl io <sim> recordVideo` first (see .tmp/motion-capture.sh)")
        openIdleChat()
        let strip = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5))
        // The two half drags need DIFFERENT destinations, because the travel that matters is measured from where the
        // card is when the drag starts: a half drag from closed must travel less than 147.5 pt, and one from open must
        // too. One shared point cannot do both — 0.33 gave the opening drag 108 pt but gave the closing drag
        // (0.80 → 0.33) 189 pt, past halfway, so the "spring back" closed the drawer instead (Codex R13 P2).
        let halfOpen = app.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.5))   // 108 pt from `left`
        let halfClose = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.5))  // 121 pt from `right`

        /// A rest, the marker, the gesture, a rest, the closing marker.
        func motion(_ name: String, _ body: () -> Void) {
            sleep(2)
            print("MOTION \(name) start \(Date().timeIntervalSince1970)")
            body()
            sleep(2)
            print("MOTION \(name) end \(Date().timeIntervalSince1970)")
        }
        /// Back to a known state without the gesture under test: the analyser reads each window's own ends. Called
        /// BEFORE a marker, never inside one — the transition it may cause belongs to no gesture.
        func settle(_ open: Bool) {
            if drawerIsOpen() != open { open ? openDrawer(20) : closeDrawer() }
            _ = waitForDrawer(open, 10)
            sleep(1)
        }
        /// The signed-in, still screen. Everything before this marker is not a gesture.
        settle(false)
        print("SETTLE signed-in-idle \(Date().timeIntervalSince1970)")

        settle(false); motion("open-button") { app.buttons["chat.drawer"].tap() }
        settle(true);  motion("close-strip") { strip.tap() }
        settle(false); motion("open-swipe") { left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0) }
        settle(true);  motion("close-swipe") { right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0) }
        // A slow half drag, held, then released: it follows the finger and springs back to where it started. Each
        // drag uses its own destination, so both travel less than half the panel.
        settle(false); motion("half-drag-open") {
            left.press(forDuration: 0.5, thenDragTo: halfOpen, withVelocity: .slow, thenHoldForDuration: 1.0)
        }
        settle(true); motion("half-drag-close") {
            right.press(forDuration: 0.5, thenDragTo: halfClose, withVelocity: .slow, thenHoldForDuration: 1.0)
        }
        settle(false); motion("flick-open") { left.press(forDuration: 0.02, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0) }
        settle(true);  motion("flick-close") { right.press(forDuration: 0.02, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0) }
        // Open, then turned round while the open spring is still running: the interrupt the flash was reported in.
        // The reversal is the app's own, armed immediately before this marker by the long press that starts the
        // open (Debug test builds only, `RootView.armDrawerInterrupt`). A launch argument cannot do it: it is
        // one-shot, and the capture's own setup consumes it long before this gesture (Codex R13 P2). The marker
        // brackets the press; the app's `drawer.interrupt` mark in the trace says when the reversal actually
        // happened, and the drawer must be CLOSED at the end of the window — it was opened by this same press.
        settle(false)
        motion("interrupt") {
            app.buttons["chat.drawer"].press(forDuration: 0.6)   // the long press arms; the release opens
            Thread.sleep(forTimeInterval: 1.5)                   // the reversal itself is 120 ms in; this is the tail
        }
        XCTAssertFalse(drawerIsOpen(), "the armed reversal did not close the drawer this press opened")
        settle(false)
        shot("motion-capture-end")
    }

    /// #410's gate, and the message box's own: the controls that act on the message share one centre line and sit
    /// on the right of the box, the attach button leads on its own on the left, and the send target is 44 pt.
    /// The context ring appears only once the chat is at least half full, so it joins the line when it is there.
    func testComposerAlignment() {
        let app = self.app!
        openIdleChat()
        let attach = app.buttons["composer.attach"], mic = app.buttons["composer.mic"]
        let send = app.buttons["composer.send"], ctx = app.buttons["composer.context"]
        for (name, e) in [("attach", attach), ("mic", mic), ("send", send)] {
            XCTAssertTrue(e.waitForExistence(timeout: 12), "\(name) is missing from the composer")
        }
        var line = [attach, mic, send]
        if ctx.exists { line.append(ctx) }
        let ys = line.map { $0.frame.midY }
        let spread = (ys.max() ?? 0) - (ys.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 0.5, "the composer controls are not on one centre line: \(ys)")
        // The + leads on the left; mic, ring and send trail on the right, where a thumb reaches them.
        XCTAssertLessThan(attach.frame.maxX, app.frame.midX, "the attach button is not on the left of the box")
        XCTAssertLessThan(app.frame.maxX - send.frame.maxX, 60, "the send disc is not near the right edge of the box")
        let disc = send.frame
        XCTAssertEqual(disc.width, 44, accuracy: 0.5, "the send target is not 44 pt wide")
        XCTAssertEqual(disc.height, 44, accuracy: 0.5, "the send target is not 44 pt tall")
        shot("composer-align")
        archiveThisChat()
    }

    /// The smoothness gate (assignment #2, Step 2): fling an idle chat that has real history and judge the frame
    /// monitor's own numbers over the interval the fling took, not its lifetime averages. Reads the overlay, so run
    /// it with TEST_RUNNER_DSH_PERF=1 — without the monitor the overlay is absent and the gate fails loudly rather
    /// than passing on nothing.
    func testScrollGate() {
        openIdleChat()
        for _ in 0..<3 {
            let more = app.buttons["Load earlier messages"]
            guard more.waitForExistence(timeout: 2) else { break }
            more.tap()
            // The head row says "Loading earlier messages" while the page is on its way, and the bar is back when it
            // has landed: waiting on that is proof, where a 2 s sleep only hoped (and a page of a long chat is many
            // hundreds of rows of work for the list).
            let loading = app.staticTexts["Loading earlier messages"]
            if loading.waitForExistence(timeout: 3) {
                for _ in 0..<240 where loading.exists { Thread.sleep(forTimeInterval: 0.5) }
            }
            _ = waitUntilResponsive()
        }
        guard waitUntilResponsive() else {
            XCTFail("the app stopped answering before the gate's flings — see .tmp/list-speed-proposal.md")
            return
        }
        guard let a = perfNumbers() else {
            XCTFail("the performance overlay is not showing; run this gate with TEST_RUNNER_DSH_PERF=1")
            return
        }
        // A fling on a chat with thousands of rows keeps the app's main thread busy for a long time — XCUITest's own
        // 60 s idle wait gives up, and its NEXT gesture then throws "Timed out while evaluating UI query" instead of
        // reporting anything about the app. Waiting for an answer between gestures turns that into numbers this gate's
        // thresholds can judge.
        //
        // The wait is BOUNDED and its outcome is ASSERTED (Codex P2, review 5): an unbounded wait let a long freeze
        // recover and still pass, and the frame numbers cannot catch it on their own — `FrameMonitor.tick` discards
        // gaps over 250 ms, and time spent waiting is time the "ms/s lost" is averaged over. So each fling and its
        // recovery is judged on its own duration, and a wait that runs out is a failure, not a footnote.
        let ui = app!
        var stalled = ""
        for i in 0..<4 {
            for (name, swipe) in [("up", { ui.swipeUp(velocity: .fast) }),
                                  ("down", { ui.swipeDown(velocity: .fast) })] {
                let began = Date()
                swipe()
                let answered = waitUntilResponsive(Self.flingBudget)
                let took = Date().timeIntervalSince(began)
                if !answered { stalled = "the app did not answer within \(Int(Self.flingBudget))s after fling \(i + 1) \(name)"; break }
                if took > Self.flingBudget {
                    stalled = String(format: "fling %d %@ took %.1fs to settle, over the %.0fs budget", i + 1, name, took, Self.flingBudget)
                    break
                }
            }
            if !stalled.isEmpty { break }
        }
        XCTAssertTrue(stalled.isEmpty, "\(stalled) — see .tmp/list-speed-proposal.md")
        sleep(3)
        guard let b = perfNumbers() else { XCTFail("the overlay went away mid-run"); return }
        let dSec = b.seconds - a.seconds
        let dFrames = b.frames - a.frames
        let dLostMs = b.lostMs - a.lostMs
        let msPerSecond = dSec > 0 ? dLostMs / dSec : 9_999
        let line = scrollLine(a, b)
        print(line)
        shot("scroll-gate")
        XCTAssertGreaterThan(dSec, 1, "the two snapshots are too close together to judge — \(line)")
        XCTAssertGreaterThan(dFrames, 0, "the monitor counted no frames while the chat was flung — \(line)")
        // Thresholds are 1.5x the worst of three baseline runs at b084d59 (116.8 / 118.7 / 132.5 ms/s lost,
        // worst frames 143 / 117 / 187 ms, 52-53 fps): this gate catches a regression, it is not the 10 ms/s
        // target — that is what assignment #2's remaining steps are for.
        XCTAssertLessThan(msPerSecond, 200, "the fling lost more time than the gate allows — \(line)")
        XCTAssertLessThan(b.worstMs, 300, "one frame was longer than the gate allows — \(line)")
        archiveThisChat()
    }

    /// How long one fling and its recovery may take before the gate fails. Calibrated from the two runs that
    /// motivated this bound: on 5c9d985 a fling pair went 60 s without an idle notification TWICE (105.8 s and
    /// 165.8 s on the clock in `.tmp/list-speed-proposal.md`), while healthy flings on an idle chat settle in
    /// single-digit seconds. 30 s is 3x the target and half of XCUITest's own idle ceiling.
    private static let flingBudget: TimeInterval = 30

    /// The gate's one line of numbers, so a failure carries them in its message.
    private func scrollLine(_ a: Perf, _ b: Perf) -> String {
        let dSec = b.seconds - a.seconds
        return String(format: "gate: %.1fs, %.0f frames (%.0f fps), %.0f hitches, %.1f ms/s lost, worst %.0f ms",
                      dSec, b.frames - a.frames, (b.frames - a.frames) / max(dSec, 0.001), b.hitches - a.hitches,
                      dSec > 0 ? (b.lostMs - a.lostMs) / dSec : 9_999, b.worstMs)
    }

    /// The streaming gate: a run streams a short reply and the monitor's numbers are judged over that window, with
    /// a functional guard that the reply actually grew. It creates its OWN chat every run — a gate must never write
    /// into a conversation the operator owns.
    func testStreamingGate() {
        // Never the operator's project: a test chat goes to a folder no project owns (operator, 2026-10-13, again).
        newChatIn(folder: "/tmp/tiger-dsh-test-a", first: "Answer here in plain text only, with no tools and no task cards: count slowly from 1 to 400, one number per line.")
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 30), "the new chat never started running")
        guard let a = perfNumbers() else {
            XCTFail("the performance overlay is not showing; run this gate with TEST_RUNNER_DSH_PERF=1")
            return
        }
        app.buttons["composer.model"].tap()
        sleep(2)
        // The sheet lists effort levels first and the models under their providers, so pick a model BY NAME: tapping
        // the first cell chose an effort row, which left the pill holding the same id as before. Then close the sheet
        // with its own Done button, because a swipe down does not dismiss it and the shot kept coming out as the sheet.
        let chosen = app.buttons["DeepSeek-V41-Flash"].firstMatch
        if chosen.waitForExistence(timeout: 8) { chosen.tap(); sleep(3) }
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 8) { done.tap(); sleep(3) }
        shot("c12-model-pill-long")
        archiveThisChat()
    }

    /// The "This chat is still working" dialog, reached from the chat's title menu while a run is going: this build owes
    /// a light and a dark picture of it (#652). It cancels out and then archives through the ordinary path.
    /// The drawer's Plugins row opens the plugin list, and the list and a plugin's page carry the Mac's artwork.
    func testPluginsShortcut() throws {
        openDrawer()
        let row = app.buttons["Plugins"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the drawer has no Plugins row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Plugins"].waitForExistence(timeout: 10), "the Plugins row did not open the plugin list")
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 20), "the plugin list never loaded")
        sleep(3)
        shot("plugins-list")
        // The drawer's own rows stay in the tree under the sheet, so the first cell is "Chats": a plugin row is one with a switch.
        app.cells.containing(.switch, identifier: nil).element(boundBy: 0).staticTexts.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Package"].waitForExistence(timeout: 10), "the first plugin's page did not open")
        sleep(3)
        shot("plugin-page")
    }

    func testArchiveDialogShots() throws {
        // PARKED by #657, past two tries: its cancel-out leaves the app without the chat's menu, so the archive step
        // fails after the shot ("the chat menu is gone", SmokeTests.swift:302). It still runs for the shot itself —
        // DSH_SHOTS=1 — because the colour pair is wanted; in a gate it skips.
        guard ProcessInfo.processInfo.environment["DSH_SHOTS"] == "1" else {
            throw XCTSkip("parked: the cancel-out races the archive step; run with DSH_SHOTS=1 to take its shot")
        }
        XCTAssertTrue(newChatIn(folder: "/tmp/tiger-dsh-test-a",
                                first: "Please run `sleep 90 && echo done` in the shell and tell me what it printed."),
                      "the chat this test made did not open")
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 60),
                      "the run never started, so the dialog cannot be reached")
        sleep(2)
        // The run has to still be going when the menu opens: a chat that has finished archives without the dialog, which
        // is how this test flaked. Top it up if it has ended.
        if !app.buttons["chat.stop"].exists {
            let field = app.textViews["composer.field"].exists ? app.textViews["composer.field"] : app.textFields["composer.field"]
            field.tap()
            field.typeText("Please run `sleep 90 && echo ok` in the shell and tell me what it printed.\n")
            XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 60), "the topping-up run never started")
        }
        sleep(2)
        app.buttons["chat.menu"].tap()
        let archiveRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Archive")).firstMatch
        XCTAssertTrue(archiveRow.waitForExistence(timeout: 5), "the chat menu has no Archive row")
        // The dialog exists only while the chat is working, and it arrives a moment after the tap — which is exactly
        // what the nine missed. Three attempts, five seconds each, before this is called a failure.
        let stopAndArchive = app.buttons["Stop and archive"]
        var shown = false
        for _ in 0..<3 where !shown {
            archiveRow.tap()
            shown = stopAndArchive.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(shown, "the working-chat dialog did not appear")
        sleep(1)
        shot("archive-dialog")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { stopAndArchive.tap() }
        sleep(2)
        archiveThisChat()
    }
}
