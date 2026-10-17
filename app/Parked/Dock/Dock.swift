import AppKit
import Carbon.HIToolbox
import IOKit.ps
import SwiftUI
import UniformTypeIdentifiers

// Docks: save the macOS Dock's layout as named Docks and switch with ⌃⌥1…9, and Den's own Dock, which also holds
// files, folders, links and widgets (clock, next meeting, memory, battery, AirDrop, Ask, today's work). Nothing about
// the macOS Dock changes until you choose to: switching a Dock, or letting Den's Dock replace it.

enum DockThing: Codable, Hashable, Identifiable {
    case app(String), file(String), link(String), widget(WidgetConfig), spacer(UUID)

    var id: String {
        switch self {
        case .app(let p): "app:" + p
        case .file(let p): "file:" + p
        case .link(let u): "link:" + u
        case .widget(let w): "widget:" + w.id.uuidString
        case .spacer(let u): "spacer:" + u.uuidString
        }
    }

    var title: String {
        switch self {
        case .app(let p), .file(let p): FileManager.default.displayName(atPath: p).replacingOccurrences(of: ".app", with: "")
        case .link(let u): URL(string: u)?.host() ?? u
        case .widget(let w): w.kind.title
        case .spacer: "Space"
        }
    }
}

struct DockSet: Codable, Identifiable {
    var id = UUID()
    var name: String
    var native: Data? // the macOS Dock's own layout (its persistent-apps and persistent-others), as it was saved
    var custom: [DockThing] = []
}

// MARK: - The macOS Dock's own settings

enum AppleDock {
    static let domain = "com.apple.dock" as CFString

    static func value(_ key: String) -> CFPropertyList? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    /// Its layout right now.
    static func current() -> Data? {
        let layout: [String: Any] = ["persistent-apps": value("persistent-apps") ?? [Any](), "persistent-others": value("persistent-others") ?? [Any]()]
        return try? PropertyListSerialization.data(fromPropertyList: layout, format: .binary, options: 0)
    }

