import AppKit
import CryptoKit
import SwiftUI

// Free up space: things you can let go of, each with the reason it's safe, because Den knows where files came
// from, when you last opened them and which projects you've gone quiet on. Everything goes to the Trash (⌘Z brings
// it back); nothing is deleted here.

struct Leftover: Identifiable, Hashable {
    let path: String
    let name: String
    let size: Int64
    let reason: String
    var safe = true // chosen for you; the rest are only suggestions
    var id: String { path }
}

struct Pile: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let note: String
    var items: [Leftover] = []
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }

/// Finding things to clean. Plain file-system work, run off the main thread.
enum Scan {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser

    /// Space on disk, summed over everything inside.
    static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walk = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = walk?.nextObject() as? URL {
            autoreleasepool { total += Int64((try? f.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func folders(in dir: URL, hidden: Bool = false) -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                                      options: hidden ? [] : [.skipsHiddenFiles])) ?? []).filter { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            return v?.isDirectory == true && v?.isSymbolicLink != true && v?.isPackage != true
        }
    }

    static func modified(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
    static func ago(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }

    static func spotlight(_ path: String, _ attr: CFString) -> Date? {
        MDItemCreate(nil, path as CFString).flatMap { MDItemCopyAttribute($0, attr) as? Date }
    }

    // MARK: build folders in projects you've gone quiet on

    /// The command that brings a project folder back, if it's one that can come back.
    static func rebuilds(_ folder: URL) -> String? {
        let dir = folder.deletingLastPathComponent(), has = { (name: String) in fm.fileExists(atPath: dir.appending(path: name).path) }
        switch folder.lastPathComponent {
        case "node_modules":
            return has("pnpm-lock.yaml") ? "pnpm install" : has("yarn.lock") ? "yarn" : has("bun.lock") || has("bun.lockb") ? "bun install" : "npm install"
        case ".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache", ".expo": return "the next build"
        case ".build": return has("Package.swift") ? "swift build" : nil
        case "target": return has("Cargo.toml") ? "cargo build" : nil
        case "Pods": return has("Podfile") ? "pod install" : nil
        case ".venv", "venv":
            return fm.fileExists(atPath: folder.appending(path: "pyvenv.cfg").path) ? (has("uv.lock") ? "uv sync" : "pip install") : nil
        default: return nil
        }
    }

    /// Git repositories within a few levels of home (not inside each other, not in Library).
    static func repos(depth: Int = 4) -> [URL] {
        let skip: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "node_modules"]
        var out: [URL] = [], level = [home]
        for _ in 0..<depth {
            level = level.flatMap { folders(in: $0) }.filter { !skip.contains($0.lastPathComponent) }.filter { dir in
                guard fm.fileExists(atPath: dir.appending(path: ".git").path) else { return true }
                out.append(dir)
                return false
            }
        }
        return out
    }

    /// When a repository was last worked in: its last commit, checkout or staging.
    static func lastWorked(_ repo: URL) -> Date {
        ["index", "HEAD", "logs/HEAD", "FETCH_HEAD"].compactMap { modified(repo.appending(path: ".git/" + $0)) }.max() ?? .distantPast
    }

    static func buildFolders(in repo: URL) -> [URL] {
        var out: [URL] = [], level = [repo]
        for _ in 0..<4 {
            level = level.flatMap { folders(in: $0, hidden: true) }.filter { dir in
                if rebuilds(dir) != nil { out.append(dir); return false }
                return !dir.lastPathComponent.hasPrefix(".")
            }
        }
        return out
    }

    static func builds(quietFor days: Double = 30) -> [Leftover] {
        repos().flatMap { repo -> [Leftover] in
            let worked = lastWorked(repo)
            guard worked < .now - days * 86400 else { return [] }
            return buildFolders(in: repo).compactMap { dir in
                let size = allocated(dir)
                guard size > 5_000_000, let command = rebuilds(dir) else { return nil }
                let inside = dir.path.dropFirst(repo.deletingLastPathComponent().path.count + 1)
                return Leftover(path: dir.path, name: String(inside), size: size,
                                reason: "\(command) brings it back · untouched since \(ago(worked))")
            }
        }
    }

    // MARK: Xcode, caches

