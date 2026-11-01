import SwiftUI
import WebKit

/// Plugins installed in DSH on the Mac: switch them on or off, install by package name, and open the ones
/// that have something to show on a phone (Scheduler, voice input, and plugins that publish a status page).
enum Plugins {
    static let names: [String: String] = [
        "@deepseek-ai/dsh-base": "Core", "@deepseek-ai/dsh-web-app": "Web app", "@deepseek-ai/dsh-experimental-agent-team-profile": "Agent Teams",
        "@deepseek-ai/dsh-experimental-voice-input-bundle": "Voice input", "@deepseek-ai/dsh-experimental-auto-review": "Auto review",
        "@deepseek-ai/dsh-experimental-schedule-bundle": "Scheduler", "dsh-better-sidebar": "Better sidebar", "dshmarket": "Plugin market",
        "dsh-context": "Context", "@tigerwho/dsh-provider-quota": "Usage", "@deepseek-ai/dsh-acp-app": "Editor agent (ACP)", "@deepseek-ai/dsh-headless": "Command-line mode",
        "@deepseek-ai/dsh-sdk-app": "Program interface (SDK)", "@deepseek-ai/dsh-sdk-minimal": "Minimal program interface",
    ]
    /// The web server this app talks to; switching it off would cut the phone off.
    static let neverOff: Set<String> = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]
    /// What to tap, in order, to reach a plugin's screen on the Mac page when its sidebar entry does not carry its
    /// name. Usage is a card in the sidebar's footer: on a phone-width page the sidebar is a rail, so its badge opens
    /// the sidebar and the card's head then unfolds the table.
    static let macTaps: [String: [String]] = [
        "@tigerwho/dsh-provider-quota": [".tg-quota-badge", ".tg-quota-head[aria-expanded=false]"],
    ]

    enum Kind { case schedule, voice, status([String]), info(String) }

    static func kind(_ b: JSON) -> Kind {
        switch b["name"].str {
        case "@deepseek-ai/dsh-experimental-schedule-bundle": return .schedule
        case "@deepseek-ai/dsh-experimental-voice-input-bundle": return .voice
        case "@deepseek-ai/dsh-experimental-agent-team-profile":
            return .info("Teams of helper agents work together inside a chat. Open a chat, tap the menu, then Agent team to see the members and the task board.")
        case "@deepseek-ai/dsh-experimental-auto-review":
            return .info("When this is on, the model checks each tool call before it runs and only asks you when it would deny it. It appears as an extra choice under Permissions in a chat's menu.")
        case "@deepseek-ai/dsh-base": return .info("The core of DSH. Everything else builds on it, so it cannot be switched off.")
        case "@deepseek-ai/dsh-web-app": return .info("The server this phone talks to. It cannot be switched off from here.")
        default: break
        }
        // Any plugin may publish a JSON status page at /<short-name>/status.json; the app shows it if it exists.
        let short = b["name"].str.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "dsh-", with: "") ?? ""
        return .status(["/\(short)/status.json", "/\(b["name"].str.split(separator: "/").last ?? "")/status.json"])
    }

    static func name(_ b: JSON) -> String {
        if let n = names[b["name"].str] { return n }
        let t = loc(b["meta"]["title"]); if !t.isEmpty && !t.hasPrefix("@") { return t }
        let base = b["name"].str.split(separator: "/").last.map(String.init) ?? b["name"].str
        let s = base.replacingOccurrences(of: "dsh-", with: "").replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    static func loc(_ v: JSON) -> String { v.string ?? v["en"].string ?? v.object.values.compactMap(\.string).first ?? "" }
    static func locked(_ b: JSON) -> Bool { neverOff.contains(b["name"].str) || b["readOnlyReason"].truthy }
}

struct PluginsView: View {
    @Environment(AppModel.self) private var app
    @Binding var path: [Route]
    @State private var bundles: [JSON]?
    @State private var error = ""
    @State private var toggle: JSON?
    @State private var getting = false
    /// What the reader just asked for, shown until the Mac's own answer comes back with the reloaded list: without it
    /// the switch springs straight back to its old position.
    @State private var asked: [String: Bool] = [:]