    /// The apps in a saved layout, as paths.
    static func apps(in data: Data) -> [String] {
        guard let layout = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tiles = layout["persistent-apps"] as? [[String: Any]] else { return [] }
        return tiles.compactMap { (($0["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String }
            .compactMap { URL(string: $0)?.path }
    }

    /// Puts a saved layout back and restarts the Dock so it shows (running apps stay open).
    static func apply(_ data: Data) {
        guard let layout = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for key in ["persistent-apps", "persistent-others"] {
            CFPreferencesSetAppValue(key as CFString, layout[key] as CFPropertyList?, domain)
        }
        restart()
    }

    static var autoHides: Bool { value("autohide") as? Bool ?? false }

    /// Out of Den's Dock's way: hidden, and so slow to come back that it doesn't. What it was is kept, to put back.
    static func stepAside() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "appleDockWas") == nil {
            defaults.set(["autohide": autoHides, "delay": value("autohide-delay") as? Double ?? -1], forKey: "appleDockWas")
        }
        CFPreferencesSetAppValue("autohide" as CFString, true as CFPropertyList, domain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, 1000.0 as CFPropertyList, domain)
        restart()
    }

    static func comeBack() {
        guard let was = UserDefaults.standard.dictionary(forKey: "appleDockWas") else { return }
        CFPreferencesSetAppValue("autohide" as CFString, (was["autohide"] as? Bool ?? false) as CFPropertyList, domain)
        let delay = was["delay"] as? Double ?? -1
        CFPreferencesSetAppValue("autohide-delay" as CFString, delay < 0 ? nil : delay as CFPropertyList, domain) // nil: as it was, unset
        UserDefaults.standard.removeObject(forKey: "appleDockWas")
        restart()
    }

    static var isAside: Bool { autoHides && (value("autohide-delay") as? Double ?? 0) >= 100 }

    private static func restart() {
        CFPreferencesAppSynchronize(domain)
        _ = runTool("/usr/bin/killall", ["Dock"])
    }
}

/// How Den's Dock looks and behaves. It starts out the size of your macOS Dock.
struct DockLook: Codable, Equatable {
    var icon: Double = 48
    var magnify = true
    var magnified: Double = 72
    var spacing: Double = 4
    var style = "dark" // dark, light, clear
    var opacity: Double = 0.5
    var radius: Double = 20
    var widgets: Double = 1 // widget size, next to the icons
    var running = true // open apps you haven't kept in the Dock
    var recents = true // apps you used lately
    var trash = true
    var dots = true
    var labels = true
    var badges = true
    var autoHide = false
    var fullScreenHides = true

    static func likeAppleDock() -> DockLook {
        var look = DockLook()
        if let n = AppleDock.value("tilesize") as? Double { look.icon = n }
        if let on = AppleDock.value("magnification") as? Bool { look.magnify = on }
        if let n = AppleDock.value("largesize") as? Double { look.magnified = max(n, look.icon) }
        if let on = AppleDock.value("show-recents") as? Bool { look.recents = on }
        return look
    }
}

// MARK: - Docks, kept in a small file

@MainActor @Observable final class Docks {
    static let shared = Docks()
    var sets: [DockSet] = []
    var active: UUID?
    /// "apple": the macOS Dock only; "brain": Den's Dock instead of it; "both".
    var mode = UserDefaults.standard.string(forKey: "dockMode") ?? "apple" { didSet { UserDefaults.standard.set(mode, forKey: "dockMode") } }
    var edge = UserDefaults.standard.string(forKey: "dockEdge") ?? "bottom" { didSet { UserDefaults.standard.set(edge, forKey: "dockEdge") } }
    var look = UserDefaults.standard.data(forKey: "dockLook").flatMap { try? JSONDecoder().decode(DockLook.self, from: $0) } ?? .likeAppleDock() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(look), forKey: "dockLook") }
    }
    var recent = UserDefaults.standard.stringArray(forKey: "dockRecents") ?? [] { didSet { UserDefaults.standard.set(recent, forKey: "dockRecents") } }
    private let file = URL.applicationSupportDirectory.appending(path: "Den/docks.json")
    private struct Saved: Codable { var sets: [DockSet]; var active: UUID? }

    var current: DockSet? { sets.first { $0.id == active } ?? sets.first }
    var showsOwn: Bool { mode != "apple" }
    var pinnedApps: Set<String> { Set((current?.custom ?? []).compactMap { if case .app(let p) = $0 { p } else { nil } }) }

    func load() {
        guard sets.isEmpty else { return }
        if let saved = try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)) { sets = saved.sets; active = saved.active }
        if sets.isEmpty { // the first Dock: open apps show up by themselves, so only widgets to start
            sets = [DockSet(name: "Main", native: AppleDock.current(),
                            custom: [Widget.calendar, .nowPlaying, .focus, .system, .battery].map { .widget(WidgetConfig(kind: $0, options: $0.defaults)) })]
            active = sets[0].id
            save()
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "dockPinsCleared") { // the first version pinned the macOS Dock's first apps for you; only what you pin stays
            defaults.set(true, forKey: "dockPinsCleared")
            let given = Set(sets.first?.native.map { Array(AppleDock.apps(in: $0).prefix(8)) } ?? [])
            if let i = sets.indices.first { sets[i].custom.removeAll { if case .app(let p) = $0 { given.contains(p) } else { false } } }
            save()
        }
        if mode == "brain", !AppleDock.isAside { // the first version only auto-hid it, so it still slid out over Den's Dock
            if defaults.object(forKey: "appleDockWas") == nil, defaults.object(forKey: "appleDockAutoHid") != nil {
                defaults.set(["autohide": defaults.bool(forKey: "appleDockAutoHid"), "delay": -1.0], forKey: "appleDockWas")
            }
            AppleDock.stepAside()
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Saved(sets: sets, active: active)).write(to: file, options: .atomic)
    }

    /// Changes the macOS Dock to the saved layout (when it has one and it differs) and Den's Dock to its items.
    func activate(_ index: Int) {
        guard sets.indices.contains(index) else { return }
        active = sets[index].id
        if mode != "brain", let native = sets[index].native, native != AppleDock.current() { AppleDock.apply(native) }
        save()
    }

    func saveAppleDock(as name: String) {
        sets.append(DockSet(name: name, native: AppleDock.current(), custom: current?.custom ?? []))
        save()
        registerKeys()
    }

    func edit(_ change: (inout [DockThing]) -> Void) {
        guard let i = sets.firstIndex(where: { $0.id == current?.id }) else { return }
        change(&sets[i].custom)
        save()
    }

    func replace(_ config: WidgetConfig) {
        edit { items in
            if let i = items.firstIndex(where: { $0.id == "widget:" + config.id.uuidString }) { items[i] = .widget(config) }
        }
    }

    /// Puts things in the Dock before `before` (an item's id), or at the end. Already there: moves it.
    func insert(_ things: [DockThing], before: String?) {
        edit { items in
            items.removeAll { t in things.contains { $0.id == t.id } }
            let at = before.flatMap { b in items.firstIndex { $0.id == b } } ?? items.count
            items.insert(contentsOf: things, at: at)
        }
    }

    /// Keep in Dock: right after the apps already kept.
    func pin(_ path: String) {
        let after = (current?.custom ?? []).lastIndex { if case .app = $0 { true } else { false } }
        let before = after.flatMap { i in (current?.custom ?? []).indices.contains(i + 1) ? current?.custom[i + 1].id : nil }
        insert([.app(path)], before: after == nil ? current?.custom.first?.id : before)
    }

    func add(_ urls: [URL], before: String? = nil) {
        insert(urls.map { $0.pathExtension == "app" ? .app($0.path) : $0.isFileURL ? .file($0.path) : .link($0.absoluteString) }, before: before)
    }

    /// An app you quit that isn't kept in the Dock joins the recent ones.
    func quit(_ path: String) {
        guard !pinnedApps.contains(path) else { return }
        recent = Array(([path] + recent.filter { $0 != path }).prefix(3))
    }

    /// Den's Dock replaces the macOS Dock by keeping it out of the way; your settings come back when you switch back.
    func setMode(_ new: String) {
        if new == "brain", mode != "brain" { AppleDock.stepAside() }
        else if new != "brain", mode == "brain" { AppleDock.comeBack() }
        mode = new
    }

    /// ⌃⌥1 … ⌃⌥9 switch to the Docks in that order.
    func registerKeys() {
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, key) in keys.enumerated().prefix(sets.count) {
            HotKey.register(UInt32(20 + i), keyCode: key, modifiers: controlKey | optionKey) { Docks.shared.activate(i) }
        }
    }
}

