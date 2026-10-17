import Quartz
import QuickLook
import SwiftUI

@main
enum Main {
    static func main() {
        // Den was called Brain: its saved data comes along (does nothing once moved, or if Den already has a folder)
        try? FileManager.default.moveItem(at: .applicationSupportDirectory.appending(path: "Brain"), to: .applicationSupportDirectory.appending(path: "Den"))
        let args = CommandLine.arguments
        if args.contains("--read-text") { readTextHelper() } // helper process: no window, no model, exits when done
        if args.contains("--check") { runCheck() }
        if args.contains("--perf") { runPerf() }
        DenApp.main()
    }
}

struct DenApp: App {
    @State private var model = AppModel()

    init() { NSApplication.shared.setActivationPolicy(.regular) } // so `swift run` gets a Dock icon too

    var body: some Scene {
        Window("Den", id: "main") {
            RootView().environment(model)
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.hiddenTitleBar) // the sidebar and header draw the top of the window
        .windowBackgroundDragBehavior(.enabled)

        MenuBarExtra("Den", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarItems().environment(model)
        }
    }
}

struct MenuBarItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("notch") private var notch = true

    var body: some View {
        Button("Search or Ask…   ⌥Space") { QuickPanelController.shared.show(model) }
        Button("Open Den") { openWindow(id: "main"); NSApp.activate() }
        Toggle("Den in the Notch", isOn: $notch)
            .onChange(of: notch) { notch ? NotchController.shared.start(model) : NotchController.shared.stop() }
        Divider()
        Text(model.memoryStatus ?? (model.imageProgress != nil ? "Reading text in pictures…" : "Memory is up to date"))
        Divider()
        Button("Quit Den") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

func sourceColor(_ source: String) -> Color {
    ["claude-code": .orange, "browser": .blue, "git": .purple, "memory": .teal, "calendar": .red, "calc": .green, "command": .indigo,
     "clipboard": .yellow][source] ?? .gray
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let inspecting = Binding(get: { model.inspected != nil || model.selection.count > 1 },
                                 set: { if !$0 { model.selection = []; model.inspected = nil } })
        HStack(spacing: 0) {
            SideBar() // on the canvas, under the window's buttons
            VStack(spacing: 0) { // the page, in one white card
            TopBar()
            HStack(spacing: 0) {
            ContentArea()
                .inspector(isPresented: inspecting) {
                    VStack(spacing: 0) {
                        InspectorHeader()
                    Group {
                        if let e = model.inspected {
                            if e.source == "memory" { MemoryDetail(entry: e).id(e.id) }
                            else if e.source == "calendar" { EventDetail(entry: e).id(e.id) }
                            else if e.source == "day" { DayDetail(entry: e).id(e.id) }
                            else if e.path != nil { FileStory(entry: e).id(e.id) }
                            else { ActivityDetail(entry: e).id(e.id) }
                        } else {
                            SelectionSummary()
                        }
                    }
                    .frame(maxHeight: .infinity)
                    }
                    .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
                }
            }
            }
            .padding(.top, 10) // ignoring the title bar's inset stretches this up to the window's top, so start where the card does
            .ignoresSafeArea(edges: .top)
            .background(Theme.page)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
            .padding(.top, 10).padding(.bottom, 10).padding(.trailing, 10)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.rail)
        .task(id: model.query) {
            let pause = model.query.split(separator: " ").count >= 3 ? 450 : 150 // let descriptions finish
            guard (try? await Task.sleep(for: .milliseconds(pause))) != nil else { return }
            await model.search()
        }
        .task(id: model.listKey) { model.reloadList() }
        .onChange(of: model.scope) { model.scopeChanged() }
        .onChange(of: model.grouping) { model.regroup() }
        .quickLookPreview($model.quickLook)
        .sheet(isPresented: $model.organizing) { OrganizeSheet(files: model.organizeFiles).environment(model) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast).font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
            if model.selection.isEmpty, !model.searching { model.reloadList() }
            Task { await model.readNewImages(); await model.growMemory() } // only what's new since last time
        }
        .task { await snapshotIfAsked(model) }
        .task { // ⌥Space from anywhere; Den's window can be reopened from the panel or the menu bar
            model.openMain = { openWindow(id: "main") }
            HotKey.register { [model] in QuickPanelController.shared.toggle(model) }
            Windows.registerKeys()
            ClipboardHistory.shared.start()
            RAMWatch.shared.start()
            if UserDefaults.standard.object(forKey: "notch") as? Bool ?? true { NotchController.shared.start(model) }
        }
        .task {
            await model.refreshMemory()
            try? await Task.sleep(for: .seconds(3))
            await model.readNewImages()
            await model.growMemory()
        }
    }
}

