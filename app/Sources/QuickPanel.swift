import AppKit
import Carbon.HIToolbox
import SwiftUI

// Ask from anywhere: ⌥Space opens a floating panel over whatever you're in. Type to find files, memory and
// activity at once; the first row asks the question instead, and the answer streams right there.

/// A system-wide shortcut through the Carbon hot-key API: no Accessibility permission, no dependency.
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false

    static func register(_ id: UInt32 = 1, keyCode: Int = kVK_Space, modifiers: Int = optionKey, _ run: @escaping () -> Void) {
        actions[id] = run
        guard refs[id] == nil else { return }
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var key = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &key)
                let id = key.id
                DispatchQueue.main.async { HotKey.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4252_4E31), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
    }
}

/// Takes keyboard focus without bringing Den forward (like Spotlight), and goes away when you click elsewhere.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

@MainActor final class QuickPanelController {
    static let shared = QuickPanelController()
    private var panel: KeyPanel?

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(_ model: AppModel) { isOpen ? close() : show(model) }

    func show(_ model: AppModel, text: String = "", ask: Bool = false) {
        let panel = self.panel ?? {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 80),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(button)?.isHidden = true }
            self.panel = p
            return p
        }()
        // a fresh view each time: empty field, focus in it
        panel.contentView = NSHostingView(rootView: QuickPanel(initial: text, askNow: ask, close: { [weak self] in self?.close() }).environment(model))
        if let screen = NSScreen.main { // centred, in the upper third, like Spotlight
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 340, y: f.maxY - f.height * 0.22))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    var window: NSWindow? { panel }
}

extension AppModel {
    /// As-you-type results for the panel: memory pages, files (name matches first), text in pictures, activity.
    func quickResults(_ text: String) async -> [Entry] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return ClipboardHistory.shared.entries([]) } // nothing typed: what you copied lately
        let fts = ftsQuery(text)
        if let sum = answerRow(text) { return [sum] } // a sum is just a sum
        var out = AppIndex.shared.matching(words) + Command.matching(words)
            + ClipboardHistory.shared.entries(words)
        // Pages named for what you typed lead; files named for it come next; pages that only mention it come after
        let pages = await MemoryStore.shared.search(fts, limit: 6).filter { $0.kind != "digest" }.prefix(3).map(Entry.init(note:))
        let titled = pages.filter { nameScore($0.title, words) > 0 }
        out += titled
        // Names first (Spotlight ranks content matches above them), then contents
        let clean = words.map(Query.clean).filter { !$0.isEmpty }
        let byName = clean.isEmpty ? [] : await Spotlight.find(clean.map { #"kMDItemDisplayName == "*\#($0)*"cd"# }.joined(separator: " && "),
                                                              sort: [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)], limit: 4)
        out += byName.sorted { nameScore($0.title, words) > nameScore($1.title, words) }
        out += pages.filter { p in !titled.contains { $0.id == p.id } }
        if let q = Query.build(Plan(keywords: words)) {
            out += await Spotlight.find(q, limit: 8).filter { e in !byName.contains { $0.id == e.id } }.prefix(5 - min(byName.count, 3))
        }
        for hit in await ImageIndex.shared.search(fts, limit: 2) {
            if var e = fileEntry(path: hit.path), !out.contains(where: { $0.id == e.id }) { e.context = "“\(hit.snippet)”"; out.append(e) }
        }
        var seen = Set<String>()
        let brain = brain
        out += await Task.detached { brain?.page(query: text, source: nil, since: nil, until: nil, offset: 0, limit: 6) ?? [] }.value
            .filter { seen.insert($0.pageKey ?? $0.id).inserted }.prefix(3)
        return Array(out.prefix(12))
    }

    /// Brings Den forward with this item's story open.
    func reveal(_ e: Entry) {
        QuickPanelController.shared.close()
        openMain?()
        NSApp.activate()
        inspected = e
    }
}

/// "what did I…", "who is…", or anything ending in "?"
func looksLikeQuestion(_ text: String) -> Bool {
    let t = text.lowercased().trimmingCharacters(in: .whitespaces)
    return t.hasSuffix("?") || ["what ", "when ", "where ", "who ", "why ", "how ", "which ", "did ", "do ", "does ", "is ", "are ", "was ",
                                "can ", "should ", "tell me", "show me", "summarize", "summarise"].contains { t.hasPrefix($0) }
}