/// The notification counts the macOS Dock shows. It keeps running while hidden, and Accessibility lets us read them.
enum DockBadges {
    static func read() -> [String: String] {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        var out: [String: String] = [:]
        func walk(_ element: AXUIElement, _ depth: Int) {
            var kids: CFTypeRef?
            guard depth < 4, AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success else { return }
            for kid in (kids as? [AXUIElement]) ?? [] {
                var title: CFTypeRef?, badge: CFTypeRef?
                AXUIElementCopyAttributeValue(kid, kAXTitleAttribute as CFString, &title)
                AXUIElementCopyAttributeValue(kid, "AXStatusLabel" as CFString, &badge)
                if let t = title as? String, let b = badge as? String, !b.isEmpty { out[t] = b }
                walk(kid, depth + 1)
            }
        }
        walk(AXUIElementCreateApplication(dock.processIdentifier), 0)
        return out
    }
}

/// One app window, as Accessibility sees it.
struct AppWindow: Identifiable {
    let id: String
    let pid: pid_t
    let title: String
    let minimized: Bool
    let element: AXUIElement
}

/// Every open app's windows (titles, and which are minimized), read every couple of seconds off the main thread.
/// Needs Accessibility, like the badges.
@MainActor @Observable final class WindowIndex {
    static let shared = WindowIndex()
    var byApp: [pid_t: [AppWindow]] = [:]
    @ObservationIgnored private var started = false

    var minimized: [AppWindow] { byApp.values.flatMap { $0 }.filter(\.minimized).sorted { $0.id < $1.id } }

    func start() {
        guard !started else { return }
        started = true
        Task {
            while true {
                if AXIsProcessTrusted() {
                    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ($0.processIdentifier, $0.localizedName ?? "") }
                    byApp = await Task.detached { WindowIndex.read(apps) }.value
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    nonisolated static func read(_ apps: [(pid: pid_t, name: String)]) -> [pid_t: [AppWindow]] {
        var out: [pid_t: [AppWindow]] = [:]
        for app in apps {
            let ax = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(ax, 0.25) // a busy app mustn't hold the Dock up
            var list: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &list) == .success else { continue }
            out[app.pid] = ((list as? [AXUIElement]) ?? []).enumerated().compactMap { i, window in
                var role: CFTypeRef?, title: CFTypeRef?, mini: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &role)
                guard (role as? String) == kAXStandardWindowSubrole else { return nil } // real windows, not panels or sheets
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &mini)
                let name = (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.name
                return AppWindow(id: "\(app.pid):\(i):\(name)", pid: app.pid, title: name, minimized: mini as? Bool ?? false, element: window)
            }
        }
        return out
    }

    /// Brings a window forward, un-minimizing it if it was.
    static func bring(_ w: AppWindow) {
        AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
    }
}

/// App and file icons, looked up once (the Dock redraws as the pointer moves).
@MainActor enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func of(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 200 { cache = [:] }
        cache[path] = i
        return i
    }
}

// MARK: - Den's Dock, on screen

@MainActor final class DockController {
    static let shared = DockController()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [Any] = []
    private var base = CGSize(width: 400, height: 60) // the bar at rest
    private var hidden = false
    private var fullScreen = false
    var window: NSWindow? { panel }
    var force = false // shown whatever the setup (for snapshots)
    var dragging: String? // a Dock item on its way somewhere