// MARK: - Content: list or grid

struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.scope == "mem:ask", !model.searching { AskPane() }
            else if model.ownPane, model.scope == "home" { HomePane() }
            else if model.ownPane, model.scope == "calendar" { CalendarPane() }
            else if model.ownPane, model.scope == "mac:storage" { StoragePane() }
            else if model.ownPane, model.scope == "mac:ram" { RAMPane() }
            else if model.browsing, !model.searching, model.layout == .list { FolderPane() } // folders that open, then a file table
            else {
                VStack(spacing: 14) {
                    PathBar()
                    Group { if model.layout == .grid { GridPane() } else { ListPane() } }
                        .scrollContentBackground(.hidden)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 20)
            }
        }
        .background(Theme.page)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if model.thinking || !model.chips.isEmpty { ChipBar() }
                if model.ownPane, !["home"].contains(model.scope ?? "") || model.scope == "mem:ask" { // pages with their own layout get the breadcrumbs
                    PathBar().padding(.horizontal, 24).padding(.top, 14)
                }
            }
            .background(Theme.page)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.remembering, !model.searching { AskBar() }
        }
        .overlay {
            if model.sections.isEmpty, !model.thinking, !model.ownPane, model.scope != "mem:ask" || model.searching {
                if model.searching { ContentUnavailableView.search(text: model.query) }
                else if model.remembering { MemoryEmpty(scope: model.scope ?? "") }
                else { ContentUnavailableView(model.browsing ? "Empty folder" : "Nothing here yet", systemImage: "tray") }
            }
        }
    }
}

/// Right-click: the item's actions, and Organize for any files in the selection.
@MainActor @ViewBuilder func entryMenu(_ ids: Set<Entry.ID>, _ model: AppModel) -> some View {
    let picked = ids.compactMap(model.entry)
    if picked.count == 1, let e = picked.first {
        ForEach(model.actions(e)) { a in Button(a.title, systemImage: a.symbol, action: a.run) }
        if let path = e.path {
            Divider()
            Button("Copy Path", systemImage: "doc.on.clipboard") { copy(path) }
        }
    }
    if picked.contains(where: { $0.path != nil }) {
        Divider()
        Menu("Organize", systemImage: "wand.and.stars") {
            ForEach(OrganizeOp.allCases.filter { $0 != .folder }) { op in
                Button(op.label, systemImage: op.symbol) { model.organize(ids, op) }
            }
            Divider()
            Button("Describe…") { model.organize(ids, nil) }
        }
    }
}

struct ListPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                if section.title.isEmpty {
                    rows(section.entries)
                } else {
                    Section(section.title) { rows(section.entries) }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Entry.ID.self) { ids in entryMenu(ids, model) } primaryAction: { ids in
            if let e = ids.first.flatMap(model.entry) { model.activate(e) } // double-click and Return
        }
        .onChange(of: model.selection) { model.selectionChanged() }
        .onKeyPress(.space) { model.quickLookSelected(); return .handled }
    }

    private func rows(_ list: [Entry]) -> some View {
        ForEach(list) { e in
            Row(entry: e, showDay: model.searching || model.browsing)
                .tag(e.id)
                .onAppear { if e.id == model.lastID { model.loadMore() } } // infinite scroll
        }
    }
}