struct QuickPanel: View {
    @Environment(AppModel.self) private var model
    let initial: String
    let askNow: Bool
    let close: () -> Void
    @State private var text = ""
    @State private var results: [Entry] = []
    @State private var selected = 0 // 0 is "Ask", then the results
    @State private var answer: UUID?
    @State private var answerHeight: CGFloat = 0
    @FocusState private var focused: Bool

    private var current: Answer? { answer.flatMap { id in model.answers.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 22)).foregroundStyle(.tint)
                TextField("Search files and memory, or ask a question", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                    .onSubmit { selected == 0 ? ask() : open(results[selected - 1]) }
                if model.asking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            if let a = current {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let t = a.text { Text(rich(t)).textSelection(.enabled).lineSpacing(3) }
                        else { ProgressView(a.status ?? "Looking through your memory…").controlSize(.small) }
                        ForEach(a.cited, id: \.self) { n in
                            Button { model.reveal(a.sources[n - 1]) } label: {
                                HStack(spacing: 6) {
                                    Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                                    Tile(entry: a.sources[n - 1], size: 18)
                                    Text(a.sources[n - 1].title).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
                }
                .frame(height: min(max(answerHeight, 60), 420)) // the panel grows with the answer, then scrolls
            } else if !text.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    row(0, symbol: "sparkle", title: "Ask: \(text)", subtitle: "Answered on this Mac from your memory, files and activity")
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, e in
                        row(i + 1, entry: e)
                    }
                }
                .padding(8)
            } else if !results.isEmpty { // nothing typed yet: the clipboard
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recently copied").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 2)
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, e in row(i + 1, entry: e) }
                }
                .padding(8)
            }

            Divider()
            Text(current == nil ? "↵ open · ⌘↵ ask · ⌘O show in Den · esc close" : "⌘O show in Den · esc close")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.vertical, 7)
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            text = initial
            focused = true
            if askNow { ask() }
        }
        .task(id: text) {
            guard (try? await Task.sleep(for: .milliseconds(120))) != nil else { return }
            if answer == nil || !text.isEmpty && current?.question != text { answer = nil }
            results = await model.quickResults(text)
            selected = looksLikeQuestion(text) || results.isEmpty ? 0 : 1 // ↵ asks a question, opens a search's top hit
        }
        .onKeyPress(.downArrow) { selected = min(selected + 1, results.count); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            ask()
            return .handled
        }
        .onKeyPress(characters: ["o"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if let a = current, let first = a.cited.first { model.reveal(a.sources[first - 1]) }
            else if selected > 0 { model.reveal(results[selected - 1]) }
            return .handled
        }
    }

    private func row(_ i: Int, symbol: String = "", title: String = "", subtitle: String = "", entry: Entry? = nil) -> some View {
        HStack(spacing: 10) {
            if let entry { Tile(entry: entry, size: 26) } else {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.tint).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry?.title ?? title).lineLimit(1).truncationMode(.middle)
                Text(entry?.context ?? subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let entry { Text(entry.source == "file" ? "File" : entry.source == "memory" ? MemoryKind.label(entry.kind) : Sources.label(entry.source))
                .font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected == i ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selected = i; i == 0 ? ask() : open(results[i - 1]) }
    }

    private func ask() {
        let question = text.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        Task {
            async let asked: Void = model.ask(question)
            try? await Task.sleep(for: .milliseconds(50))
            answer = model.answers.last?.id
            await asked
        }
    }

    /// Files and pages open in their own app; memory and activity open in Den with their story.
    private func open(_ e: Entry) {
        switch e.source {
        case "calc": copy(e.url ?? ""); close(); return
        case "clipboard": ClipboardHistory.shared.copy(e.id); close(); return
        case "command":
            close() // first, so a window command moves the window you were in
            if let c = Command.all.first(where: { "cmd:" + $0.title == e.id }) { c.run(model) }
            return
        default: break
        }
        if let path = e.path, !e.isFolder {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            close()
        } else if e.source == "browser", let url = e.url.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
            close()
        } else {
            model.reveal(e)
        }
    }
}
