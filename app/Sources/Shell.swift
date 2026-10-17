import CoreServices
import SwiftUI

// The window, laid out like a modern file manager: an icon rail, a panel with your folders (or memory) as a tree
// and a storage card, a top bar with search and one blue action, and pages made of a storage overview, folders that
// open, file cards and a file table. Icons are Iconsax.

enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let page = dynamic(.white, NSColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1))
    static let panel = dynamic(NSColor(white: 0.985, alpha: 1), NSColor(red: 0.098, green: 0.098, blue: 0.106, alpha: 1))
    static let rail = dynamic(NSColor(white: 0.965, alpha: 1), NSColor(red: 0.07, green: 0.07, blue: 0.078, alpha: 1))
    static let card = dynamic(.white, NSColor(red: 0.118, green: 0.118, blue: 0.13, alpha: 1))
    static let well = dynamic(NSColor(white: 0.955, alpha: 1), NSColor(white: 1, alpha: 0.06))
    static let line = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.085))
    static let ink = dynamic(NSColor(white: 0.1, alpha: 1), NSColor(white: 0.95, alpha: 1))
    static let onInk = dynamic(.white, NSColor(white: 0.08, alpha: 1))
    static let brand = Color(red: 0.2, green: 0.5, blue: 0.97)
    static let folderGrey = dynamic(NSColor(white: 0.53, alpha: 1), NSColor(white: 0.6, alpha: 1)) // the tree's folders
    static let selected = dynamic(NSColor(white: 0.945, alpha: 1), NSColor(white: 1, alpha: 0.08))
    static let treeLine = dynamic(NSColor(white: 0.82, alpha: 1), NSColor(white: 1, alpha: 0.16))
    // the storage card: a grey rim with a tab, around a clearly lighter panel, in both modes
    static let rim = dynamic(NSColor(white: 0.935, alpha: 1), NSColor(white: 0.125, alpha: 1))
    static let rimPanel = dynamic(.white, NSColor(white: 0.185, alpha: 1))
    static let folderBack = Color(red: 0.31, green: 0.6, blue: 0.9) // the big folders: sky blue, frosted front
    static let folderLid = Color(red: 0.42, green: 0.69, blue: 0.95)
    static let projects: [Color] = [.pink, .purple, .indigo, .teal, .orange, .mint, .blue, .cyan]

    /// The same colour for the same name, every time (Swift's own hash changes each launch).
    static func color(for name: String) -> Color { projects[seed(name) % projects.count] }
    static func seed(_ name: String) -> Int { name.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fffffff } }
}

extension View {
    /// A white card with a hairline, the app's basic surface.
    func card(_ radius: CGFloat = 12) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Outline buttons like "Sort by" and "Filter"; `primary` is the one blue button.
struct PillButton: ButtonStyle {
    var primary = false
    var height: CGFloat? = nil // a row of buttons shares one height

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: height ?? 34)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(primary ? Theme.brand : Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(primary ? Color.white.opacity(0.18) : Theme.line))
            .shadow(color: primary ? Theme.brand.opacity(0.3) : .black.opacity(0.04), radius: primary ? 6 : 1, y: 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// A segmented control: a grey well, the chosen segment raised.
struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var icons = false
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Group {
                        if icons { Icon(label, size: 17, bold: selection == value) } else { Text(label) }
                    }
                    .font(.system(size: compact ? 12 : 13, weight: selection == value ? .medium : .regular))
                    .foregroundStyle(selection == value ? (icons ? Theme.brand : Color.primary) : Color.secondary)
                    .padding(.horizontal, icons ? 9 : 14).frame(height: compact ? 24 : 30)
                    .frame(maxWidth: icons ? nil : .infinity)
                    .background {
                        if selection == value {
                            RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous).fill(Theme.card).shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 2 : 3)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
    }
}

/// Initials in a colour of their own, for people.
struct Avatar: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let hue = Double(Theme.seed(name) % 360) / 360
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.45))
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.25, brightness: 0.95), in: Circle())
            .overlay(Circle().strokeBorder(Theme.page, lineWidth: 2))
    }
}

// MARK: - Sidebar: where to go, your folders or your memory, and storage