    static func xcode() -> [Leftover] {
        let dev = home.appending(path: "Library/Developer")
        let derived = folders(in: dev.appending(path: "Xcode/DerivedData")).map { d in
            Leftover(path: d.path, name: (d.lastPathComponent.components(separatedBy: "-").first ?? "") + " build data",
                     size: allocated(d), reason: "Xcode makes it again on the next build")
        }
        let support = ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].flatMap { os in
            folders(in: dev.appending(path: "Xcode/\(os) DeviceSupport")).map { d in
                Leftover(path: d.path, name: "\(os) \(d.lastPathComponent.components(separatedBy: " ").first ?? "") device support",
                         size: allocated(d), reason: "copied again when you next connect a device on it")
            }
        }
        let sims = dev.appending(path: "CoreSimulator/Caches")
        let simCache = fm.fileExists(atPath: sims.path)
            ? [Leftover(path: sims.path, name: "Simulator caches", size: allocated(sims), reason: "the Simulator rebuilds them")] : []
        return (derived + support + simCache).filter { $0.size > 10_000_000 }
    }

    /// "com.google.Chrome" → "Google Chrome"; anything else stays as it is.
    static func appName(_ folder: String) -> String {
        guard folder.contains("."), !folder.contains(" "),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) else { return folder }
        return fm.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    static func caches() -> [Leftover] {
        let named: [String: (String, Bool)] = [ // what a few well-known caches hold, and whether to choose them for you
            "ms-playwright": ("browsers for Playwright tests; downloaded again when needed", true),
            "huggingface": ("downloaded AI models; downloaded again when needed, which can take a while", false),
            "Homebrew": ("downloaded packages Homebrew already installed", true),
        ]
        let library = folders(in: home.appending(path: "Library/Caches")).filter { !$0.lastPathComponent.hasPrefix("com.apple.") }
        let tools = folders(in: home.appending(path: ".cache"), hidden: true) + [home.appending(path: ".npm/_cacache")]
        // ~/.cache also holds things like downloaded AI models: only the well-known package caches are chosen for you
        let plainCaches: Set<String> = ["uv", "pip", "pre-commit", "node-gyp", "puppeteer", "prisma", "pnpm", "yarn", "bun", "_cacache", "go-build"]
        return (library + tools).filter { fm.fileExists(atPath: $0.path) }.compactMap { dir in
            let size = allocated(dir)
            guard size > 50_000_000 else { return nil }
            let folder = dir.lastPathComponent == "_cacache" ? "npm" : dir.lastPathComponent
            let known = named[folder]
            let library = dir.path.contains("/Library/Caches/") || plainCaches.contains(dir.lastPathComponent)
            return Leftover(path: dir.path, name: appName(folder) + " cache", size: size,
                            reason: known?.0 ?? (library ? "kept to speed things up; it fills again as you use it"
                                                         : "files a tool downloaded; it fetches them again if it needs them"),
                            safe: known?.1 ?? library)
        }
    }

    // MARK: Downloads

    static let installerTypes: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    /// "Figma-124.3.dmg" → "figma", "Raycast_v1.2.dmg" → "raycast": the app an installer is for.
    static func installerApp(_ file: String) -> String {
        let words = (file as NSString).deletingPathExtension.split(whereSeparator: { "-_ .".contains($0) })
        let skip: Set<String> = ["mac", "macos", "osx", "darwin", "universal", "arm64", "x64", "aarch64", "installer", "setup", "latest"]
        return words.prefix { w in !w.contains(where: \.isNumber) && !skip.contains(w.lowercased()) }.joined().lowercased()
    }

    static func downloads(apps: Set<String>) -> (installers: [Leftover], unopened: [Leftover]) {
        let dir = home.appending(path: "Downloads")
        var installers: [Leftover] = [], unopened: [Leftover] = []
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            let added = spotlight(item.path, kMDItemDateAdded) ?? modified(item) ?? .now
            let used = spotlight(item.path, kMDItemLastUsedDate)
            let from = hostOf(whereFroms(item.path)).map { " from \($0)" } ?? ""
            if installerTypes.contains(item.pathExtension.lowercased()) {
                guard added < .now - 7 * 86400 else { continue }
                let app = installerApp(item.lastPathComponent)
                let installed = !app.isEmpty && apps.contains(app)
                installers.append(Leftover(path: item.path, name: item.lastPathComponent, size: allocated(item),
                                           reason: installed ? "the app is installed · downloaded \(ago(added))" : "downloaded\(from) \(ago(added))",
                                           safe: installed || added < .now - 30 * 86400))
            } else if used == nil, added < .now - 30 * 86400 {
                let size = allocated(item)
                guard size > 1_000_000 else { continue }
                unopened.append(Leftover(path: item.path, name: item.lastPathComponent, size: size,
                                         reason: "downloaded\(from) \(ago(added)) · never opened", safe: false))
            }
        }
        return (installers, unopened)
    }

    // MARK: duplicates and forgotten big files

    static func sha(_ url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { autoreleasepool { hasher.update(data: chunk) } }
        return Data(hasher.finalize())
    }

    /// Exact copies: the one you used most recently stays, the rest are suggested.
    static func duplicates(_ paths: [String]) -> [Leftover] {
        let sized = Dictionary(grouping: paths) { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        return sized.filter { $0.key > 0 && $0.value.count > 1 }.values.flatMap { same -> [Leftover] in
            Dictionary(grouping: same) { sha(URL(fileURLWithPath: $0)) }.filter { $0.key != nil && $0.value.count > 1 }.values.flatMap { copies in
                let last = { (p: String) in spotlight(p, kMDItemLastUsedDate) ?? modified(URL(fileURLWithPath: p)) ?? .distantPast }
                let keep = copies.max { last($0) < last($1) }!
                return copies.filter { $0 != keep }.map { p in
                    Leftover(path: p, name: (p as NSString).lastPathComponent, size: allocated(URL(fileURLWithPath: p)),
                             reason: "same as \(tilde(keep)), which stays")
                }
            }
        }
    }

    static func forgotten(_ paths: [String]) -> [Leftover] {
        let cutoff = Date.now - 180 * 86400
        return paths.filter { !$0.contains("/Library/") && !$0.contains("/node_modules/") && !$0.contains("/.") }.compactMap { p in
            let used = spotlight(p, kMDItemLastUsedDate), added = spotlight(p, kMDItemDateAdded) ?? modified(URL(fileURLWithPath: p)) ?? .now
            guard (used ?? added) < cutoff else { return nil }
            return Leftover(path: p, name: (p as NSString).lastPathComponent, size: allocated(URL(fileURLWithPath: p)),
                            reason: used.map { "last opened \(ago($0))" } ?? "never opened · added \(ago(added))", safe: false)
        }
    }
}

