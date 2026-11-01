import SwiftUI

/// Which screen the main area shows. The drawer's nav rows replace it by identity, like a chat swap — never a push.
enum MainPage: Hashable { case chat, chats, projects }

/// A sheet the drawer opens. Settings carries Plugins, the Task board and Digest watch inside it; Scheduled is the
/// drawer's own third row.
enum RootSheet: String, Identifiable {
    case settings, plugins, scheduler, board
    var id: String { rawValue }
}

/// The drawer, as the operator's own Claude screenshots have it: a pinned header with the serif wordmark and a glass
/// search button, one column of rows at a 46 pt pitch, a Pinned section over ten recents, and a big bottom bar. It is
/// mounted once and never moves — the chat slides right over it — so opening is a transform of the chat.
struct SideDrawer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let width: CGFloat
    let pick: (String) -> Void
    let page: (MainPage) -> Void
    let sheet: (RootSheet) -> Void
    /// Opens the Chats page with its search field already focused.
    let search: () -> Void
    /// The panel's own way out. The strip of chat beside it also closes the drawer by touch, but the strip is
    /// `accessibilityHidden` (it is decorative): a reader who cannot see the strip needs a control they can reach,
    /// which is this button.
    let close: () -> Void
    /// The root's focus, so this button is where VoiceOver lands when the drawer opens.
    @AccessibilityFocusState.Binding var focused: RootFocus?
    @State private var newChat = false
    @State private var renameId: String?
    @State private var renameText = ""
    @State private var archiveActive: String?

    /// The header is pinned above the list, so the list's own top padding has to clear exactly this much. At
    /// accessibility text sizes the wordmark is taller than the ordinary band, and the band and the list's clearance
    /// grow with it — the rows must never slide under the wordmark.
    private static let headerHeight: CGFloat = 58
    /// The wordmark's own size, scaled: the reference's 26 pt at ordinary text sizes, larger when the reader has
    /// asked for larger text. A literal 26 pt would ignore Dynamic Type entirely (Codex R11 P2).
    @ScaledMetric(relativeTo: .title) private var wordmarkSize: CGFloat = 26
    /// The band the one-row header occupies: the reference's 58 pt, or the wordmark's own line when the reader's
    /// text size makes it taller. Only the one-row arrangement uses it — the stacked arrangement's height is its
    /// content's, and the list sits under whatever the header turns out to be.
    private var headerBand: CGFloat { max(Self.headerHeight, wordmarkSize * 1.6) }
    /// The one pitch the nav rows and the chats share.
    private static let rowHeight: CGFloat = 46

    /// Ink on the light canvas, paper on the dark one: the drawer keeps the chat's own canvas colour, so its text
    /// follows it. The New chat pill uses the inverse pair.
    private var ink: Color { scheme == .dark ? Tok.paper : Tok.ink }
    private var pillFill: Color { scheme == .dark ? Tok.paper : Tok.ink }
    private var pillText: Color { scheme == .dark ? Tok.ink : Tok.paper }

    /// The circle at the bottom left holds the reader's own initial. The Mac's name is the only name this app has.
    private var initial: String {
        String(DSHClient.shared.hostLabel.first.map { Character(String($0).uppercased()) } ?? "T")
    }

    private var pinned: [SessionRow] {
        // Every pin, however old: cutting to the newest 40 first dropped an old pinned chat from the drawer.
        // Pins are picked out before the sort, so a long roster is not sorted whole on every drawer pass to find a few.
        app.groups(filter: .all, query: "").flatMap(\.rows)
            .filter { app.pinned.contains($0.id) && !app.archived.contains($0.id) }
            .sorted { $0.updated > $1.updated }
    }
    /// The chats under the Pinned section, grouped by the project they belong to (R20). Pinned chats are not in
    /// here — the section above is theirs. `recentGroups` reads through the one list cache the drawer already rides.
    private var projects: [AppModel.Group] { app.recentGroups() }

    /// The project headers the reader has folded shut, as the one comma-joined string `@AppStorage` can hold.
    @AppStorage("drawer.collapsed") private var collapsedRaw = ""
    private var collapsed: Set<String> { Self.collapsedIDs(collapsedRaw) }

    /// The ids in the stored string. Pure, so what the drawer persists across launches is testable without a UI:
    /// the fold state is the only thing this drawer keeps.
    static func collapsedIDs(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }

    /// The stored string with a project folded in, or taken back out. Sorted, so the same set of folds is always
    /// the same string and a rewrite of it is never mistaken for a change.
    static func toggled(_ raw: String, _ id: String) -> String {
        var ids = collapsedIDs(raw)
        if !ids.insert(id).inserted { ids.remove(id) }
        return ids.sorted().joined(separator: ",")
    }

    /// Fold a project's chats away, or let them back. The write is animated here rather than with an implicit
    /// animation on the list: the rows leaving and the chevron turning have to run on the same clock, or the header
    /// flashes through a state that is neither open nor closed.
    private func toggleProject(_ id: String) {
        withAnimation(.snappy(duration: 0.25)) { collapsedRaw = Self.toggled(collapsedRaw, id) }
    }

    var body: some View {
        // A direct read of the rows themselves. The lists are built through a cached grouping, and a body that only
        // goes through the cache never depends on the rows: it would run once, before the list arrives, and never
        // again — an empty list of projects under a full chat list.
        let _ = app.rows.count
        // The header and the list are stacked rather than layered: the clearance the rows need IS the header's own
        // height, at every text size and in either arrangement, so a scaled wordmark can never end up over a row
        // and the list needs no matching inset to be kept in step with it (Codex R13 P2).
        VStack(spacing: 0) {
            header
            scrolling
        }
        .frame(width: width, alignment: .leading)
        .background(Tok.canvas(scheme).ignoresSafeArea())
        .overlay(alignment: .bottom) { bottomBar }
        .sheet(isPresented: $newChat) {
            NewChatSheet { id, text in
                if let text, !text.isEmpty { PendingOpen.shared.set(id, text) }
                pick(id)
            }
            .sheetCanvas()
        }
        .alert("Rename chat", isPresented: Binding(get: { renameId != nil }, set: { if !$0 { renameId = nil } })) {
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) { renameId = nil }
            Button("Save") { if let id = renameId, !renameText.trimmingCharacters(in: .whitespaces).isEmpty { Task { await app.rename(id, renameText.trimmingCharacters(in: .whitespaces)) } }; renameId = nil }
        }
        .confirmationDialog("This chat is still working", isPresented: Binding(get: { archiveActive != nil }, set: { if !$0 { archiveActive = nil } }), titleVisibility: .visible) {
            Button("Stop and archive", role: .destructive) { if let id = archiveActive { Task { _ = await app.setArchived(id, true, stop: true) } } }
        } message: { Text("Archive it and stop its work?") }
    }

    // MARK: header

    /// Pinned above the list on a solid canvas fill (nothing on this screen resizes; the list is simply laid out
    /// under it).
    ///
    /// One row holds the wordmark and the search circle for as long as the wordmark truly fits beside it at the
    /// reader's text size. When it does not — an accessibility size, a narrow panel — the arrangement stacks instead
    /// of truncating the name: `ViewThatFits` makes that choice from the real proposed width, so it is never a
    /// threshold guessed here (Codex R13 P2). There is no close button in either arrangement: the reference's header
    /// has only the search circle, and the panel's own way out for VoiceOver is its `.escape` action, which draws
    /// nothing (an X that the photograph does not have was the design review's, not the app's).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader
            stackedHeader
        }
        .padding(.leading, 22)
        .padding(.trailing, 16)
        .padding(.top, 2)
        .background(Tok.canvas(scheme))
    }

    /// The reference's own header: the wordmark, the search circle, one row, the 58 pt band.
    private var wideHeader: some View {
        HStack(spacing: 12) {
            wordmark
            Spacer(minLength: 0)
            searchButton
        }
        .frame(height: headerBand, alignment: .top)
    }

    /// The fallback: the wordmark keeps a line of its own and the control goes under it. Increasing the band's
    /// height cannot create horizontal room, so the room comes from the arrangement.
    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            wordmark
            searchButton
        }
    }

    private var wordmark: some View {
        Text("Orcinus Orca")
            .font(.system(size: wordmarkSize, weight: .regular, design: .serif))
            // The app sets .fontDesign(.rounded) on the root, and that environment value overrides the design of
            // any font below it — including an explicit one. Restating the design here is what makes it serif.
            .fontDesign(.serif)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The header's one control. It is also where VoiceOver lands when the drawer opens (`focused == .drawer`):
    /// the panel's first element, since the visible close button is gone.
    private var searchButton: some View {
        Button { search() } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 17))
        }
        .glassCircleButton()
        .accessibilityIdentifier("drawer.search")
        .accessibilityLabel("Search chats")
        .accessibilityFocused($focused, equals: .drawer)
    }

    // MARK: list

    private var scrolling: some View {
        List {
            nav("Chats", "bubble.left.and.bubble.right") { page(.chats) }
            nav("Projects", "folder") { page(.projects) }
            if app.can("schedule") { nav("Scheduled", "calendar.badge.clock") { sheet(.scheduler) } }
            nav("Plugins", "puzzlepiece") { sheet(.plugins) }

            let pins = pinned
            if !pins.isEmpty {
                label("Pinned")
                ForEach(pins) { r in chat(r) }
            }
            ForEach(projects) { g in
                projectHeader(g, collapsed.contains(g.id))
                if !collapsed.contains(g.id) {
                    ForEach(g.rows) { r in chat(r) }
                }
            }
            viewAll
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .scrollIndicators(.hidden)
        // One pitch, no section spacing and no minimum row height: every row is exactly 46 pt, which is what makes
        // the nav rows and the chats line up as one column.
        .environment(\.defaultMinListRowHeight, 0)
        .listSectionSpacing(0)
        .contentMargins(.bottom, 84, for: .scrollContent)
        .refreshable { await app.refreshList()?.value }
    }

    /// The one leading column every row shares: an icon centred 33 pt from the drawer's edge, so the text starts at
    /// 55 pt on the nav rows and on the chats alike.
    private func lead(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17))
            .foregroundStyle(Tok.secondaryText(scheme))
            .frame(width: 44)
    }

    private func nav(_ title: String, _ symbol: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 0) {
                lead(symbol)
                Text(title).font(.system(size: 17)).foregroundStyle(ink)
                Spacer(minLength: 0)
            }
            .padding(.leading, 11)
            .frame(height: Self.rowHeight)
        }
        .buttonStyle(RowPress())
        .plainRow()
        .accessibilityIdentifier("drawer.\(title.lowercased())")
    }

    @ViewBuilder private func chat(_ r: SessionRow) -> some View {
        let isPinned = app.pinned.contains(r.id) && !app.archived.contains(r.id)
        let isArchived = app.archived.contains(r.id)
        let current = r.id == app.currentChatID
        Button { pick(r.id) } label: {
            HStack(spacing: 0) {
                lead("bubble.left")
                Text(r.displayTitle)
                    .font(.system(size: 17))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if r.running {
                    // Working is a spinner; the green dot is kept for "finished, not yet opened" (operator, 2026-10-13).
                    ProgressView().controlSize(.mini).tint(.secondary).padding(.trailing, 32)
                } else if app.doneUnseen.contains(r.id) {
                    Circle().fill(Tok.ok).frame(width: 8, height: 8).padding(.trailing, 34)
                }
            }
            .padding(.leading, 11)
            .frame(height: Self.rowHeight)
            .background {
                // The chat that is open, marked as the reference marks it: a static rounded fill, no animation.
                if current {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Tok.surface(scheme))
                        .frame(height: 44)
                        .padding(.leading, 11)
                        .padding(.trailing, 14)
                }
            }
        }
        .buttonStyle(RowPress())
        .plainRow()
        .accessibilityIdentifier("drawer.row")
        // The reference shows no second line, so the state rides in the label a reader hears.
        .accessibilityLabel(r.running ? "\(r.displayTitle), Working" : app.doneUnseen.contains(r.id) ? "\(r.displayTitle), Done" : r.displayTitle)
        .swipeActions(edge: .leading) {
            if app.can("workspace") {
                Button { Task { await app.togglePin(r.id) } } label: { Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") }.tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            if app.can("workspace") {
                Button { archive(r.id, !isArchived) } label: { Label(isArchived ? "Unarchive" : "Archive", systemImage: isArchived ? "tray.and.arrow.up" : "archivebox") }.tint(.indigo)
            }
        }
        .contextMenu {
            Button { renameText = r.title == r.id ? "" : r.title; renameId = r.id } label: { Label("Rename", systemImage: "pencil") }
            if app.can("workspace") { Button { Task { await app.togglePin(r.id) } } label: { Label(isPinned ? "Unpin" : "Pin", systemImage: "pin") } }
            if app.can("fork") { Button { Task { if let nid = await app.fork(r.id) { pick(nid) } } } label: { Label("Fork", systemImage: "arrow.triangle.branch") } }
            if app.can("workspace") { Button { archive(r.id, !isArchived) } label: { Label(isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") } }
        }
    }

    /// A project's own row: the folder in the shared lead column, the project's name, and the chevron that turns
    /// as its chats fold away. It sits on the same 46 pt pitch as everything else, so the folder lines up under the
    /// Projects row above it and the chats below it keep one text column.
    private func projectHeader(_ g: AppModel.Group, _ folded: Bool) -> some View {
        let n = g.rows.count
        return Button { toggleProject(g.id) } label: {
            HStack(spacing: 0) {
                lead("folder")
                Text(g.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tok.secondaryText(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tok.secondaryText(scheme))
                    .rotationEffect(.degrees(folded ? -90 : 0))
                    .padding(.trailing, 30)
            }
            .padding(.leading, 11)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .plainRow()
        .accessibilityIdentifier("drawer.project")
        .accessibilityLabel("\(g.label), \(n) \(n == 1 ? "chat" : "chats")")
        .accessibilityHint("Shows or hides its chats")
        .accessibilityValue(folded ? "Collapsed" : "Expanded")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Tok.secondaryText(scheme))
            .padding(.leading, 22)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .plainRow()
    }

    private var viewAll: some View {
        Button { page(.chats) } label: {
            HStack(spacing: 4) {
                Text("View all").font(.system(size: 15)).foregroundStyle(Tok.secondaryText(scheme))
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.secondaryText(scheme))
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
            .frame(height: 44)
        }
        .buttonStyle(RowPress())
        .plainRow()
        .accessibilityIdentifier("drawer.viewall")
    }

    /// The bottom bar: the reader's initial in a grey circle on the left, an inverse New chat pill on the right,
    /// floating over the list on a solid band of the panel's own canvas.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { sheet(.settings) } label: {
                Text(initial)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 43, height: 43)
                    .background(Circle().fill(Tok.surface(scheme)))
            }
            .accessibilityIdentifier("drawer.settings")
            .accessibilityLabel("Settings")
            Spacer(minLength: 0)
            Button { newChat = true } label: {
                // The cub, not a plus: the reference's own New chat pill carries the app's face.
                HStack(spacing: 6) {
                    Image("Mascot").resizable().scaledToFit().frame(width: 18, height: 18)
                    Text("New chat")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(pillText)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(Capsule().fill(pillFill))
            }
            .accessibilityIdentifier("home.new")
            .accessibilityLabel("New chat")
        }
        .padding(.leading, 25)
        .padding(.trailing, 27)
        .padding(.vertical, 10)
        // One flat colour under the bar: no Material and no blur, and nothing about the panel's size changes.
        .background(Tok.canvas(scheme).ignoresSafeArea(edges: .bottom))
        .frame(maxWidth: .infinity)
    }

    private func archive(_ id: String, _ on: Bool) {
        Task { if await app.setArchived(id, on) == "active" { archiveActive = id } }
    }
}