struct SideBar: View {
    @Environment(AppModel.self) private var model
    private static let mac = Host.current().localizedName ?? "This Mac"

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                SideRow(tag: "home", icon: "Home2", title: "Home")
                SideRow(tag: "recents", icon: "Clock", title: "Recents", count: model.recents.files.count)
                if model.brain != nil { SideRow(tag: "activity", icon: "Activity", title: "Activity") }
                SideRow(tag: "calendar", icon: "Calendar", title: "Calendar")
                SideRow(tag: "mem:ask", icon: "MagicStar", title: "Ask")
                SideRow(tag: "mac:storage", icon: "Driver", title: "Storage")
                SideRow(tag: "mac:ram", icon: "Ram", title: "RAM")
            }
            .padding(.horizontal, 10).padding(.top, 44) // clear of the window's buttons
            Segments(options: [("folders", "Folders"), ("memory", "Memory")], selection: $model.panelTab, compact: true)
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if model.panelTab == "folders" {
                        ForEach(AppModel.locations, id: \.url) { loc in TreeNode(url: loc.url, name: loc.name, depth: 0) }
                    } else {
                        MemoryTree()
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            if let p = model.imageProgress, p.total > 0 { status("Reading text in pictures · \(p.done) of \(p.total)") }
            else if let s = model.memoryStatus { status(s) }
            StorageCard().padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
            HStack(spacing: 9) {
                Avatar(name: NSFullUserName(), size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(NSFullUserName()).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(Self.mac).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .frame(width: 236)
        .onChange(of: model.scope) { if model.remembering { model.panelTab = "memory" } else if model.browsing { model.panelTab = "folders" } }
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 18).padding(.top, 4)
    }
}

/// Where you are sits on a small raised card.
struct SelectedRow: ViewModifier {
    let on: Bool
    let hover: Bool

    func body(content: Content) -> some View {
        content.background {
            if on {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card)
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
            } else if hover {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well)
            }
        }
    }
}

struct SideRow: View {
    @Environment(AppModel.self) private var model
    let tag: String
    let icon: String
    let title: String
    var count: Int? = nil
    @State private var hover = false

