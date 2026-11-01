import SwiftUI

/// Context and usage for one chat: what the desktop's own sidebar shows, read from the projection values the chat
/// already receives on its stream. Nothing here is fetched separately.
struct UsageSheet: View {
    let chat: ChatModel

    private var pressure: JSON { chat.proj["contextPressure"] ?? .null }
    private var breakdown: JSON { chat.proj["contextBreakdown"] ?? .null }
    private var timeline: JSON { chat.proj["contextTimeline"] ?? .null }
    private var stats: JSON { chat.proj["sessionStats"] ?? .null }
    private var activity: JSON { chat.proj["contextActivity"] ?? .null }

    var body: some View {
        NavigationStack {
            List {
                Section("Context window") { window }
                Section("What is filling it") { filling }
                Section("This run") { run }
                Section("Today") { today }
            }
            .navigationTitle("Context & usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton() }
        }
    }

    // MARK: sections

    @ViewBuilder private var window: some View {
        let used = pressure["pressureTokens"].double ?? timeline["current"]["total"].double ?? 0
        let size = pressure["contextWindow"].double ?? timeline["contextWindow"].double ?? 0
        let projected = pressure["projectedTokens"].double ?? 0
        if size > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(Fmt.count(used)) of \(Fmt.count(size))").font(.headline)
                    Spacer()
                    Text(percent(used, size)).font(.subheadline.weight(.semibold)).foregroundStyle(tint(used, size))
                }
                ProgressView(value: min(used, size), total: size).tint(tint(used, size))
                if projected > used {
                    Text("Next turn needs about \(Fmt.count(projected))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("The chat is compacted automatically when it gets close to the window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            Text("This DSH does not report a context window for this chat.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var filling: some View {
        let current = timeline["current"] ?? .null
        let rows: [(String, Double)] = [
            ("Your messages", current["user"].double ?? 0),
            ("Replies", current["assistant"].double ?? 0),
            ("Tool output", current["tool"].double ?? 0),
            ("Skills", current["skill"].double ?? 0),
            ("Injected context", current["inject"].double ?? 0),
            ("Tool definitions", current["tools"].double ?? breakdown["toolsTokens"].double ?? 0),
            ("System prompt", current["system"].double ?? breakdown["systemTokens"].double ?? 0),
        ].filter { $0.1 > 0 }
        if rows.isEmpty {
            Text("Nothing reported yet.").foregroundStyle(.secondary)
        } else {
            ForEach(rows, id: \.0) { name, n in
                HStack {
                    Text(name)
                    Spacer()
                    Text(Fmt.count(n)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder private var run: some View {
        let s = stats
        if s.isObject {
            row("Turns", s["turns"].double.map { String(Int($0)) })
            row("Steps", s["steps"].double.map { String(Int($0)) })
            row("Time to first token", s["ttftMs"].double.map { Fmt.clock($0 / 1000) })
            row("Thinking and writing", s["decodeMs"].double.map { Fmt.clock($0 / 1000) })
            row("Tool time", s["toolMs"].double.map { Fmt.clock($0 / 1000) })
            if let t = s["decodeTokens"].double, let ms = s["decodeMs"].double, ms > 0 {
                row("Speed", String(format: "%.0f tokens/s", t / (ms / 1000)))
            }
            if let model = timeline["model"].string, !model.isEmpty { row("Model", model) }
        } else {
            Text("No run yet in this chat.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var today: some View {
        let days = activity["days"] ?? .null
        // The host keys days by the Mac's local date. The newest key was shown before, so a chat last used yesterday
        // showed yesterday under "Today" (Codex r158).
        // Gregorian whatever the phone's calendar setting; the phone's time zone stands in for the Mac's (Codex r159).
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
        let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if days[key].isObject {
            let day = days[key]
            row("Tokens", Fmt.count(day["tokens"].double ?? 0))
            row("Requests", day["requests"].double.map { String(Int($0)) })
            ForEach(costRows(day["cost"]), id: \.0) { name, tokens in
                row(name, Fmt.count(tokens))
            }
        } else {
            Text("Nothing used today in this chat.").foregroundStyle(.secondary)
        }
    }

    // MARK: pieces

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? "—").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// The host reports token counts per provider, model and price tier; there are no prices in it, so the sheet
    /// shows the tokens under each provider and model rather than inventing a currency figure.
    private func costRows(_ cost: JSON) -> [(String, Double)] {
        var out: [(String, Double)] = []
        for (provider, models) in cost.object {
            for (model, tiers) in models.object {
                var n = 0.0
                for (_, tier) in tiers.object { for (_, v) in tier.object { n += v.double ?? 0 } }
                out.append(("\(provider) · \(model)", n))
            }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    private func percent(_ used: Double, _ size: Double) -> String {
        guard size > 0 else { return "" }
        return String(format: "%.0f%%", min(100, used / size * 100))
    }

    private func tint(_ used: Double, _ size: Double) -> Color {
        guard size > 0 else { return .secondary }
        let f = used / size
        return f > 0.9 ? .red : f > 0.7 ? .orange : .green
    }
}
