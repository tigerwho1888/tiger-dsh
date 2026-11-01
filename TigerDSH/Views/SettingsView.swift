import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Binding var path: [Route]
    @State private var confirmSignOut = false
    @AppStorage("perf.overlay") private var perfOverlay = false

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Mac", value: DSHClient.shared.hostLabel)
                LabeledContent("State", value: ["live": "Connected", "connecting": "Connecting", "reconnecting": "Reconnecting", "offline": "Offline"][app.conn.rawValue] ?? app.conn.rawValue)
                LabeledContent("Sockets opened / closed", value: "\(app.mux.opened) / \(app.mux.closed)")
                LabeledContent("Chat list updated", value: app.listAt > 0 ? Fmt.ago(app.listAt) + (Fmt.ago(app.listAt) == "now" ? "" : " ago") : "—")
            }
            if app.can("providers") {
                Section("Models") {
                    NavigationLink(value: Route.models) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Models and providers")
                                Text("Keys, models and the default model").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "cpu").foregroundStyle(.primary) }
                    }
                }
            }
            if app.can("speech") {
                Section("Voice") { NavigationLink { VoiceSetupView() } label: { Label { Text("Dictation setup") } icon: { Image(systemName: "waveform").foregroundStyle(.primary) } } }
            }
            // Plugins, the Task board and the digest watch live here; Plugins also has a row of its own in the drawer.
            Section("More") {
                NavigationLink(value: Route.plugins) { Label { Text("Plugins") } icon: { Image(systemName: "puzzlepiece").foregroundStyle(.primary) } }
                if app.boardReady == true { NavigationLink(value: Route.board) { Label { Text("Task board") } icon: { Image(systemName: "checklist").foregroundStyle(.primary) } } }
                DigestWatchCard()
            }
            Section {
                Toggle(isOn: Binding(get: { Notifier.enabled }, set: { on in
                    Task {
                        let ok = await Notifier.set(on)
                        if on && !ok { app.say("iOS has notifications switched off for this app. Turn them on in Settings.") }
                    }
                })) { Label { Text("Tell me when a chat needs me") } icon: { Image(systemName: "bell").foregroundStyle(.primary) } }
            } header: { Text("Notifications") } footer: { Text("An approval or a question arrives as a notification, even with the app closed and the phone locked. Your Mac sends it.") }
            Section {
                Toggle(isOn: $perfOverlay) { Label { Text("Performance overlay") } icon: { Image(systemName: "gauge").foregroundStyle(.primary) } }
                if perfOverlay { Button("Reset counters") { FrameMonitor.shared.reset() } }
            } header: { Text("Diagnostics") } footer: { Text("Shows the frame rate and any stutters (frames that arrive late) while you use the app.") }
            Section {
                Button { app.clearCache() } label: { Label { Text("Clear cached data") } icon: { Image(systemName: "trash").foregroundStyle(.primary) } }
            } header: { Text("Data on this phone") } footer: { Text("Chat lists and recent chats kept for offline viewing.") }
            Section {
                NavigationLink { AdvancedSettingsView() } label: { Label { Text("Advanced settings") } icon: { Image(systemName: "slider.horizontal.3").foregroundStyle(.primary) } }
            } header: { Text("Everything else") } footer: { Text("Every setting this DSH reports — the agent loop, subagents, the sandbox, web search, the session log and the rest.") }
            Section {
                ForEach(AppModel.contract.keys.sorted(), id: \.self) { g in
                    LabeledContent(GenericJSONView.label(g), value: !app.capReady ? "Checking…" : app.capabilities[g] == false ? "Not available" : "Available")
                }
            } header: { Text("Features on this DSH") } footer: { Text("A feature this DSH version lacks is switched off by itself; everything else keeps working.") }
            Section {
                Button("Sign out of this Mac", role: .destructive) { confirmSignOut = true }
            }
            Section {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
        // Ink, not the accent: a Settings row is not a link that has been coloured in. The icons follow the text
        // colour here — the reference's are black, and the shared More-sheet rows deliberately use secondary ones —
        // which takes an explicit foregroundStyle on each icon: inside a NavigationLink the icon is drawn with the
        // accent whatever the list is tinted with.
        .tint(.primary)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // The app's canvas behind the grouped cards, so Settings matches the chat and the list.
        .scrollContentBackground(.hidden)
        .background(Tok.canvas(scheme))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)) }
                    .accessibilityIdentifier("settings.close")
                    .accessibilityLabel("Close")
            }
        }
        .confirmationDialog("Sign out of this Mac?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { path.removeAll(); app.signOut() }
        } message: { Text("You will need a fresh DSH link from the Mac to connect again.") }
    }
}

