import SwiftUI

/// Where a message sits inside its run of same-side messages. The corners and the gaps between bubbles follow from
/// it: two bubbles of the same side sit close and tighten the corner where they meet, and a group starts with the
/// quiet timestamp above it.
enum MessageGroup { case single, first, middle, last

    var startsGroup: Bool { self == .single || self == .first }
    var endsGroup: Bool { self == .single || self == .last }
}

struct ItemView: View {
    let item: ChatItem
    let chat: ChatModel
    let folds: FoldState
    @Binding var sheet: ChatSheet?
    var groupMembers: [ChatItem] = []
    var group: MessageGroup = .single

    var body: some View {
        switch item.kind {
        case .user: UserMessageView(item: item, chat: chat, sheet: $sheet, group: group)
        case .pending: PendingMessageView(item: item, chat: chat)
        case .assistant: AssistantMessageView(item: item, chat: chat, folds: folds, sheet: $sheet, live: false)
        case .live: AssistantMessageView(item: item, chat: chat, folds: folds, sheet: $sheet, live: true)
        case .group: ProcessGroupHeader(item: item, members: groupMembers, chat: chat, folds: folds)
        case .error: ErrorRow(item: item, chat: chat)
        case .note: NoteRow(text: item.text)
        case .retry: RetryRow(item: item, folds: folds)
        case .changes: ChangesChip(item: item, chat: chat, sheet: $sheet)
        case .workflow: WorkflowCard(item: item, chat: chat)
        case .deliverables: DeliverablesCard(item: item, sheet: $sheet)
        }
    }
}

// MARK: user

struct UserMessageView: View {
    let item: ChatItem
    let chat: ChatModel
    @Binding var sheet: ChatSheet?
    var group: MessageGroup = .single
    @Environment(AppModel.self) private var app
    @State private var unfolded = false