    var body: some View {
        List {
            Loading(value: bundles, error: error) { all in
                let usable = all.filter { !Plugins.locked($0) }, core = all.filter(Plugins.locked)
                Section { ForEach(usable.indices, id: \.self) { i in row(usable[i]) } } header: { Text("Plugins") } footer: { Text("Switching a plugin on or off applies on your Mac.") }
                if !core.isEmpty { Section("Required") { ForEach(core.indices, id: \.self) { i in row(core[i]) } } }
                if app.can("pluginsinstall") {
                    Section { Button("Get plugins…") { getting = true } } footer: { Text("Install a plugin from its package name. It is installed on your Mac.") }
                }
            }
        }
        .navigationTitle("Plugins")
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(toggle.map { ($0["enabled"].truthy ? "Turn off " : "Turn on ") + Plugins.name($0) } ?? "", isPresented: Binding(get: { toggle != nil }, set: { if !$0 { toggle = nil } }), titleVisibility: .visible) {
            if let b = toggle {
                Button(b["enabled"].truthy ? "Turn off" : "Turn on", role: b["enabled"].truthy ? .destructive : nil) { Task { await setEnabled(b, !b["enabled"].truthy) } }
                // Backing out puts the switch back where the Mac has it.
                Button("Cancel", role: .cancel) { asked[b["name"].str] = nil }
            }
        } message: { Text(toggle?["enabled"].truthy == true ? "Anything it adds will disappear until you turn it on again." : "This turns the plugin on for DSH on your Mac.") }
        .sheet(isPresented: $getting) { NavigationStack { GetPluginSheet { Task { await load() } } } }
    }

    private func row(_ b: JSON) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.plugin(b["name"].str)) {
                HStack(spacing: 12) {
                    PluginIcon(bundle: b)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Plugins.name(b))
                        Text((b["enabled"].truthy || Plugins.locked(b) ? "" : "Off · ") + b["version"].str).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !Plugins.locked(b) {
                Toggle(Plugins.name(b), isOn: Binding(get: { asked[b["name"].str] ?? b["enabled"].truthy },
                                                      set: { v in asked[b["name"].str] = v; toggle = b })).labelsHidden()
            }
        }
    }

    func load() async {
        do { bundles = try await DSHClient.shared.rpc("pluginManager/listBundles").array; app.pluginCache = bundles ?? []; asked = [:]; self.error = "" }
        catch { self.error = error.localizedDescription; if bundles != nil { app.say(self.error) } }
    }

    private func setEnabled(_ b: JSON, _ on: Bool) async {
        do {
            let r = try await DSHClient.shared.rpc("pluginManager/setBundleEnabled", ["name": b["name"], "enabled": .bool(on)])
            app.say(r["application"].str == "restart-required" ? "Saved. Restart DSH on the Mac to apply." : r["error"].truthy ? "Could not change it" : "Done")
        } catch { app.say(error.localizedDescription) }
        await load()
    }
}

/// A plugin's artwork the way the Mac's plugin page draws it: the plugin's own icon in a hairline tile — 40 pt with
/// the art at 30 in a list row, 48 with 36 at the head of a plugin's page — or the Mac's default connector blocks
/// when the plugin has none.
struct PluginIcon: View {
    let bundle: JSON
    var tile: CGFloat = 40
    @State private var image: UIImage?

