import SwiftUI

/// Renders a reply's markdown with native text. Equatable on the source, so a finished message never redraws.
struct MarkdownView: View, Equatable {
    let text: String
    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text }

    var body: some View {
        let blocks = Markdown.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { i in
                MDBlockView(block: blocks[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the streaming scan remembers between updates. A reference box because it must survive the view being
/// rebuilt, and because mutating a box's own fields inside `body` is not a state change — reassigning @State there
/// would be.
final class SplitCache {
    var text = ""
    var byteCount = 0
    var chunks: [String] = []
    /// Where the unfinished tail began, as a UTF-8 offset: O(1) to turn back into an index on a native string.
    var tailOffset = 0
    var inFence = false
    var prevLine = ""
}

/// While a reply streams, everything up to the last finished paragraph is drawn once and kept;
/// only the unfinished tail is parsed again on each update.
struct StreamingMarkdownView: View {
    let text: String
    @State private var cache = SplitCache()

    var body: some View {
        let (stable, tail) = Self.split(text, cache: cache)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(stable.indices, id: \.self) { i in
                MarkdownView(text: stable[i]).equatable()
            }
            if !tail.isEmpty { MarkdownView(text: tail).equatable() }
        }
    }

    /// Splits at paragraph boundaries that can no longer change, in fixed chunks so earlier chunks keep
    /// their identity (and their cached parse) as the text grows.
    static func split(_ text: String, cache: SplitCache) -> ([String], String) {
        // Walk forward line by line; cut at a blank line outside a code fence once a chunk is long enough.
        // Because the text only grows at the end, every earlier cut lands in the same place on each update — so a
        // reply that merely grew resumes at the tail the last scan stopped at instead of being walked from its
        // first character again. That walk is O(length) per token, and it is what made a long reply jank.
        var chunks: [String] = []
        var chunkStart = text.startIndex
        var inFence = false
        var prevLine = ""
        // The state as it was when the tail began — NOT the state at the end of the last scan: the tail's own lines
        // are walked again, so a fence that opened inside the tail would toggle a second time on the resume.
        var tailInFence = false
        var tailPrevLine = ""
        if cache.byteCount > 0, text.utf8.count >= cache.byteCount, text.utf8.starts(with: cache.text.utf8),
           let resume = String.Index(text.utf8.index(text.utf8.startIndex, offsetBy: cache.tailOffset), within: text) {
            chunks = cache.chunks
            chunkStart = resume
            inFence = cache.inFence
            prevLine = cache.prevLine
            tailInFence = cache.inFence
            tailPrevLine = cache.prevLine
        }
        var lineStart = chunkStart
        var cut = false
        while lineStart < text.endIndex {
            guard let nl = text[lineStart...].firstIndex(of: "\n") else { break }   // last line is unfinished
            let line = String(text[lineStart..<nl])
            let next = text.index(after: nl)
            if line.range(of: #"^\s{0,3}(`{3,}|~{3,})"#, options: .regularExpression) != nil { inFence.toggle() }
            if !inFence, line.trimmingCharacters(in: .whitespaces).isEmpty, !prevLine.isEmpty,
               prevLine.range(of: #"^(\s*)([-*+]|\d{1,9}[.)])\s+"#, options: .regularExpression) == nil,
               prevLine.range(of: #"^\s{2,}\S"#, options: .regularExpression) == nil,
               !prevLine.contains("|"), prevLine.range(of: #"^\s{0,3}>"#, options: .regularExpression) == nil,
               next < text.endIndex, text.distance(from: chunkStart, to: next) >= 600 {
                chunks.append(String(text[chunkStart..<next]))
                chunkStart = next
                cut = true
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { prevLine = line } else if !inFence { prevLine = "" }
            if cut { tailInFence = inFence; tailPrevLine = prevLine; cut = false }
            lineStart = next
        }
        cache.text = text
        cache.byteCount = text.utf8.count
        cache.chunks = chunks
        cache.tailOffset = text.utf8.distance(from: text.utf8.startIndex, to: chunkStart)
        // The tail's starting state, not the scan's end: saving the end made a fence that opened in the tail toggle
        // shut on the next update, and a streaming code block broke into prose (Codex r160).
        cache.inFence = tailInFence
        cache.prevLine = tailPrevLine
        return (chunks, String(text[chunkStart...]))
    }
}

struct MDBlockView: View {
    let block: MDBlock

    var body: some View {
        switch block {
        case .heading(let lv, let t):
            Text(t).font(lv == 1 ? .title2.bold() : lv == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .textSelection(.enabled)
        case .paragraph(let t):
            Text(t).font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let lang, let code):
            CodeBlockView(lang: lang, code: code)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.35)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(inner.indices, id: \.self) { i in MDBlockView(block: inner[i]) }
                }
                .foregroundStyle(.secondary)
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    let it = items[i]
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(it.marker).foregroundStyle(.secondary).monospacedDigit()
                            .frame(minWidth: it.marker == "•" ? 10 : 20, alignment: .trailing)
                        Text(it.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(it.indent) * 18)
                }
            }
        case .table(let head, let rows):
            TableBlockView(head: head, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

struct CodeBlockView: View {
    let lang: String
    let code: String
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((lang.isEmpty ? "code" : lang).uppercased())
                    .font(Tok.chip).tracking(0.6)
                    .foregroundStyle(Tok.secondaryText(scheme))
                Spacer()
                Button { UIPasteboard.general.string = code; app.say("Copied") } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy code")
                    .tapTarget()
            }
            .padding(.horizontal, Tok.sp3).padding(.vertical, Tok.sp2)
            Rectangle().fill(Tok.hairline(scheme)).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(Tok.sp3)
            }
        }
        .background(Tok.surface(scheme), in: RoundedRectangle(cornerRadius: Tok.rTile, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Tok.rTile, style: .continuous).stroke(Tok.hairline(scheme)) }
        .clipShape(RoundedRectangle(cornerRadius: Tok.rTile, style: .continuous))
    }
}

struct TableBlockView: View {
    let head: [AttributedString]
    let rows: [[AttributedString]]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(head.indices, id: \.self) { i in
                        Text(head[i]).font(.subheadline.weight(.semibold)).padding(.horizontal, Tok.sp3).padding(.vertical, Tok.sp2)
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                }
                .background(Tok.surface(scheme))
                ForEach(rows.indices, id: \.self) { r in
                    Rectangle().fill(Tok.hairline(scheme)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { i in
                            Text(rows[r][i]).font(.subheadline).padding(.horizontal, Tok.sp3).padding(.vertical, Tok.sp2)
                                .frame(maxWidth: 260, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: Tok.rTile, style: .continuous).stroke(Tok.hairline(scheme)) }
            .clipShape(RoundedRectangle(cornerRadius: Tok.rTile, style: .continuous))
        }
    }
}