    var body: some View {
        let long = item.text.count > 700 || item.text.split(separator: "\n", omittingEmptySubsequences: false).count > 12
        VStack(alignment: .trailing, spacing: 4) {
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(long && !unfolded ? 10 : nil)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    // The reader's own side of the conversation: the one accent, and the corner toward it tightens
                    // where the next bubble of the same group follows.
                    .background(Tok.accent, in: BubbleShape(side: .trailing, group: group))
                    .contextMenu {
                        Button { UIPasteboard.general.string = item.text; app.say("Copied") } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { chat.quote(item.text) } label: { Label("Quote", systemImage: "text.quote") }
                        Button { sheet = .quote(item.text) } label: { Label("Quote part", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        if chat.child.isEmpty && app.can("fork") {
                            Button { sheet = .edit(item.key) } label: { Label("Edit and branch", systemImage: "pencil") }
                        }
                    }
            }
            if long {
                Button(unfolded ? "Show less" : "Show full prompt") { withAnimation(.snappy) { unfolded.toggle() } }
                    .font(.footnote.weight(.medium))
            }
            let att = Array(repeating: "Photo", count: item.images) + item.files
            if !att.isEmpty {
                Label(att.joined(separator: " · "), systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, (1 - Tok.bubbleWidth) * 320)
    }
}

/// A bubble's outline: the two corners on the bubble's own side tighten where another bubble of the same group
/// follows, which is what makes a run of messages read as one run.
struct BubbleShape: Shape {
    enum Side { case leading, trailing }
    let side: Side
    let group: MessageGroup

    func path(in rect: CGRect) -> Path {
        let big = Tok.rBubble, small = Tok.rBubbleTight
        let tightTop = !group.startsGroup
        let tightBottom = !group.endsGroup
        let tl = side == .leading ? (tightTop ? small : big) : big
        let bl = side == .leading ? (tightBottom ? small : big) : big
        let tr = side == .trailing ? (tightTop ? small : big) : big
        let br = side == .trailing ? (tightBottom ? small : big) : big
        return UnevenRoundedRectangle(topLeadingRadius: tl, bottomLeadingRadius: bl,
                                      bottomTrailingRadius: br, topTrailingRadius: tr,
                                      style: .continuous).path(in: rect)
    }
}

struct PendingMessageView: View {
    let item: ChatItem
    let chat: ChatModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(item.text.isEmpty ? "Attachment" : item.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(item.state == "failed" ? Color.red : Tok.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if item.state == "sending" {
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            } else if item.state == "failed" {
                HStack(spacing: 14) {
                    Text("Not sent").foregroundStyle(.red)
                    Button("Retry") { chat.retrySend(item.rpc) }
                    Button("Discard", role: .destructive) { chat.dropSend(item.rpc) }
                }
                .font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }
}

// MARK: assistant

struct AssistantMessageView: View {
    let item: ChatItem
    let chat: ChatModel
    let folds: FoldState
    @Binding var sheet: ChatSheet?
    let live: Bool
    @Environment(AppModel.self) private var app

    /// Consecutive tool calls fold into one chip; questions get their own card.
    enum Seg { case text(Int, String), think(Int, String), tools(Int, [Block]), question(Int, Block) }

    static func segments(_ blocks: [Block]) -> [Seg] {
        var out: [Seg] = []
        var tools: [Block] = []
        var toolStart = 0
        func flush() { if !tools.isEmpty { out.append(.tools(toolStart, tools)); tools = [] } }
        for (i, b) in blocks.enumerated() {
            switch b {
            case .tool(_, let name, _):
                if name == "ask_user_question" { flush(); out.append(.question(i, b)) } else { if tools.isEmpty { toolStart = i }; tools.append(b) }
            case .think(let t):
                flush(); if ChatModel.hasInk(t) { out.append(.think(i, t)) }
            case .text(let t):
                flush(); if ChatModel.hasInk(t) { out.append(.text(i, t)) }
            }
        }
        flush()
        return out
    }

    /// A live row's words come from the stream itself: the row list keeps only a snapshot, refreshed when the
    /// stream's shape changes, so only this view redraws on each streamed flush.
    private var blocks: [Block] { live ? (chat.stream ?? item.blocks) : item.blocks }

    var body: some View {
        let segs = Self.segments(blocks)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                switch s {
                case .text(_, let t):
                    if live { StreamingMarkdownView(text: t) } else { MarkdownView(text: t).equatable() }
                case .think(let i, let t):
                    // Keyed by the turn, not the item key: the item's own key changes from "live" to its final id
                    // when the reply finishes, and a Thinking fold the reader opened must not collapse then.
                    FoldRow(key: "t\(item.turn):k\(i)", icon: "brain", title: live ? "Thinking…" : "Thinking",
                            folds: folds, tint: Tok.think, live: live) {
                        Text(t).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                case .tools(let i, let tools):
                    // Keyed by the first tool call's id: the message's own key changes from "live" to its final id when
                    // the reply finishes, and a chip the reader opened must not collapse at that moment.
                    let cid: String = { if case .tool(let c, _, _) = tools[0] { return c }; return "\(item.key):t\(i)" }()
                    ToolGroupChip(key: "tool:" + cid, tools: tools, chat: chat, folds: folds)
                case .question(_, let b):
                    AnsweredQuestionCard(block: b, chat: chat, folds: folds, key: item.key)
                }
            }
        }
        // C2: the reply is plain text on the canvas. No bubble, no background, no border, no horizontal interior
        // padding and no trailing reservation — the reply column is the transcript's whole width, and the code tiles
        // and tables inside it keep their own surfaces on top of the canvas.
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The per-message action row is gone with the bubble; the actions live in the long-press menu, where the
        // reader already looks for them on their own messages.
        .contextMenu {
            if !live {
                let text = item.blocks.compactMap(\.text).joined(separator: "\n\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MessageActions(item: item, text: text, chat: chat, sheet: $sheet)
                }
            }
        }
    }
}

/// Three dots breathing in turn. Each is a `PulseDot`, so the breathing never moves with the row (operator video,
/// 2026-10-13) and costs the app nothing per frame.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                PulseDot(color: .secondary, low: 0.3, period: 0.6, delay: Double(i) * 0.2, animate: !reduceMotion)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }
}

struct MessageActions: View {
    let item: ChatItem
    let text: String
    let chat: ChatModel
    @Binding var sheet: ChatSheet?
    @Environment(AppModel.self) private var app

    var body: some View {
        let fb = chat.feedback[item.messageId]?["rating"].string
        HStack(spacing: 10) {
            Button { UIPasteboard.general.string = text; app.say("Copied") } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy")
                .tapTarget()
            // Straight to Messages, Notes or Mail, without the copy-and-switch round trip.
            ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
                .tapTarget()
            Button { chat.quote(text) } label: { Image(systemName: "text.quote") }
                .accessibilityLabel("Quote")
                .tapTarget()
            // Pick the lines to quote instead of the whole reply.
            Button { sheet = .quote(text) } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                .accessibilityLabel("Quote part")
                .tapTarget()
            if chat.child.isEmpty && chat.ends[item.turn] != nil && app.can("fork") {
                Button {
                    Task { if let seq = chat.ends[item.turn], let nid = await app.fork(chat.sid, atSeq: seq) { app.say("Branch started"); NotificationCenter.default.post(name: .openChat, object: nid) } }
                } label: { Image(systemName: "arrow.triangle.branch") }
                .accessibilityLabel("Branch from here")
                .tapTarget()
            }
            if app.can("feedback") && !item.messageId.isEmpty {
                Button { sheet = .feedback(item.messageId, "positive") } label: { Image(systemName: fb == "positive" ? "hand.thumbsup.fill" : "hand.thumbsup") }
                    .accessibilityLabel("Good")
                    .tapTarget()
                Button { sheet = .feedback(item.messageId, "negative") } label: { Image(systemName: fb == "negative" ? "hand.thumbsdown.fill" : "hand.thumbsdown") }
                    .accessibilityLabel("Bad")
                    .tapTarget()
            }
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }
}

extension Notification.Name { static let openChat = Notification.Name("openChat") }

struct FoldRow<Content: View>: View {
    let key: String
    let icon: String
    let title: String
    let folds: FoldState
    /// The row's own colour: reasoning is purple, tool rows orange, everything else quiet.
    var tint: Color? = nil
    /// Whether this row's work is still happening: a pulsing dot joins the glyph.
    var live: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let open = folds.open.contains(key)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { folds.toggle(key) }
            } label: {
                HStack(spacing: 6) {
                    if live { LiveDot() }
                    Image(systemName: icon).font(.footnote)
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint ?? .secondary)
                // A text-high row was a thin target between two paragraphs. The finger gets 10 pt more above and
                // below; the negative padding hands the layout back, so the transcript keeps its spacing.
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .padding(.vertical, -10)
            }
            .buttonStyle(PressableStyle())
            if open {
                content()
                    .lineLimit(nil)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2) }
            }
        }
    }
}