/// Thumbnails, Finder-icon-view style: click, ⌘-click, double-click, right-click.
struct GridPane: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 176), spacing: 10, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.entries) { e in
                            Cell(entry: e, selected: model.selection.contains(e.id))
                                .onTapGesture(count: 2) { model.click(e, extend: false); model.activate(e) }
                                .onTapGesture { model.click(e, extend: NSEvent.modifierFlags.contains(.command)) }
                                .contextMenu { entryMenu(model.selection.contains(e.id) ? model.selection : [e.id], model) }
                                .onAppear { if e.id == model.lastID { model.loadMore() } }
                        }
                    } header: {
                        if !section.title.isEmpty {
                            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background(.background)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = []; model.selectionChanged() } // click on empty space deselects
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.quickLookSelected(); return .handled }
        .onKeyPress(.return) { if let e = model.inspected { model.activate(e) }; return .handled }
    }
}

struct Cell: View {
    let entry: Entry
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Thumb(entry: entry, size: 104)
                .frame(width: 120, height: 108)
                .padding(5)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9))
            Text(entry.title)
                .font(.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(selected ? Color.white : Color.primary)
            Text(dayLabel(entry.date)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Quick Look's real thumbnail (photos, video frames, PDF pages, documents), else the Finder icon.
struct Thumb: View {
    let entry: Entry
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 6 : 3))
                    .shadow(color: .black.opacity(size > 40 ? 0.18 : 0), radius: 2, y: 1)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path ?? "/")).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: entry.id) {
            guard let path = entry.path, !entry.isFolder else { return }
            image = await Thumbs.image(path, size: size)
        }
    }
}

/// What the on-device model understood, as filters you can take away.
struct ChipBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(.tint).symbolEffect(.pulse, isActive: model.thinking)
                if model.thinking { Text("Understanding…").foregroundStyle(.secondary) }
                ForEach(model.chips) { chip in
                    Button { model.remove(chip) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: chip.symbol)
                            Text(chip.label).strikethrough(chip.ignored)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(chip.ignored ? .secondary : .primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(chip.ignored ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint.opacity(0.12)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(chip.ignored ? "Nothing matched this too, so results ignore it" : "Remove this filter")
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

struct Row: View {
    let entry: Entry
    let showDay: Bool

    var body: some View {
        HStack(spacing: 10) {
            Tile(entry: entry, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(entry.context).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(when).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
        }
        .frame(height: 36) // fixed: rows measured mid-animation (inspector sliding in) otherwise stay tall
    }

    private var when: String {
        guard entry.date != .distantPast else { return "" }
        if entry.source == "memory" { return dayLabel(entry.date) } // a page is about a day, not a moment
        return (showDay || entry.source == "memory") && !Calendar.current.isDateInToday(entry.date)
            ? dayLabel(entry.date) : entry.date.formatted(date: .omitted, time: .shortened)
    }
}

/// Files get their real Finder icon; activity gets a tinted symbol tile.
struct Tile: View {
    let entry: Entry
    let size: CGFloat

    var body: some View {
        if entry.path != nil {
            Thumb(entry: entry, size: size)
        } else if entry.source == "memory", entry.kind == "project" { // each project its own colour
            let color = Theme.color(for: entry.title)
            Image(systemName: "folder.fill").font(.system(size: size * 0.62))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        } else if entry.source == "memory", entry.kind == "person" {
            Avatar(name: entry.title, size: size)
        } else if entry.source == "memory", entry.kind == "day" { // a little calendar page
            VStack(spacing: 0) {
                Text(entry.date, format: .dateTime.weekday(.abbreviated)).font(.system(size: size * 0.22, weight: .bold)).foregroundStyle(.red)
                    .textCase(.uppercase)
                Text(entry.date, format: .dateTime.day()).font(.system(size: size * 0.42, weight: .medium)).monospacedDigit()
            }
            .frame(width: size, height: size)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Theme.line))
        } else {
            RoundedRectangle(cornerRadius: size * 0.26)
                .fill(sourceColor(entry.source).opacity(0.15))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: entry.source == "memory" ? MemoryKind.symbol(entry.kind) : entry.kind == "email" ? "envelope"
                          : entry.source == "command" ? entry.kind : Sources.symbol(entry.source))
                        .font(.system(size: size * 0.48, weight: .medium))
                        .foregroundStyle(sourceColor(entry.source))
                }
        }
    }
}