    var body: some View {
        let src = PluginArtwork.source(bundle)
        ZStack {
            if let ui = PluginArtwork.cached(src) ?? image {
                Image(uiImage: ui).resizable().scaledToFit().frame(width: tile * 0.75, height: tile * 0.75)
            }
        }
        .frame(width: tile, height: tile)
        .overlay(RoundedRectangle(cornerRadius: tile * 0.25, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .task(id: src) { image = await PluginArtwork.image(src) }
        .accessibilityHidden(true)
    }
}

/// Plugin icons arrive as base64 data URLs, nearly all SVG, which UIKit cannot decode: WebKit draws each one once —
/// the same engine the Mac page uses, so it looks the same — and the picture is kept for the rest of the session.
@MainActor
enum PluginArtwork {
    /// The Mac's default connector-blocks SVG, drawn once at 144 px on the Mac so it never waits on WebKit.
    static let fallback = "data:image/png;base64,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"

    /// The manifest's icon when it is a base64 image URL (nothing else is ever put into the page), else the default.
    static func source(_ b: JSON) -> String {
        let s = b["meta"]["icon"].str
        let ok = s.hasPrefix("data:image/") && s.contains(";base64,")
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "+/=:;,.-".unicodeScalars.contains($0) }
        return ok ? s : fallback
    }

    /// Watched, so a tile shows its picture the moment it lands: the list rebuilds its rows while icons are still
    /// drawing, and a rebuilt row's own wait sat at the back of the queue, so the first rows stayed empty (2026-10-15).
    @Observable final class Drawn { var images: [String: UIImage] = [:] }
    private static let drawn = Drawn()
    private static var cache: [String: UIImage] {
        get { drawn.images }
        set { drawn.images = newValue }
    }
    private static var chain: Task<Void, Never>?
    static func cached(_ src: String) -> UIImage? { cache[src] }

    /// One drawing at a time, in one web view.
    static func image(_ src: String) async -> UIImage? {
        if let ui = cache[src] { return ui }
        if src.hasPrefix("data:image/png;base64,"), let d = Data(base64Encoded: String(src.dropFirst(22))), let ui = UIImage(data: d) {
            cache[src] = ui
            return ui
        }
        let previous = chain
        let mine = Task {
            await previous?.value
            if cache[src] == nil, let ui = await draw(src) { cache[src] = ui }
        }
        chain = mine
        await mine.value
        // A drawing that did not come back shows the default this time and is tried again next time.
        if let ui = cache[src] { return ui }
        return src == fallback ? nil : await image(fallback)
    }

    private static let side: CGFloat = 48
    /// One web view for every icon: a fresh one spent about two seconds starting its page process, so seven icons took
    /// fifteen seconds and the list sat on empty tiles meanwhile (2026-10-15).
    private static let web: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: CGRect(x: -2 * side, y: 0, width: side, height: side), configuration: config)
    }()

    private static func draw(_ src: String) async -> UIImage? {
        // Off the screen but inside the window: a web view in no window had its page process put to sleep after the
        // first two icons, and every icon after them waited forever (2026-10-15).
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(web)
        defer { web.removeFromSuperview() }
        let loader = Loader()
        web.navigationDelegate = loader
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loader.done = c
            loader.navigation = web.loadHTMLString("<html><head><meta name='viewport' content='width=\(Int(side))'></head><body style='margin:0;background:transparent'><img src='\(src)' style='display:block;width:\(Int(side))px;height:\(Int(side))px'></body></html>", baseURL: nil)
            Task { @MainActor in try? await Task.sleep(for: .seconds(5)); loader.finish() }
        }
        // A page that failed or ran out of time may leave the last icon's page in the shared view: draw nothing then.
        guard loader.loaded else { return nil }
        // A snapshot of a web view nobody sees comes back blank, so the page draws the loaded picture into a canvas
        // at three times the size and hands it back as a PNG. A loaded SVG is not yet a decoded one: drawn straight
        // away it can paint nothing, which left empty tiles (2026-10-15), so the page waits for the decode and an
        // all-clear canvas counts as no picture — the default shows and the icon is tried again next time.
        let px = Int(side) * 3
        let js = "const i = document.images[0]; if (!i) return ''; try { await i.decode(); } catch (e) { return ''; } if (!i.naturalWidth) return ''; const c = document.createElement('canvas'); c.width = c.height = \(px); const g = c.getContext('2d'); g.drawImage(i, 0, 0, \(px), \(px)); const d = g.getImageData(0, 0, \(px), \(px)).data; for (let k = 3; k < d.length; k += 4) if (d[k]) return c.toDataURL('image/png'); return '';"
        // The script gets the same five seconds: one that never answers would hold every icon queued behind it.
        let drawn = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            loader.drawn = c
            web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { loader.hand((try? $0.get()) as? String) }
            Task { @MainActor in try? await Task.sleep(for: .seconds(5)); loader.hand(nil) }
        }
        guard let url = drawn, url.hasPrefix("data:image/png;base64,"),
              let data = Data(base64Encoded: String(url.dropFirst(22))) else { return nil }
        return UIImage(data: data, scale: 3)
    }

    @MainActor private final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        var drawn: CheckedContinuation<String?, Never>?
        /// The shared web view still reports on a page an earlier, timed-out icon left loading; only this icon's counts.
        var navigation: WKNavigation?
        func hand(_ url: String?) { drawn?.resume(returning: url); drawn = nil }
        func finish() { done?.resume(); done = nil }
        var loaded = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if navigation === self.navigation, done != nil { loaded = true; finish() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if navigation === self.navigation { finish() } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if navigation === self.navigation { finish() } }
    }
}