/// The 7 pt dot that says a fold is still working: `Tok.run`, breathing between 35% and full over 0.9 s. Reduce
/// Motion makes it steady rather than taking it away — the dot is also the row's "this is happening now" mark.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulseDot(color: Tok.run, low: 0.35, period: 0.9, animate: !reduceMotion)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// A round dot whose breathing is handed to Core Animation, which runs it outside the app. The SwiftUI
/// repeat-forever animation it replaces woke the app's main thread on every display frame for as long as a reply was
/// being written — the per-frame work the 10-14/15 crashes all died in.
/// With `image` it breathes that asset instead of a round fill (the empty screen's orca).
struct PulseDot: UIViewRepresentable {
    var color: Color
    var low: Float
    var period: Double
    var delay: Double = 0
    var animate = true
    var image: String? = nil

    func makeUIView(context: Context) -> DotView { DotView() }
    func updateUIView(_ v: DotView, context: Context) {
        if let image {
            v.backgroundColor = .clear
            v.layer.contents = UIImage(named: image)?.cgImage
            v.layer.contentsGravity = .resizeAspect
            v.round = false
        } else {
            v.backgroundColor = UIColor(color)
        }
        v.spec = DotView.Spec(low: low, period: period, delay: delay, animate: animate)
    }

    final class DotView: UIView {
        struct Spec: Equatable { var low: Float; var period: Double; var delay: Double; var animate: Bool }
        var spec: Spec? { didSet { if spec != oldValue { restart() } } }
        var round = true
        override func layoutSubviews() { super.layoutSubviews(); layer.cornerRadius = round ? min(bounds.width, bounds.height) / 2 : 0 }
        override func didMoveToWindow() { super.didMoveToWindow(); restart() }
        private func restart() {
            layer.removeAnimation(forKey: "pulse")
            guard window != nil, let spec, spec.animate else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = spec.low; a.toValue = 1
            a.duration = spec.period; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = CACurrentMediaTime() + spec.delay
            a.fillMode = .backwards
            // Kept across a trip to the background, which would otherwise strip it and leave the dot still.
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "pulse")
        }
    }
}