    /// Let go of a kept thing away from the Dock and it's gone, in a puff of smoke.
    func dragStarted(_ id: String) {
        dragging = id
        Task {
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(80)) }
            try? await Task.sleep(for: .milliseconds(150)) // a drop on the Dock clears it first
            defer { dragging = nil }
            guard dragging == id, let p = panel, !p.frame.contains(NSEvent.mouseLocation),
                  Docks.shared.current?.custom.contains(where: { $0.id == id }) == true else { return }
            Docks.shared.edit { $0.removeAll { $0.id == id } }
            NSAnimationEffect.poof.show(centeredAt: NSEvent.mouseLocation, size: NSSize(width: 48, height: 48))
        }
    }

    private var look: DockLook { Docks.shared.look }
    private var edge: String { Docks.shared.edge }
    private var shouldHide: Bool { look.autoHide || (look.fullScreenHides && fullScreen) }

    func start(_ model: AppModel) {
        Docks.shared.load()
        Docks.shared.registerKeys()
        guard Docks.shared.showsOwn || force, panel == nil else { return }
        let p = NotchPanel(contentRect: CGRect(origin: .zero, size: base), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // the bar draws its own; the rest of the window is see-through and lets clicks through
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let align: Alignment = edge == "left" ? .leading : edge == "right" ? .trailing : .bottom
        p.contentView = NSHostingView(rootView: CustomDock().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align).environment(model))
        panel = p
        place(animated: false)
        p.orderFrontRegardless()
        let track: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { DockController.shared.track() } }
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track),
                    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { track($0); return $0 }].compactMap { $0 }
        let spaces = NSWorkspace.shared.notificationCenter
        WindowIndex.shared.start()
        observers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification].map { name in
            spaces.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DockController.shared.checkFullScreen() } }
        }
        checkFullScreen()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        monitors = []
        observers = []
        panel?.close()
        panel = nil
        hidden = false
    }

    func restart(_ model: AppModel) { stop(); start(model) }

    /// The bar measured itself at rest.
    func fit(_ size: CGSize) {
        guard abs(size.width - base.width) > 0.5 || abs(size.height - base.height) > 0.5 else { return }
        base = size
        place(animated: false)
    }

    /// Room for icons to grow and for names above them, so hovering never resizes the window.
    private var frame: CGRect {
        guard let screen = NSScreen.screens.first else { return .zero }
        let v = screen.visibleFrame, f = screen.frame, gap: CGFloat = 4
        let grow = look.magnify ? max(look.magnified - look.icon, 0) : 0
        let head = grow + (look.labels ? 40 : 6), slack = grow * 2.4 + 8
        let vertical = edge != "bottom"
        let size = vertical ? CGSize(width: base.width + head, height: base.height + slack) : CGSize(width: base.width + slack, height: base.height + head)
        var origin = switch edge {
        case "left": CGPoint(x: f.minX + gap, y: v.midY - size.height / 2)
        case "right": CGPoint(x: f.maxX - size.width - gap, y: v.midY - size.height / 2)
        default: CGPoint(x: v.midX - size.width / 2, y: f.minY + gap)
        }
        if hidden { // just past the edge
            switch edge {
            case "left": origin.x = f.minX - size.width
            case "right": origin.x = f.maxX
            default: origin.y = f.minY - size.height
            }
        }
        return CGRect(origin: origin, size: size)
    }

    private func place(animated: Bool) {
        guard let p = panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(frame, display: true)
            }
        } else {
            p.setFrame(frame, display: true)
        }
    }

    private func slide(hide: Bool) {
        guard hidden != hide else { return }
        hidden = hide
        place(animated: true)
    }

    /// Like the macOS Dock: away in full-screen apps (and with auto-hide) until you push the pointer against the edge.
    private func track() {
        guard let p = panel, let screen = NSScreen.screens.first else { return }
        guard shouldHide else { slide(hide: false); return }
        let m = NSEvent.mouseLocation, f = screen.frame
        let atEdge = switch edge {
        case "left": m.x <= f.minX + 1 && abs(m.y - f.midY) < base.height / 2 + 60
        case "right": m.x >= f.maxX - 1 && abs(m.y - f.midY) < base.height / 2 + 60
        default: m.y <= f.minY + 1 && abs(m.x - f.midX) < base.width / 2 + 60
        }
        if hidden, atEdge, f.contains(m) { slide(hide: false) }
        else if !hidden, !p.frame.insetBy(dx: -8, dy: -8).contains(m), NSEvent.pressedMouseButtons & 1 == 0 { slide(hide: true) }
    }

    func checkFullScreen() {
        Task {
            try? await Task.sleep(for: .milliseconds(400)) // after the space finishes sliding in
            fullScreen = Self.isFullScreen()
            if !shouldHide { slide(hide: false) }
            else if let p = panel, !p.frame.contains(NSEvent.mouseLocation) { slide(hide: true) }
        }
    }

    /// The frontmost app has a window the size of the whole screen: it's in full screen.
    static func isFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return windows.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && (w[kCGWindowLayer as String] as? Int) == 0
                && ((w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                    .map { screens.contains($0.size) } ?? false)
        }
    }
}

/// Shows a fixed-size card at another size, taking up that size.
struct Scaled<Content: View>: View {
    let k: CGFloat
    @ViewBuilder var content: Content
    @State private var size = CGSize.zero

    var body: some View {
        content.fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .scaleEffect(k, anchor: .topLeading)
            .frame(width: size.width * k, height: size.height * k, alignment: .topLeading)
    }
}

struct CustomDock: View {
    @Environment(AppModel.self) private var model
    @State private var open: [String] = [] // apps running, in the order they opened
    @State private var badges: [String: String] = [:]
    @State private var pointer: CGFloat? // along the bar, from its middle
    @State private var length: CGFloat = 0 // the bar as drawn now
    @State private var lengths: [String: CGFloat] = [:] // widgets, along the bar
    @State private var shrink: CGFloat = 1 // too much for the screen: everything gets smaller, as in the macOS Dock
    private var docks: Docks { .shared }

    enum Slot: Identifiable {
        case thing(DockThing), open(String), recent(String), divider(String), window(AppWindow), trash
        var id: String {
            switch self {
            case .window(let w): "window:" + w.id
            case .thing(let t): t.id
            case .open(let p): "open:" + p
            case .recent(let p): "recent:" + p
            case .divider(let d): "divider:" + d
            case .trash: "trash"
            }
        }
    }

    /// Kept things in your order, open apps right after the kept apps, then recent apps, then the Bin.
    private var slots: [Slot] {
        let kept = docks.current?.custom ?? [], look = docks.look
        let pinned = docks.pinnedApps
        let extra = look.running ? open.filter { !pinned.contains($0) } : []
        let cut = kept.lastIndex { if case .app = $0 { true } else { false } }.map { $0 + 1 } ?? 0
        var out = kept[..<cut].map(Slot.thing) + extra.map(Slot.open)
        let recents = look.recents ? docks.recent.filter { !pinned.contains($0) && !open.contains($0) } : []
        if !recents.isEmpty { out += [.divider("recent")] + recents.map(Slot.recent) }
        let rest = kept[cut...].map(Slot.thing)
        if !rest.isEmpty { out += (out.isEmpty ? [] : [.divider("rest")]) + rest }
        let minimized = AppleDock.value("minimize-to-application") as? Bool == true ? [] : WindowIndex.shared.minimized
        if !minimized.isEmpty { out += [.divider("windows")] + minimized.map(Slot.window) }
        if look.trash { out += [.divider("trash"), .trash] }
        return out
    }