/// Models and providers: the host's settings/*, credentials/* and llm/* methods, as the desktop Models page uses them.
/// A typed API key goes straight to `credentials/set` and is never stored or shown on the phone.
@MainActor @Observable
final class ProvidersModel {
    struct Row: Identifiable {
        var id: String { provider }
        let provider: String
        let name: String
        let ns: String
        let path: [String]
        let prof: JSON
        let group: JSON?
        let removable: Bool
        let keyRef: String?
        var cred: JSON?
    }
    var rows: [Row] = []
    var known: [JSON] = []
    var namespaces: [String: JSON] = [:]
    var catalog: JSON = .null
    var writable = false
    var loaded = false
    var error = ""

    static let pnames: [String: String] = [
        "amazon-bedrock": "Amazon Bedrock", "anthropic": "Anthropic", "azure-openai-responses": "Azure OpenAI", "cerebras": "Cerebras",
        "deepseek": "DeepSeek (API)", "deepseek-official": "DeepSeek", "deepseek-account": "DeepSeek Account", "fireworks": "Fireworks AI",
        "github-copilot": "GitHub Copilot", "google": "Google Gemini", "google-vertex": "Google Vertex AI", "groq": "Groq", "huggingface": "Hugging Face",
        "kimi-coding": "Kimi Coding", "minimax": "MiniMax", "mistral": "Mistral AI", "moonshotai": "Moonshot AI", "nvidia": "NVIDIA", "openai": "OpenAI",
        "openai-codex": "OpenAI Codex", "opencode": "OpenCode Zen", "opencode-go": "OpenCode Go", "openrouter": "OpenRouter", "together": "Together AI",
        "vercel-ai-gateway": "Vercel AI Gateway", "xai": "xAI", "xiaomi": "Xiaomi MiMo", "zai": "Z.ai",
    ]
    static func pname(_ id: String, _ shown: String?) -> String {
        if let s = shown, !s.isEmpty, s != id { return s }
        if let n = pnames[id] { return n }
        return id.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).capitalized
    }
    static func keyRef(_ route: String) -> String { route.uppercased().replacingOccurrences(of: "[^A-Z0-9]+", with: "_", options: .regularExpression) + "_API_KEY" }
    static func keyLooksBad(_ v: String) -> Bool {
        v.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) == nil || v.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
            || v.range(of: #"^(["']).*\1$"#, options: .regularExpression) != nil
    }
    static func get(_ v: JSON, _ path: [String]) -> JSON { path.reduce(v) { $0[$1] } }

    func load(app: AppModel) async {
        do {
            async let conf = DSHClient.shared.rpc("llm/listConfigurableProviders")
            async let desc = DSHClient.shared.rpc("settings/describe")
            async let cat = app.modelCatalog(force: true)
            let (c, d, k) = try await (conf, desc, cat)
            writable = d["writable"].truthy
            namespaces = Dictionary(d["namespaces"].array.map { ($0["ns"].str, $0) }, uniquingKeysWith: { a, _ in a })
            catalog = k
            var out: [Row] = []; var kn: [JSON] = []
            for p in c.array {
                guard let n = namespaces[p["settingsNs"].str] else { continue }
                let path = p["settingsPath"].array.map(\.str)
                let prof = path.isEmpty ? n["value"] : Self.get(n["value"], path)
                if !path.isEmpty && prof.isNull {
                    if p["settingsNs"].str == "llm-pi-ai" { var q = p.object; q["name"] = .string(Self.pname(p["provider"].str, p["displayName"].string)); kn.append(.object(q)) }
                    continue
                }
                let group = k["groups"].array.first { $0["id"].str == p["provider"].str }
                if p["provider"].str == "deepseek-account" && (group?["models"].array.isEmpty ?? true) { continue }
                let prefs = prof.isObject ? prof : [:]
                out.append(Row(provider: p["provider"].str, name: Self.pname(p["provider"].str, p["displayName"].string), ns: p["settingsNs"].str, path: path, prof: prefs, group: group,
                               removable: !path.isEmpty && !Self.get(n["user"], path).isNull && Self.get(n["base"], path).isNull,
                               keyRef: p["provider"].str == "deepseek-account" ? nil : (prefs["apiKeyEnv"].string.flatMap { $0.isEmpty ? nil : $0 } ?? Self.keyRef(p["provider"].str)), cred: nil))
            }
            let refs = Array(Set(out.compactMap(\.keyRef)))
            if !refs.isEmpty, let cr = try? await DSHClient.shared.rpc("credentials/describe", ["refs": .array(refs.map { .string($0) })]) {
                for i in out.indices { if let r = out[i].keyRef { out[i].cred = cr[r] } }
            }
            rows = out
            known = kn.sorted { $0["name"].str < $1["name"].str }
            loaded = true; error = ""
        } catch { self.error = error.localizedDescription }
    }

    func models(_ r: Row) -> [(id: String, name: String)] {
        if case .array(let own) = r.prof["models"] { return own.map { ($0["id"].str, $0["name"].string ?? $0["id"].str) } }
        return (r.group?["models"].array ?? []).map { ($0["id"].str, $0["name"].string ?? $0["id"].str) }
    }

    /// Returns an error message, or nil.
    func write(_ ns: String, _ ops: [JSON], fenced: Bool = true, app: AppModel) async -> String? {
        do {
            let v = try await DSHClient.shared.rpc("settings/mutate", .obj([("ns", .string(ns)), ("ops", .array(ops)), ("expectedRevision", fenced ? namespaces[ns]?["revision"] : nil)]))
            if v["ns"].string != nil { namespaces[ns] = v }
            return nil
        } catch let e as RPCError where e.code == "settings/conflict" {
            await load(app: app)
            return "The settings changed on the Mac meanwhile. Reloaded; try again."
        } catch { return error.localizedDescription }
    }

    func setDefault(_ provider: String, _ model: String, app: AppModel) async {
        let m = Catalog.find(catalog, provider, model)
        let cur = catalog["default"]
        let keep = (m?["reasoning"]["efforts"].array.contains { $0["id"].str == cur["reasoningEffort"].str } ?? false) && !cur["reasoningEffort"].str.isEmpty
            ? cur["reasoningEffort"].string : m?["reasoning"]["defaultEffort"].string
        let ops: [JSON] = [["op": "set", "path": ["provider"], "value": .string(provider)], ["op": "set", "path": ["model"], "value": .string(model)],
                           keep.map { ["op": "set", "path": ["reasoningEffort"], "value": .string($0)] } ?? ["op": "unset", "path": ["reasoningEffort"]]]
        if let e = await write("agent-default-model", ops, app: app) { app.say(e); return }
        app.catalogCache = nil
        app.say("Default model set")
        await load(app: app)
    }

    func setDefaultEffort(_ effort: String, app: AppModel) async {
        if let e = await write("agent-default-model", [["op": "set", "path": ["reasoningEffort"], "value": .string(effort)]], app: app) { app.say(e); return }
        app.catalogCache = nil
        app.say("Default effort set")
        await load(app: app)
    }
}

