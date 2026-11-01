import SwiftUI

/// Every settings namespace the host reports, edited generically. This is the phone's answer to the desktop's
/// separate settings pages — agent loop, subagents, the bash sandbox, web search, the session log, the account —
/// without a screen per page: the host describes the values and this screen picks a control from each value's type.
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var namespaces: [JSON] = []
    @State private var error = ""
    @State private var loading = true
    @State private var writable = false
    @State private var edit: Edit?

    /// One pending change: a string or a number typed into the alert.
    struct Edit: Identifiable {
        let id = UUID()
        let ns: String
        let revision: Double?
        let path: [String]
        let title: String
        var text: String
        let isNumber: Bool
    }

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if !error.isEmpty {
                ContentUnavailableView(error, systemImage: "gearshape")
            } else {
                if !writable {
                    Section { Text("These settings are read-only on this Mac.").font(.footnote).foregroundStyle(.secondary) }
                }
                ForEach(namespaces.indices, id: \.self) { i in
                    let n = namespaces[i]
                    Section {
                        let value = n["value"]
                        if value.object.isEmpty {
                            Text("Empty").foregroundStyle(.secondary)
                        } else {
                            ForEach(value.object.keys.sorted(), id: \.self) { key in
                                row(ns: n["ns"].str, revision: n["revision"].double, key: key, value: value[key])
                            }
                        }
                    } header: {
                        Text(n["ns"].str).textCase(nil).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle("Advanced settings")
        .scrollContentBackground(.hidden)
        .background(Tok.canvas(scheme))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(edit?.title ?? "", isPresented: Binding(get: { edit != nil }, set: { if !$0 { edit = nil } })) {
            if let e = edit {
                TextField(e.title, text: Binding(get: { e.text }, set: { edit?.text = $0 }))
                    .keyboardType(e.isNumber ? .decimalPad : .default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { edit = nil }
                Button("Save") { save() }
            }
        } message: {
            Text("This is written to DSH on your Mac.")
        }
    }

    @ViewBuilder private func row(ns: String, revision: Double?, key: String, value: JSON) -> some View {
        switch value {
        case .bool(let on):
            Toggle(key, isOn: Binding(get: { on }, set: { v in Task { await set(ns, [key], .bool(v), revision: revision) } }))
                .disabled(!writable)
        case .number(let n):
            Button { edit = Edit(ns: ns, revision: revision, path: [key], title: key, text: trim(n), isNumber: true) } label: {
                HStack { Text(key); Spacer(); Text(trim(n)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .disabled(!writable)
        case .string(let s):
            Button { edit = Edit(ns: ns, revision: revision, path: [key], title: key, text: s, isNumber: false) } label: {
                HStack { Text(key); Spacer(); Text(s.isEmpty ? "—" : s).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            .disabled(!writable)
        case .array(let a):
            HStack { Text(key); Spacer(); Text("\(a.count) item\(a.count == 1 ? "" : "s")").foregroundStyle(.secondary) }
        case .object:
            HStack { Text(key); Spacer(); Text("group").foregroundStyle(.secondary) }
        case .null:
            HStack { Text(key); Spacer(); Text("not set").foregroundStyle(.secondary) }
        }
    }

    private func trim(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 9e15 ? String(Int(n)) : String(format: "%g", n)
    }

    private func save() {
        guard let e = edit else { return }
        let value: JSON = e.isNumber ? (Double(e.text.trimmingCharacters(in: .whitespaces)) .map { JSON.number($0) } ?? .null) : .string(e.text)
        edit = nil
        guard case .null = value, e.isNumber else { Task { await set(e.ns, e.path, value, revision: e.revision) }; return }
        app.say("That is not a number")
    }

    func load() async {
        do {
            let d = try await DSHClient.shared.rpc("settings/describe")
            writable = d["writable"].truthy
            namespaces = d["namespaces"].array.sorted { $0["ns"].str < $1["ns"].str }
            error = ""
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Writes one value. The host fences every write with the revision it described, so a settings change made on
    /// the Mac in the meantime comes back as a conflict and is reloaded rather than overwritten.
    private func set(_ ns: String, _ path: [String], _ value: JSON, revision: Double?) async {
        do {
            _ = try await DSHClient.shared.rpc("settings/mutate", .obj([
                ("ns", .string(ns)),
                ("ops", .array([.obj([("op", .string("set")), ("path", .array(path.map { .string($0) })), ("value", value)])])),
                ("expectedRevision", revision.map { JSON.number($0) }),
            ]))
            app.say("Saved")
            await load()
        } catch let e as RPCError where e.code == "settings/conflict" {
            await load()
            app.say("That setting changed on the Mac meanwhile. Reloaded; try again.")
        } catch {
            app.say(error.localizedDescription)
        }
    }
}
