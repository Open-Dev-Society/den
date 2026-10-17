import FoundationModels
import SwiftUI

// Organize: plain English -> one of a few well-defined operations -> a plan you check -> moves you can undo.
// The model only picks the operation (and a folder name); deterministic code decides every path.
// Nothing is ever deleted or overwritten.

enum OrganizeOp: String, CaseIterable, Identifiable {
    case rename = "rename by content", kind = "folders by kind", month = "folders by month", site = "folders by site", folder = "into one folder"
    var id: Self { self }
    var label: String {
        switch self {
        case .rename: "Rename by what's in them"
        case .kind: "Folders by kind"
        case .month: "Folders by month"
        case .site: "Folders by site"
        case .folder: "Into one folder"
        }
    }
    var symbol: String {
        switch self {
        case .rename: "character.cursor.ibeam"
        case .kind: "square.grid.2x2"
        case .month: "calendar"
        case .site: "globe"
        case .folder: "folder.badge.plus"
        }
    }
}

@Generable
struct OrganizeDraft {
    @Guide(description: "What the person wants done to the selected files.", .anyOf(OrganizeOp.allCases.map(\.rawValue)))
    var operation: String
    @Guide(description: "The folder name when moving everything into one folder; otherwise empty.")
    var folder: String
    @Guide(description: "Which files it applies to, if the request names a kind; otherwise any.", .anyOf(["any"] + Query.kinds.keys.sorted()))
    var kind: String
}

@Generable
struct NameDraft {
    @Guide(description: "2 to 6 lowercase words joined by hyphens, no extension, e.g. stripe-invoice-sept-2026")
    var name: String
}

struct Move: Identifiable {
    let id = UUID()
    let from: URL
    let to: URL?
    var on: Bool
    var note: String? = nil
}

/// What was actually done, so it can be undone exactly.
struct Batch {
    var moves: [(from: URL, to: URL)] = []
    var created: [URL] = []
}

enum Organizer {
    private static let fm = FileManager.default

    /// Does this file fit the kind a request named? ("the PDFs", "screenshots")
    static func matches(_ e: Entry, _ kind: String) -> Bool {
        switch kind {
        case "any": true
        case "screenshot": e.path.map(isScreenshot) ?? false
        case "folder": e.isFolder
        case "pdf": category(e) == "PDFs"
        case "image": category(e) == "Images"
        case "video": category(e) == "Videos"
        case "audio": category(e) == "Audio"
        case "code": category(e) == "Code"
        case "archive": category(e) == "Archives"
        default: category(e) == "Documents" // document, spreadsheet, presentation
        }
    }

    static func interpret(_ request: String) async -> (op: OrganizeOp, folder: String, kind: String)? {
        let text = request.lowercased()
        if AI.available {
            let session = LanguageModelSession(instructions: "Pick the file operation that matches the request.")
            if let d = try? await session.respond(to: request, generating: OrganizeDraft.self, options: GenerationOptions(samplingMode: .greedy)).content,
               let op = OrganizeOp(rawValue: d.operation) {
                return (op, d.folder, Query.kinds[d.kind] == nil ? "any" : d.kind)
            }
        }
        // Without the model: plain keywords
        if text.contains("rename") || text.contains("name") { return (.rename, "", "any") }
        if text.contains("month") || text.contains("date") { return (.month, "", "any") }
        if text.contains("site") || text.contains("from") || text.contains("source") { return (.site, "", "any") }
        if text.contains("kind") || text.contains("type") { return (.kind, "", "any") }
        return nil
    }