    var body: some View {
        let on = model.scope == tag && !model.searching
        Button { model.query = ""; model.scope = tag } label: {
            HStack(spacing: 10) {
                Icon(icon, size: 17, bold: on).foregroundStyle(on ? Theme.brand : Color.secondary)
                Text(title).font(.system(size: 13, weight: on ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 { Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .modifier(SelectedRow(on: on, hover: hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A folder and, once opened, the folders inside it, joined by tree lines.
struct TreeNode: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let name: String
    let depth: Int
    @State private var expanded = false
    @State private var children: [URL] = []
    @State private var hover = false

    var body: some View {
        let on = model.folder?.standardizedFileURL == url.standardizedFileURL && !model.searching
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if on { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
                else { model.query = ""; model.scope = "loc:" + url.path; withAnimation(.snappy(duration: 0.2)) { expanded = true } }
            } label: {
                HStack(spacing: 10) {
                    Icon("Folder", size: 17, bold: true).foregroundStyle(on ? Theme.brand : Theme.folderGrey)
                    Text(name).font(.system(size: 13, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.75)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .modifier(SelectedRow(on: on, hover: hover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }

            if expanded, !children.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(children.enumerated()), id: \.element) { i, child in
                        TreeNode(url: child, name: child.lastPathComponent, depth: depth + 1)
                            .overlay(alignment: .topLeading) { Elbow(last: i == children.count - 1) }
                    }
                }
                .padding(.leading, 22)
            }
        }
        .task(id: model.folder) { // where you are is shown: the folders above it open
            if let here = model.folder?.standardizedFileURL.path, here.hasPrefix(url.standardizedFileURL.path + "/") { expanded = true }
        }
        .task(id: expanded) {
            guard expanded, children.isEmpty else { return }
            let url = url
            children = await Task.detached { // a few dozen folders, read off the main thread
                ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: .skipsHiddenFiles)) ?? [])
                    .filter { let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]); return v?.isDirectory == true && v?.isPackage != true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    .prefix(40).map { $0 }
            }.value
        }
    }
}

/// One child's connector: down from under its parent's folder, a rounded turn, a short stub towards its own; the line
/// carries on past it to the next child unless it's the last.
struct Elbow: View {
    let last: Bool

    var body: some View {
        GeometryReader { g in
            Path { p in
                let x: CGFloat = -3.5, mid: CGFloat = 15, r: CGFloat = 6 // under the parent's folder; rows are 30 high
                p.move(to: CGPoint(x: x, y: -8))
                p.addLine(to: CGPoint(x: x, y: mid - r))
                p.addQuadCurve(to: CGPoint(x: x + r, y: mid), control: CGPoint(x: x, y: mid))
                p.addLine(to: CGPoint(x: x + 10, y: mid))
                if !last {
                    p.move(to: CGPoint(x: x, y: mid - r))
                    p.addLine(to: CGPoint(x: x, y: g.size.height + 1))
                }
            }
            .stroke(Theme.treeLine, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

struct MemoryTree: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [Note] = []
    @State private var people: [Note] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("mem:ask", "Ask", "MagicStar")
            row("mem:day", "Journal", "Book1", count: model.memoryCounts["day"])
            row("mem:project", "Projects", "Briefcase", count: model.memoryCounts["project"])
            children(projects) { note in
                model.query = ""
                model.scope = "loc:" + note.key.dropFirst("project:".count)
                model.inspected = Entry(note: note)
            }
            row("mem:person", "People", "Profile2User", count: model.memoryCounts["person"])
            children(people) { note in model.scope = "mem:person"; model.inspected = Entry(note: note) }
            row("mem:note", "Notes", "NoteText", count: (model.memoryCounts["note"] ?? 0) + (model.memoryCounts["claude"] ?? 0))
            if model.brain != nil {
                Text("Sources").font(.system(size: 11, weight: .medium)).textCase(.uppercase).tracking(0.5).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                ForEach(model.sourceList, id: \.self) { s in
                    row(s, Sources.label(s), ["claude-code": "Messages2", "browser": "Global", "git": "Hierarchy", "zsh": "Command"][s] ?? "Document",
                        count: model.counts[s])
                }
            }
        }
        .task {
            projects = Array(await MemoryStore.shared.notes(["project"]).sorted { $0.date > $1.date }.prefix(6))
            people = Array(await MemoryStore.shared.notes(["person"]).prefix(6))
        }
    }

    private func row(_ tag: String, _ title: String, _ icon: String, count: Int? = nil) -> some View {
        let on = model.scope == tag && !model.searching
        return Button { model.query = ""; model.scope = tag } label: {
            HStack(spacing: 10) {
                Icon(icon, size: 17, bold: on).foregroundStyle(on ? Theme.brand : Color.secondary)
                Text(title).font(.system(size: 13, weight: on ? .medium : .regular))
                Spacer(minLength: 0)
                if let count, count > 0 { Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .modifier(SelectedRow(on: on, hover: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func children(_ notes: [Note], open: @escaping (Note) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notes) { note in
                Button { open(note) } label: {
                    Text(note.title).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topLeading) { // the same rounded elbows as the folder tree
                    Path { p in p.move(to: CGPoint(x: -15, y: 0)); p.addLine(to: CGPoint(x: -15, y: 7))
                        p.addQuadCurve(to: CGPoint(x: -9, y: 13), control: CGPoint(x: -15, y: 13)); p.addLine(to: CGPoint(x: -4, y: 13)) }
                        .stroke(Theme.treeLine, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                }
            }
        }
        .padding(.leading, 34)
        .overlay(alignment: .topLeading) { Rectangle().fill(Theme.treeLine).frame(width: 1.3).padding(.leading, 18.4).padding(.bottom, 19) }
    }
}

/// Free space, and the way to more of it: a grey card with a tab, a white panel inside.
struct StorageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let v = try? Scan.home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(v?.volumeTotalCapacity ?? 1), free = v?.volumeAvailableCapacityForImportantUsage ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon("Cloud", size: 18, bold: true)
                Text("Storage").font(.system(size: 14.5, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.88))
            .padding(.horizontal, 12).frame(height: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text("Den finds what's safe to clear, and tells you why.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                GeometryReader { g in
                    Capsule().fill(Theme.well).overlay(alignment: .leading) {
                        Capsule().fill(Color(red: 0.14, green: 0.78, blue: 0.36)).frame(width: g.size.width * Double(total - free) / Double(max(total, 1)))
                    }
                }
                .frame(height: 6)
                Text("\(Text(bytes(total - free)).foregroundStyle(.primary)) of \(Text(bytes(total)).foregroundStyle(.primary)) Used")
                    .foregroundStyle(.secondary).font(.system(size: 12.5))
                Button { model.query = ""; model.scope = "mac:storage" } label: {
                    HStack(spacing: 8) { Icon("Flash", size: 17, bold: true); Text("Free up space") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(DarkButton())
            }
            .padding(11)
            .background(Theme.rimPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line.opacity(0.6)))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .padding(.horizontal, 5).padding(.bottom, 5)
        }
        .background(TabCard().fill(Theme.rim))
        .overlay(TabCard().stroke(Theme.line, lineWidth: 1))
    }
}

/// A card whose top-left rises into a tab, like a folder's.
struct TabCard: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, c: CGFloat = 14, drop: CGFloat = 12, tab = w * 0.66
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tab - 6, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + tab + 24, y: r.minY + drop), // a gentle slope down, rounded where it turns
                   control1: CGPoint(x: r.minX + tab + 6, y: r.minY), control2: CGPoint(x: r.minX + tab + 12, y: r.minY + drop))
        p.addLine(to: CGPoint(x: r.minX + w - c, y: r.minY + drop))
        p.addQuadCurve(to: CGPoint(x: r.minX + w, y: r.minY + drop + c), control: CGPoint(x: r.minX + w, y: r.minY + drop))
        p.addLine(to: CGPoint(x: r.minX + w, y: r.minY + h - c))
        p.addQuadCurve(to: CGPoint(x: r.minX + w - c, y: r.minY + h), control: CGPoint(x: r.minX + w, y: r.minY + h))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.minY + h))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + h - c), control: CGPoint(x: r.minX, y: r.minY + h))
        p.closeSubpath()
        return p
    }
}