struct ProvidersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var m = ProvidersModel()
    @State private var adding = false

    var body: some View {
        List {
            if !m.loaded && m.error.isEmpty { ProgressView() }
            if !m.error.isEmpty { Text(m.error).foregroundStyle(.secondary) }
            if m.loaded {
                if !m.writable { Text("This DSH profile is read-only, so nothing here can be changed.").font(.footnote).foregroundStyle(.secondary) }
                let d = m.catalog["default"]
                Section {
                    NavigationLink { DefaultModelPicker(m: m) } label: {
                        LabeledContent("Model", value: (Catalog.find(m.catalog, d["provider"].str, d["model"].str)?["name"].string ?? (d["model"].string ?? "Not set"))
                                       + (d["reasoningEffort"].string.map { " · \($0)" } ?? ""))
                    }
                } header: { Text("Default model") } footer: { Text("Used for new chats.") }
                Section("Providers") {
                    ForEach(m.rows) { r in
                        NavigationLink { ProviderDetail(m: m, provider: r.provider) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name)
                                let n = m.models(r).count
                                Text("\(r.keyRef == nil ? "Your DeepSeek account" : r.cred?["configured"].truthy == true ? "Key saved" : "No key") · \(n) model\(n == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if m.writable { Section { Button("Add provider…") { adding = true } } }
            }
        }
        .navigationTitle("Models")
        .scrollContentBackground(.hidden)
        .background(Tok.canvas(scheme))
        .refreshable { await m.load(app: app) }
        .task { if !m.loaded { await m.load(app: app) } }
        .sheet(isPresented: $adding) { NavigationStack { AddProviderSheet(m: m) } }
    }
}

struct DefaultModelPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let m: ProvidersModel
    var body: some View {
        let d = m.catalog["default"]
        let cur = Catalog.find(m.catalog, d["provider"].str, d["model"].str)
        let effs = cur?["reasoning"]["efforts"].array ?? []
        let curEff = d["reasoningEffort"].string ?? cur?["reasoning"]["defaultEffort"].str ?? ""
        List {
            if !effs.isEmpty {
                Section("Effort · \(cur?["name"].str ?? "")") {
                    ForEach(effs.indices, id: \.self) { i in
                        CheckRow(title: effs[i]["name"].str, sub: effs[i]["description"].string, on: effs[i]["id"].str == curEff) {
                            Task { await m.setDefaultEffort(effs[i]["id"].str, app: app) }
                        }
                    }
                }
            }
            ForEach(m.catalog["groups"].array.indices, id: \.self) { gi in
                let g = m.catalog["groups"].array[gi]
                Section(g["name"].str) {
                    ForEach(g["models"].array.indices, id: \.self) { mi in
                        let x = g["models"].array[mi]
                        CheckRow(title: x["name"].str, on: g["id"].str == d["provider"].str && x["id"].str == d["model"].str) {
                            Task { await m.setDefault(g["id"].str, x["id"].str, app: app) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Default model")
        .scrollContentBackground(.hidden)
        .background(Tok.canvas(scheme))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProviderDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let m: ProvidersModel
    let provider: String
    @State private var key = ""
    @State private var url = ""
    @State private var newModel = ""
    @State private var note = ""
    @State private var confirmRemove = false
    @State private var loaded = false

    var body: some View {
        if let r = m.rows.first(where: { $0.provider == provider }) {
            let ms = m.models(r)
            let d = m.catalog["default"]
            let canURL = !r.path.isEmpty || r.prof["baseURL"].string != nil
            Form {
                if let ref = r.keyRef {
                    Section {
                        LabeledContent("Status", value: r.cred?["configured"].truthy == true ? (r.cred?["source"].str == "env" ? "From the Mac's environment" : "Saved on the Mac") : "Not set")
                        if m.writable { SecureField("Paste new key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        if m.writable && r.cred?["configured"].truthy == true && r.cred?["writable"].truthy == true {
                            Button("Remove key", role: .destructive) {
                                Task {
                                    do { try await DSHClient.shared.rpc("credentials/unset", ["ref": .string(ref)]); app.say("Key removed"); await m.load(app: app) } catch { app.say(error.localizedDescription) }
                                }
                            }
                        }
                    } header: { Text("API key") } footer: { Text(note.isEmpty ? "Stored on the Mac. It cannot be shown again." : note) }
                }
                if canURL && m.writable {
                    Section("Endpoint") { TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
                }
                Section {
                    if ms.isEmpty { Text(r.keyRef != nil && r.cred?["configured"].truthy != true ? "Models appear once a key is set" : "No models listed").foregroundStyle(.secondary) }
                    ForEach(ms, id: \.id) { x in
                        CheckRow(title: x.name, sub: x.name != x.id ? x.id : nil, on: provider == d["provider"].str && x.id == d["model"].str) {
                            Task { await m.setDefault(provider, x.id, app: app) }
                        }
                        .swipeActions {
                            if m.writable && ms.count > 1 { Button("Remove", role: .destructive) { Task { await removeModel(r, x.id) } } }
                        }
                        .contextMenu {
                            if m.writable && ms.count > 1 { Button("Remove", role: .destructive) { Task { await removeModel(r, x.id) } } }
                        }
                    }
                    if m.writable { TextField("Add model id", text: $newModel).textInputAutocapitalization(.never).autocorrectionDisabled() }
                } header: { Text("Models") } footer: { Text("Tap a model to make it the default for new chats. Swipe or long-press to remove one.") }
                if m.writable && r.removable {
                    Section { Button("Remove provider", role: .destructive) { confirmRemove = true } }
                }
            }
            .navigationTitle(r.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if m.writable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save(r) } }.bold()
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty && newModel.trimmingCharacters(in: .whitespaces).isEmpty && url.trimmingCharacters(in: .whitespaces) == r.prof["baseURL"].str)
                    }
                }
            }
            .onAppear { if !loaded { url = r.prof["baseURL"].str; loaded = true } }
            .confirmationDialog("Remove \(r.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove provider", role: .destructive) { Task { await remove(r) } }
            } message: { Text("This deletes the provider and its saved key from the Mac. Chats that used it keep their history.") }
        } else {
            ProgressView()
        }
    }

    private func save(_ r: ProvidersModel.Row) async {
        // The pasted key stays in the field until the Mac has it: a save refused for another field kept nothing.
        let k = key.trimmingCharacters(in: .whitespaces)
        let u = url.trimmingCharacters(in: .whitespaces)
        let nm = newModel.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty && ProvidersModel.keyLooksBad(k) { app.say("That does not look like a plain API key"); return }
        if !u.isEmpty && u.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) == nil { app.say("Enter an http or https address"); return }
        let cur = m.models(r)
        if !nm.isEmpty && cur.contains(where: { $0.id == nm }) { app.say("That model is already listed"); return }
        var ops: [JSON] = []
        let p = r.path.map { JSON.string($0) }
        if !k.isEmpty && !r.path.isEmpty && (r.prof["apiKeyEnv"].string ?? "").isEmpty, let ref = r.keyRef { ops.append(["op": "set", "path": .array(p + ["apiKeyEnv"]), "value": .string(ref)]) }
        if u != r.prof["baseURL"].str { ops.append(u.isEmpty ? ["op": "unset", "path": .array(p + ["baseURL"])] : ["op": "set", "path": .array(p + ["baseURL"]), "value": .string(u)]) }
        if !nm.isEmpty {
            let own = r.prof["models"].array
            let next: [JSON] = (cur + [(id: nm, name: nm)]).map { x in own.first { $0["id"].str == x.id } ?? .obj([("id", .string(x.id)), ("name", x.name != x.id ? .string(x.name) : nil)]) }
            ops.append(["op": "set", "path": .array(p + ["models"]), "value": .array(next)])
        }
        if !ops.isEmpty, let e = await m.write(r.ns, ops, app: app) { app.say(e); return }
        if !k.isEmpty, let ref = r.keyRef {
            do { try await DSHClient.shared.rpc("credentials/set", ["ref": .string(ref), "value": .string(k)]) } catch { app.say(error.localizedDescription); return }
            // Cleared only if it is still the key that was sent: one pasted while this saved is the reader's next.
            if key.trimmingCharacters(in: .whitespaces) == k { key = "" }
            note = "Key saved (\(k.count) characters). It is stored on the Mac and cannot be shown again."
        }
        newModel = ""
        app.say("Saved")
        await m.load(app: app)
    }

    private func removeModel(_ r: ProvidersModel.Row, _ id: String) async {
        let cur = m.models(r)
        guard cur.count > 1 else { app.say("A provider needs at least one model"); return }
        let own = r.prof["models"].array
        let next: [JSON] = cur.filter { $0.id != id }.map { x in own.first { $0["id"].str == x.id } ?? .obj([("id", .string(x.id)), ("name", x.name != x.id ? .string(x.name) : nil)]) }
        if let e = await m.write(r.ns, [["op": "set", "path": .array(r.path.map { .string($0) } + ["models"]), "value": .array(next)]], app: app) { app.say(e); return }
        app.say("Model removed")
        await m.load(app: app)
    }

    private func remove(_ r: ProvidersModel.Row) async {
        // The provider goes first and its key after: the other order left a provider whose key was already gone when
        // the second step failed (Codex r156).
        if let e = await m.write(r.ns, [["op": "unset", "path": .array(r.path.map { .string($0) })]], fenced: false, app: app) { app.say(e); return }
        app.catalogCache = nil
        var said = "Provider removed"
        if let ref = r.keyRef { do { try await DSHClient.shared.rpc("credentials/unset", ["ref": .string(ref)]) } catch { said += ", but its key could not be deleted: \(error.localizedDescription)" } }
        app.say(said)
        await m.load(app: app)
        dismiss()
    }
}

struct AddProviderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let m: ProvidersModel
    @State private var name = ""
    @State private var route = ""
    @State private var url = ""
    @State private var api = "openai-completions"
    @State private var key = ""
    @State private var models = ""
    @State private var busy = false

    private var valid: Bool {
        route.range(of: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
            && url.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
            && !ids.isEmpty
    }
    private var ids: [String] { Array(NSOrderedSet(array: models.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })) as? [String] ?? [] }

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $name)
                TextField("Identifier, e.g. acme-gateway", text: $route).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Provider") } footer: { Text("The identifier uses lowercase letters, digits and dashes.") }
            Section {
                TextField("https://gateway.example/v1", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Protocol", selection: $api) {
                    Text("OpenAI Chat Completions").tag("openai-completions")
                    Text("OpenAI Responses").tag("openai-responses")
                    Text("Anthropic Messages").tag("anthropic-messages")
                }
                SecureField("API key (optional)", text: $key)
            } header: { Text("Connection") } footer: { Text("Any service that speaks the OpenAI or Anthropic API.") }
            Section {
                TextField("One model id per line", text: $models, axis: .vertical).lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Fetch from endpoint") { Task { await fetch() } }
            } header: { Text("Models") } footer: { Text("Fetch asks the endpoint which models it serves.") }
            if !m.known.isEmpty {
                Section {
                    NavigationLink("Choose from known providers (\(m.known.count))") { KnownProvidersView(m: m, close: { dismiss() }) }
                }
            }
        }
        .navigationTitle("Add provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button { Task { await create() } } label: { if busy { ProgressView() } else { Text("Add").bold() } }.disabled(!valid || busy) }
        }
    }

    private func fetch() async {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard url.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { app.say("Enter the endpoint first"); return }
        if !k.isEmpty && ProvidersModel.keyLooksBad(k) { app.say("That does not look like a plain API key"); return }
        app.say("Asking the endpoint…")
        do {
            let list = try await DSHClient.shared.rpc("llm/discoverModels", ["settingsNs": "llm-pi-ai", "request": .obj([("baseURL", .string(url.trimmingCharacters(in: .whitespaces))), ("api", .string(api)), ("apiKey", k.isEmpty ? nil : .string(k))])], timeout: 40)
            let found = list.array.map { $0["id"].str }
            models = found.joined(separator: "\n")
            app.say(found.isEmpty ? "The endpoint listed no models" : "\(found.count) models found")
        } catch { app.say(error.localizedDescription) }
    }

    private func create() async {
        let k = key.trimmingCharacters(in: .whitespaces)
        if m.rows.contains(where: { $0.provider == route }) || m.known.contains(where: { $0["provider"].str == route }) { app.say("That identifier is taken"); return }
        if !k.isEmpty && ProvidersModel.keyLooksBad(k) { app.say("That does not look like a plain API key"); return }
        busy = true; defer { busy = false }
        let ref = ProvidersModel.keyRef(route)
        let value: JSON = .obj([("displayName", name.isEmpty ? nil : .string(name)), ("apiKeyEnv", k.isEmpty ? nil : .string(ref)), ("api", .string(api)),
                                ("baseURL", .string(url.trimmingCharacters(in: .whitespaces))), ("models", .array(ids.map { ["id": .string($0)] }))])
        // The key first: a provider written without its key would look added but fail on its first message.
        if !k.isEmpty { do { try await DSHClient.shared.rpc("credentials/set", ["ref": .string(ref), "value": .string(k)]) } catch { app.say(error.localizedDescription); return } }
        if let e = await m.write("llm-pi-ai", [["op": "set", "path": ["providers", .string(route)], "value": value]], app: app) { app.say(e); return }
        key = ""
        app.catalogCache = nil
        app.say("Provider added")
        await m.load(app: app)
        dismiss()
    }
}