    var body: some View {
        let look = docks.look, edge = docks.edge, vertical = edge != "bottom"
        let icon = look.icon * shrink, pad: CGFloat = 6
        let k = (look.icon + 10) / 64 * look.widgets * shrink
        let inner = max(icon, 64 * k)
        let slots = self.slots
        let centers = baseCenters(slots, icon: icon, spacing: look.spacing)
        let near = pointer.flatMap { p in centers.indices.min { abs(centers[$0] - p) < abs(centers[$1] - p) } }
        let stack = vertical ? AnyLayout(VStackLayout(alignment: edge == "left" ? .leading : .trailing, spacing: look.spacing))
                             : AnyLayout(HStackLayout(alignment: .bottom, spacing: look.spacing))
        let edgeSide: Edge.Set = edge == "left" ? .leading : edge == "right" ? .trailing : .bottom
        stack {
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, slot in
                let s = magnify(centers[i], icon: icon, look: look)
                Group {
                    switch slot {
                    case .thing(.widget(let config)):
                        Scaled(k: k) { WidgetCard(config: config) { Docks.shared.replace($0) } }
                            .onGeometryChange(for: CGFloat.self) { vertical ? $0.size.height : $0.size.width } action: { lengths[slot.id] = $0 }
                            .contextMenu {
                                Button("Remove from Dock") { docks.edit { $0.removeAll { $0.id == slot.id } } }
                                Button("Edit Dock…") { model.go("mac:dock") }
                            }
                            .padding(edgeSide, (inner - 64 * k) / 2)
                    case .thing(.spacer):
                        Color.clear.frame(width: vertical ? icon : 12, height: vertical ? 12 : icon).padding(edgeSide, (inner - icon) / 2)
                    case .divider:
                        Rectangle().fill(.white.opacity(0.25)).frame(width: vertical ? icon * 0.75 : 1, height: vertical ? 1 : icon * 0.75)
                            .padding(edgeSide, (inner - icon * 0.75) / 2)
                    default:
                        DockIcon(slot: slot, size: icon, scale: s, edge: edge,
                                 label: look.labels && near == i && abs(centers[i] - (pointer ?? .infinity)) < icon * s / 2 + look.spacing,
                                 running: { if case .open = slot { true } else if case .thing(.app(let p)) = slot { open.contains(p) } else { false } }(),
                                 dots: look.dots, badges: look.badges ? badges : [:])
                            .padding(edgeSide, (inner - icon) / 2)
                    }
                }
                .modifier(DockDragSource(id: { switch slot { case .divider, .trash, .window: nil; default: slot.id } }()))
            }
        }
        .padding(pad)
        .background(alignment: vertical ? (edge == "left" ? .leading : .trailing) : .bottom) {
            RoundedRectangle(cornerRadius: look.radius, style: .continuous)
                .fill(look.style == "light" ? Color.white.opacity(look.opacity) : Color.black.opacity(look.style == "clear" ? 0 : look.opacity))
                .background(look.style == "clear" ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial),
                            in: RoundedRectangle(cornerRadius: look.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: look.radius, style: .continuous).strokeBorder(.white.opacity(look.style == "clear" ? 0 : 0.12)))
                .shadow(color: .black.opacity(look.style == "clear" ? 0 : 0.25), radius: 10, y: 3)
                .frame(width: vertical ? inner + pad * 2 : nil, height: vertical ? nil : inner + pad * 2)
        }
        .environment(\.colorScheme, look.style == "light" ? .light : .dark)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            length = vertical ? size.height : size.width
            guard pointer == nil else { return } // at rest only
            DockController.shared.fit(vertical ? CGSize(width: inner + pad * 2, height: size.height) : CGSize(width: size.width, height: inner + pad * 2))
            let room = (NSScreen.screens.first.map { vertical ? $0.visibleFrame.height : $0.visibleFrame.width } ?? 1200) - 60
            let wanted = min(1, room / max(length / shrink, 1))
            if abs(wanted - shrink) > 0.02 { shrink = wanted }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): pointer = (vertical ? p.y : p.x) - length / 2
            case .ended: withAnimation(.easeOut(duration: 0.2)) { pointer = nil }
            }
        }
        .animation(.easeOut(duration: 0.12), value: pointer == nil)
        .onDrop(of: [DockDrop.item, .fileURL], delegate: DockDrop(slots: slots, centers: centers, icon: icon, length: length, vertical: vertical))
        .task { refresh() }
        .task { // the macOS Dock's badges, when Accessibility is allowed
            while !Task.isCancelled {
                if docks.look.badges { badges = await Task.detached { DockBadges.read() }.value }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy == .regular,
               let path = app.bundleURL?.path { docks.quit(path) }
            refresh()
        }
    }

    private func refresh() {
        open = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }.compactMap { $0.bundleURL?.path }
    }

    /// Where each thing sits at rest, from the bar's middle, so growing icons don't move what's measured.
    private func baseCenters(_ slots: [Slot], icon: CGFloat, spacing: Double) -> [CGFloat] {
        var x: CGFloat = 0, out: [CGFloat] = []
        for slot in slots {
            let w: CGFloat = switch slot {
            case .thing(.widget): lengths[slot.id] ?? 64
            case .thing(.spacer): 12
            case .divider: 1
            default: icon
            }
            out.append(x + w / 2)
            x += w + spacing
        }
        let total = max(x - spacing, 0)
        return out.map { $0 - total / 2 }
    }

    /// The macOS Dock's swell: biggest under the pointer, easing off over about three icons.
    private func magnify(_ center: CGFloat, icon: CGFloat, look: DockLook) -> CGFloat {
        guard look.magnify, let p = pointer else { return 1 }
        let reach = icon * 3, d = abs(p - center)
        guard d < reach else { return 1 }
        return 1 + (look.magnified / look.icon - 1) * (cos(.pi * d / reach) + 1) / 2
    }
}

