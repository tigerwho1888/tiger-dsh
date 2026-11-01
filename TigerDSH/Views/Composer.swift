import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// What the chat needs: a question waiting for an answer, queued messages and
/// the task count. These sit at the TOP of the chat, so the bottom of the screen holds only the message field —
/// which is what the operator asked for on 2026-10-06 after the dock grew three status cards above the composer.
// No working bar with a timer: like Claude for iOS, a running chat shows only the composer's stop button
// (operator, 2026-10-13).
struct ChatTopStatus: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel
    @Binding var sheet: ChatSheet?

    var body: some View {
        VStack(spacing: 6) {
            ConnBanner()
            // Keyed by the question, so a new one starts with nothing picked: a reused dock carried the last answers over.
            if let q = liveQuestions.first { QuestionDock(question: q, chat: chat).id(q.id) }
            QueueCards(chat: chat)
            if !chat.todos.isEmpty {
                let done = chat.todos.filter { $0["status"].str == "completed" }.count
                HStack(spacing: 8) {
                    Button { sheet = .todos } label: {
                        Label("\(done)/\(chat.todos.count) tasks", systemImage: "checklist").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .panelChrome(14)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Tok.sp4)
        .padding(.bottom, 6)
        .frame(maxWidth: Tok.readingColumn)
        .frame(maxWidth: .infinity)
    }

    struct LiveQuestion: Identifiable { let id: String; let callId: String?; let eventId: String?; let questions: [JSON] }

    var liveQuestions: [LiveQuestion] {
        var out: [LiveQuestion] = []
        var seen = Set<String>()
        for q in chat.proj["userQuestions"]?["active"].array ?? [] where q["state"].str != "continued" {
            out.append(LiveQuestion(id: q["callId"].str, callId: q["callId"].str, eventId: nil, questions: q["questions"].array))
            seen.insert(q["callId"].str)
        }
        for (eid, f) in app.waterQuestions {
            let w = f["request"]["wait"]
            guard f["agentId"].str == chat.sid, !(w["callId"].string.map(seen.contains) ?? false) else { continue }
            out.append(LiveQuestion(id: w["callId"].string ?? eid, callId: w["callId"].string, eventId: eid, questions: f["request"]["questions"].array))
        }
        return out
    }
}

/// The policy line, as a band of its own above the transcript (Codex R11 P2).
///
/// It used to be the first line of `ChatTopStatus`, which is an OVERLAY on the scroll view: the caption was drawn
/// over the conversation, and the reference's own screenshot shows the transcript's first line starting below it,
/// not behind it (`.tmp/oct9/chat.png`). In the restored chat the transcript text crossed behind the words
/// (`.tmp/look-r12/chat.png`).
///
/// The band is reserved whether or not there is a policy to show — the transcript does not move when a chat's
/// policy changes — and its height is scaled, so larger text pushes the conversation down instead of running under
/// it. Its condition is the chat's own, not the run's: the reference shows the line in both Oct 9 screenshots,
/// including the empty chat, where nothing is running at all.
struct ChatPolicyBand: View {
    @Environment(\.colorScheme) private var scheme
    let chat: ChatModel
    /// The reference's line, plus a little breathing room either side.
    @ScaledMetric(relativeTo: .caption2) private var bandHeight: CGFloat = 22

    var body: some View {
        Text(chat.autoApproved ? "auto-approved · yolo mode" : "")
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: bandHeight)
            // Opaque, and the same canvas the transcript is set on: nothing shows through it, and it is a band
            // rather than a floating label — the shape the reference has.
            .background(Tok.canvas(scheme))
            .accessibilityHidden(!chat.autoApproved)
    }
}

struct ArchivedBar: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Label("This chat is archived", systemImage: "archivebox").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button {
                busy = true
                Task {
                    if await app.setArchived(chat.id, false) == nil { app.archived.remove(chat.id) }
                    busy = false
                }
            } label: {
                if busy { ProgressView().controlSize(.small) } else { Text("Restore").font(.subheadline.weight(.semibold)) }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
            .disabled(busy)
            .accessibilityIdentifier("chat.restore")
        }
        .padding(.horizontal, Tok.sp3).padding(.vertical, Tok.sp2)
        .panelChrome(Tok.rCard)
        .padding(.bottom, 6)
    }
}