@MainActor @Observable final class Cleanup {
    static let shared = Cleanup()
    var piles: [Pile] = []
    var pending: [String] = [] // still looking
    var chosen: Set<String> = []
    var scanned: Date?

    static let kinds: [Pile] = [
        Pile(id: "builds", title: "Project build folders", symbol: "hammer",
             note: "Packages and build output in projects you haven't touched for a month. One command brings each back."),
        Pile(id: "xcode", title: "Xcode leftovers", symbol: "swift", note: "Build data and device files. Xcode makes them again when it needs them."),
        Pile(id: "caches", title: "App caches", symbol: "archivebox", note: "Apps keep these to speed things up and fill them again as you use them."),
        Pile(id: "installers", title: "Installers", symbol: "shippingbox", note: "Disk images and packages in Downloads. Once the app is installed, they aren't needed."),
        Pile(id: "duplicates", title: "Duplicates", symbol: "doc.on.doc", note: "Exact copies in Downloads, Desktop and Documents. The copy you used last stays."),
        Pile(id: "unopened", title: "Downloads you never opened", symbol: "arrow.down.circle", note: "Over a month old and never opened. Suggestions only."),
        Pile(id: "large", title: "Big files you've forgotten", symbol: "externaldrive", note: "Over 500 MB, not opened in six months. Suggestions only."),
    ]

    var chosenSize: Int64 { piles.flatMap(\.items).filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        piles = []
        chosen = []
        pending = Self.kinds.map(\.id)
        let apps = Set(AppIndex.shared.apps.map { $0.name.lowercased().filter(\.isLetter) })
        let big = await Spotlight.find("kMDItemFSSize > 500000000", limit: 300).compactMap(\.path)
        let mid = await Spotlight.find("kMDItemFSSize > 20000000", limit: 2000,
                                       scopes: ["Downloads", "Desktop", "Documents"].map { Scan.home.appending(path: $0) }).compactMap(\.path)
        await withTaskGroup(of: [(String, [Leftover])].self) { group in
            group.addTask { [("builds", Scan.builds())] }
            group.addTask { [("xcode", Scan.xcode())] }
            group.addTask { [("caches", Scan.caches())] }
            group.addTask { let d = Scan.downloads(apps: apps); return [("installers", d.installers), ("unopened", d.unopened)] }
            group.addTask { [("duplicates", Scan.duplicates(mid))] }
            group.addTask { [("large", Scan.forgotten(big))] }
            for await found in group { for (id, items) in found { add(id, items) } }
        }
        scanned = .now
    }

    /// Each thing appears once, in the first pile that explains it best (builds before big files, and so on).
    private func add(_ id: String, _ found: [Leftover]) {
        pending.removeAll { $0 == id }
        var pile = Self.kinds.first { $0.id == id }!
        let taken = Set(piles.flatMap(\.items).map(\.path))
        pile.items = found.filter { item in !taken.contains(item.path) && !taken.contains { item.path.hasPrefix($0 + "/") } }
            .sorted { $0.size > $1.size }
        guard !pile.items.isEmpty else { return }
        chosen.formUnion(pile.items.filter(\.safe).map(\.id))
        piles.append(pile)
        piles.sort { a, b in Self.kinds.firstIndex { $0.id == a.id }! < Self.kinds.firstIndex { $0.id == b.id }! }
    }

