import Foundation
import SwiftUI

/// Block-level markdown for replies. Inline styling (bold, italic, code, links, strikethrough) uses the system's
/// own parser; blocks are split here so tables and code can scroll sideways in their own box.
indirect enum MDBlock: Hashable {
    case heading(Int, AttributedString)
    case paragraph(AttributedString)
    case code(String, String)
    case quote([MDBlock])
    case list([MDListItem])
    case table([AttributedString], [[AttributedString]])
    case rule
}

struct MDListItem: Hashable { var indent: Int; var marker: String; var text: AttributedString }

enum Markdown {
    // NSCache is thread-safe on its own.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 600; return c }()
    final class Box { let v: [MDBlock]; init(_ v: [MDBlock]) { self.v = v } }

    static func parse(_ src: String) -> [MDBlock] {
        let key = src as NSString
        if let b = cache.object(forKey: key) { return b.v }
        let text = src.count > 120_000 ? String(src.prefix(120_000)) + "\n\n… (shortened)" : src
        let v = blocks(text, depth: 0)
        cache.setObject(Box(v), forKey: key)
        return v
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        var code: [Range<AttributedString.Index>] = []
        for run in a.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                a[run.range].font = .system(.callout, design: .monospaced)
                a[run.range].backgroundColor = Color.primary.opacity(0.07)
                code.append(run.range)
                // A path in backticks opens the file on the Mac.
                if run.link == nil, let u = fileLink(String(a[run.range].characters)) { a[run.range].link = u }
            }
            if let link = run.link, !(link.scheme == "https" || link.scheme == "http" || link.scheme == "mailto") {
                // A link to a file (no scheme, or file:) opens it in the file viewer; anything else stays plain.
                a[run.range].link = (link.scheme == nil || link.scheme == "file") ? fileLink(link.path(percentEncoded: false), strict: false) : nil
            }
        }
        // Bare web addresses: the markdown parser only links the bracketed form.
        let plain = String(a.characters)
        for m in linkDetector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            guard let u = m.url, u.scheme == "https" || u.scheme == "http", let sr = Range(m.range, in: plain),
                  let r = Range<AttributedString.Index>(sr, in: a), a[r].runs.allSatisfy({ $0.link == nil }),
                  !code.contains(where: { $0.overlaps(r) }) else { continue }
            a[r].link = u
        }
        return a
    }

    nonisolated(unsafe) private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// `dshfile://open?p=<path>` for text that reads as a file path: an absolute or home or ./ path, or a name with an
    /// extension (`ChatView.swift`, `docs/a.md`). A trailing `:line` is dropped. `strict: false` takes any path, for
    /// links the reply itself marked as files.
    static func fileLink(_ raw: String, strict: Bool = true) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"(:\d+){1,2}$"#, options: .regularExpression) { s.removeSubrange(r) }
        // A path the reply marked as a file may hold spaces ("My Notes/plan.md"); a guessed one may not.
        guard (2...400).contains(s.count), !strict || !s.contains(where: \.isWhitespace) else { return nil }
        if strict {
            guard s.range(of: #"^[\w./~@+-]+$"#, options: .regularExpression) != nil, !s.hasSuffix("/") else { return nil }
            let last = s.split(separator: "/").last.map(String.init) ?? s
            let rooted = s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./")
            // A known file type only: `x.count` or `app.say` in code is a member, not a file.
            let ext = last.split(separator: ".").last.map { $0.lowercased() } ?? ""
            let hasExt = last.contains(".") && !last.hasPrefix(".") && fileTypes.contains(ext)
            guard (rooted && s.count > 2) || hasExt else { return nil }
        }
        var c = URLComponents(); c.scheme = "dshfile"; c.host = "open"; c.queryItems = [URLQueryItem(name: "p", value: s)]
        return c.url
    }

    private static let fileTypes: Set<String> = ["swift", "md", "markdown", "txt", "json", "jsonl", "yml", "yaml", "toml", "ini", "cfg", "conf", "env",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "sh", "zsh", "bash", "rb", "go", "rs", "java", "kt", "c", "h", "m", "mm", "cpp", "hpp",
        "css", "scss", "html", "xml", "plist", "log", "csv", "sql", "lock", "patch", "diff", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "pdf"]

    /// The path a `fileLink` carries, or nil for any other URL.
    static func filePath(_ u: URL) -> String? {
        guard u.scheme == "dshfile" else { return nil }
        return URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value
    }

    private static let listRE = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$"#)
    private static let tableSep = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#)
    private static let fenceRE = try! NSRegularExpression(pattern: #"^\s{0,3}(`{3,}|~{3,})\s*([\w+#.-]*)\s*$"#)
    private static let headRE = try! NSRegularExpression(pattern: #"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$"#)
    private static let hrRE = try! NSRegularExpression(pattern: #"^\s{0,3}([-*_])(\s*\1){2,}\s*$"#)

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
    private static func isQuote(_ l: String) -> Bool { l.range(of: #"^\s{0,3}>"#, options: .regularExpression) != nil }
    private static func cells(_ l: String) -> [String] {
        // An escaped `\|` is part of the cell, not a border, so it is set aside before the borders go (Codex r160, r161).
        var t = l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "\u{0}")
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: "\u{0}", with: "|").trimmingCharacters(in: .whitespaces) }
    }
    private static func isTableStart(_ L: [String], _ i: Int) -> Bool {
        L[i].contains("|") && i + 1 < L.count && match(tableSep, L[i + 1]) != nil && L[i + 1].contains("-")
    }
    private static func starter(_ l: String) -> Bool {
        match(fenceRE, l) != nil || l.range(of: #"^\s{0,3}(`{3,}|~{3,})"#, options: .regularExpression) != nil
            || match(headRE, l) != nil || isQuote(l) || match(listRE, l) != nil || match(hrRE, l) != nil
    }

    static func blocks(_ src: String, depth: Int) -> [MDBlock] {
        let L = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var out: [MDBlock] = []
        while i < L.count {
            let ln = L[i]
            if ln.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if let m = match(fenceRE, ln) {
                let ch = m[1].first!, n = m[1].count
                var code: [String] = []; i += 1
                while i < L.count {
                    let t = L[i].trimmingCharacters(in: .whitespaces)
                    if t.count >= n && t.allSatisfy({ $0 == ch }) { break }
                    code.append(L[i]); i += 1
                }
                i += 1
                out.append(.code(m[2], code.joined(separator: "\n")))
                continue
            }
            if let m = match(headRE, ln) { out.append(.heading(min(m[1].count, 4), inline(m[2]))); i += 1; continue }
            if match(hrRE, ln) != nil { out.append(.rule); i += 1; continue }
            if isQuote(ln) {
                var q: [String] = []
                while i < L.count && isQuote(L[i]) { q.append(L[i].replacingOccurrences(of: #"^\s{0,3}>\s?"#, with: "", options: .regularExpression)); i += 1 }
                out.append(.quote(depth < 4 ? blocks(q.joined(separator: "\n"), depth: depth + 1) : [.paragraph(AttributedString(q.joined(separator: "\n")))]))
                continue
            }
            if isTableStart(L, i) {
                let head = cells(ln); i += 2
                var rows: [[AttributedString]] = []
                while i < L.count && !L[i].trimmingCharacters(in: .whitespaces).isEmpty && L[i].contains("|") {
                    let c = cells(L[i]); i += 1
                    if rows.count < 500 { rows.append(head.indices.map { inline($0 < c.count ? c[$0] : "") }) }
                }
                out.append(.table(head.map(inline), rows))
                continue
            }
            if match(listRE, ln) != nil {
                var items: [MDListItem] = []
                var counters: [Int: Int] = [:]
                while i < L.count {
                    if let mm = match(listRE, L[i]) {
                        let indent = min(4, mm[1].replacingOccurrences(of: "\t", with: "    ").count / 2)
                        let ordered = mm[2].first!.isNumber
                        var marker = "•"
                        if ordered {
                            let start = Int(mm[2].dropLast()) ?? 1
                            let n = counters[indent].map { $0 + 1 } ?? start
                            counters[indent] = n; marker = "\(n)."
                        } else { counters[indent] = nil }
                        for k in counters.keys where k > indent { counters[k] = nil }
                        items.append(MDListItem(indent: indent, marker: marker, text: inline(mm[3])))
                        i += 1
                    } else if !L[i].trimmingCharacters(in: .whitespaces).isEmpty && L[i].range(of: #"^\s{2,}\S"#, options: .regularExpression) != nil && !items.isEmpty {
                        items[items.count - 1].text += AttributedString(" ") + inline(L[i].trimmingCharacters(in: .whitespaces)); i += 1
                    } else if L[i].trimmingCharacters(in: .whitespaces).isEmpty && i + 1 < L.count && match(listRE, L[i + 1]) != nil {
                        i += 1
                    } else { break }
                }
                out.append(.list(items))
                continue
            }
            var p = [ln]; i += 1
            while i < L.count && !L[i].trimmingCharacters(in: .whitespaces).isEmpty && !starter(L[i]) && !isTableStart(L, i) { p.append(L[i]); i += 1 }
            out.append(.paragraph(inline(p.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))))
        }
        return out
    }

    /// Where the streaming text can be split: the end of the last paragraph that can no longer change.
    static func liveCut(_ text: String, from: String.Index) -> String.Index? {
        var search = text.endIndex
        var tries = 0
        while tries < 6, let r = text.range(of: "\n\n", options: .backwards, range: from..<search) {
            tries += 1
            let seg = text[from..<r.lowerBound]
            let lines = seg.split(separator: "\n", omittingEmptySubsequences: false)
            let fences = lines.filter { $0.range(of: #"^\s{0,3}(`{3,}|~{3,})"#, options: .regularExpression) != nil }.count
            if fences % 2 == 0, let last = lines.last {
                let l = String(last)
                if match(listRE, l) == nil && l.range(of: #"^\s{2,}\S"#, options: .regularExpression) == nil && !l.contains("|") && !isQuote(l) {
                    return r.upperBound
                }
            }
            search = r.lowerBound
        }
        return nil
    }
}
