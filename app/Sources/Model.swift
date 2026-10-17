import AppKit
import Observation

@MainActor @Observable final class AppModel {
    @ObservationIgnored let brain = BrainDB() // optional: activity from brain.py
    let recents = Recents()

    var scope: String? = "home" // "recents", "activity", an activity source, or "loc:<path>"
    var folder: URL?
    var span = Span.all
    var query = ""
    var plan: Plan? // what the model understood; shown as removable chips
    var relaxed: Set<String> = [] // filters let go of because nothing matched them all
    var thinking = false
    var selection: Set<Entry.ID> = []
    var layout = Layout.list
    var grouping = Grouping.day
    var organizing = false // the Organize sheet
    var organizeOp: OrganizeOp? // set when it was opened from a menu, so the plan is ready on arrival
    var organizeFiles: [Entry] = []
    var organizeScope: String? // "Recents", "Downloads"… when acting on the whole view
    var toast: String?
    var memoryStatus: String? // what the memory is writing right now
    var memoryCounts: [String: Int] = [:]
    var answers: [Answer] = []
    var asking = false
    @ObservationIgnored var growing = false
    @ObservationIgnored var lastQuestion: Question? // for follow-ups: "that day", "there"
    @ObservationIgnored var openMain: (() -> Void)? // reopens Den's window from the panel
    var inspected: Entry?
    var panelTab = "folders" // the panel shows your folders, or your memory
    var quickLook: URL?
    private(set) var sections: [Section] = []
    private(set) var counts: [String: Int] = [:]
    @ObservationIgnored private var loaded: [Entry] = []
    @ObservationIgnored private var done = true
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var back: [URL] = []
    @ObservationIgnored private(set) var lastID: Entry.ID?
    private let pageSize = 200