    func trash(_ model: AppModel, _ undo: UndoManager?) {
        var batch = Batch(), freed: Int64 = 0
        for item in piles.flatMap(\.items) where chosen.contains(item.id) {
            var landed: NSURL?
            guard (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &landed)) != nil,
                  let to = landed as URL? else { continue }
            batch.moves.append((URL(fileURLWithPath: item.path), to))
            freed += item.size
        }
        let gone = Set(batch.moves.map(\.from.path))
        piles = piles.map { var p = $0; p.items.removeAll { gone.contains($0.path) }; return p }.filter { !$0.items.isEmpty }
        chosen.subtract(gone)
        registerUndo(batch, undo, model, name: "Move to Trash") { Task { await Cleanup.shared.scan() } }
        model.show("Moved \(bytes(freed)) to the Trash. Empty it to get the space back, or ⌘Z to undo.")
    }
}

struct StoragePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    @State private var open: Set<String> = []
    private var cleanup: Cleanup { .shared }

    var body: some View {
        VStack(spacing: 0) {
            disk.padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            List {
                ForEach(cleanup.piles) { pile in
                    Section {
                        let all = open.contains(pile.id) || pile.items.count <= 6
                        ForEach(all ? pile.items : Array(pile.items.prefix(5))) { row($0) }
                        if !all {
                            Button("Show \(pile.items.count - 5) more") { open.insert(pile.id) }.buttonStyle(.link).padding(.leading, 30)
                        }
                    } header: { header(pile) }
                }
                if !cleanup.pending.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking through " + cleanup.pending.compactMap { id in Cleanup.kinds.first { $0.id == id }?.title.lowercased() }
                            .formatted(.list(type: .and))).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else if cleanup.piles.isEmpty, cleanup.scanned != nil {
                    ContentUnavailableView("Nothing to clean", systemImage: "sparkles", description: Text("Your Mac is tidy."))
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text(cleanup.chosen.isEmpty ? "Choose what to move to the Trash" : "\(cleanup.chosen.count) chosen · \(bytes(cleanup.chosenSize))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Look Again", systemImage: "arrow.clockwise") { Task { await cleanup.scan() } }.disabled(!cleanup.pending.isEmpty)
                Button("Move to Trash", systemImage: "trash") { cleanup.trash(model, undo) }
                    .buttonStyle(.borderedProminent).disabled(cleanup.chosen.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .task { if cleanup.scanned == nil, cleanup.pending.isEmpty { await cleanup.scan() } }
    }

    private var disk: some View {
        let v = try? Scan.home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(v?.volumeTotalCapacity ?? 1), free = v?.volumeAvailableCapacityForImportantUsage ?? 0
        let used = Double(total - free) / Double(total), chosen = Double(cleanup.chosenSize) / Double(total)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(bytes(free)) free").font(.title2.weight(.semibold))
                Text("of \(bytes(total))").foregroundStyle(.secondary)
                Spacer()
                if cleanup.chosenSize > 0 { Text("\(bytes(free + cleanup.chosenSize)) free after this").foregroundStyle(.green) }
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * max(used - chosen, 0))
                    Rectangle().fill(Color.green).frame(width: geo.size.width * min(chosen, used))
                    Rectangle().fill(.quaternary)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
    }

    private func header(_ pile: Pile) -> some View {
        let ids = Set(pile.items.map(\.id))
        let all = Binding(get: { ids.isSubset(of: cleanup.chosen) },
                          set: { $0 ? cleanup.chosen.formUnion(ids) : cleanup.chosen.subtract(ids) })
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: all).toggleStyle(.checkbox).labelsHidden()
            Label(pile.title, systemImage: pile.symbol).font(.headline)
            Text(bytes(pile.size)).foregroundStyle(.secondary).monospacedDigit()
            Text(pile.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func row(_ item: Leftover) -> some View {
        let on = Binding(get: { cleanup.chosen.contains(item.id) },
                         set: { if $0 { cleanup.chosen.insert(item.id) } else { cleanup.chosen.remove(item.id) } })
        let url = URL(fileURLWithPath: item.path)
        return HStack(spacing: 10) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
            Button("Show in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.leading, 20)
        .contentShape(Rectangle())
        .onTapGesture { model.inspected = .file(item.path, date: Scan.modified(url) ?? .now, kind: url.hasDirectoryPath ? "Folder" : url.pathExtension.uppercased(), isFolder: url.hasDirectoryPath) }
    }
}