/// Dock items can be dragged along the Dock or off it (which removes kept ones).
struct DockDragSource: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.onDrag {
                DockController.shared.dragStarted(id)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: DockDrop.item.identifier, visibility: .ownProcess) { done in
                    done(Data(id.utf8), nil)
                    return nil
                }
                return provider
            }
        } else {
            content
        }
    }
}

/// Dropping on the Dock: files onto an app open with it, onto the Bin go to the Trash, anywhere else they're kept
/// there; Dock items dragged along it move.
struct DockDrop: DropDelegate {
    let slots: [CustomDock.Slot]
    let centers: [CGFloat]
    let icon: CGFloat
    let length: CGFloat
    let vertical: Bool

    static let item = UTType(exportedAs: "local.den.dockitem")

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { DockController.shared.dragging = nil } // it landed on the Dock: nothing to remove
        let p = (vertical ? info.location.y : info.location.x) - length / 2
        let onto = centers.indices.first { abs(centers[$0] - p) < icon / 2 }.map { slots[$0] }
        // the kept thing at or after the drop point, to go before
        let index = centers.firstIndex { p < $0 } ?? centers.count
        let before = slots[index...].lazy.compactMap { if case .thing(let t) = $0 { t.id } else { nil } }.first
        for provider in info.itemProviders(for: [Self.item]) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: Self.item.identifier) { data, _ in
                guard let id = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let docks = Docks.shared
                        if let thing = docks.current?.custom.first(where: { $0.id == id }) { docks.insert([thing], before: before == id ? nil : before) }
                        else if id.hasPrefix("open:") || id.hasPrefix("recent:") { // an open app dragged in: keep it here
                            docks.insert([.app(String(id.drop { $0 != ":" }.dropFirst()))], before: before)
                        }
                    }
                }
            }
        }
        for provider in info.itemProviders(for: [.fileURL]) {
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                guard let url = url as? URL else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch onto {
                        case .thing(.app(let app)), .open(let app), .recent(let app):
                            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                        case .trash:
                            _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil) // Finder's Put Back brings it back
                        default:
                            Docks.shared.add([url], before: before)
                        }
                    }
                }
            }
        }
        return true
    }
}

struct DockIcon: View {
    @Environment(AppModel.self) private var model
    let slot: CustomDock.Slot
    let size: CGFloat
    let scale: CGFloat
    let edge: String
    let label: Bool
    let running: Bool
    let dots: Bool
    let badges: [String: String]
    @State private var stack = false
    @State private var bouncing = false

    private var path: String? {
        switch slot {
        case .thing(.app(let p)), .thing(.file(let p)), .open(let p), .recent(let p): p
        case .window(let w): NSRunningApplication(processIdentifier: w.pid)?.bundleURL?.path
        default: nil
        }
    }
    private var isApp: Bool { path?.hasSuffix(".app") == true }
    private var title: String {
        switch slot {
        case .thing(let t): t.title
        case .window(let w): w.title
        case .trash: "Bin"
        default: path.map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") } ?? ""
        }
    }