    enum Layout: String, CaseIterable { case list = "List", grid = "Grid" }
    enum Grouping: String, CaseIterable { case day = "Date", kind = "Kind", folder = "Folder", none = "None" }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let locations: [(name: String, symbol: String, url: URL)] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out = [("Home", "house", home), ("Desktop", "menubar.dock.rectangle", home.appending(path: "Desktop")),
                   ("Documents", "doc", home.appending(path: "Documents")), ("Downloads", "arrow.down.circle", home.appending(path: "Downloads"))]
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) { out.append(("iCloud Drive", "icloud", iCloud)) }
        return out
    }()

    var entries: [Entry] { sections.flatMap(\.entries) }
    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var browsing: Bool { scope?.hasPrefix("loc:") == true }
    var remembering: Bool { scope?.hasPrefix("mem:") == true }
    /// Sections with a view of their own rather than a list: the calendar, storage, RAM.
    var ownPane: Bool { !searching && ["home", "calendar", "mac:storage", "mac:ram"].contains(scope ?? "") }
    private var memoryKinds: [String] {
        ["mem:day": ["day"], "mem:project": ["project"], "mem:person": ["person"], "mem:note": ["note", "claude"]][scope ?? ""] ?? []
    }
    var listKey: String { "\(scope ?? "")|\(span.rawValue)|\(folder?.path ?? "")" }
    var sourceList: [String] { Sources.order.filter { counts[$0] != nil } + counts.keys.filter { !Sources.order.contains($0) }.sorted() }

    var title: String {
        if searching { return "Search" }
        if let folder { return FileManager.default.displayName(atPath: folder.path) }
        switch scope {
        case "home": return "Home"
        case "recents": return "Recents"
        case "activity": return "Activity"
        case "calendar": return "Calendar"
        case "mac:storage": return "Storage"
        case "mac:ram": return "RAM"
        case "mem:ask": return "Ask"
        case "mem:day": return "Journal"
        case "mem:project": return "Projects"
        case "mem:person": return "People"
        case "mem:note": return "Notes"
        case let s?: return Sources.label(s)
        default: return ""
        }
    }
    var subtitle: String {
        if !searching, let folder { return tilde(folder.path) }
        if ownPane { return "" } // these have their own headings
        if !searching, scope == "mem:ask" { return answers.isEmpty ? "On this Mac" : "\(answers.count) \(answers.count == 1 ? "question" : "questions")" }
        let n = entries.count
        let noun = searching ? (n == 1 ? "result" : "results") : (n == 1 ? "item" : "items")
        return "\(n.formatted())\(done || searching ? "" : "+") \(noun)"
    }

    init() {
        recents.onChange = { [weak self] in self?.rebuild() }
        recents.start()
        refresh()
    }

    func refresh() {
        let brain = brain
        Task { counts = await Task.detached { brain?.counts() ?? [:] }.value }
    }

    // MARK: listing

    func scopeChanged() {
        selection = []
        inspected = nil
        guard browsing, let path = scope?.dropFirst(4) else { folder = nil; return }
        let url = URL(fileURLWithPath: String(path))
        if folder != url { back = []; folder = url }
    }

    func reloadList() {
        loaded = []
        done = false
        loadMore(force: true)
    }

    func loadMore(force: Bool = false) {
        guard force || !done else { return }
        if remembering {
            done = true
            let kinds = memoryKinds
            Task {
                loaded = await MemoryStore.shared.notes(kinds).map(Entry.init(note:))
                rebuild()
            }
            return
        }
        if browsing {
            loaded = folder.map(listFolder) ?? []
            done = true
        } else if scope == "calendar" { // the last month and the next two weeks, newest first
            loaded = CalendarSource.shared.events(from: .now - 30 * 86400, to: .now + 14 * 86400).map(Entry.init(event:)).sorted { $0.date > $1.date }
            done = true
        } else if ["recents", "home"].contains(scope ?? "") || scope?.hasPrefix("mac:") == true || brain == nil {
            done = true
        } else if let brain { // read off the main thread, so switching sections never stalls the window
            let key = listKey, offset = loaded.count, size = pageSize, source = scope == "activity" ? nil : scope, (since, until) = span.bounds
            done = true // no second request while this one is out
            Task {
                let page = await Task.detached { brain.page(query: "", source: source, since: since, until: until, offset: offset, limit: size) }.value
                guard key == listKey, loaded.count == offset else { return } // you moved on meanwhile
                loaded += page
                done = page.count < size
                rebuild()
            }
            return
        }
        rebuild()
    }

    private func rebuild() {
        guard !searching else { return } // search results own the list
        if remembering {
            sections = loaded.isEmpty ? [] : [Section(title: "", entries: loaded)]
            lastID = nil
            return
        }
        let (since, until) = span.bounds
        let inSpan = { (e: Entry) in (since.map { e.date >= $0 } ?? true) && (until.map { e.date < $0 } ?? true) }
        let list: [Entry]
        if browsing {
            list = loaded
        } else if scope == "recents" {
            list = recents.files.filter(inSpan)
        } else if scope == "calendar" {
            list = loaded.filter(inSpan)
        } else if scope == "activity" { // files join the timeline only as far back as the activity pages reach
            let floor = done ? Date.distantPast : loaded.last?.date ?? .distantPast
            list = dedupe((loaded + recents.files.filter { inSpan($0) && $0.date >= floor }).sorted { $0.date > $1.date }, adjacent: true)
        } else {
            list = dedupe(loaded, adjacent: true)
        }
        sections = group(list)
        lastID = list.last?.id
    }

    func regroup() { rebuild() }

    /// Sections in the order their newest item appears; by day they stay in time order.
    private func group(_ list: [Entry]) -> [Section] {
        if grouping == .none { return list.isEmpty ? [] : [Section(title: "", entries: list)] }
        var order: [String] = [], members: [String: [Entry]] = [:]
        for e in list {
            let key = switch grouping {
            case .day: dayLabel(e.date)
            case .kind: category(e)
            default: e.path.map { tilde(($0 as NSString).deletingLastPathComponent) } ?? Sources.label(e.source)
            }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(e)
        }
        return order.map { Section(title: $0, entries: members[$0]!) }
    }

    /// Repeat visits to one page: once in search results, back-to-back repeats collapsed in timelines.
    private func dedupe(_ list: [Entry], adjacent: Bool) -> [Entry] {
        var seen = Set<String>(), last: String?
        return list.filter { e in
            let key = e.pageKey
            defer { last = key; if let key { seen.insert(key) } }
            guard let key else { return true }
            return adjacent ? last != key : !seen.contains(key)
        }
    }

    // MARK: search

    func search() async {
        token += 1
        let t = token
        selection = []
        inspected = nil
        plan = nil
        relaxed = []
        thinking = false
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { rebuild(); return }
        await run(Plan(keywords: words), t) // instant: names and contents
        guard words.count >= 3, AI.available else { return }
        thinking = true // a description, not keywords: let the on-device model read it
        let understood = await AI.plan(query)
        guard t == token else { return }
        thinking = false
        if let understood { plan = understood; await run(understood, t) }
    }

    /// Strict first; if nothing matches, let go of what people misremember most: the source, then the time,
    /// then needing every word. Whatever was let go shows as a struck-through chip.
    private func run(_ p: Plan, _ t: Int) async {
        var noSource = p, noTime = p, neither = p
        noSource.source = ""; noTime.after = nil; noTime.before = nil
        neither.source = ""; neither.after = nil; neither.before = nil
        var tries: [(plan: Plan, anyWord: Bool, dropped: Set<String>)] = [(p, false, [])]
        if !p.source.isEmpty { tries.append((noSource, false, ["source"])) }
        if p.after != nil || p.before != nil { tries.append((noTime, false, ["date"])) }
        if neither != p { tries.append((neither, false, ["source", "date"])) }
        if p.keywords.count > 1 { tries.append((neither, true, ["source", "date", "some words"])) }
        let pictures = await imageHits(p)
        var files: [Entry] = [], dropped: Set<String> = []
        for attempt in tries {
            guard let q = Query.build(attempt.plan, anyWord: attempt.anyWord) else { continue }
            files = await Spotlight.find(q)
            if !files.isEmpty || !pictures.isEmpty { dropped = attempt.dropped; break }
        }
        guard t == token else { return }
        relaxed = dropped
        let hits = { (e: Entry) in nameScore(e.title, p.keywords) }
        files = files.enumerated().sorted { (hits($0.element), -$0.offset) > (hits($1.element), -$1.offset) }.map(\.element) // most words in the name first
        let named = files.prefix { hits($0) > 0 }.count // text found inside a picture ranks right after name matches
        let found = Set(files.map(\.id))
        files.insert(contentsOf: pictures.filter { !found.contains($0.id) }, at: named)
        let activity = p.keywords.isEmpty || p.kind != "any" ? [] :
            brain?.page(query: p.keywords.joined(separator: " "), source: nil, since: p.after, until: p.before, offset: 0, limit: 60) ?? []
        let fts = ftsQuery(p.keywords.joined(separator: " "))
        let memory = fts.isEmpty ? [] : await MemoryStore.shared.search(fts, limit: 8).filter { $0.kind != "digest" }.prefix(6).map(Entry.init(note:))
        guard t == token else { return }
        sections = [Section(title: "Memory", entries: memory), Section(title: "Files", entries: files),
                    Section(title: "Activity", entries: dedupe(activity, adjacent: false))]
            .filter { !$0.entries.isEmpty }
        lastID = nil
    }

    /// Pictures whose text matches, with the matching words as their subtitle.
    private func imageHits(_ p: Plan) async -> [Entry] {
        let fts = ftsQuery(p.keywords.joined(separator: " "))
        guard !fts.isEmpty, ["any", "image", "screenshot"].contains(p.kind) else { return [] }
        return await ImageIndex.shared.search(fts).compactMap { hit -> Entry? in
            guard var e = fileEntry(path: hit.path), !isNoise(hit.path) else { return nil }
            if let after = p.after, e.date < after { return nil }
            if let before = p.before, e.date >= before { return nil }
            if p.kind == "screenshot", !isScreenshot(hit.path) { return nil }
            e.context = "“\(hit.snippet)”"
            return e
        }
    }

    // MARK: reading text in pictures (bounded: newest 500 images, one at a time, text only)

    var imageProgress: (done: Int, total: Int)?
    @ObservationIgnored private var readingImages = false

    /// Catches up on pictures not read yet: once at first, then only new ones. Gentle: one at a time, low priority.
    func readNewImages() async {
        guard !readingImages else { return }
        readingImages = true
        defer { readingImages = false; imageProgress = nil; returnFreedMemory() }
        var todo: [(path: String, mtime: Double)] = []
        for e in await imagesToRead() {
            guard let path = e.path else { continue }
            let m = modified(URL(fileURLWithPath: path))
            if await !ImageIndex.shared.isKnown(path, m) { todo.append((path, m)) }
        }
        let mtimes = Dictionary(todo.map { ($0.path, $0.mtime) }, uniquingKeysWith: { a, _ in a })
        var done = 0
        imageProgress = (0, todo.count)
        await readInHelper(todo.map(\.path)) { path, text in // one helper for the whole batch
            await ImageIndex.shared.store(path, mtimes[path] ?? 0, text)
            done += 1
            self.imageProgress = (done, todo.count)
        }
    }

    struct Chip: Identifiable {
        let id: String, label: String, symbol: String
        var ignored = false
    }

    var chips: [Chip] {
        guard let p = plan else { return [] }
        var out = p.keywords.map { Chip(id: "w:" + $0, label: $0, symbol: "textformat", ignored: relaxed.contains("some words")) }
        if p.kind != "any" { out.append(Chip(id: "kind", label: p.kind.capitalized, symbol: "doc")) }
        if !p.source.isEmpty {
            out.append(Chip(id: "source", label: "from " + p.source, symbol: "arrow.down.circle", ignored: relaxed.contains("source")))
        }
        if p.after != nil || p.before != nil {
            let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
            let label = [p.after.map { $0.formatted(f) }, p.before.map { $0.addingTimeInterval(-86400).formatted(f) }]
                .map { $0 ?? "…" }.joined(separator: " – ")
            out.append(Chip(id: "date", label: label, symbol: "calendar", ignored: relaxed.contains("date")))
        }
        return out
    }

    func remove(_ chip: Chip) {
        guard var p = plan else { return }
        switch chip.id {
        case "kind": p.kind = "any"
        case "source": p.source = ""
        case "date": p.after = nil; p.before = nil
        default: p.keywords.removeAll { "w:" + $0 == chip.id }
        }
        plan = p
        relaxed = []
        token += 1
        let t = token
        Task { await run(p, t) }
    }

    // MARK: selection & navigation

    func entry(_ id: Entry.ID) -> Entry? { entries.first { $0.id == id } }
    /// One item: its story. Several: a summary with Organize. None: the inspector closes.
    func selectionChanged() { inspected = selection.count == 1 ? selection.first.flatMap(entry) : nil }

    var selectedFiles: [Entry] { entries.filter { selection.contains($0.id) && $0.path != nil } }

    /// Grid clicks: plain click selects one, ⌘-click adds or removes.
    func click(_ e: Entry, extend: Bool) {
        if extend { if selection.remove(e.id) == nil { selection.insert(e.id) } } else { selection = [e.id] }
        selectionChanged()
    }

    /// The selected files, or with nothing selected, every file in view.
    func organize(_ ids: Set<Entry.ID>, _ op: OrganizeOp?) {
        if !ids.isEmpty { selection = ids; selectionChanged() }
        organizeFiles = ids.isEmpty ? Array(entries.filter { $0.path != nil }.prefix(300))
                                    : entries.filter { ids.contains($0.id) && $0.path != nil }
        organizeScope = ids.isEmpty ? title : nil
        organizeOp = op
        organizing = true
    }

    /// What a summary is made from: names, kinds, places, dates and origins (no file contents for groups).
    func material(_ list: [Entry]) -> String {
        list.prefix(40).map { e in
            var parts = [e.title, e.kind, e.date.formatted(.dateTime.month(.abbreviated).day())]
            if let path = e.path {
                parts.append(tilde((path as NSString).deletingLastPathComponent))
                if let host = hostOf(whereFroms(path)) { parts.append("from " + host) }
            } else { parts.append(e.context) }
            return "- " + parts.joined(separator: " · ")
        }.joined(separator: "\n") + (list.count > 40 ? "\n…and \(list.count - 40) more" : "")
    }

    func show(_ message: String) {
        toast = message
        Task { try? await Task.sleep(for: .seconds(4)); if toast == message { toast = nil } }
    }

    func open(folder url: URL) {
        if let folder { back.append(folder) }
        query = ""
        if !browsing { scope = "loc:" + url.path }
        folder = url
    }

    func goBack() { if let f = back.popLast() { folder = f } }
    func goUp() { if let f = folder, f.path != "/" { back.append(f); folder = f.deletingLastPathComponent() } }
    var canGoBack: Bool { !back.isEmpty }

    /// Double-click or Return: enter folders, otherwise the item's first action.
    func activate(_ e: Entry) {
        if e.isFolder, let path = e.path { open(folder: URL(fileURLWithPath: path)) } else { actions(e).first?.run() }
    }

    func quickLookSelected() {
        if let path = inspected?.path { quickLook = URL(fileURLWithPath: path) }
    }

    // MARK: activity details

    struct Info {
        var record: [String: Any] = [:]
        var raw: [String: Any] = [:]
    }

    func info(for e: Entry) -> Info {
        guard let id = e.dbID, let record = brain?.item(id) else { return Info() }
        let raw = (record["raw"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return Info(record: record, raw: raw ?? [:])
    }

    /// What else was happening: nearby files and activity, in time order, with this item in place.
    func around(_ e: Entry, at date: Date) async -> [Entry] {
        let window = "(kMDItemLastUsedDate >= \(Query.time(date - 3600)) && kMDItemLastUsedDate < \(Query.time(date + 3600)))"
            + " || (kMDItemDateAdded >= \(Query.time(date - 3600)) && kMDItemDateAdded < \(Query.time(date + 3600)))"
        let files = await Spotlight.find(window, sort: [], limit: 40)
        let brain = brain, sources = sourceList
        let activity = await Task.detached { sources.flatMap { brain?.near(date, source: $0) ?? [] } }.value
            + meetings(since: date - 3600, until: date + 3600).map(\.entry)
        let gap = { (x: Entry) in abs(x.date.timeIntervalSince(date)) }
        var seen: Set<String> = [e.id], perFolder: [String: Int] = [:]
        let nearest = (files + activity).sorted { gap($0) < gap($1) }.filter { x in
            if x.path != nil { perFolder[x.context, default: 0] += 1; if perFolder[x.context]! > 2 { return false } } // a clone or unzip isn't a story
            return seen.insert(x.pageKey ?? x.id).inserted
        }.prefix(8)
        var me = e
        me.date = date // at the moment the story is anchored to, not e.g. a folder's last change
        return (Array(nearest) + [me]).sorted { $0.date < $1.date }
    }

    func sameOrigin(_ e: Entry, host: String) async -> [Entry] {
        await Spotlight.find(#"kMDItemWhereFroms == "*\#(Query.clean(host))*"cd"#, sort: [], limit: 9).filter { $0.id != e.id }
    }

    func visit(_ url: String) -> Entry? { brain?.visit(url: url) }

    struct Action: Identifiable {
        let title: String, symbol: String, run: () -> Void
        var id: String { title }
    }

    func actions(_ e: Entry, _ info: Info = Info()) -> [Action] {
        if let path = e.path {
            let url = URL(fileURLWithPath: path)
            let reveal = Action(title: "Reveal in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if e.isFolder { return [Action(title: "Open", symbol: "arrow.right.circle") { [weak self] in self?.open(folder: url) }, reveal] }
            return [Action(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) },
                    Action(title: "Quick Look", symbol: "eye") { [weak self] in self?.quickLook = url }, reveal]
        }
        var out: [Action] = []
        let link = e.url ?? ""
        if link.hasPrefix("http"), let url = URL(string: link) {
            out.append(Action(title: e.source == "git" ? "Open on GitHub" : "Open Page", symbol: "safari") { NSWorkspace.shared.open(url) })
        }
        if e.source == "claude-code", let session = info.raw["sessionId"] as? String {
            let cd = (info.raw["cwd"] as? String).map { "cd '\($0.replacingOccurrences(of: "'", with: "'\\''"))' && " } ?? ""
            out.append(Action(title: "Copy Resume Command", symbol: "doc.on.doc") { copy(cd + "claude --resume " + session) })
        }
        if e.source == "zsh" {
            out.append(Action(title: "Copy Command", symbol: "doc.on.doc") { copy(info.record["body"] as? String ?? e.title) })
        }
        if link.hasPrefix("file://"), let url = URL(string: link) {
            out.append(Action(title: "Reveal in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if link.hasPrefix("http") { out.append(Action(title: "Copy Link", symbol: "link") { copy(link) }) }
        return out
    }
}

/// How well a name matches the words: exactly (the file you meant), then starting with them, then containing them.
func nameScore(_ title: String, _ words: [String]) -> Int {
    let name = title.lowercased()
    return words.map { $0.lowercased() }.reduce(0) { score, w in
        score + (name == w || (name as NSString).deletingPathExtension == w ? 10 : name.hasPrefix(w) ? 3 : name.contains(w) ? 1 : 0)
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func dayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    if d > .now { return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) } // ahead: always with its date
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: .now)).day ?? 0
    if days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    let thisYear = cal.isDate(d, equalTo: .now, toGranularity: .year)
    return d.formatted(thisYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
}