/// A row of the drawer's list: no separators, no insets and no card of its own — the panel is one canvas.
private extension View {
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// The press fill the drawer's rows share: a soft rounded grey while the finger is down, inset 8 pt.
struct RowPress: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? Tok.surface(scheme) : Color.clear))
            .contentShape(Rectangle())
    }
}

/// The chat list as a page of its own, shown in the main area by the drawer's Chats row: a search field, plain rows
/// with the title over a relative time, a funnel for the filters, and an ink New chat pill.
struct ChatsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let workspace: String?
    let focusSearch: Bool
    let pick: (String) -> Void
    let newChat: () -> Void
    /// The root's VoiceOver focus, carried by this page's own menu button while the page is the active one.
    var focused: AccessibilityFocusState<RootFocus?>.Binding?
    @State private var query = ""
    @State private var filter: AppModel.Filter = .all
    @FocusState private var searchFocused: Bool
    /// A working chat the reader swiped to archive: the Mac refuses until it is stopped, so this asks, as the drawer does.
    @State private var archiveActive: String?

    private var ink: Color { scheme == .dark ? Tok.paper : Tok.ink }

    var body: some View {
        // Same direct read as the drawer: the rows are read through a cached grouping.
        let _ = app.rows.count
        // The whole list is grouped under its projects, except where a group would say nothing: a search already
        // answers with one list of matches, and a single project's own page is one project. Only the top-level,
        // unsearched page is sections (R20).
        let grouped = workspace == nil && query.trimmingCharacters(in: .whitespaces).isEmpty
        let sections = grouped ? app.groups(filter: filter, query: "").filter { !$0.rows.isEmpty } : []
        // The flat list is built only when it is what the page shows: in the grouped case it would be a second
        // walk and sort of every row on each pass for a list nothing draws.
        let rows = sections.isEmpty ? app.chats(filter: filter, query: query, workspace: workspace, limit: 300) : []
        VStack(spacing: 0) {
            search
            List {
                if sections.isEmpty {
                    if rows.isEmpty {
                        // A filter that empties the list says what that means and offers the way back, rather
                        // than "No chats", which reads as if the history were gone.
                        VStack(spacing: Tok.sp3) {
                            Text(!query.isEmpty ? "No chats match" : filter == .unread ? "You're all caught up" : filter == .all ? "No chats" : "Nothing here right now")
                                .font(Tok.body).foregroundStyle(Tok.secondaryText(scheme))
                            if query.isEmpty && filter != .all {
                                Button("Show all chats") { filter = .all }
                                    .font(Tok.chip).frame(minHeight: 44)
                                    .foregroundStyle(Tok.actionTint(scheme))
                                    .accessibilityIdentifier("filter.reset")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, Tok.sp5)
                        .plainRow()
                    }
                    ForEach(rows) { r in row(r) }
                } else {
                    ForEach(sections) { g in
                        Section {
                            // Newest first inside the project, which is the order this page has always had — the
                            // grouping only puts a name over each run of it.
                            ForEach(g.rows.sorted { $0.updated > $1.updated }) { r in row(r) }
                        } header: {
                            sectionHeader(g.label)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Tok.canvas(scheme))
            .contentMargins(.bottom, 76, for: .scrollContent)
            .refreshable { await app.refreshList()?.value }
        }
        .background(Tok.canvas(scheme))
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { DrawerMenuButton(focused: focused) }
            ToolbarItem(placement: .topBarTrailing) { funnel }
        }
        .overlay(alignment: .bottomTrailing) { newChatPill }
        .onAppear { if focusSearch { searchFocused = true } }
        .confirmationDialog("This chat is still working", isPresented: Binding(get: { archiveActive != nil }, set: { if !$0 { archiveActive = nil } }), titleVisibility: .visible) {
            Button("Stop and archive", role: .destructive) { if let id = archiveActive { Task { _ = await app.setArchived(id, true, stop: true) } } }
        } message: { Text("Archive it and stop its work?") }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.footnote).foregroundStyle(Tok.secondaryText(scheme))
            TextField("Search chats", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Tok.body)
                .focused($searchFocused)
                .accessibilityIdentifier("chats.search")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .panelChrome(Tok.rCard)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// The funnel the reference keeps at the top right: one menu of the five filters.
    private var funnel: some View {
        Menu {
            ForEach(AppModel.Filter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    if filter == f { Label(label(f), systemImage: "checkmark") } else { Text(label(f)) }
                }
                .accessibilityIdentifier("filter.\(f.rawValue)")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("chats.filter")
        .accessibilityLabel("Filter")
    }

    private func label(_ f: AppModel.Filter) -> String {
        switch f {
        case .all: return "All"
        case .working: return "Working"
        case .answer: return "Needs you"
        // Finished while you were away and not opened since: the chats with a reply waiting to be read.
        case .unread: return "Ready to read"
        case .archived: return "Archived"
        }
    }

    /// A project's name over its chats: the same words the drawer's header uses, in the page's secondary ink. It is
    /// painted on the canvas because a plain List's headers stick, and a row scrolling under a clear one would read
    /// through it.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Tok.secondaryText(scheme))
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .background(Tok.canvas(scheme))
            .plainRow()
    }

    @ViewBuilder private func row(_ r: SessionRow) -> some View {
        Button { pick(r.id) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.displayTitle).font(.system(size: 17)).foregroundStyle(ink).lineLimit(1)
                    Text(Fmt.agoLong(r.updated)).font(.footnote).foregroundStyle(Tok.secondaryText(scheme))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Tok.secondaryText(scheme).opacity(0.7))
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        // A row that dims under the finger, so the tap is seen before the chat opens.
        .buttonStyle(PressableStyle())
        .plainRow()
        .accessibilityIdentifier("chat.row")
        .swipeActions(edge: .trailing) {
            if app.can("workspace") {
                let isArchived = app.archived.contains(r.id)
                Button { Task { if await app.setArchived(r.id, !isArchived) == "active" { archiveActive = r.id } } } label: { Label(isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") }.tint(.indigo)
            }
        }
    }

    private var newChatPill: some View {
        Button { newChat() } label: {
            HStack(spacing: 6) {
                Image("Mascot").resizable().scaledToFit().frame(width: 18, height: 18)
                Text("New chat")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(scheme == .dark ? Tok.ink : Tok.paper)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Capsule().fill(scheme == .dark ? Tok.paper : Tok.ink))
        }
        .padding(.trailing, 16)
        .padding(.bottom, 6)
        .accessibilityIdentifier("chats.new")
        .accessibilityLabel("New chat")
    }
}

/// The project list the drawer's Projects row shows: one row per workspace, each opening the Chats page filtered
/// to it.
struct ProjectsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let open: (String) -> Void
    /// The root's VoiceOver focus, carried by this page's own menu button while the page is the active one.
    var focused: AccessibilityFocusState<RootFocus?>.Binding?

    private var ink: Color { scheme == .dark ? Tok.paper : Tok.ink }

    var body: some View {
        // The same count the project's own page lists: the visible chats of that workspace, read through the one
        // grouping cache rather than walked per row.
        let counts = Dictionary(app.groups(filter: .all, query: "").map { ($0.id, $0.total) }, uniquingKeysWith: { first, _ in first })
        List {
            ForEach(app.workspaces) { w in
                Button { open(w.id) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.label).font(.system(size: 17)).foregroundStyle(ink).lineLimit(1)
                            Text(w.path).font(.footnote).foregroundStyle(Tok.secondaryText(scheme)).lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                        Text("\(counts[w.id] ?? 0)")
                            .font(.system(size: 15))
                            .foregroundStyle(Tok.secondaryText(scheme))
                            .monospacedDigit()
                            .accessibilityLabel("\((counts[w.id] ?? 0)) \((counts[w.id] ?? 0) == 1 ? "chat" : "chats")")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Tok.secondaryText(scheme).opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .plainRow()
                .accessibilityIdentifier("project.row")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tok.canvas(scheme))
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerMenuButton(focused: focused) } }
    }
}

/// The drawer's own pan: a right swipe anywhere on the chat opens it, a left drag closes it. A plain SwiftUI drag on
/// the container either loses to the chat's own scroll views or steals their touches, and a code block scrolls
/// sideways, so this is a real pan recognizer whose delegate refuses touches that belong to a sideways scroller or
/// to a text view, and whose begin check wants a mostly horizontal movement.
struct DrawerPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    /// A new touch has won the gesture: the drawer's spring lets go of the card where it is drawn, so an
    /// interruption picks up from the presented offset rather than from the last destination (Codex R12).
    let began: () -> Void
    let moved: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer, let v = p.view else { return false }
            let t = p.velocity(in: v)
            // A slow drag reports no velocity at all; the touch rules above decide for it instead. Either direction
            // begins: right opens the drawer, left closes it, and the handler tells them apart.
            if abs(t.x) < 1 && abs(t.y) < 1 { return true }
            return abs(t.x) > abs(t.y) * 1.5
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let v = view {
                if v is UITextView || v is UITextField { return false }
                if let s = v as? UIScrollView, !(s is UICollectionView), s.contentSize.width > s.bounds.width + 1 { return false }
                view = v.superview
            }
            return true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        g.isEnabled = enabled
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) { g.isEnabled = enabled }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let t = g.translation(in: g.view)
        switch g.state {
        case .began: began()
        case .changed: moved(t.x)
        case .ended, .cancelled, .failed: ended(t.x, g.velocity(in: g.view).x)
        default: break
        }
    }
}
