import Foundation

enum ToolText {
    static func summary(_ args: String) -> String {
        guard let d = args.data(using: .utf8), let j = try? JSON.parse(d) else { return "" }
        for k in ["command", "cmd", "path", "file_path", "pattern", "query", "url", "description"] {
            let v = j[k]
            if let s = v.string { return String(s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(140)) }
            if !v.isNull { return String(v.compact.prefix(140)) }
        }
        return ""
    }

    static func kind(_ name: String) -> String {
        switch name {
        case "read": return "read"
        case "read_image": return "readImage"
        case "grep", "glob": return "search"
        case "write": return "write"
        case "edit", "apply_patch": return "edit"
        case "bash", "pwsh", "exec_command", "write_stdin": return "commands"
        case "run_code": return "code"
        case "web_search": return "webSearch"
        case "web_fetch": return "webFetch"
        case "todo_write", "create_goal", "update_goal", "get_goal": return "plan"
        case "ask_user_question", "request_user_input": return "questions"
        default:
            if name.hasSuffix("_inspect") { return "search" }
            if name.hasPrefix("terminal_") { return "commands" }
            if name == "subagent" || name.hasPrefix("subagent_") { return "subagents" }
            return "tools"
        }
    }
    static let done = ["thinking": "Analysis completed", "read": "Read files", "readImage": "Read images", "write": "Wrote files", "search": "Searched code",
                       "edit": "Edited files", "commands": "Ran commands", "code": "Ran code", "webSearch": "Searched the web", "webFetch": "Visited web pages",
                       "subagents": "Coordinated subagents", "plan": "Updated the plan", "questions": "Asked questions", "tools": "Called tools"]
    static let liveLabel = ["thinking": "Analyzing the request", "read": "Reading files", "readImage": "Reading images", "write": "Writing files", "search": "Searching code",
                            "edit": "Editing files", "commands": "Running commands", "code": "Running code", "webSearch": "Searching the web", "webFetch": "Visiting web pages",
                            "subagents": "Coordinating subagents", "plan": "Updating the plan", "questions": "Waiting for your action", "tools": "Calling tools"]
    static let icon = ["read": "doc.text", "readImage": "photo", "write": "square.and.pencil", "search": "magnifyingglass", "edit": "pencil.line",
                       "commands": "terminal", "code": "chevron.left.forwardslash.chevron.right", "webSearch": "globe", "webFetch": "safari",
                       "subagents": "person.2", "plan": "checklist", "questions": "questionmark.bubble", "tools": "wrench.and.screwdriver", "thinking": "brain"]
}

/// Title for a folded run of tool and thinking steps: "Read files and ran commands" when done,
/// "Running commands" plus what it is doing while live.
enum ProcessGroupInfo {
    @MainActor static func info(_ members: [ChatItem], chat: ChatModel, live: Bool) -> (title: String, icon: String, detail: String) {
        var seen = Set<String>()
        var count: [String: Int] = [:]
        var running: String?
        var detail = ""
        var lastThink = ""
        for m in members {
            for b in m.blocks {
                switch b {
                case .think(let t): if ChatModel.hasInk(t) { lastThink = t }
                case .tool(let cid, let n, let a):
                    guard !seen.contains(cid) else { continue }
                    seen.insert(cid)
                    let k = ToolText.kind(n)
                    count[k, default: 0] += 1
                    // Only a live header needs to know what is still running; reading `results` in a finished one
                    // redrew it whenever any other tool finished (Codex r164).
                    if live, chat.results[cid] == nil { running = k; detail = ToolText.summary(a) }
                case .text: break
                }
            }
        }
        let ranked = count.sorted { $0.value > $1.value }
        if !live {
            let labels = ranked.prefix(3).map { ToolText.done[$0.key] ?? $0.key }
            var t: String
            switch labels.count {
            case 0: t = ToolText.done["thinking"]!
            case 1: t = labels[0]
            case 2: t = labels[0] + " and " + labels[1].lowercasedFirst
            default: t = ([labels[0]] + labels.dropFirst().map(\.lowercasedFirst)).joined(separator: ", ") + (ranked.count > 3 ? ", etc." : "")
            }
            return (t, ranked.isEmpty ? "brain" : (ToolText.icon[ranked[0].key] ?? "wrench.and.screwdriver"), "")
        }
        if running == nil {
            let paras = lastThink.replacingOccurrences(of: "**", with: "").components(separatedBy: "\n\n").map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            detail = String((paras.last ?? "").prefix(140))
        }
        return (ToolText.liveLabel[running ?? "thinking"]!, ToolText.icon[running ?? "thinking"] ?? "brain", detail)
    }
}

extension String { var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() } }