/// The dark button: a soft top-to-bottom gradient and a hairline of light along its top.
struct DarkButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let top = Theme.dynamic(NSColor(white: 0.21, alpha: 1), NSColor(white: 0.3, alpha: 1))
        let bottom = Theme.dynamic(NSColor(white: 0.09, alpha: 1), NSColor(white: 0.19, alpha: 1))
        configuration.label
            .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
            .frame(height: 36)
            .background(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Icon("SearchNormal1", size: 16).foregroundStyle(.secondary)
                TextField("Search files, folders, pictures, memory…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($typing)
                    .onExitCommand { model.query = ""; typing = false }
                if model.query.isEmpty {
                    Text("⌘F").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                } else {
                    Button { model.query = "" } label: { Icon("CloseCircle", size: 16).foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 540).frame(height: 34)
            .card(10)
            .background { Button("") { typing = true }.keyboardShortcut("f").opacity(0) }
            Spacer(minLength: 12)
            if model.entries.contains(where: { $0.path != nil }) {
                IconButton(icon: "Broom", help: model.selection.isEmpty ? "Organize everything in view (⌘K)" : "Organize the selected files (⌘K)") {
                    model.organize(model.selection, nil)
                }
                .keyboardShortcut("k")
            }
            IconButton(icon: "MessageQuestion", help: "Ask from anywhere with ⌥Space") { QuickPanelController.shared.show(model) }
            Button { QuickPanelController.shared.show(model) } label: {
                HStack(spacing: 6) { Icon("Add", size: 16); Text("Ask Den") }
            }
            .buttonStyle(PillButton(primary: true)).fixedSize()
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 19).foregroundStyle(.primary.opacity(0.75))
                .frame(width: 34, height: 34)
                .background { if hover { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

// MARK: - Breadcrumbs, sort, filter, view

struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            if model.browsing, !model.searching {
                Button(action: model.goBack) { Icon("ArrowLeft2", size: 16) }.buttonStyle(.plain).disabled(!model.canGoBack)
                    .keyboardShortcut("[").help("Back")
                Button(action: model.goUp) { Icon("ArrowUp", size: 16) }.buttonStyle(.plain).keyboardShortcut(.upArrow).help("Enclosing folder")
            }
            crumbs
            Spacer()
            if !model.ownPane || model.searching, model.scope != "mem:ask" {
                if !model.searching, !model.remembering {
                    Menu {
                        Picker("Group by", selection: $model.grouping) { ForEach(AppModel.Grouping.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.inline)
                    } label: { HStack(spacing: 6) { Text("Group by \(model.grouping.rawValue.lowercased())"); Icon("ArrowDown2", size: 14) } }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(PillButton()).fixedSize()
                }
                if !model.browsing, !model.searching, !model.remembering {
                    Menu {
                        Picker("When", selection: $model.span) { ForEach(Span.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
                    } label: { HStack(spacing: 6) { Icon("Filter", size: 15); Text(model.span == .all ? "Filter" : model.span.rawValue) } }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(PillButton()).fixedSize()
                }
                Segments(options: [(AppModel.Layout.list, "RowVertical"), (AppModel.Layout.grid, "Category")], selection: $model.layout, icons: true)
            }
        }
        .font(.system(size: 13.5))
        .frame(height: 36)
    }

    /// Home / personal / brain: each part takes you there.
    @ViewBuilder private var crumbs: some View {
        if model.browsing, !model.searching, let folder = model.folder {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let inside = folder.path.hasPrefix(home) ? folder.path.dropFirst(home.count).split(separator: "/").map(String.init) : []
            let parts = [("Home", home)] + inside.enumerated().map { i, name in (name, home + "/" + inside[...i].joined(separator: "/")) }
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("/").foregroundStyle(.tertiary) }
                Button(part.0) { model.scope = "loc:" + part.1 }.buttonStyle(.plain)
                    .foregroundStyle(i == parts.count - 1 ? Color.primary : Color.secondary)
                    .fontWeight(i == parts.count - 1 ? .medium : .regular)
                    .lineLimit(1).fixedSize()
            }
        } else {
            Button("Home") { model.query = ""; model.scope = "home" }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text("/").foregroundStyle(.tertiary)
            Text(model.scope == "home" && !model.searching ? "Overview" : model.title).fontWeight(.medium).lineLimit(1).fixedSize()
            if !model.subtitle.isEmpty, !model.ownPane {
                Text(model.subtitle).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 4) // gives way first when it's narrow
            }
        }
    }
}

// MARK: - Home

struct HomePane: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [Note] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StorageOverview()
                PathBar()
                if !projects.isEmpty {
                    section("Projects") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 18)], spacing: 22) {
                            ForEach(projects.prefix(10)) { note in
                                let dir = String(note.key.dropFirst("project:".count))
                                FolderCard(title: note.title, subtitle: "Updated \(note.date.formatted(.relative(presentation: .named)))", path: dir) {
                                    model.query = ""
                                    model.scope = "loc:" + dir
                                    model.inspected = Entry(note: note)
                                }
                            }
                        }
                    }
                }
                section("Recent files", note: "Quick access to what you opened last.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                        ForEach(model.recents.files.prefix(8)) { FileCard(entry: $0) }
                    }
                }
                section("All files") {
                    FileTable(files: Array(model.recents.files.prefix(25)))
                    Button("Show all \(model.recents.files.count) recent files") { model.scope = "recents" }.buttonStyle(PillButton())
                }
            }
            .padding(24)
        }
        .background(Theme.page)
        .task { projects = await MemoryStore.shared.notes(["project"]).sorted { $0.date > $1.date } }
    }
}