    static func fileName(for text: String, current: String) async -> String? {
        guard AI.available else { return nil }
        let session = LanguageModelSession(instructions: """
            Suggest a short descriptive file name for this file. Keep names, numbers and dates that identify it.
            """)
        guard let d = try? await session.respond(to: "Current name: \(current)\n\n\(text.prefix(4000))",
                                                 generating: NameDraft.self, options: GenerationOptions(samplingMode: .greedy)).content
        else { return nil }
        let slug = d.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { s, c in
            if !(c == "-" && s.last == "-") { s.append(c) }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : String(slug.prefix(60))
    }

    /// Every path is decided here. Files stay next to where they are: "folders by kind" makes Images/ beside them.
    static func plan(_ op: OrganizeOp, folder: String, files: [Entry], progress: @escaping (String) -> Void) async -> [Move] {
        var taken = Set<String>(), out: [Move] = []
        func unique(_ url: URL) -> URL { // never overwrite: "name 2.ext", "name 3.ext"…
            let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var candidate = url, n = 2
            while fm.fileExists(atPath: candidate.path) || taken.contains(candidate.path) {
                candidate = url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                n += 1
            }
            taken.insert(candidate.path)
            return candidate
        }
        let safeFolder = folder.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        for (i, f) in files.enumerated() {
            guard let path = f.path else { continue }
            let from = URL(fileURLWithPath: path), dir = from.deletingLastPathComponent()
            if f.isFolder, op != .folder { // "folders by kind" shouldn't file folders into "Folders/"
                out.append(Move(from: from, to: nil, on: false, note: "Folders stay where they are"))
                continue
            }
            var bucket: String?, newName: String?, note: String?
            switch op {
            case .kind:
                bucket = category(f)
            case .month:
                let v = try? from.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
                bucket = (v?.addedToDirectoryDate ?? v?.creationDate ?? f.date).formatted(.iso8601.year().month())
            case .site:
                bucket = hostOf(whereFroms(path))
                if bucket == nil { note = "No record of where it came from" }
            case .folder:
                bucket = safeFolder.isEmpty ? nil : safeFolder
                if bucket == nil { note = "No folder name" }
            case .rename:
                progress("Reading \(i + 1) of \(files.count)…")
                if let text = await fileText(from), let name = await fileName(for: text, current: from.lastPathComponent) {
                    newName = from.pathExtension.isEmpty ? name : "\(name).\(from.pathExtension)"
                } else { note = AI.available ? "Couldn't read this one" : "Needs Apple Intelligence" }
            }
            var to: URL?
            if let bucket {
                if bucket == dir.lastPathComponent { note = "Already there" } // Images/photo.png stays put
                else { to = dir.appending(path: bucket).appending(path: from.lastPathComponent) }
            }
            if let newName {
                if newName == from.lastPathComponent { note = "Already named well" } else { to = dir.appending(path: newName) }
            }
            let target = to.map(unique)
            out.append(Move(from: from, to: target, on: target != nil, note: note))
        }
        return out
    }

    /// Moves what it can, skipping anything that would overwrite; creates folders as needed.
    static func apply(_ moves: [(from: URL, to: URL)]) -> Batch {
        var batch = Batch()
        for (from, to) in moves {
            let dir = to.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
                batch.created.append(dir)
            }
            guard !fm.fileExists(atPath: to.path), (try? fm.moveItem(at: from, to: to)) != nil else { continue }
            batch.moves.append((from, to))
        }
        return batch
    }

    /// Puts everything back and removes the folders it made, if they're empty again.
    static func undo(_ batch: Batch) -> Batch {
        let back = apply(batch.moves.reversed().map { (from: $0.to, to: $0.from) })
        for dir in batch.created.reversed() where (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
        return back
    }
}

/// Undo and Redo go through the window's own undo manager, so ⌘Z / ⇧⌘Z just work.
@MainActor func registerUndo(_ batch: Batch, _ manager: UndoManager?, _ model: AppModel, name: String = "Organize",
                             then: @escaping () -> Void = {}) {
    manager?.registerUndo(withTarget: model) { m in
        _ = Organizer.undo(batch)
        m.reloadList()
        then()
        manager?.registerUndo(withTarget: m) { m in // registered while undoing, so this is the redo
            let again = Organizer.apply(batch.moves)
            m.reloadList()
            then()
            registerUndo(again, manager, m, name: name, then: then)
        }
    }
    manager?.setActionName(name)
}

struct OrganizeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    let files: [Entry]
    @State private var request = ""
    @State private var moves: [Move] = []
    @State private var status: String?
    @State private var op: OrganizeOp?
    @State private var kind = "any"