struct PluginView: View {
    @Environment(AppModel.self) private var app
    let name: String
    @Binding var path: [Route]
    @State private var status: JSON?
    @State private var statusError = ""
    @State private var confirmRemove = false

    var body: some View {
        let b = app.pluginCache.first { $0["name"].str == name } ?? ["name": .string(name)]
        let kind = Plugins.kind(b)
        List {
            Section {
                HStack(spacing: 14) {
                    PluginIcon(bundle: b, tile: 48)
                    VStack(alignment: .leading) {
                        Text(Plugins.name(b)).font(.title3.bold())
                        if !b["version"].str.isEmpty { Text("Version " + b["version"].str).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                let d = Plugins.loc(b["meta"]["description"]).isEmpty ? b["description"].str : Plugins.loc(b["meta"]["description"])
                if !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(.secondary) }
            }
            if b["enabled"].truthy && !Plugins.locked(b) {
                // The plugin's own page, the one the Mac shows: every plugin draws its screens in the web app, and the
                // phone can host that same page instead of a copy of each one.
                Section { NavigationLink("Open as on the Mac") { MacPluginPage(title: Plugins.name(b), taps: Plugins.macTaps[name] ?? []) } }
            }
            if b["enabled"].truthy || Plugins.locked(b) {
                switch kind {
                case .schedule:
                    Section { NavigationLink("Scheduled tasks", value: Route.scheduler) }
                case .voice:
                    Section { NavigationLink("Dictation setup") { VoiceSetupView() } }
                case .info(let t):
                    Section("On the phone") { Text(t).font(.subheadline) }
                case .status:
                    if let status { StatusView(name: name, data: status) }
                    else if !statusError.isEmpty { Section("On the phone") { Text(statusError).font(.subheadline).foregroundStyle(.secondary) } }
                    else { Section { ProgressView() } }
                }
            } else {
                Section("On the phone") { Text("Switch the plugin on to use it.").foregroundStyle(.secondary) }
            }
            Section("Details") {
                LabeledContent("Package") { Text(name).textSelection(.enabled) }
                if let r = b["readOnlyReason"].string { LabeledContent("Locked", value: r) }
            }
            let rows = b["rows"].array
            if !rows.isEmpty {
                Section("What it adds") {
                    ForEach(rows.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Plugins.loc(rows[i]["meta"]["title"]).isEmpty ? rows[i]["rowId"].str : Plugins.loc(rows[i]["meta"]["title"]))
                            let d = Plugins.loc(rows[i]["meta"]["description"])
                            if !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if b["removable"].truthy && !Plugins.locked(b) && app.can("pluginsinstall") {
                Section { Button("Remove plugin", role: .destructive) { confirmRemove = true } }
            }
        }
        .navigationTitle(Plugins.name(b))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadStatus(kind) }
        .task { await loadStatus(kind) }
        .confirmationDialog("Remove \(Plugins.name(b))?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove plugin", role: .destructive) {
                Task {
                    do { try await DSHClient.shared.rpc("pluginManager/removeBundle", ["name": .string(name)]); app.say("Removed") } catch { app.say(error.localizedDescription) }
                    if !path.isEmpty { path.removeLast() }
                }
            }
        } message: { Text("This deletes the package from your Mac. You can install it again later.") }
    }

    private func loadStatus(_ kind: Plugins.Kind) async {
        if app.pluginCache.isEmpty { app.pluginCache = (try? await DSHClient.shared.rpc("pluginManager/listBundles"))?.array ?? [] }
        guard case .status(let urls) = kind else { return }
        var err = ""
        for u in urls {
            do { status = try await DSHClient.shared.getJSON(u); statusError = ""; return }
            catch let e as RPCError { err = e.kind == .missing ? "This plugin has no screen of its own, so there is nothing to open here." : e.message }
            catch { err = "Could not reach the plugin." }
        }
        // Old figures are not kept on screen under a failed refresh: shown first, they hid the error (Codex r158).
        status = nil
        statusError = err
    }
}

/// The Mac's own web app, signed in with this phone's cookie, with the plugin's sidebar entry picked for the reader
/// when one carries its name. Everything on it is live and tappable, exactly as on the Mac; the app does not need to
/// know what a plugin draws.
struct MacPluginPage: View {
    let title: String
    var taps: [String] = []
    var body: some View {
        MacWebView(pick: title, taps: taps)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct MacWebView: UIViewRepresentable {
    let pick: String
    /// Selectors tapped in order instead of the name match, for a plugin whose entry is not named after it.
    var taps: [String] = []

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Picks the sidebar entry whose label carries the plugin's name, once the web app has drawn it; gives up
        // quietly after a few seconds and leaves the page as it is.
        let js = taps.isEmpty ? """
        (function(){var want=\(Self.jsString(pick.lowercased()));var n=0;var t=setInterval(function(){n++;
        var els=document.querySelectorAll('[aria-label],button,[role=button],a');
        for(var i=0;i<els.length;i++){var l=((els[i].getAttribute('aria-label')||els[i].textContent)||'').trim().toLowerCase();
        if(l&&l.length<60&&(l.indexOf(want)>=0||want.indexOf(l)>=0)){els[i].click();clearInterval(t);return;}}
        if(n>40)clearInterval(t);},250);})();
        """ : """
        (function(){var steps=\(Self.jsArray(taps));var k=0,n=0;var t=setInterval(function(){n++;
        var e=document.querySelector(steps[k]);if(e){e.click();k++;if(k>=steps.length)clearInterval(t);}
        if(n>40)clearInterval(t);},250);})();
        """
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = false
        guard let base = DSHClient.shared.baseURL else { return web }
        let store = web.configuration.websiteDataStore.httpCookieStore
        let cookies = (DSHClient.shared.cookie ?? "").split(separator: ";").compactMap { pair -> HTTPCookie? in
            let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let host = base.host() else { return nil }
            return HTTPCookie(properties: [.name: kv[0], .value: kv[1], .domain: host, .path: "/", .secure: "TRUE"])
        }
        Task { @MainActor in
            for c in cookies { await store.setCookie(c) }
            web.load(URLRequest(url: base))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func jsArray(_ a: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: a)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// A plugin's own status page. Two known shapes get a proper view (usage quotas and a run state);
/// anything else is shown as labelled values.
struct StatusView: View {
    let name: String
    let data: JSON

    var body: some View {
        if data["providers"].array.contains(where: { !$0["windows"].array.isEmpty || $0["balance"].isObject }) {
            QuotaView(d: data)
        } else {
            GenericJSONView(value: data, depth: 0)
        }
    }
}

struct QuotaView: View {
    let d: JSON
    var body: some View {
        if d["current"].isObject {
            Section("In use now") {
                LabeledContent("Provider", value: d["current"]["provider"].str)
                LabeledContent("Model", value: d["current"]["model"].str)
                if let c = d["checkedAt"].string { LabeledContent("Checked", value: Fmt.agoISO(c)) }
            }
        }
        ForEach(d["providers"].array.indices, id: \.self) { i in
            let p = d["providers"].array[i]
            Section(p["name"].str + (p["status"].str.isEmpty || p["status"].str == "ok" ? "" : " · " + p["status"].str)) {
                if let plan = p["plan"].string { LabeledContent("Plan", value: plan) }
                if p["balance"].isObject {
                    let b = p["balance"]
                    LabeledContent("Balance", value: String(format: "%.2f", b["amount"].double ?? 0) + " " + b["currency"].str + (b["cap"].double.map { String(format: " of %.0f", $0) } ?? ""))
                }
                ForEach(p["windows"].array.indices, id: \.self) { wi in
                    let w = p["windows"].array[wi]
                    let pct = w["pct"].double ?? 0
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(w["label"].str); Spacer(); Text(pct > 0 && pct < 1 ? String(format: "%.1f%% used", pct) : "\(Int(pct.rounded()))% used").monospacedDigit() }
                        ProgressView(value: min(100, max(0, pct)), total: 100).tint(pct >= 90 ? .red : pct >= 70 ? .orange : .accentColor)
                        let sub = [w["used"].double != nil && w["cap"].double != nil ? String(format: "%.2f of %.2f %@", w["used"].double!, w["cap"].double!, w["currency"].str) : "",
                                   w["resetsAt"].string.map { "resets " + Fmt.until($0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let det = p["detail"].string { Text(det).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

extension Fmt {
    static func until(_ iso: String) -> String {
        guard let t = parseISO(iso) else { return "" }
        var s = Int(t.timeIntervalSinceNow)
        if s <= 0 { return "any moment now" }
        let d = s / 86400; s -= d * 86400
        let h = s / 3600; s -= h * 3600
        let m = Int((Double(s) / 60).rounded())
        return d > 0 ? "in \(d)d \(h)h" : h > 0 ? "in \(h)h \(m)m" : "in \(max(1, m))m"
    }
}

struct GenericJSONView: View {
    let value: JSON
    let depth: Int

    static func label(_ k: String) -> String {
        let spaced = k.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    static func text(_ v: JSON) -> String {
        switch v {
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(format: "%.2f", n)
        case .bool(let b): return b ? "Yes" : "No"
        case .string(let s): return s
        case .null: return "—"
        default: return ""
        }
    }

    var body: some View {
        let o = value.object
        let prims = o.filter { !$0.value.isObject && $0.value.array.isEmpty }.sorted { $0.key < $1.key }
        let nested = o.filter { $0.value.isObject || !$0.value.array.isEmpty }.sorted { $0.key < $1.key }
        if !prims.isEmpty {
            Section {
                ForEach(prims.prefix(80), id: \.key) { k, v in LabeledContent(Self.label(k)) { Text(Self.text(v)).textSelection(.enabled) } }
            }
        }
        if depth < 3 {
            ForEach(nested.prefix(40), id: \.key) { k, v in
                if v.isObject {
                    Section(Self.label(k)) { EmptyView() }
                    GenericJSONView(value: v, depth: depth + 1)
                } else {
                    Section(Self.label(k)) {
                        ForEach(v.array.prefix(60).indices, id: \.self) { i in
                            let x = v.array[i]
                            if x.isObject {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(x.object.sorted { $0.key < $1.key }.prefix(12), id: \.key) { kk, vv in
                                        if !vv.isObject { Text("\(Self.label(kk)): \(Self.text(vv))").font(.caption) }
                                    }
                                }
                            } else { Text(Self.text(x)) }
                        }
                    }
                }
            }
        }
    }
}

struct GetPluginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let done: () -> Void
    @State private var spec = ""
    @State private var found: JSON?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Package name, for example @scope/plugin", text: $spec).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy)
                    // What was looked up is what gets installed: a changed name has to be looked up again.
                    .onChange(of: spec) { _, _ in found = nil }
            } footer: { Text("Looks the package up first. Nothing is installed until you confirm.") }
            if let v = found {
                Section {
                    LabeledContent("Package", value: v["name"].string ?? spec)
                    if let ver = v["version"].string { LabeledContent("Version", value: ver) }
                    if let reg = v["registry"].string { LabeledContent("From", value: reg) }
                }
                if let d = v["description"].string { Section("About") { Text(d) } }
                Section { Text("Installing downloads code to your Mac and runs it inside DSH. Only install packages you trust.").font(.footnote) }
            }
        }
        .navigationTitle(found == nil ? "Get plugins" : "Install plugin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await (found == nil ? look() : install()) } } label: { if busy { ProgressView() } else { Text(found == nil ? "Look up" : "Install").bold() } }
                    .disabled(busy || spec.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func look() async {
        busy = true; defer { busy = false }
        do {
            let v = try await DSHClient.shared.rpc("pluginManager/inspect", ["spec": .string(spec.trimmingCharacters(in: .whitespaces))], timeout: 60)
            if v["status"].str != "accepted" {
                let p = v["problem"].str
                app.say(p == "already-installed" ? "That plugin is already installed" : p == "not-found" ? "No package with that name" : p == "not-a-bundle" ? "That package is not a DSH plugin" : "Could not use that: " + (v["reason"].string ?? p))
                return
            }
            found = v
        } catch { app.say(error.localizedDescription) }
    }

    private func install() async {
        busy = true; defer { busy = false }
        app.say("Installing… this can take a minute")
        do {
            let r = try await DSHClient.shared.rpc("pluginManager/installBundle", ["spec": .string(spec.trimmingCharacters(in: .whitespaces)), "options": ["enabled": false]], timeout: 240)
            app.say(r["application"].str == "failed" || r["error"].truthy ? "Install failed" + (r["packageResult"]["kind"].string.map { ": " + $0 } ?? "") : "Installed. Switch it on from the list.")
        } catch { app.say(error.localizedDescription) }
        done(); dismiss()
    }
}

/// Dictation runs on the Mac with a local model; it has to be prepared once.
struct VoiceSetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = app.speechProvider
        let ph = p?["preparation"] ?? .null
        Form {
            if let p {
                Section {
                    LabeledContent("Engine", value: p["name"].str)
                    LabeledContent("Status", value: ["ready": "Ready", "standby": "Ready", "waking": "Starting", "downloading": "Downloading", "checking": "Checking",
                                                     "loading": "Loading", "failed": "Needs attention", "cancelling": "Cancelling"][ph["phase"].str] ?? "Not set up yet")
                } footer: { Text("Dictation runs on your Mac with a local model. Use the microphone button next to the message field in a chat.") }
                if let est = p["setupEstimate"].object["recommendedDiskBytes"]?.double {
                    Section { Text(String(format: "About %.1f GB of disk and %d to %d minutes to set up.", est / 1e9, p["setupEstimate"]["minimumMinutes"].int ?? 0, p["setupEstimate"]["maximumMinutes"].int ?? 0)).font(.footnote) }
                }
                switch ph["phase"].str {
                case "downloading":
                    Section {
                        ProgressView(value: ph["completedBytes"].double ?? 0, total: max(1, ph["totalBytes"].double ?? 1))
                        Text("Downloading " + ph["resource"].str).font(.caption)
                        Button("Cancel download", role: .destructive) { prep(cancel: true) }
                    }
                case "checking", "loading", "waking", "cancelling": Section { ProgressView() }
                case "failed":
                    Section { Text(ph["message"].str).foregroundStyle(.red); Button("Try again") { prep(cancel: false) } }
                case "ready", "standby": Section { Text("Ready. Tap the microphone to dictate.") }
                default: Section { Button("Prepare on the Mac") { prep(cancel: false) }.bold() }
                }
            } else {
                Text(app.can("speech") ? "No dictation engine is available on the Mac." : "The Mac has not loaded voice input. Turn on the Voice input plugin, then restart DSH on the Mac.")
            }
        }
        .navigationTitle("Voice input")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await app.loadSpeech() }
            app.mux.sub("speech", "speech/follow", onError: { _ in }) { f in app.speech = f }
        }
        .onDisappear { app.mux.unsub("speech") }
    }

    private func prep(cancel: Bool) {
        guard let id = app.speechProvider?["id"] else { return }
        Task {
            do { try await DSHClient.shared.rpc(cancel ? "speech/cancelPreparation" : "speech/prepare", ["providerId": id]) }
            catch { app.say(error.localizedDescription) }
        }
    }
}