struct BottomDock: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel
    /// The chat's sheet state: the composer's model pill opens the model sheet from here (this is the argument the
    /// recovered call sites passed and the reconstruction had dropped).
    @Binding var sheet: ChatSheet?
    var onSend: () -> Void

    var body: some View {
        glassGroup {
            VStack(spacing: 8) {
                if chat.readOnly {
                    Text("This subagent is read-only.").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                } else if app.archived.contains(chat.id) {
                    // The host silently drops a message sent to an archived chat, so the field is replaced rather
                    // than left to swallow it (operator, 2026-10-13).
                    ArchivedBar(chat: chat)
                } else {
                    Composer(chat: chat, sheet: $sheet, onSend: onSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .frame(maxWidth: Tok.readingColumn)
            .frame(maxWidth: .infinity)
        }
        .modifier(LegacyBarFill())
    }
}

struct QueueCards: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let chat: ChatModel
    @State private var editing: JSON?
    @State private var editText = ""

    /// The queued messages this card draws, in order, with the kind that decides whether each one is steerable: the
    /// user's own messages waiting in `next-turn` and `next-step`, and nothing else. The body draws exactly this
    /// list, and keeping the choice in one place is what lets a unit test assert the render condition without a live
    /// accessibility tree — SwiftUI builds its accessibility nodes only when a client asks, which is why the
    /// identifier cannot be read off a hosted hierarchy (the screen half stays in the UI smoke test).
    static func cards(_ chat: ChatModel) -> [(item: JSON, kind: String)] {
        let inbox = chat.proj["inbox"] ?? .null
        return (inbox["next-turn"].array.map { ($0, "next-turn") } + inbox["next-step"].array.map { ($0, "next-step") })
            .filter { $0.0["source"]["kind"].str == "user" }
    }

    /// Send now steers the turn that is running, so it is offered on a `next-turn` card while the chat is running
    /// and nowhere else: a `next-step` message has no running turn to steer and an idle chat has nothing to steer.
    static func offersSendNow(_ kind: String, running: Bool) -> Bool { kind == "next-turn" && running }

    var body: some View {
        let items = Self.cards(chat)
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { _, x in
                    let m = x.item
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(.secondary).frame(minHeight: 44)
                        // The prefix is a label, not part of the message: a queued message that already says
                        // "Queued" in its own words does not get a second one in front of it.
                        let msg = ChatModel.plainText(m["content"])
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg.localizedCaseInsensitiveContains("queued") ? msg : "Queued · " + msg)
                                .font(.footnote).lineLimit(2)
                                .frame(minHeight: 44, alignment: .leading)
                            // Send now sits under the message, the way the Claude app lays out a queued message
                            // (operator, 2026-10-15): a pill the thumb finds, not a line inside the menu. The accent
                            // marks the action; the fill stays the token surface so it sits in the card.
                            if Self.offersSendNow(x.kind, running: chat.running) {
                                Button { act("steer", m) } label: {
                                    Label("Send now", systemImage: "paperplane.fill")
                                        .font(Tok.chip)
                                        .padding(.horizontal, Tok.sp3).frame(minHeight: 32)
                                        .background(Tok.surface(scheme), in: Capsule())
                                        .overlay { Capsule().stroke(Tok.hairline(scheme)) }
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableStyle())
                                .foregroundStyle(Tok.actionTint(scheme))
                                .accessibilityIdentifier("queue.sendnow")
                            }
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button { editText = ChatModel.plainText(m["content"]); editing = m } label: { Label("Edit", systemImage: "pencil") }
                            if Self.offersSendNow(x.kind, running: chat.running) { Button { act("steer", m) } label: { Label("Send now", systemImage: "paperplane") } }
                            Button(role: .destructive) { act("remove", m) } label: { Label("Remove", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.body)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .panelChrome(Tok.rCard)
                }
            }
            .alert("Edit queued message", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Message", text: $editText, axis: .vertical)
                Button("Cancel", role: .cancel) { editing = nil }
                Button("Save") {
                    if let m = editing, !editText.trimmingCharacters(in: .whitespaces).isEmpty {
                        // Only the text is edited here: the queued item's images and files ride along unchanged.
                        let t = editText
                        let content = JSON.array([["type": "text", "text": .string(t)]] + m["content"].array.filter { $0["type"].str != "text" })
                        // A refused edit reopens the editor with the reader's text, instead of losing it to the old one.
                        Task { do { try await DSHClient.shared.rpc("session/updateQueue", ["request": ["sessionId": .string(chat.sid), "itemId": m["id"], "action": ["kind": "edit", "content": content]]]) } catch { app.say(error.localizedDescription); editText = t; editing = m } }
                    }
                    editing = nil
                }
            }
        }
    }

    private func act(_ kind: String, _ m: JSON) {
        Task { do { try await DSHClient.shared.rpc("session/updateQueue", ["request": ["sessionId": .string(chat.sid), "itemId": m["id"], "action": ["kind": .string(kind)]]]) } catch { app.say(error.localizedDescription) } }
    }
}