    var body: some View {
        let side = size * scale
        picture(side)
            .frame(width: side, height: side)
            .overlay(alignment: .topTrailing) {
                if let badge = badges[title] {
                    Text(badge).font(.system(size: max(10, size * 0.26), weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: size * 0.38, minHeight: size * 0.38)
                        .background(.red, in: Capsule()).offset(x: 4, y: -3)
                }
            }
            .overlay(alignment: edge == "left" ? .leading : edge == "right" ? .trailing : .bottom) {
                if dots, running {
                    Circle().fill(.primary.opacity(0.8)).frame(width: 4, height: 4)
                        .offset(x: edge == "left" ? -5 : edge == "right" ? 5 : 0, y: edge == "bottom" ? 5 : 0)
                }
            }
            .overlay(alignment: edge == "left" ? .trailing : edge == "right" ? .leading : .top) {
                if label {
                    Text(title).font(.system(size: 13)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: edge == "left" ? 120 : edge == "right" ? -120 : 0, y: edge == "bottom" ? -34 : 0)
                        .allowsHitTesting(false)
                }
            }
            .offset(y: edge == "bottom" && bouncing ? -size * 0.4 : 0)
            .offset(x: edge == "left" && bouncing ? size * 0.4 : edge == "right" && bouncing ? -size * 0.4 : 0)
            .animation(bouncing ? .easeInOut(duration: 0.3).repeatForever(autoreverses: true) : .easeOut(duration: 0.15), value: bouncing)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .contextMenu { menu }
            .popover(isPresented: $stack, arrowEdge: edge == "left" ? .trailing : edge == "right" ? .leading : .top) { if let path { FolderStack(path: path) } }
            .onChange(of: running) { if running { bouncing = false } }
    }

    @ViewBuilder private func picture(_ side: CGFloat) -> some View {
        switch slot {
        case .trash:
            Image(nsImage: NSImage(named: NSImage.trashEmptyName) ?? NSImage()).resizable().interpolation(.high)
        case .window:
            Image(nsImage: Icons.of(path ?? "/")).resizable().interpolation(.high).padding(side * 0.08)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: side * 0.24, weight: .semibold))
                        .padding(3).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
        case .thing(.link(let url)):
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).fill(.blue.gradient)
                .overlay { Image(systemName: "link").font(.system(size: side * 0.42, weight: .semibold)).foregroundStyle(.white) }
                .help(url)
        default:
            Image(nsImage: Icons.of(path ?? "/")).resizable().interpolation(.high)
        }
    }

    private func tap() {
        switch slot {
        case .window(let w):
            WindowIndex.bring(w)
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        case .thing(.link(let url)):
            URL(string: url).map { _ = NSWorkspace.shared.open($0) }
        default:
            guard let path else { return }
            if isApp {
                if !running {
                    bouncing = true
                    Task { try? await Task.sleep(for: .seconds(8)); bouncing = false } // in case it never says it's open
                }
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            } else {
                var folder: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &folder)
                if folder.boolValue { stack.toggle() } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if let path {
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }
            if isApp {
                if Docks.shared.pinnedApps.contains(path) { Button("Remove from Dock") { Docks.shared.edit { $0.removeAll { $0.id == "app:" + path } } } }
                else { Button("Keep in Dock") { Docks.shared.pin(path) } }
            } else {
                Button("Remove from Dock") { Docks.shared.edit { $0.removeAll { $0.id == slot.id } } }
            }
            if let app, let windows = WindowIndex.shared.byApp[app.processIdentifier], !windows.isEmpty {
                Divider()
                ForEach(windows) { w in Button(w.minimized ? w.title + " (minimized)" : w.title) { WindowIndex.bring(w) } }
                Divider()
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            if let app {
                Divider()
                Button("Hide") { app.hide() }
                Button("Quit") { app.terminate() }
            }
        } else if case .thing(.link) = slot {
            Button("Remove from Dock") { Docks.shared.edit { $0.removeAll { $0.id == slot.id } } }
        } else if case .trash = slot {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
        }
        Divider()
        Button("Dock Settings…") { model.go("mac:dock") }
    }
}

/// A folder in the Dock opens as a stack: its newest things first.
struct FolderStack: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        let items = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.addedToDirectoryDateKey],
                                                                    options: .skipsHiddenFiles)) ?? [])
            .sorted { added($0) > added($1) }.prefix(24)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78)), count: 4), spacing: 10) {
                ForEach(Array(items), id: \.self) { url in
                    VStack(spacing: 4) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        Text(url.lastPathComponent).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .draggable(url)
                }
            }
            Divider()
            HStack {
                Button("Open in Den") { model.go("loc:" + path) }
                Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func added(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate ?? .distantPast }
}

/// The charge, from the Mac's power sources (nil on a Mac without a battery).
func battery() -> (percent: Int, charging: Bool)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let now = d[kIOPSCurrentCapacityKey] as? Int, let full = d[kIOPSMaxCapacityKey] as? Int, full > 0 else { continue }
        return (now * 100 / full, d[kIOPSIsChargingKey] as? Bool ?? false)
    }
    return nil
}

// MARK: - Setting up Docks, in Den

