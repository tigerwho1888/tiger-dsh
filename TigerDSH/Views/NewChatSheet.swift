import SwiftUI

/// New chat: project (default: the one with the newest chat), agent preset, model, effort, first message.
struct NewChatSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String, String?) -> Void

    @State private var workspaceId = UserDefaults.standard.string(forKey: "new.ws") ?? ""
    @State private var cwd = ""
    @State private var preset = ""
    @State private var presets: [JSON] = []
    @State private var catalog: JSON?
    @State private var model = ""          // "provider|model", "" = default
    @State private var effort = ""
    @State private var text = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !app.workspaces.isEmpty {
                        Picker("Project", selection: $workspaceId) {
                            ForEach(app.workspaces) { w in Text(w.label).tag(w.id) }
                        }
                        // Named, so a test can choose the repository it prepared instead of the default project.
                        .accessibilityIdentifier("newchat.project")
                        // The photographed order: the project, the folder it brings with it, and then the field that
                        // overrides it — a reader reads the pair before the exception to it.
                        if cwd.trimmingCharacters(in: .whitespaces).isEmpty,
                           let w = app.workspaces.first(where: { $0.id == workspaceId }) {
                            LabeledContent("Working folder") { Text(w.path).lineLimit(1).truncationMode(.head) }
                        }
                    }
                    // The folder is the reader's own field either way (#582): with a project chosen it overrides that
                    // project's own folder, and with no projects it is the only way to say where the chat goes.
                    TextField("Folder, for example /Users/you/project", text: $cwd)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if presets.count > 1 {
                        Picker("Agent preset", selection: $preset) {
                            ForEach(presets.indices, id: \.self) { i in Text(presets[i]["id"].str).tag(presets[i]["id"].str) }
                        }
                    }
                    if let cat = catalog {
                        Picker("Model", selection: $model) {
                            Text(defaultModelLabel(cat)).tag("")
                            ForEach(cat["groups"].array.indices, id: \.self) { gi in
                                let g = cat["groups"].array[gi]
                                Section(g["name"].str) {
                                    ForEach(g["models"].array.indices, id: \.self) { mi in
                                        let x = g["models"].array[mi]
                                        Text(x["name"].str).tag(modelTag(g, x))
                                    }
                                }
                            }
                        }
                        .onChange(of: model) { _, _ in effort = "" }
                        let effs = selectedModel(cat)?["reasoning"]["efforts"].array ?? []
                        if !effs.isEmpty {
                            Picker("Effort", selection: $effort) {
                                Text("Default").tag("")
                                ForEach(effs.indices, id: \.self) { i in Text(effs[i]["name"].str).tag(effs[i]["id"].str) }
                            }
                        }
                    }
                }
                Section("First message") {
                    TextField("What should we work on? (optional)", text: $text, axis: .vertical).lineLimit(3...10)
                }
            }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Not once Create is under way: the creation goes on regardless, and opened the chat and sent its
                // first message after the reader had cancelled (Codex r148).
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await create() } } label: { if creating { ProgressView() } else { Text("Create").bold() } }
                        .disabled(creating || (cwd.trimmingCharacters(in: .whitespaces).isEmpty && workspaceId.isEmpty))
                        .accessibilityIdentifier("newchat.create")
                }
            }
            .interactiveDismissDisabled(creating)
            // Kept watching, not checked once: projects that arrive after the sheet opened left Create disabled (r148).
            .onChange(of: app.workspaces.map(\.id), initial: true) { _, ids in
                if !ids.contains(workspaceId) { workspaceId = app.defaultProject()?.id ?? ids.first ?? "" }
            }
            .task {
                if app.can("model") { catalog = try? await app.modelCatalog(force: false) }
                if app.can("presets"), let p = try? await DSHClient.shared.rpc("agentPresets/list") {
                    presets = p["presets"].array
                    preset = presets.first { $0["isDefault"].truthy }?["id"].string ?? presets.first?["id"].string ?? ""
                }
            }
        }
    }

    /// The picker's tag for one model — its group and its own id, which `selectedModel` splits apart again. A
    /// function because the concatenation inline in the picker's builder is where the type checker gave up.
    private func modelTag(_ group: JSON, _ model: JSON) -> String {
        group["id"].str + "|" + model["id"].str
    }

    /// The picker's first row: the Mac's own default model, named when the catalog knows it. A function rather than
    /// an inline lookup, where the nesting inside the picker's builder is what the type checker gave up on.
    private func defaultModelLabel(_ cat: JSON) -> String {
        let def = cat["default"]
        let model = def["model"].str
        let name = Catalog.find(cat, def["provider"].str, model)?["name"].string
        return "Default · " + (name ?? model)
    }

    private func selectedModel(_ cat: JSON) -> JSON? {
        if model.isEmpty { return Catalog.find(cat, cat["default"]["provider"].str, cat["default"]["model"].str) }
        let p = model.split(separator: "|", maxSplits: 1).map(String.init)
        return p.count == 2 ? Catalog.find(cat, p[0], p[1]) : nil
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            let defaultPreset = presets.first { $0["isDefault"].truthy }?["id"].string ?? ""
            // A folder typed in wins over the project's own, and the host refuses a workspaceId and a cwd together
            // (session/create, dsh-api-session-controller): exactly one of the two goes over.
            let folder = cwd.trimmingCharacters(in: .whitespaces)
            let req: JSON = .obj([
                ("workspaceId", (app.workspaces.isEmpty || !folder.isEmpty) ? nil : .string(workspaceId)),
                ("cwd", folder.isEmpty ? nil : .string(folder)),
                ("agentPreset", presets.count > 1 && preset != defaultPreset && !preset.isEmpty ? .string(preset) : nil),
            ])
            let id = try await DSHClient.shared.rpc("session/create", ["request": req])["sessionId"].str
            if let cat = catalog, !model.isEmpty || !effort.isEmpty {
                let p = model.isEmpty ? [cat["default"]["provider"].str, cat["default"]["model"].str] : model.split(separator: "|", maxSplits: 1).map(String.init)
                do {
                    guard p.count == 2 else { throw RPCError(kind: .bad, code: "model", message: "That model is not in the Mac's list.") }
                    try await DSHClient.shared.rpc("session/selectModel", ["request": .obj([("sessionId", .string(id)), ("provider", .string(p[0])), ("model", .string(p[1])), ("reasoningEffort", effort.isEmpty ? nil : .string(effort))])])
                } catch { app.say("Chat created, but the model was not changed: \(error.localizedDescription)") }
            }
            app.rows[id] = SessionRow(id: id, blank: true)
            UserDefaults.standard.set(workspaceId, forKey: "new.ws")
            let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss()
            onCreated(id, first.isEmpty ? nil : first)
        } catch { app.say(error.localizedDescription) }
    }
}