struct ToolGroupChip: View {
    let key: String
    let tools: [Block]
    let chat: ChatModel
    let folds: FoldState

    var body: some View {
        let first: (String, String) = { if case .tool(_, let n, let a) = tools[0] { return (n, a) }; return ("", "") }()
        let names = Array(Set(tools.compactMap { b -> String? in if case .tool(_, let n, _) = b { return n }; return nil })).sorted().prefix(3).joined(separator: ", ")
        let title = tools.count == 1 ? "\(first.0) · \(ToolText.summary(first.1))" : "Used \(tools.count) tools · \(names)"
        FoldRow(key: key, icon: ToolText.icon[ToolText.kind(first.0)] ?? "wrench.and.screwdriver", title: title,
                folds: folds, tint: Tok.tool) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, b in
                    if case .tool(let cid, let n, let a) = b {
                        VStack(alignment: .leading, spacing: 4) {
                            (Text(n).bold() + Text("  " + ToolText.summary(a)).foregroundColor(.secondary)).font(.footnote)
                            if let r = chat.results[cid] {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    Text(String(r.text.prefix(1500)))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(r.isError ? Color.red : Color.primary)
                                        .fixedSize(horizontal: true, vertical: true)
                                        .textSelection(.enabled)
                                }
                                .padding(8)
                                .background(Tok.warmSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                Text("Running…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .lineLimit(1)
    }
}

/// Runs of thinking and tool-only steps collapse into one line, like the desktop:
/// "Read files and ran commands" when done, "Running commands · <command>" while live.
struct ProcessGroupHeader: View {
    let item: ChatItem
    let members: [ChatItem]
    let chat: ChatModel
    let folds: FoldState

    var body: some View {
        // The live member's blocks come from the stream, as in AssistantMessageView: the list's copy is a snapshot.
        let ms = item.groupLive && members.last?.kind == .live
            ? Array(members.dropLast()) + [{ var m = members[members.count - 1]; m.blocks = chat.stream ?? m.blocks; return m }()]
            : members
        let info = ProcessGroupInfo.info(ms, chat: chat, live: item.groupLive)
        let open = folds.open.contains("gh:" + item.groupId)
        Button {
            withAnimation(.snappy(duration: 0.25)) { folds.toggle("gh:" + item.groupId) }
        } label: {
            HStack(spacing: 7) {
                if item.groupLive { ProgressView().controlSize(.mini) } else { Image(systemName: info.icon).font(.footnote) }
                (Text(info.title).fontWeight(.medium) + Text(info.detail.isEmpty ? "" : " · " + info.detail).foregroundColor(.secondary))
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            // A quiet warm capsule, not the orange the individual tool rows wear: this row stands for a run of work,
            // not for one call.
            .background(Tok.warmSurface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("process.group")
    }

}


struct AnsweredQuestionCard: View {
    let block: Block
    let chat: ChatModel
    let folds: FoldState
    let key: String

    var body: some View {
        if case .tool(let cid, _, let args) = block, let ans = Self.answers(chat, cid) {
            let qs = (try? JSON.parse(Data(args.utf8)))?["questions"].array ?? []
            let head = qs.first.map { $0["header"].string ?? $0["question"].str } ?? "Question"
            FoldRow(key: "\(key):q\(cid)", icon: "checkmark.circle", title: "Answered · \(head)", folds: folds) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(qs.indices, id: \.self) { i in
                        let q = qs[i]
                        let x = ans.first { $0["id"].str == q["id"].str } ?? (i < ans.count ? ans[i] : .null)
                        let sel = (x["selected"].array.map(\.str) + (x["custom"].string.map { [$0] } ?? [])).joined(separator: ", ")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q["question"].str).font(.footnote).foregroundStyle(.secondary)
                            Text(sel.isEmpty ? "—" : sel).font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
    }

    static func answers(_ chat: ChatModel, _ callId: String) -> [JSON]? {
        if let s = chat.proj["userQuestions"]?["settled"].array.first(where: { $0["callId"].str == callId }) { return s["answers"].array }
        if let r = chat.results[callId], let j = try? JSON.parse(Data(r.text.utf8)), case .array(let a) = j["answers"] { return a }
        return nil
    }
}

// MARK: small rows

struct ErrorRow: View {
    let item: ChatItem
    let chat: ChatModel
    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                if let plain = Self.plain(item.text) {
                    // The raw tail (a JSON body, a stack dump) stays behind the disclosure; the readable sentence is
                    // what the row shows. The photographed label is the native bright blue with a black chevron —
                    // the one deliberate exception to the quiet palette (LOOK-SPEC, INFERRED from chat.png).
                    DisclosureGroup {
                        Text(item.text).font(.caption).textSelection(.enabled)
                    } label: {
                        // CENTRED, as the photograph's own row is: measured on .tmp/oct9/chat.png, its four label
                        // lines start at 65.7 / 54.2 / 64.6 / 59.4 pt — different left edges, one centre line. A
                        // DisclosureGroup's label centres its lines by itself, which is why nothing is forced here.
                        Text(plain).foregroundStyle(Color.blue)
                    }
                    .tint(.primary)
                } else {
                    Text(item.text).foregroundStyle(Color.blue)
                }
            }
            .font(.subheadline)
            .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .textSelection(.enabled)
            if chat.isLastError(item) {
                Button("Try again") { chat.tryAgain() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }

    /// The readable part of an error, or nil when the whole text is already readable. A host appends its raw payload
    /// after a `Details:`, `Raw:`, `Traceback` or a bare `{` often enough that the disclosure is worth having; when
    /// there is no such tail the label is the message itself, which is what the reference's own error row shows.
    static func plain(_ text: String) -> String? {
        // A host error is often `<status>: {"message":…}`. The reference's own error row shows the status and the
        // message and keeps the payload behind the disclosure, so that shape is unwrapped first.
        if let r = text.range(of: "{\""), let j = try? JSON.parse(Data(text[r.lowerBound...].utf8)) {
            let head = String(text[text.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = j["message"].string, !m.isEmpty {
                let named = name(head)
                return named.isEmpty ? m : named + " " + m
            }
        }
        let cuts = ["\nDetails:", "\nRaw:", "\nTraceback", "\n{"]
        var best: String?
        for c in cuts {
            guard let r = text.range(of: c) else { continue }
            let head = String(text[text.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if head.count >= 20, best == nil || head.count < best!.count { best = head }
        }
        guard let b = best, b.count < text.count else { return nil }
        return b
    }

    /// The head of a `<status>: {"message":…}` error, in the words the photographed row uses. The Oct 9 build's host
    /// sent a sentence — "Usage limit reached (429): You've reached your weekly usage limit…" — where today's sends
    /// the bare status, so the status the app can name is named here; anything else keeps the host's own head rather
    /// than inventing a phrase for a code no photograph shows.
    private static func name(_ head: String) -> String {
        let code = head.hasSuffix(":") ? String(head.dropLast()).trimmingCharacters(in: .whitespaces) : head
        return code == "429" ? "Usage limit reached (429):" : head
    }
}

struct NoteRow: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }
}

struct RetryRow: View {
    let item: ChatItem
    let folds: FoldState
    var body: some View {
        let label = ["scheduled": "Waiting to retry the model request", "started": "Retried the model request", "cancelled": "Model request retry cancelled"][item.state] ?? "Retry"
        let maxs = item.maxRetries.map(String.init) ?? "∞"
        FoldRow(key: item.key, icon: "arrow.clockwise", title: "\(label) (\(item.retry)/\(maxs)) · \(max(1, Int((item.delayMs / 1000).rounded())))s", folds: folds) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Retry delay: \(Int(item.delayMs)) ms")
                Text("Reason: \(item.text)")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct ChangesChip: View {
    let item: ChatItem
    let chat: ChatModel
    @Binding var sheet: ChatSheet?
    var body: some View {
        let sm = chat.changes[item.seq]
        Button { sheet = .changes(item.seq) } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.badge.ellipsis").font(.footnote)
                Group {
                    if let sm, sm.isObject {
                        Text("\(sm["total"].int ?? 0) file\(sm["total"].int == 1 ? "" : "s") changed · ") + Text("+\(sm["added"].int ?? 0)").foregroundColor(.green) + Text(" −\(sm["deleted"].int ?? 0)").foregroundColor(.red)
                    } else if sm?.string == "err" { Text("Changes unavailable") } else { Text("Checking changes…") }
                }
                .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Tok.warmSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .task(id: chat.snapshots) { await chat.loadChanges(item.seq) }
    }
}

struct WorkflowCard: View {
    let item: ChatItem
    let chat: ChatModel

    var body: some View {
        let done = item.stopReason != nil || item.interrupted
        let st = item.stopReason.map { ["completed": "Completed", "cancelled": "Cancelled", "error": "Failed"][$0] ?? $0 } ?? (item.interrupted ? "Interrupted" : "Running")
        func ms(_ m: WFMember) -> String { m.outcome.map { ["completed": "Completed", "failed": "Failed", "cancelled": "Cancelled"][$0] ?? $0 } ?? (done ? "Interrupted" : "Running") }
        var phases: [(String?, [WFMember])] = []
        for m in item.members.prefix(60) {
            if let i = phases.firstIndex(where: { $0.0 == m.phase }) { phases[i].1.append(m) } else { phases.append((m.phase, [m])) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text(item.name).font(.headline).lineLimit(1)
                Spacer()
                Text(st).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background((st == "Failed" ? Color.red : st == "Running" ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            }
            ForEach(Array(phases.enumerated()), id: \.offset) { _, p in
                Text(p.0 ?? "Unphased").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(p.1, id: \.seq) { m in
                    Button {
                        NotificationCenter.default.post(name: .openChild, object: [chat.sid, m.childId])
                    } label: {
                        HStack {
                            Circle().fill(ms(m) == "Running" ? Color.green : ms(m) == "Failed" ? Color.red : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            Text(m.label).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text(ms(m)).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        // The height is the label's, so the whole row takes the tap, not just its text; 6 pt more
                        // each side for the finger, handed back to the layout so the card keeps its size (Codex r49).
                        .frame(minHeight: 32)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .padding(.vertical, -6)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(14)
        .background(Tok.warmSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension Notification.Name { static let openChild = Notification.Name("openChild") }

struct DeliverablesCard: View {
    let item: ChatItem
    @Binding var sheet: ChatSheet?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Files from this chat · \(item.deliverables.count)", systemImage: "doc.on.doc").font(.subheadline.weight(.semibold))
            ForEach(item.deliverables.prefix(20), id: \.path) { f in
                Button { sheet = .file(f.path) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.base(f.path)).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(f.description.isEmpty ? f.path : f.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(Tok.warmSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