struct QuestionDock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let question: ChatTopStatus.LiveQuestion
    let chat: ChatModel
    @State private var selected: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]
    @State private var cannot = false
    @State private var sending = false

    /// The dock's own corner radius, shared with the two buttons so the row cannot drift from the card it sits in.
    private static let rDock: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs your answer", systemImage: "questionmark.bubble.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(question.questions.indices, id: \.self) { qi in
                        let q = question.questions[qi]
                        let qid = q["id"].string ?? "\(qi)"
                        let multi = q["multiSelect"].truthy || q["multiple"].truthy
                        VStack(alignment: .leading, spacing: 6) {
                            if let h = q["header"].string { Text(h.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                            Text(q["question"].str).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            if let d = q["detail"].string { Text(d).font(.footnote).foregroundStyle(.secondary) }
                            ForEach(q["options"].array.indices, id: \.self) { oi in
                                let o = q["options"].array[oi]
                                let on = selected[qid, default: []].contains(o["label"].str)
                                Button {
                                    var s = selected[qid, default: []]
                                    if on { s.removeAll { $0 == o["label"].str } } else { if multi { s.append(o["label"].str) } else { s = [o["label"].str] } }
                                    selected[qid] = s
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(o["label"].str).font(.subheadline.weight(.medium))
                                            if let d = o["description"].string { Text(d).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                                    }
                                    .padding(10)
                                    .background(on ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            TextField("Other answer", text: Binding(get: { custom[qid] ?? "" }, set: { custom[qid] = $0 }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack(spacing: Tok.sp2) {
                Button {
                    Task { await send() }
                } label: {
                    HStack { Spacer(); if sending { ProgressView() } else { Text("Send answer").bold() }; Spacer() }.frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Self.rDock))
                .tint(Tok.actionTint(scheme))
                .accessibilityIdentifier("question.send")

                // The way out the card never had. The host reads an empty `selected` with no `custom` as the user
                // having explicitly skipped the question, so Skip answers every one of them that way. It wears the
                // dock's own radius and type in the secondary weight, so the row reads as one control and its
                // quieter half rather than two competing calls to action.
                Button {
                    Task { await send(skipAll: true) }
                } label: {
                    Text("Skip").font(.body.weight(.semibold)).frame(minHeight: 44).padding(.horizontal, Tok.sp4)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: Self.rDock))
                .tint(Tok.actionTint(scheme))
                .accessibilityIdentifier("question.skip")
            }
            .disabled(sending)
        }
        .padding(14)
        .panelChrome(Self.rDock)
        .alert("Cannot answer here", isPresented: $cannot) {
            Button("Stop the run", role: .destructive) { Task { await chat.stop() } }
            Button("OK", role: .cancel) {}
        } message: { Text("This question was asked while the app was closed, so the phone can no longer answer it. Answer it on the Mac, or stop the run.") }
    }

    /// The answers the host is sent, one per question, in the order they were asked — a pure function, so the shape
    /// the host contract requires can be asserted without a live dock.
    ///
    /// A question with nothing picked and nothing typed is not a refusal: `dsh-tool-ask-user` reads `selected: []`
    /// with no `custom` as "the user explicitly skipped this question". `skipAll` answers every question that way,
    /// and a partial answer sends the questions the reader left alone as skips.
    static func answers(questions: [JSON], selected: [String: [String]], custom: [String: String], skipAll: Bool = false) -> [JSON] {
        questions.enumerated().map { qi, q in
            let qid = q["id"].string ?? "\(qi)"
            let picked = skipAll ? [] : selected[qid, default: []]
            let text = skipAll ? "" : (custom[qid] ?? "").trimmingCharacters(in: .whitespaces)
            return .obj([("id", q["id"]), ("selected", .array(picked.map { .string($0) })), ("custom", text.isEmpty ? nil : .string(text))])
        }
    }

    private func send(skipAll: Bool = false) async {
        let answers = Self.answers(questions: question.questions, selected: selected, custom: custom, skipAll: skipAll)
        // One answered question is enough to send; the questions left alone travel as skips. Only a dock where
        // nothing at all was picked or typed has nothing to send.
        if !skipAll && !answers.contains(where: { !$0["selected"].array.isEmpty || !$0["custom"].isNull }) {
            app.say("Pick an answer, or tap Skip")
            return
        }
        sending = true
        defer { sending = false }
        let said = skipAll ? "Skipped" : "Answer sent"
        if let eid = question.eventId {
            // A refused send already said why; only an answer that left the phone is announced as sent.
            if await app.answerWaterfallQuestion(eventId: eid, answers: .array(answers)) { app.say(said) }
            return
        }
        do {
            let ok = try await DSHClient.shared.rpc("userQuestions/answer", ["agentId": .string(chat.sid), "callId": .str(question.callId), "answer": ["answers": .array(answers)]])
            if ok.bool == false { cannot = true } else {
                // The answer is the phone's own, so the host sends no cancel for it: the request has to leave the
                // app's own list here, or the island goes on saying "Waiting for your answer" after it was given.
                app.questionAnswered(sid: chat.sid, callId: question.callId)
                app.say(said)
            }
        } catch { app.say(error.localizedDescription) }
    }
}

// MARK: the composer's controls, in whichever shape fits

/// The controls that act on the message, as ONE view with two arrangements: a single row when they fit the box's
/// width, and a stacked pair when they do not. `Composer` picks between them with `ViewThatFits`, so the choice is
/// made from the real proposed width rather than from a guess about the device.
///
/// Why it exists (Codex R11 P2): on the photographed 402 pt screen the row has about 338 pt after the box's own
/// margins and interior padding, and the four 44 pt targets, the model pill and the attachments have to share it.
/// The old row was a single `HStack` whose model pill carried `.fixedSize(horizontal: true, …)` — at a large text
/// size, or with a long model name and three attachments, it simply overflowed. The pill is allowed to shrink
/// within a cap now, and when even that does not fit, the model and the pictures move to a row of their own.
///
/// It owns no state: `mic` is the composer's recorder, the sheet and picker bindings are the composer's, and the
/// two actions close over the composer's own `send()`. That is what lets the two arrangements be the same view.
struct ComposerControls: View {
    @Bindable var chat: ChatModel
    @Binding var sheet: ChatSheet?
    @Binding var attachments: [Attachment]
    let mic: MicRecorder
    let stopMode: Bool
    let canSend: Bool
    let discInk: Color
    let discFill: Color
    /// The composer's stop-tap count: the haptic's trigger, changed on the tap and on nothing else.
    let stopTaps: Int
    /// The app, passed in rather than read from the environment: dictation is the only thing these controls need
    /// it for, and a view that owns its input can be laid out and measured without the whole app around it.
    let app: AppModel
    /// Whether this Mac offers dictation at all: `app.speech`, read by the composer.
    let hasSpeech: Bool
    @Binding var showPhotos: Bool
    @Binding var showFiles: Bool
    @Binding var showCamera: Bool
    let send: () -> Void
    /// The composer's saved messages (JSON). A binding, not storage of its own: the composer lifts `rowLayout` and
    /// `stackedLayout` out of this view, which is never mounted, so storage here would never redraw the menu.
    @Binding var savedRaw: String

    var body: some View { rowLayout }

    /// One row: the + and its pictures on the left, everything that acts on the message on the right, where a
    /// thumb reaches it. `ViewThatFits` measures this arrangement first, and it is measured at its OWN width —
    /// `fixedSize` is what makes "does it fit" mean the row's real width rather than the smallest width its
    /// flexible pieces can be squeezed into. Without it the pill simply truncated, the row always "fitted", and
    /// the fallback below was never reached.
    var rowLayout: some View {
        HStack(alignment: .center, spacing: 4) {
            attach
            model
            pictures
            Spacer(minLength: 0)
            actions
        }
    }

    /// Two rows, for a width the single row cannot hold: the model and the pictures get the width they need, and
    /// every action keeps its 44 pt target on a line of its own.
    var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 4) {
                model
                pictures
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 4) {
                attach
                Spacer(minLength: 0)
                actions
            }
        }
    }

    /// The four controls that act on the message: 44 pt targets on one centre line (C3). The row is
    /// centre-aligned, so equal heights are what put their centres on that line.
    private var actions: some View {
        HStack(alignment: .center, spacing: 4) {
            // Dictation appends to whatever is already typed, so the mic stays put: hiding it as soon as there is a
            // draft or a picture is how the operator found voice input missing.
            if hasSpeech {
                Button { Task { await mic.start(app: app, chat: chat) } } label: {
                    Image(systemName: "mic").font(.system(size: 17, weight: .medium))
                        .frame(width: 40, height: 40).background(Tok.controlFill, in: Circle())
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.primary)
                .disabled(mic.phase != .idle)
                .accessibilityIdentifier("composer.mic")
                .accessibilityLabel("Dictate")
            }
            ContextRing(chat: chat)
            Button {
                // One control, two jobs: with nothing to send it stops the run, and with a message typed it sends
                // (or queues, while the chat is working). The composer's own `send` decides which.
                send()
            } label: {
                // The disc is the inverse pair — ink on paper, paper on ink — so the one solid control on the screen
                // reads at a glance: a 17 pt bold arrow in a 30 pt circle inside the 44 pt target. Nothing is padded
                // on one side only: the 3 pt bottom pad this had lifted the disc 2 pt off the row's centre line,
                // which is what testComposerAlignment measures at 0.5 pt.
                Image(systemName: stopMode ? "stop.fill" : "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(discInk)
                    .frame(width: 40, height: 40)
                    .background(discFill, in: Circle())
                    .opacity(canSend ? 1 : (stopMode ? 1 : 0.48))
                    .animation(.easeInOut(duration: 0.18), value: stopMode)
                    .frame(width: 44, height: 44)
            }
            .disabled(!canSend && !stopMode)
            .accessibilityIdentifier(stopMode ? "chat.stop" : "composer.send")
            .accessibilityLabel(stopMode ? "Stop" : "Send")
            // Stopping is immediate and answers the touch with the light haptic the app's decisive controls share.
            // The trigger is the tap itself (Codex R11 P3): `stopMode` also flips when a run starts or ends and when
            // the draft becomes empty, so typing or a run update used to fire a "stop" haptic of its own.
            .sensoryFeedback(.impact(weight: .light), trigger: stopTaps)
        }
    }

    private var attach: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") } }
            Button { showFiles = true } label: { Label("Choose File", systemImage: "folder") }
            savedPrompts
        } label: {
            Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40).background(Tok.controlFill, in: Circle())
                .frame(width: 44, height: 44)
        }
        // The tint belongs on the Menu itself: a tint on the label inside it is what made the plus blue.
        .tint(Color.primary)
        .accessibilityIdentifier("composer.attach")
        .accessibilityLabel("Add attachment")
    }

    /// Messages worth typing once: the field's words saved under the +, and any of them put back in the field with
    /// a tap — added after what is already there rather than over it.
    private var saved: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(savedRaw.utf8))) ?? [] }
        nonmutating set { savedRaw = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]" }
    }

    @ViewBuilder private var savedPrompts: some View {
        let draft = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = saved
        if !draft.isEmpty || !list.isEmpty {
            Menu {
                if !draft.isEmpty, !list.contains(draft) {
                    Button { saved = Array(([draft] + list).prefix(20)) } label: { Label("Save This Message", systemImage: "bookmark") }
                }
                ForEach(list, id: \.self) { p in
                    Button(Self.title(p)) {
                        chat.draft = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? p : chat.draft + "\n" + p
                        chat.saveDraft()
                    }
                }
                if !list.isEmpty {
                    Menu {
                        ForEach(list, id: \.self) { p in
                            Button(Self.title(p), role: .destructive) { saved = saved.filter { $0 != p } }
                        }
                    } label: { Label("Remove", systemImage: "trash") }
                }
            } label: { Label("Saved Messages", systemImage: "bookmark") }
            .accessibilityIdentifier("composer.saved")
        }
    }

    /// A saved message's first line, short enough for a menu row.
    nonisolated static func title(_ p: String) -> String {
        let line = p.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? p
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    /// The model the chat is running on, where the reader decides it. The pill hugs its words and truncates only
    /// past the cap (#577, #580: it used to stretch from the + to the mic), and it names the model the way #571
    /// asked — the short name in primary ink, the effort in secondary, no bullet between them. Tapping it opens
    /// the model sheet.
    ///
    /// It is allowed to SHRINK inside that cap rather than being fixed to its intrinsic width: a fixed pill is what
    /// made the single row overflow instead of falling back to the stacked one.
    private var model: some View {
        Button { sheet = .model } label: {
            HStack(spacing: 5) {
                Text(chat.model?.short ?? "Model").foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                    // The cap belongs on the name, and `fixedSize` keeps the frame at the name's own width: without it
                    // the frame took all 120 pt and left a gap between the name and the effort.
                    .frame(maxWidth: 120, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                if let effort = chat.model?.effort, !effort.isEmpty {
                    Text(effort).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 14).frame(height: 40)
            // The same quiet fill as the + and the mic, so the row reads as one family of round controls.
            .background(Tok.controlFill, in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("composer.model")
        .accessibilityLabel("Model")
        // The label alone replaced the model and the effort a VoiceOver reader could otherwise hear (review 4, P3):
        // the value is what `label` renders — the short name and the effort (#571).
        .accessibilityValue(chat.model?.label ?? "Not selected")
    }

    /// A pasted picture rides inside the field's own chrome, at the height the bar already has: it belongs with the
    /// message, and a row of chips above the bar pushed the bar up.
    @ViewBuilder private var pictures: some View {
        if !attachments.isEmpty {
            HStack(spacing: 6) {
                ForEach(attachments.prefix(3)) { a in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if a.isImage, let ui = UIImage(data: a.data) {
                                Image(uiImage: ui).resizable().scaledToFill()
                            } else {
                                Image(systemName: "doc").font(.system(size: 15)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)) }
                        Button { attachments.removeAll { $0.id == a.id } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                                // A bigger target for the finger, 24 pt for the layout: the padding widens the hit
                                // shape and the negative padding gives the space back, so the 30 pt thumbnails keep
                                // their size. Not to the right: that side is the mic's (Codex r49).
                                .frame(width: 24, height: 24)
                                .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 0))
                                .contentShape(Rectangle())
                                .padding(EdgeInsets(top: -10, leading: -10, bottom: -10, trailing: 0))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 8, y: -8)
                        .accessibilityLabel("Remove \(a.name)")
                    }
                }
                if attachments.count > 3 {
                    // The ones past the third have no thumbnail of their own: the count opens a list of them all, each
                    // one removable (Codex r60).
                    Menu {
                        ForEach(attachments) { a in
                            Button(role: .destructive) { attachments.removeAll { $0.id == a.id } } label: {
                                Label("Remove \(a.name)", systemImage: a.isImage ? "photo" : "doc")
                            }
                        }
                    } label: {
                        Text("+\(attachments.count - 3)").font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 30, minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(attachments.count - 3) more attachments")
                }
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: composer

struct Composer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Bindable var chat: ChatModel
    /// The chat's sheet state, for the model pill.
    @Binding var sheet: ChatSheet?
    var onSend: () -> Void
    /// The composer is rebuilt for every chat, so a photo picked here and not yet sent would vanish on a trip to
    /// another chat while the typed text, kept on disk, came back: the attachments live in the app, per chat, and a
    /// photo that finishes loading after the reader left still lands in the chat it was picked for.
    private var attachments: [Attachment] {
        get { app.draftAttachments[chat.sid] ?? [] }
        nonmutating set { app.draftAttachments[chat.sid] = newValue.isEmpty ? nil : newValue }
    }
    private var attachmentsBinding: Binding<[Attachment]> { Binding(get: { attachments }, set: { attachments = $0 }) }
    /// Messages the reader saved to send again, newest first, as JSON: kept on this phone only.
    @AppStorage("composer.savedPrompts") private var savedPrompts = "[]"
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var suggestions: [Suggestion] = []
    @State private var suggestTask: Task<Void, Never>?
    @State private var commands: [JSON]?
    @State private var skills: [JSON]?
    @State private var mic = MicRecorder()
    @State private var focused = false

    struct Suggestion: Identifiable { let id = UUID(); let insert: String; let title: String; let sub: String }

    var body: some View {
        VStack(spacing: 4) {
            if !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { s in
                            Button { pick(s) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    if !s.sub.isEmpty { Text(s.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
                .panelChrome(14)
            }
            if mic.phase != .idle { MicBar(mic: mic, chat: chat) }
            // C3's two rows: the message on top, then the controls that act on it, on one centre line. The
            // reconstruction had them in ONE row, and that is what let the model pill squeeze the field to 29 pt in
            // t4's testQueuePill: the text wrapped on every keystroke, the dock grew and shrank under the reader, and
            // the typing was lost to a "Modifying state during view update" re-entry — the draft never took, so the
            // message was never sent, let alone queued.
            VStack(alignment: .leading, spacing: 0) {
                // A UIKit text view (MessageField): the return key sends, the field grows over several lines, and a
                // screenshot pasted the iOS way — long-press, Paste — becomes an attachment.
                MessageField(text: $chat.draft, focused: $focused, placeholder: placeholder,
                             onSend: { if canSend { send() } },
                             onImage: { img in
                                 if let d = img.jpegData(compressionQuality: 0.9), let a = Self.imageAttachment(d, name: "Pasted.jpg") {
                                     attachments.append(a)
                                 }
                             })
                    .padding(.vertical, 8).padding(.leading, 14)
                    .overlay(alignment: .topLeading) {
                        // The placeholder follows the field's own rule: whitespace-only counts as empty, and a running
                        // chat asks for the queue instead of a new message.
                        if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(placeholder).foregroundStyle(.secondary)
                                .padding(.top, 10).padding(.leading, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: chat.draft) { _, _ in chat.saveDraft(); checkSuggest() }
                // C3's two rows, and one more when they cannot fit (Codex R11 P2): `ViewThatFits` measures the
                // single row against the box's real width and falls back to the stacked one when the model name,
                // the effort, the attachments and four 44 pt targets cannot share it — a narrow phone, or the
                // reader's own text size. Both carry every action.
                ViewThatFits(in: .horizontal) {
                    ComposerControls(chat: chat, sheet: $sheet, attachments: attachmentsBinding, mic: mic,
                                     stopMode: stopMode, canSend: canSend, discInk: discInk, discFill: discFill,
                                     stopTaps: stopTaps, app: app, hasSpeech: app.speech != nil,
                                     showPhotos: $showPhotos, showFiles: $showFiles, showCamera: $showCamera,
                                     send: { tapSend() }, savedRaw: $savedPrompts)
                        .rowLayout
                    ComposerControls(chat: chat, sheet: $sheet, attachments: attachmentsBinding, mic: mic,
                                     stopMode: stopMode, canSend: canSend, discInk: discInk, discFill: discFill,
                                     stopTaps: stopTaps, app: app, hasSpeech: app.speech != nil,
                                     showPhotos: $showPhotos, showFiles: $showFiles, showCamera: $showCamera,
                                     send: { tapSend() }, savedRaw: $savedPrompts)
                        .stackedLayout
                }
            }
            // One floating card with a margin on every side, the way the reference holds its composer, instead of a
            // full-width bar glued to the keyboard. The box's own padding is inside the chrome, so the hairline
            // wraps the whole two-row control.
            .padding(4)
            .composerFieldChrome()
            .padding(.horizontal, Tok.sp4)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let sid = chat.sid
            Task {
                var failed = 0
                for it in items {
                    if let d = try? await it.loadTransferable(type: Data.self), let a = Self.imageAttachment(d, name: "Photo.jpg") {
                        app.draftAttachments[sid, default: []].append(a)
                    }
                    else { failed += 1 }
                }
                photoItems = []
                if failed > 0 { app.say(failed == 1 ? "1 photo could not be added" : "\(failed) photos could not be added") }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else {
                if case .failure(let e) = r { app.say(e.localizedDescription) }
                return
            }
            var failed: [String] = []
            defer { if !failed.isEmpty { app.say("Could not add " + failed.joined(separator: ", ")) } }
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                // Sized before it is read: the whole file is loaded into memory here, and a huge one froze or ended the
                // app (Codex r162). 100 MB stays well inside the host's 300 MiB request limit once encoded (r163).
                if let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 100_000_000 {
                    failed.append(u.lastPathComponent + " (over 100 MB)"); continue
                }
                guard let d = try? Data(contentsOf: u) else { failed.append(u.lastPathComponent); continue }
                let type = UTType(filenameExtension: u.pathExtension)
                if type?.conforms(to: .image) == true, let a = Self.imageAttachment(d, name: u.lastPathComponent) { attachments.append(a) }
                else { attachments.append(Attachment(name: u.lastPathComponent, mediaType: type?.preferredMIMEType ?? "application/octet-stream", data: d)) }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in if let d = img.jpegData(compressionQuality: 0.9) { attachments.append(Attachment(name: "Photo.jpg", mediaType: "image/jpeg", data: d)) } }
                .ignoresSafeArea()
        }
        // A catalog that failed to load at launch (a hiccup, or a Mac that was still waking) used to leave the mic
        // missing until the app was relaunched; opening a chat asks again.
        // Keyed on the connection so a catalog that failed while the Mac was away is asked for again when it comes
        // back, without leaving and reopening the chat.
        .task(id: app.conn) { if app.conn == .live, app.speech == nil { await app.loadSpeech() } }
        // Leaving the chat with the bar still up would hold the audio session and the recorder; the reader is not
        // looking at either any more.
        .onDisappear { mic.cancel() }
        .sensoryFeedback(.impact(weight: .light), trigger: acceptedSends)
    }

    private var canSend: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    /// The send/stop disc's tap. The haptic is fired from HERE, on the tap, rather than from a `stopMode` change
    /// (Codex R11 P3): `stopMode` also flips when a run starts or ends and when the draft becomes empty, so typing
    /// or a run update fired a "stop" haptic of its own while the tap itself did not have to fire one at all.
    private func tapSend() {
        if stopMode {
            stopTaps += 1
            Task { await chat.stop() }
        } else {
            send()
        }
    }

    /// Handed to the controls, which fire the haptic on it.
    @State private var stopTaps = 0
    @State private var acceptedSends = 0
    /// A slash command waits on the Mac before the draft clears; a second tap in that gap would run it twice.
    @State private var commandBusy = false

    /// The idle placeholder, and the one a running chat shows instead: a message typed while the chat works is
    /// queued for after this turn, and the field says so.
    private var placeholder: String { chat.running ? "Queue for after this turn…" : "Message" }

    /// The send disc is the inverse of the canvas: ink on paper, paper on ink.
    private var discInk: Color { scheme == .dark ? Tok.ink : Tok.paper }
    private var discFill: Color { scheme == .dark ? Tok.paper : Tok.ink }

    /// Running with nothing to send: the disc becomes the stop square, at full opacity.
    private var stopMode: Bool { chat.running && !canSend }

    // MARK: image limits

    /// What this Mac accepts in one message. It arrives with the session's own projections, so the composer can
    /// refuse in plain words BEFORE anything is sent, instead of letting the Mac reject it after the reader pressed
    /// send. Missing limits mean no local check — the host stays the authority.
    private var limits: (count: Int, each: Int, total: Int, pixels: Int, side: Int)? {
        guard let l = chat.proj["imageLimits"], l.isObject else { return nil }
        // The fallbacks are this Mac's own numbers, read off its projections on 2026-10-07: they only apply if a
        // payload ever arrives without the block.
        return (l["maxImagesPerMessage"].int ?? 20, l["maxImageBytes"].int ?? 20_971_520,
                l["maxMessageImageBytes"].int ?? 209_715_200, l["maxImagePixels"].int ?? 64_000_000,
                l["maxImageDimension"].int ?? 8192)
    }

    /// The sentence to show instead of attaching, or nil when the image is fine.
    private func refusal(_ img: UIImage, bytes: Int) -> String? {
        guard let lim = limits else { return nil }
        let images = attachments.filter(\.isImage)
        if images.count >= lim.count { return "This Mac takes at most \(lim.count) images in one message." }
        if bytes > lim.each { return "That image is \(Fmt.bytes(Double(bytes))). This Mac takes up to \(Fmt.bytes(Double(lim.each))) each." }
        let total = images.reduce(0) { $0 + $1.data.count } + bytes
        if total > lim.total { return "Those images add up to more than this Mac takes in one message, \(Fmt.bytes(Double(lim.total)))." }
        let pixels = Int(img.size.width * img.size.height * img.scale * img.scale)
        if pixels > lim.pixels { return "That image is \(pixels / 1_000_000) megapixels. This Mac takes up to \(lim.pixels / 1_000_000)." }
        if max(img.size.width, img.size.height) > CGFloat(lim.side) { return "That image is longer than \(lim.side) pixels on a side." }
        return nil
    }

    /// One door for every picture that comes in — paste, library, file, camera — so the limits are checked once.
    private func addImage(_ img: UIImage, name: String) {
        guard let d = img.jpegData(compressionQuality: 0.9), let a = Self.imageAttachment(d, name: name) else {
            app.say("That picture could not be read.")
            return
        }
        if let no = refusal(img, bytes: a.data.count) { app.say(no); return }
        attachments.append(a)
    }

    /// HEIC and other formats become JPEG so the host accepts them; very large photos are scaled to 4096 px.
    static func imageAttachment(_ d: Data, name: String) -> Attachment? {
        guard let img = UIImage(data: d) else { return nil }
        let m = max(img.size.width, img.size.height)
        var out = img
        if m > 4096 {
            let s = 4096 / m
            let size = CGSize(width: img.size.width * s, height: img.size.height * s)
            // At scale 1: the default is the screen's, and a 3x phone drew a 12,288 px picture the host refuses (Codex r134).
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            out = UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        }
        guard let jpg = out.jpegData(compressionQuality: 0.9) else { return nil }
        let base = (name as NSString).deletingPathExtension
        return Attachment(name: base + ".jpg", mediaType: "image/jpeg", data: jpg)
    }

    private func send() {
        let text = chat.draft
        guard canSend, !commandBusy else { return }
        // Last look at the Mac's image limits before anything leaves the phone: they can change under a running
        // session, and a refusal here is a sentence instead of a failed send.
        if let lim = limits {
            let images = attachments.filter(\.isImage)
            let total = images.reduce(0) { $0 + $1.data.count }
            if images.count > lim.count { app.say("This Mac takes at most \(lim.count) images in one message."); return }
            if total > lim.total { app.say("Those images add up to more than this Mac takes in one message, \(Fmt.bytes(Double(lim.total)))."); return }
            if let big = images.first(where: { $0.data.count > lim.each }) {
                app.say("\(big.name) is \(Fmt.bytes(Double(big.data.count))). This Mac takes up to \(Fmt.bytes(Double(lim.each))) each.")
                return
            }
        }
        // Answer an accepted send once, after the checks that can refuse it.
        acceptedSends += 1
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty, chat.child.isEmpty, app.can("commands"),
           let m = trimmed.range(of: #"^/([\w-]+)"#, options: .regularExpression) {
            let name = String(trimmed[m].dropFirst())
            commandBusy = true
            Task {
                defer { commandBusy = false }
                // A lookup that fails keeps the draft and says so: falling through would send a real command to the
                // agent as an ordinary message. Only a list the Mac returned is kept.
                if commands == nil {
                    do { commands = try await DSHClient.shared.rpc("commands/list", ["agentId": .string(chat.sid)]).array }
                    catch { app.say(error.localizedDescription); return }
                }
                if commands?.contains(where: { $0["name"].str == name }) == true {
                    do {
                        let r = try await DSHClient.shared.rpc("commands/execute", ["agentId": .string(chat.sid), "line": .string(trimmed), "submittedAttachments": []])
                        // A command the Mac refused (`/permission invalid`) answers normally with kind "error": the
                        // line stays to be corrected instead of being typed again (Codex r174).
                        guard r["result"]["kind"].str != "error" else {
                            app.say(r["result"]["text"].string.map { String($0.prefix(160)) } ?? "Command failed"); return
                        }
                        // Cleared only once the Mac ran it, and only if the reader has not typed since: a failed
                        // command stays in the field to retry, and words typed while it ran are kept.
                        if chat.draft == text { chat.draft = ""; chat.saveDraft() }
                        let t = r["result"]["text"].string
                        app.say(t.map { String($0.prefix(160)) } ?? "Done")
                    } catch { app.say(error.localizedDescription) }
                } else { sendMessage(text) }
            }
            return
        }
        sendMessage(text)
    }

    private func sendMessage(_ text: String) {
        let att = attachments
        // Only clear what was sent: a slash command waits for the Mac before reaching here, and anything typed while
        // it waited has to survive. The cleared draft is written through, so the sent text cannot come back from the
        // saved draft the next time this chat is opened.
        if chat.draft == text { chat.draft = "" }
        chat.saveDraft()
        attachments = []; suggestions = []
        chat.send(text: text, attachments: att)
        onSend()
    }

    private func checkSuggest() {
        suggestTask?.cancel()
        let v = chat.draft
        let at = v.range(of: #"(^|\s)@([^\s@]*)$"#, options: .regularExpression)
        let sl = v.range(of: #"^/([\w-]*)$"#, options: .regularExpression)
        guard at != nil || sl != nil else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            var items: [Suggestion] = []
            if let sl {
                // A failed or cancelled lookup leaves the cache empty so the next keystroke asks again.
                if commands == nil && app.can("commands") { commands = (try? await DSHClient.shared.rpc("commands/list", ["agentId": .string(chat.sid)]))?.array }
                if skills == nil && app.can("skills") { skills = (try? await DSHClient.shared.rpc("skills/list", ["request": ["sessionId": .string(chat.sid)]]))?["skills"].array }
                let q = v[sl].dropFirst().lowercased()
                items = ((commands ?? []) + (skills ?? [])).filter { $0["name"].str.lowercased().hasPrefix(q) }.prefix(12)
                    .map { Suggestion(insert: "/" + $0["name"].str + " ", title: "/" + $0["name"].str, sub: $0["description"].str) }
            } else if let at, app.can("refs") {
                let q = String(v[at].drop { $0 != "@" }.dropFirst())
                async let f = try? await DSHClient.shared.rpc("fileReferences/list", ["agentId": .string(chat.sid), "query": .string(q)])
                async let s = try? await DSHClient.shared.rpc("sessionReferenceResolver/candidates", ["agentId": .string(chat.sid), "query": .string(q)])
                let (fr, sr) = await (f, s)
                items = (fr?.array ?? []).prefix(8).map { x in
                    let dir = x["kind"].str == "directory"
                    let p = x["path"].str
                    return Suggestion(insert: "@" + p + (dir && !p.hasSuffix("/") ? "/" : "") + " ", title: p, sub: dir ? "Folder" : "File")
                } + (sr?.array ?? []).prefix(5).map { Suggestion(insert: $0["mention"].str + " ", title: $0["displayTitle"].string ?? $0["label"].str, sub: "Chat") }
            }
            guard !Task.isCancelled else { return }
            suggestions = items
        }
    }

    private func pick(_ s: Suggestion) {
        chat.draft = chat.draft.replacingOccurrences(of: #"(^|\s)(@[^\s@]*|/[\w-]*)$"#, with: "$1" + NSRegularExpression.escapedTemplate(for: s.insert), options: .regularExpression)
        suggestions = []
        focused = true
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController(); p.sourceType = .camera; p.delegate = context.coordinator; return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(self) }
    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: voice input: DSH's own speech-to-text on the Mac (speech/transcribe), recorded as 16 kHz mono WAV

/// The Mac accepts exactly one shape of recording — RIFF/WAVE, a 16-byte `fmt ` chunk, PCM, one channel, 16 kHz,
/// 16-bit, and the `data` chunk immediately after it, with every length in the header matching the file exactly —
/// and it says so in as many words when anything differs. AVAudioRecorder's own file is not that shape: it writes
/// chunks of its own, and the microphone's rate is whatever the session gave it. So the recording is decoded and
/// rewritten here, with a header we build ourselves.
enum CanonicalWAV {
    static func data(from url: URL) -> Data? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let src = file.processingFormat
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: src, to: dst) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames),
              (try? file.read(into: inBuf)) != nil else { return nil }
        let outFrames = AVAudioFrameCount(Double(frames) * 16000 / max(1, src.sampleRate)) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outFrames) else { return nil }
        var supplied = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if supplied { outStatus.pointee = .endOfStream; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, outBuf.frameLength > 0, let ch = outBuf.int16ChannelData?[0] else { return nil }
        return wav(Data(bytes: ch, count: Int(outBuf.frameLength) * 2))
    }

    /// The 44-byte header, byte for byte the one the Mac's own validator checks.
    private static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)          // PCM
        u16(1)          // one channel
        u32(16000)      // sample rate
        u32(32000)      // byte rate
        u16(2)          // block align
        u16(16)         // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

@MainActor @Observable
final class MicRecorder {
    enum Phase { case idle, preparing, recording, transcribing, message }
    var phase: Phase = .idle
    var message = ""
    var level: Float = 0
    var started = Date()
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var maxSeconds = 120.0
    @ObservationIgnored private var maxBytes = 25_000_000
    @ObservationIgnored private var selection: JSON = [:]
    /// Bumped by every start and every cancel. An attempt that comes back from an await under a different number is
    /// no longer the attempt the reader is watching, and stops instead of starting the microphone behind their back.
    @ObservationIgnored private var attempt = 0
    /// The file this attempt is recording into, so its own cleanup can never touch another attempt's audio.
    @ObservationIgnored private var recordingURL: URL?

    /// Each attempt gets its own file. Two attempts overlap whenever one is cancelled during transcription and the
    /// reader starts another: with one shared `dictation.wav`, the older attempt's cleanup deleted the newer
    /// recording's audio out from under it.
    private func fileURL(_ mine: Int) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(mine).wav")
    }

    func start(app: AppModel, chat: ChatModel) async {
        guard phase == .idle else { return }
        // From here on every tap answers on screen: the bar says what it is doing, and every way out of this function
        // leaves a sentence behind. A tap that produced nothing at all was the worst thing this could do.
        //
        // `attempt` is what makes Cancel during "Preparing" mean it: the phase is set back to idle while this
        // function is suspended in one of the awaits below, so every resume checks that it is still the attempt the
        // reader is watching before it touches the microphone.
        attempt += 1
        let mine = attempt
        message = ""
        phase = .preparing
        await app.loadSpeech()
        guard mine == attempt else { return }
        guard let sp = app.speech else { fail("Voice input is not available on this Mac."); return }
        guard app.speechUsable else { app.showVoiceSetup = true; phase = .idle; return }
        maxSeconds = sp["maxDurationSeconds"].double ?? 120
        maxBytes = sp["maxAudioBytes"].int ?? 25_000_000
        selection = sp["selection"]
        // iOS answers the permission question once, and an unanswered prompt hangs this await for ever — the bar
        // would sit on "Preparing" with nothing to press. It is raced with a clock, and the request itself is asked
        // for OUTSIDE the group: a structured child that awaited it could never be cancelled, and withTaskGroup waits
        // for every child before it returns, so the clock could never win the race it was written for.
        let answer = PermissionAnswer()
        Task { answer.set(await AVAudioApplication.requestRecordPermission()) }
        let allowed: Bool? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { try? await Task.sleep(for: .seconds(25)); return nil }
            group.addTask {
                for _ in 0..<250 {
                    if let v = answer.value { return v }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard mine == attempt else { return }
        guard let allowed else {
            fail("iOS never answered the microphone question. Check Settings ▸ Privacy ▸ Microphone, then try again.")
            return
        }
        guard allowed else {
            fail("Microphone access is off for this app. Turn it on in Settings ▸ Privacy ▸ Microphone.")
            return
        }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let url = fileURL(mine)
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: maxSeconds) else {
                fail("The microphone is busy — another app may be using it. Close that app and try again.")
                return
            }
            recorder = r; recordingURL = url; started = Date(); phase = .recording
            meter = Task { @MainActor [weak self] in
                while let self, self.phase == .recording, !Task.isCancelled {
                    r.updateMeters()
                    self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
                    if !r.isRecording { await self.stop(app: app, chat: chat); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            fail("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    /// One place for a dead end to become a sentence the reader can act on.
    private func fail(_ text: String) { message = text; phase = .message }

    func stop(app: AppModel, chat: ChatModel) async {
        guard phase == .recording, let r = recorder, let url = recordingURL else {
            if phase == .preparing || phase == .recording { fail("The recording had already stopped.") }
            return
        }
        // The attempt this audio belongs to. The transcription outlives a cancel — leaving the chat cancels — so a
        // stale answer must not be written into the next attempt's draft, and its cleanup must not delete the next
        // attempt's file. Both are checked against this number.
        let mine = attempt
        r.stop(); meter?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .transcribing
        // Decoded and rewritten into the one shape the Mac accepts, rather than trusting the recorder's own file.
        guard let d = CanonicalWAV.data(from: url), d.count > 44 else {
            fail("That recording could not be read back. Try again.")
            return
        }
        if d.count > maxBytes { message = "That recording is too long to send."; phase = .message; return }
        do {
            var req = selection.object
            req["audioBase64"] = .string(d.base64EncodedString())
            let v = try await DSHClient.shared.rpc("speech/transcribe", ["request": .object(req)], timeout: 120)
            guard mine == attempt, phase == .transcribing else { return }
            let text = v["text"].str.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { fail("No speech was recognised in that recording. Try again, a little closer to the phone."); return }
            chat.draft = chat.draft.isEmpty ? text : chat.draft + (chat.draft.hasSuffix(" ") ? "" : " ") + text
            phase = .idle
            app.say("Review the text, then send")
        } catch {
            // A failure that belongs to a cancelled attempt is not the reader's failure to read either.
            guard mine == attempt else { return }
            fail("The Mac could not turn that recording into text: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: url)
        if mine == attempt { recordingURL = nil }
    }

    func cancel() {
        attempt += 1
        recorder?.stop(); recorder?.deleteRecording(); meter?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recordingURL = nil
        phase = .idle
    }
}

/// A one-shot answer written by one task and read by another. The microphone permission request cannot be cancelled,
/// so it is asked for outside the race and its answer is read from here.
private final class PermissionAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?
    func set(_ v: Bool) { lock.lock(); answer = v; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return answer }
}

/// The context ring: how full the chat's window is, and nothing at all until it is worth knowing — the reference
/// shows it only from 50% usage. 18 pt of ring, 3 pt of stroke, slate until 85% and orange past it, in a 44 pt
/// target so it can be tapped (it opens the same Context & usage sheet the chat's menu does).
struct ContextRing: View {
    let chat: ChatModel
    @Environment(\.colorScheme) private var scheme
    @State private var sheet: ChatSheet?

    private var used: Double { chat.proj["contextPressure"]?["pressureTokens"].double ?? chat.proj["contextTimeline"]?["current"]["total"].double ?? 0 }
    private var size: Double { chat.proj["contextPressure"]?["contextWindow"].double ?? chat.proj["contextTimeline"]?["contextWindow"].double ?? 0 }
    private var fraction: Double { size > 0 ? min(1, max(0, used / size)) : 0 }

    var body: some View {
        if fraction >= 0.5 {
            Button { sheet = .usage } label: {
                ZStack {
                    // The ring is an ACTION's tint, not a bubble's fill: at the dark canvas the slate measured
                    // about 1.5:1 and the ring was barely there (Codex R11 P2).
                    Circle().stroke(Tok.actionTint(scheme).opacity(0.22), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(fraction >= 0.85 ? Color.orange : Tok.actionTint(scheme), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.context")
            .accessibilityLabel("Context window")
            .accessibilityValue("\(Int(fraction * 100))% used")
            .sheet(item: $sheet) { s in ChatSheetView(sheet: s, chat: chat, present: $sheet).sheetCanvas() }
        }
    }
}

struct MicBar: View {
    @Environment(AppModel.self) private var app
    let mic: MicRecorder
    let chat: ChatModel
    var body: some View {
        HStack(spacing: 10) {
            switch mic.phase {
            case .recording:
                Circle().fill(Color.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(Fmt.clock(ctx.date.timeIntervalSince(mic.started))).monospacedDigit().font(.subheadline.weight(.semibold)) }
                GeometryReader { g in
                    Capsule().fill(Color.secondary.opacity(0.2)).overlay(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.7)).frame(width: g.size.width * CGFloat(mic.level))
                    }
                }
                .frame(height: 6)
                Button("Cancel") { mic.cancel() }
                Button("Done") { Task { await mic.stop(app: app, chat: chat) } }.bold()
            case .transcribing:
                ProgressView()
                Text("Turning speech into text…").font(.subheadline)
                Spacer()
            case .preparing:
                ProgressView()
                Text("Getting the microphone ready…").font(.subheadline)
                Spacer()
                Button("Cancel") { mic.cancel() }
            case .message:
                Text(mic.message).font(.subheadline)
                Spacer()
                Button("OK") { mic.phase = .idle }
            case .idle: EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .panelChrome(14)
    }
}