// MARK: - Inspector: a file's story

struct FileStory: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    @State private var story: Story?
    @State private var visits: [String: Entry] = [:]
    @State private var host: String?
    @State private var siblings: [Entry] = []
    @State private var around: [Entry] = []
    @State private var text: String?
    @State private var summary: String?
    @State private var summarizing = false

    private var url: URL { URL(fileURLWithPath: entry.path ?? "/") }
    private var isImage: Bool { (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Tile(entry: entry, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.title3.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                        Text(([entry.kind, story?.size] + (story?.facts.map(\.1) ?? [])).compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }

                ActionRow(actions: model.actions(entry))

                if !entry.isFolder {
                    FilePreview(url: url).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if summarizing || summary != nil { SummaryCard(text: summary) }

                if let s = story {
                    if !s.origins.isEmpty || s.downloaded != nil {
                        Block(title: "Came from", symbol: "arrow.down.circle") {
                            ForEach(s.origins, id: \.self) { origin in
                                if let visit = visits[origin] {
                                    RelatedRow(entry: visit, current: false) // the page itself, from your activity
                                } else if let link = URL(string: origin), link.scheme?.hasPrefix("http") == true {
                                    Link(destination: link) { Label(link.host() ?? origin, systemImage: "globe") }.help(origin)
                                } else {
                                    Label(origin, systemImage: "envelope").lineLimit(2) // e.g. the mail it was attached to
                                }
                            }
                            if let d = s.downloaded { Label(d, systemImage: "arrow.down.to.line").foregroundStyle(.secondary) }
                        }
                    }

                    Block(title: "History", symbol: "calendar") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                            ForEach(s.history, id: \.0) { k, v in
                                GridRow { Text(k).foregroundStyle(.secondary); Text(v) }
                            }
                            GridRow {
                                Text("Where").foregroundStyle(.secondary)
                                Text(tilde(((entry.path ?? "") as NSString).deletingLastPathComponent)).textSelection(.enabled)
                            }
                        }
                    }

                    if let repo = s.repo, !s.commits.isEmpty {
                        Block(title: "Commits in \(repo)", symbol: "arrow.triangle.branch") {
                            ForEach(s.commits, id: \.hash) { c in
                                HStack(spacing: 8) {
                                    Text(c.hash).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(c.subject).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(c.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let host, !siblings.isEmpty {
                    Block(title: "Also from \(host)", symbol: "square.stack") {
                        ForEach(siblings) { RelatedRow(entry: $0, current: false, showDay: true) }
                    }
                }

                if around.count > 1 {
                    Block(title: "Around this time", symbol: "clock") {
                        ForEach(around) { RelatedRow(entry: $0, current: $0.id == entry.id) }
                    }
                }

                if let text, isImage {
                    DisclosureGroup("Text in this image") {
                        Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .padding(20)
        }
        .task { await load() }
    }

    /// Cheapest first, so the panel fills in as you watch: metadata, links, neighbours, then reading the file.
    private func load() async {
        guard let path = entry.path else { return }
        let s = await Task.detached { makeStory(path) }.value
        story = s
        visits = Dictionary(s.origins.compactMap { o in model.visit(o).map { (o, $0) } }, uniquingKeysWith: { a, _ in a })
        if let h = s.origins.compactMap({ URL(string: $0)?.host() }).first {
            host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            siblings = await model.sameOrigin(entry, host: host!)
        }
        around = await model.around(entry, at: s.anchor)
        summarizing = AI.available // "Reading…" while the text is read, then summarized
        defer { summarizing = false }
        if entry.isFolder {
            let inside = listFolder(url)
            guard !inside.isEmpty else { return }
            summary = await AI.summary(of: "Folder: \(entry.title)\n" + model.material(inside), .folder)
            return
        }
        text = await fileText(url)
        guard let text else { return }
        summary = await AI.summary(of: "File name: \(entry.title)\n\n" + text, .file)
    }
}

// MARK: - Inspector: an activity item

struct ActivityDetail: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    @State private var info = AppModel.Info()
    @State private var around: [Entry] = []
    @State private var summary: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Tile(entry: entry, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.title3.weight(.semibold)).lineLimit(4).textSelection(.enabled)
                        Text(entry.context).foregroundStyle(.secondary)
                    }
                }

                ActionRow(actions: model.actions(entry, info))

                if let summary { SummaryCard(text: summary) }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("When").foregroundStyle(.secondary); Text(entry.date.formatted(date: .complete, time: .shortened)) }
                    GridRow { Text("Source").foregroundStyle(.secondary); Text(Sources.label(entry.source)) }
                    if let url = entry.url {
                        GridRow { Text("Location").foregroundStyle(.secondary); Text(url).textSelection(.enabled) }
                    }
                }

                if let body = info.record["body"] as? String, entry.source != "browser",
                   body.trimmingCharacters(in: .whitespacesAndNewlines) != entry.title {
                    Text(body.prefix(20_000))
                        .font(entry.source == "zsh" ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }

                if around.count > 1 {
                    Block(title: "Around this time", symbol: "clock") {
                        ForEach(around) { RelatedRow(entry: $0, current: $0.id == entry.id) }
                    }
                }

                if let raw = info.record["raw"] as? String {
                    DisclosureGroup("Source record") {
                        Text(pretty(raw).prefix(20_000))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .padding(20)
        }
        .task {
            info = model.info(for: entry)
            if let body = info.record["body"] as? String, body.count > 400 { // short ones say it all already
                summary = await AI.summary(of: body, .activity)
            }
            around = await model.around(entry, at: entry.date)
        }
    }

    private func pretty(_ raw: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return raw }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Pieces

/// What each Memory view is, before it has anything in it.
struct MemoryEmpty: View {
    let scope: String

    var body: some View {
        let (title, symbol, text) = [
            "mem:day": ("Your journal writes itself", "book.closed",
                        "Each day gets a short entry, written on this Mac from what you worked on, opened and read."),
            "mem:project": ("Projects appear as you work", "shippingbox",
                            "A page per project you've been active in: what it is and what's been happening lately."),
            "mem:note": ("No notes yet", "note.text", "Say “remember …” below. Claude Code's notes about you show up here too."),
            "mem:person": ("People appear as you work with them", "person.2",
                           "A page per person you build with or keep up with: from commits in your repos, profiles you visit and your conversations."),
        ][scope] ?? ("Memory", "brain", "")
        ContentUnavailableView(title, systemImage: symbol, description: Text(text))
    }
}

struct SummaryCard: View {
    let text: String? // nil while it's being worked out

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("On-device summary", systemImage: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            Text(text ?? "Reading…").foregroundStyle(text == nil ? .secondary : .primary).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ActionRow: View {
    let actions: [AppModel.Action]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                Button(action: action.run) { Label(action.title, systemImage: action.symbol) }
                    .buttonStyle(PillButton(primary: i == 0, height: 34)) // the first is the blue one
            }
        }
    }
}

struct Block<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
            content
        }
    }
}

/// A linked item: click to see its story, wherever it lives.
struct RelatedRow: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let current: Bool
    var showDay = false

    var body: some View {
        Button { model.inspected = entry } label: {
            HStack(spacing: 8) {
                Tile(entry: entry, size: 20)
                Text(entry.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(showDay ? dayLabel(entry.date) : entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(current ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
    }
}

/// The real Quick Look preview, inline, like Finder's preview pane.
struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .compact) }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