/// A titled part of a page, with a chevron like a disclosure.
func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Icon("ArrowDown2", size: 15).foregroundStyle(.secondary)
                Text(title).font(.system(size: 17, weight: .medium))
            }
            if let note { Text(note).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.leading, 23) }
        }
        content()
    }
}

// MARK: - Storage overview: what fills the disk, by kind

struct DiskPart: Codable, Hashable {
    let name: String
    let bytes: Int64
}

enum DiskUse {
    /// Spotlight's own sizes for each kind of file in your home folder (and your apps). Synchronous, so it runs off the
    /// main thread; once a day is plenty. Space on disk, not the files' nominal size: iCloud files that aren't
    /// downloaded take none.
    static func measure() -> [DiskPart] {
        let size = "kMDItemPhysicalSize"
        let kinds: [(String, String, String)] = [
            ("Videos", #"kMDItemContentTypeTree == "public.movie""#, size),
            ("Pictures", #"kMDItemContentTypeTree == "public.image""#, size),
            ("Documents", #"kMDItemContentTypeTree == "com.adobe.pdf" || kMDItemContentTypeTree == "public.presentation" || kMDItemContentTypeTree == "public.spreadsheet" || kMDItemContentTypeTree == "public.composite-content""#, size),
            ("Music", #"kMDItemContentTypeTree == "public.audio""#, size),
            ("Apps", #"kMDItemContentType == "com.apple.application-bundle""#, size),
        ]
        return kinds.map { name, predicate, size in
            guard let q = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, [size] as CFArray, nil) else { return DiskPart(name: name, bytes: 0) }
            MDQuerySetSearchScope(q, (name == "Apps" ? ["/Applications", NSHomeDirectory() + "/Applications"] : [NSHomeDirectory()]) as CFArray, 0)
            MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue))
            var total: Int64 = 0
            for i in 0..<MDQueryGetResultCount(q) {
                if let v = MDQueryGetAttributeValueOfResultAtIndex(q, size as CFString, i) {
                    total += (Unmanaged<AnyObject>.fromOpaque(v).takeUnretainedValue() as? NSNumber)?.int64Value ?? 0
                }
            }
            return DiskPart(name: name, bytes: total)
        }
    }
}

struct StorageOverview: View {
    @Environment(AppModel.self) private var model
    @AppStorage("diskUse.v2") private var saved = Data()
    @State private var parts: [DiskPart] = []

    private static let colors: [String: Color] = ["Videos": Theme.brand, "Documents": .cyan, "Pictures": .purple, "Music": .pink, "Apps": .orange]

    var body: some View {
        let v = try? Scan.home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(v?.volumeTotalCapacity ?? 1), free = v?.volumeAvailableCapacityForImportantUsage ?? 0, used = total - free
        let counted = parts.reduce(0) { $0 + $1.bytes }
        let fit = counted > used ? Double(used) / Double(counted) : 1 // hard links and clones are counted twice; never more than you've used
        let known = Int64(Double(counted) * fit)
        let bars: [(String, Int64, Color)] = parts.filter { $0.bytes > 0 }.map { ($0.name, Int64(Double($0.bytes) * fit), Self.colors[$0.name] ?? .gray) }
            + [("Other", max(used - known, 0), Color.gray.opacity(0.75)), ("Free space", free, Theme.well)]
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage Overview").font(.system(size: 17, weight: .medium))
                Spacer()
                Text("You've used \(Text(bytes(used)).fontWeight(.semibold).foregroundStyle(.primary)) of \(Text(bytes(total)).fontWeight(.semibold).foregroundStyle(.primary)). Free up space safely in Storage.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(bars, id: \.0) { _, size, color in
                        Rectangle().fill(color).frame(width: g.size.width * Double(size) / Double(max(total, 1)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 28)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(bars, id: \.0) { name, size, color in
                    HStack(spacing: 7) {
                        Circle().fill(color).frame(width: 8, height: 8).overlay(Circle().strokeBorder(Theme.line))
                        Text(name).foregroundStyle(.secondary)
                        Text(bytes(size)).fontWeight(.medium)
                    }
                    .font(.system(size: 13)).lineLimit(1).fixedSize()
                }
                if parts.isEmpty { Text("Measuring…").font(.system(size: 13)).foregroundStyle(.secondary) }
            }
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .task {
            struct Saved: Codable { let at: Date; let parts: [DiskPart] }
            if let old = try? JSONDecoder().decode(Saved.self, from: saved) {
                parts = old.parts
                if old.at > .now - 86400 { return }
            }
            let fresh = await Task.detached(priority: .utility) { DiskUse.measure() }.value
            parts = fresh
            saved = (try? JSONEncoder().encode(Saved(at: .now, parts: fresh))) ?? Data()
            returnFreedMemory()
        }
    }
}

// MARK: - A folder

struct FolderPane: View {
    @Environment(AppModel.self) private var model
    @State private var all = false

    var body: some View {
        let folders = model.entries.filter(\.isFolder), files = model.entries.filter { !$0.isFolder }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PathBar()
                if !folders.isEmpty {
                    section("Folders") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 18)], spacing: 22) {
                            ForEach(all ? folders : Array(folders.prefix(10))) { e in
                                FolderCard(title: e.title, subtitle: "Updated \(e.date.formatted(.relative(presentation: .named)))", path: e.path) {
                                    model.activate(e)
                                }
                                .contextMenu { ForEach(model.actions(e)) { a in Button(a.title, action: a.run) } }
                            }
                        }
                        if folders.count > 10, !all { Button("Show all \(folders.count) folders") { all = true }.buttonStyle(PillButton()) }
                    }
                }
                section("Files") {
                    if files.isEmpty { Text("No files here.").font(.system(size: 13)).foregroundStyle(.secondary) }
                    else { FileTable(files: files) }
                }
            }
            .padding(24)
        }
        .background(Theme.page)
        .onChange(of: model.folder) { all = false }
    }
}