    private var count: Int { moves.filter { $0.on && $0.to != nil }.count }
    private var targets: [Entry] { files.filter { Organizer.matches($0, kind) } }
    private var heading: String {
        let n = targets.count, noun = n == 1 ? "item" : "items"
        let only = kind == "any" ? "" : " · only \(kind == "pdf" ? "PDFs" : kind + "s")"
        return model.organizeScope.map { "Organize \(n) \(noun) in \($0)\(only)" } ?? "Organize \(n) \(noun)\(only)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(heading, systemImage: "wand.and.stars").font(.headline)

            HStack {
                TextField("Say what to do, e.g. “rename these by what's in them”", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await understand() } }
                Button("Plan") { Task { await understand() } }.disabled(request.isEmpty)
            }

            HStack(spacing: 6) {
                ForEach(OrganizeOp.allCases.filter { $0 != .folder }) { o in
                    Button { Task { await make(o, folder: "") } } label: { Label(o.label, systemImage: o.symbol) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .tint(op == o ? .accentColor : nil)
                }
            }
            .controlSize(.small)

            if let status { ProgressView(status).controlSize(.small) }

            if !moves.isEmpty {
                List($moves) { $m in
                    Toggle(isOn: $m.on) {
                        HStack(spacing: 8) {
                            Text(m.from.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(m.to == nil ? .secondary : .primary)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            if let to = m.to {
                                Text(relative(to, from: m.from)).lineLimit(1).truncationMode(.middle).fontWeight(.medium)
                            } else {
                                Text(m.note ?? "Unchanged").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(m.to == nil)
                }
                .frame(minHeight: 220)
            }

            HStack {
                Text("Nothing is deleted or overwritten. ⌘Z undoes it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(count) \(count == 1 ? "change" : "changes")") { apply() }
                    .keyboardShortcut(.defaultAction).disabled(count == 0)
            }
        }
        .padding(20)
        .frame(width: 680)
        .task { if let op = model.organizeOp { await make(op, folder: "") } }
    }

    private func understand() async {
        status = "Understanding…"
        guard let understood = await Organizer.interpret(request) else { status = "Try one of the suggestions"; return }
        kind = understood.kind
        await make(understood.op, folder: understood.folder)
    }

    private func make(_ o: OrganizeOp, folder: String) async {
        op = o
        status = "Planning…"
        moves = await Organizer.plan(o, folder: folder, files: targets) { status = $0 }
        status = nil
    }

    private func apply() {
        let done = Organizer.apply(moves.compactMap { m in m.on ? m.to.map { (from: m.from, to: $0) } : nil })
        registerUndo(done, undoManager, model)
        model.selection = []
        model.inspected = nil
        model.reloadList()
        model.show("Organized \(done.moves.count) \(done.moves.count == 1 ? "item" : "items") · ⌘Z to undo")
        dismiss()
    }

    private func relative(_ to: URL, from: URL) -> String {
        let base = from.deletingLastPathComponent().path + "/"
        return to.path.hasPrefix(base) ? String(to.path.dropFirst(base.count)) : tilde(to.path)
    }
}

/// Several things selected: what they are, and what you can do with them.
struct SelectionSummary: View {
    @Environment(AppModel.self) private var model
    @State private var summary: String?
    @State private var summarizing = false

    var body: some View {
        let files = model.selectedFiles
        let shelves = Dictionary(grouping: files, by: category).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let bytes = files.compactMap { try? URL(fileURLWithPath: $0.path!).resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        VStack(alignment: .leading, spacing: 16) {
            Text("\(model.selection.count) selected").font(.title3.weight(.semibold))
            if !files.isEmpty {
                Text(([ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)] + shelves.map { "\($0.1) \($0.1 == 1 && $0.0.hasSuffix("s") ? String($0.0.dropLast()).lowercased() : $0.0.lowercased())" })
                    .joined(separator: " · ")).foregroundStyle(.secondary)
                Button { model.organize(model.selection, nil) } label: { Label("Organize…", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }
            if summarizing || summary != nil { SummaryCard(text: summary) }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: model.selection) { // settles first: ⌘-clicking through items shouldn't fire a summary per click
            summary = nil
            guard AI.available, (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
            summarizing = true
            defer { summarizing = false }
            let picked = model.entries.filter { model.selection.contains($0.id) }
            summary = await AI.summary(of: model.material(picked), .selection)
        }
    }
}