struct DockPane: View {
    @Environment(AppModel.self) private var model
    @State private var docks = Docks.shared
    @State private var importing = false
    @State private var linking = false
    @State private var link = ""
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let look = Binding(get: { docks.look }, set: { docks.look = $0 })
        Form {
            Section {
                // Buttons, not a picker: this changes the macOS Dock, so only a real click may do it
                LabeledContent("Use") {
                    HStack {
                        ForEach([("apple", "The macOS Dock"), ("brain", "Den's Dock instead"), ("both", "Both")], id: \.0) { mode, title in
                            Button { docks.setMode(mode); DockController.shared.restart(model) } label: {
                                Label(title, systemImage: docks.mode == mode ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(docks.mode == mode ? Color.accentColor : Color.primary)
                        }
                    }
                }
                if docks.mode == "brain" {
                    Text("The macOS Dock is kept out of the way. Choosing it again puts its settings back as they were.").font(.caption).foregroundStyle(.secondary)
                }
                if docks.showsOwn {
                    Picker("Position on screen", selection: Binding(get: { docks.edge }, set: { docks.edge = $0; DockController.shared.restart(model) })) {
                        Text("Left").tag("left"); Text("Bottom").tag("bottom"); Text("Right").tag("right")
                    }
                    .pickerStyle(.segmented)
                }
            } header: { Text("Dock setup") }

            if docks.showsOwn {
                Section {
                    LabeledContent("Size") {
                        Slider(value: look.icon, in: 16...128) { Text("Size") } minimumValueLabel: { Text("Small") } maximumValueLabel: { Text("Large") }
                    }
                    Toggle("Magnification", isOn: look.magnify)
                    if docks.look.magnify {
                        LabeledContent("Magnified size") {
                            Slider(value: look.magnified, in: docks.look.icon...max(docks.look.icon, 160)) { Text("Magnified") }
                                minimumValueLabel: { Text("Small") } maximumValueLabel: { Text("Large") }
                        }
                    }
                    LabeledContent("Spacing") { Slider(value: look.spacing, in: 0...20) }
                    LabeledContent("Widgets") { Slider(value: look.widgets, in: 0.7...1.5) { Text("Widgets") } minimumValueLabel: { Text("Smaller") } maximumValueLabel: { Text("Bigger") } }
                    Picker("Background", selection: look.style) {
                        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("None").tag("clear")
                    }
                    .pickerStyle(.segmented)
                    if docks.look.style != "clear" { LabeledContent("Opacity") { Slider(value: look.opacity, in: 0...1) } }
                    LabeledContent("Corners") { Slider(value: look.radius, in: 0...36) }
                    Toggle("Show open apps you haven't kept in the Dock", isOn: look.running)
                    Toggle("Show recent apps", isOn: look.recents)
                    Toggle("Show the Bin", isOn: look.trash)
                    Toggle("Show dots under open apps", isOn: look.dots)
                    Toggle("Show names on hover", isOn: look.labels)
                    Toggle("Automatically hide and show the Dock", isOn: look.autoHide)
                    Toggle("Hide in full-screen apps", isOn: look.fullScreenHides)
                    Toggle("Notification badges", isOn: look.badges)
                    if docks.look.badges, !AXIsProcessTrusted() {
                        HStack {
                            Text("Badges, minimized windows and window lists need Accessibility access.").font(.caption).foregroundStyle(.secondary)
                            Button("Allow…") { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
                        }
                    }
                    Button("Match the macOS Dock's Size") {
                        let mac = DockLook.likeAppleDock()
                        docks.look.icon = mac.icon; docks.look.magnify = mac.magnify; docks.look.magnified = mac.magnified
                    }
                } header: { Text("Appearance") }

                Section {
                    ForEach(docks.current?.custom ?? []) { thing in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(thing.title, systemImage: symbol(thing))
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") { docks.edit { $0.removeAll { $0 == thing } } }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                            if case .widget(let config) = thing { WidgetSettings(config: config) { docks.replace($0) }.padding(.leading, 28) }
                        }
                    }
                    .onMove { from, to in docks.edit { $0.move(fromOffsets: from, toOffset: to) } }
                    HStack {
                        Button("Add Apps or Files…") { importing = true }
                        Button("Add Link…") { link = ""; linking = true }
                        Button("Add Space") { docks.edit { $0.append(.spacer(UUID())) } }
                    }
                } header: { Text("Kept in Den's Dock") } footer: {
                    Text("Open apps show up by themselves; right-click one and choose Keep in Dock to keep it. Drag things along the Dock to move them, or drop files and folders on it.")
                }
            }

            Section {
                ForEach(Array(docks.sets.enumerated()), id: \.element.id) { i, set in
                    HStack {
                        Image(systemName: set.id == docks.current?.id ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(set.name)
                            Text(summary(set)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if i < 9 { Text("⌃⌥\(i + 1)").font(.callout.monospaced()).foregroundStyle(.secondary) }
                        Button("Switch") { docks.activate(i) }.disabled(set.id == docks.current?.id)
                        Button("Delete", systemImage: "trash") { docks.sets.remove(at: i); docks.save(); docks.registerKeys() }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(docks.sets.count == 1)
                    }
                }
                Button("Save the macOS Dock as a New Dock…") { name = "Dock \(docks.sets.count + 1)"; naming = true }
            } header: { Text("Docks") } footer: {
                Text("Each Dock remembers the macOS Dock's apps and what's kept in Den's Dock. Switching doesn't open or close any app.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) { gallery }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { docks.add(urls) }
        }
        .alert("Add a link", isPresented: $linking) {
            TextField("https://", text: $link)
            Button("Add") { if let u = URL(string: link), u.scheme != nil { docks.add([u]) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Name this Dock", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { docks.saveAppleDock(as: name.isEmpty ? "Dock" : name) }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { docks.load() }
    }

    /// Every widget, live, to add with one click.
    private var gallery: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Widgets").font(.headline)
                Text(docks.showsOwn ? "Click + to add one to Den's Dock" : "They live in Den's Dock: turn it on below to use them")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Widget.allCases, id: \.self) { w in
                        VStack(spacing: 6) {
                            WidgetCard(config: WidgetConfig(kind: w, options: w.defaults)).fixedSize()
                            HStack(spacing: 4) {
                                Text(w.title).font(.caption).foregroundStyle(.secondary)
                                Button("Add \(w.title)", systemImage: "plus.circle.fill") {
                                    docks.edit { $0.append(.widget(WidgetConfig(kind: w, options: w.defaults))) }
                                }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    private func summary(_ set: DockSet) -> String {
        let apps = set.native.map { AppleDock.apps(in: $0).count } ?? 0
        return "\(apps) apps in the macOS Dock · \(set.custom.count) kept in Den's Dock"
    }

    private func symbol(_ t: DockThing) -> String {
        switch t {
        case .app: "app"
        case .file: "doc"
        case .link: "link"
        case .widget(let w): w.kind.symbol
        case .spacer: "space"
        }
    }
}