// MARK: - Files as cards and as a table

struct FileCard: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    @State private var size: Int64?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Icon(Iconsax.forFile(entry.path ?? "", folder: entry.isFolder), size: 21).foregroundStyle(.primary.opacity(0.7))
                .frame(width: 42, height: 42)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(size.map(bytes) ?? entry.context).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(model.actions(entry)) { a in Button(a.title, action: a.run) }
            } label: { Icon("More", size: 18).rotationEffect(.degrees(90)).foregroundStyle(.secondary) }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
        }
        .padding(12)
        .card(12)
        .overlay { if hover { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.brand.opacity(0.35)) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.activate(entry) }
        .onTapGesture { model.inspected = entry }
        .task(id: entry.id) {
            guard let path = entry.path else { return }
            size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
        }
    }
}

/// Name, where it lives, when you last opened it, its size and where it came from.
struct FileTable: View {
    let files: [Entry]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("File name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Where").frame(width: 190, alignment: .leading)
                Text("Last opened").frame(width: 120, alignment: .leading)
                Text("Size").frame(width: 76, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(height: 42)
            .background(Theme.well.opacity(0.6))
            ForEach(files) { e in
                Rectangle().fill(Theme.line).frame(height: 1)
                FileRow(entry: e)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .card()
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    @State private var hover = false
    @State private var size: Int64?
    @State private var from: String?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 11) {
                Icon(Iconsax.forFile(entry.path ?? "", folder: entry.isFolder), size: 18).foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        if from != nil { Icon("Global", size: 11) }
                        Text(from.map { "From \($0)" } ?? "On this Mac")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.context).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(width: 190, alignment: .leading)
            Text(entry.date.formatted(.relative(presentation: .named))).lineLimit(1).frame(width: 120, alignment: .leading)
            Text(size.map(bytes) ?? "—").monospacedDigit().frame(width: 76, alignment: .leading)
            Menu {
                ForEach(model.actions(entry)) { a in Button(a.title, action: a.run) }
            } label: { Icon("More", size: 17).foregroundStyle(.secondary) }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).frame(width: 24)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).frame(height: 58)
        .background(hover || model.inspected?.id == entry.id ? Theme.well.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.activate(entry) }
        .onTapGesture { model.inspected = entry }
        .task(id: entry.id) {
            guard let path = entry.path else { return }
            size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
            from = await Task.detached { hostOf(whereFroms(path)) }.value
        }
    }
}

/// The details panel's header: what you're looking at, and the way to close it.
struct InspectorHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text(kind).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            IconButton(icon: "SidebarRight", help: "Close the details") {
                model.selection = []
                model.inspected = nil
            }
        }
        .padding(.leading, 20).padding(.trailing, 10)
        .frame(height: 50)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var kind: String {
        guard let e = model.inspected else { return "\(model.selection.count) selected" }
        if e.path != nil { return e.isFolder ? "Folder" : "File" }
        return switch e.source {
        case "memory": MemoryKind.label(e.kind)
        case "calendar": "Meeting"
        case "day": "Day"
        default: Sources.label(e.source)
        }
    }
}