struct KnownProvidersView: View {
    @Environment(AppModel.self) private var app
    let m: ProvidersModel
    let close: () -> Void
    @State private var picked: JSON?
    @State private var key = ""

    var body: some View {
        List {
            ForEach(m.known.indices, id: \.self) { i in
                Button(m.known[i]["name"].str) { picked = m.known[i] }.foregroundStyle(.primary)
            }
        }
        .navigationTitle("Known providers")
        .navigationBarTitleDisplayMode(.inline)
        .alert(picked?["name"].str ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })) {
            SecureField("API key (optional)", text: $key)
            Button("Cancel", role: .cancel) { picked = nil; key = "" }
            Button("Add") { if let p = picked { Task { await add(p) } } }
        } message: { Text("Adds it with its built-in model list. You can add the key later.") }
    }

    private func add(_ p: JSON) async {
        let v = key.trimmingCharacters(in: .whitespaces); key = ""
        if !v.isEmpty && ProvidersModel.keyLooksBad(v) { app.say("That does not look like a plain API key"); return }
        let ref = ProvidersModel.keyRef(p["provider"].str)
        if !v.isEmpty { do { try await DSHClient.shared.rpc("credentials/set", ["ref": .string(ref), "value": .string(v)]) } catch { app.say(error.localizedDescription); return } }
        if let e = await m.write("llm-pi-ai", [["op": "set", "path": p["settingsPath"], "value": v.isEmpty ? [:] : ["apiKeyEnv": .string(ref)]]], app: app) { app.say(e); return }
        app.catalogCache = nil
        app.say("Provider added")
        await m.load(app: app)
        close()
    }
}
