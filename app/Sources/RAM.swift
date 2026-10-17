import AppKit
import Darwin
import SwiftUI

// RAM, honestly: macOS keeps memory full on purpose, so "cleaning" it does little. What helps is knowing what's
// using it, what keeps growing, and quitting that. Memory per app includes all its helper processes.

struct AppMemory: Identifiable {
    let id: String // the app bundle's path, or the program's name
    let name: String
    var bytes: Int64 = 0
    var processes = 0
    var app: NSRunningApplication? // set for apps you can quit
}

/// Which app a process belongs to: the outermost .app it lives in (Chrome's helpers count as Chrome), else its own name.
func owner(ofProcessAt path: String) -> (id: String, name: String) {
    if let r = path.range(of: ".app/") {
        let bundle = String(path[..<r.lowerBound]) + ".app"
        return (bundle, ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension)
    }
    // ~/.local/share/claude/versions/2.1.296 is "claude": skip version numbers and plumbing folders
    let parts = path.split(separator: "/").map(String.init)
    let name = parts.last { !($0.first?.isNumber ?? true) && !["versions", "bin", "libexec", "current"].contains($0) } ?? parts.last ?? path
    return (name, name == "com.apple.WebKit.WebContent" ? "Web pages (Safari, Mail…)" : name)
}

enum RAM {
    /// Every process of yours, by the app it belongs to, biggest first.
    static func byApp() -> [AppMemory] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { a in a.bundleURL.map { ($0.path, a) } },
                                 uniquingKeysWith: { a, _ in a })
        var apps: [String: AppMemory] = [:]
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue } // not yours, or gone
            let who = owner(ofProcessAt: String(cString: path))
            apps[who.id, default: AppMemory(id: who.id, name: who.name, app: running[who.id])].bytes += Int64(info.ri_phys_footprint)
            apps[who.id]!.processes += 1
        }
        return apps.values.sorted { $0.bytes > $1.bytes }
    }

    struct System { var used: Int64 = 0, total: Int64 = 0, swap: Int64 = 0, pressure = 1 } // 1 normal, 2 warning, 4 critical

    static func system() -> System {
        var s = System(total: Int64(ProcessInfo.processInfo.physicalMemory))
        var vm = vm_statistics64_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
        }
        if ok == KERN_SUCCESS { // as Activity Monitor counts it: app memory + wired + compressed
            let page = Int64(vm_kernel_page_size)
            s.used = (Int64(vm.internal_page_count) - Int64(vm.purgeable_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count)) * page
        }
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { s.swap = Int64(swap.xsu_used) }
        var level: Int32 = 1, lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0) == 0 { s.pressure = Int(level) }
        return s
    }

    /// "Grew from 1.1 GB to 3.8 GB since 9:40": only when it's grown a lot, both relatively and in size.
    static func growth(_ samples: [(at: Date, bytes: Int64)], now: Int64) -> String? {
        guard let first = samples.first, first.at < .now - 3600, now > first.bytes * 3 / 2, now - first.bytes > 400_000_000 else { return nil }
        return "Grew from \(bytes(first.bytes)) to \(bytes(now)) since \(first.at.formatted(date: .omitted, time: .shortened))"
    }
}

/// Samples every five minutes for a day, so growth shows up; nothing is written to disk.
@MainActor @Observable final class RAMWatch {
    static let shared = RAMWatch()
    var apps: [AppMemory] = []
    var system = RAM.System()
    @ObservationIgnored var history: [String: [(at: Date, bytes: Int64)]] = [:]
    @ObservationIgnored private var started = false

    func refresh(record: Bool = false) async {
        let (apps, system) = await Task.detached { (RAM.byApp(), RAM.system()) }.value
        self.apps = apps
        self.system = system
        guard record else { return }
        for a in apps.prefix(40) { history[a.id, default: []].append((.now, a.bytes)) }
        for k in history.keys { history[k]?.removeAll { $0.at < .now - 86400 } }
        history = history.filter { !($0.value.isEmpty) }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { // live widgets and readings churn small allocations; hand the freed pages back to macOS often
            while true { try? await Task.sleep(for: .seconds(20)); returnFreedMemory() }
        }
        Task {
            while true {
                await refresh(record: true)
                returnFreedMemory() // widgets and readings churn small allocations; give the pages back
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}

struct RAMPane: View {
    @State private var watch = RAMWatch.shared
    @State private var restarting: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            summary.padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            List(watch.apps.filter { $0.bytes > 20_000_000 }) { row($0) }
                .listStyle(.inset)
        }
        .task { // live while you're looking
            while !Task.isCancelled {
                await watch.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var summary: some View {
        let s = watch.system
        let (word, tint): (String, Color) = s.pressure >= 4 ? ("High", .red) : s.pressure >= 2 ? ("Rising", .orange) : ("Normal", .green)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(bytes(s.used)) in use").font(.title2.weight(.semibold))
                Text("of \(bytes(s.total))").foregroundStyle(.secondary)
                Spacer()
                if s.swap > 100_000_000 { Text("\(bytes(s.swap)) swapped to disk").foregroundStyle(.secondary) }
                Label("Pressure: \(word)", systemImage: "circle.fill").foregroundStyle(tint).labelStyle(.titleAndIcon)
            }
            ProgressView(value: Double(s.used), total: Double(max(s.total, 1))).tint(tint)
            Text(s.pressure >= 2 ? "Your Mac is short on memory. Quit apps you aren't using, starting with the biggest or the ones that keep growing."
                                 : "macOS keeps memory full on purpose, so a high number is fine. What matters is pressure; while it's normal, there's nothing to clean.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func row(_ a: AppMemory) -> some View {
        let samples = watch.history[a.id] ?? []
        let grew = RAM.growth(samples, now: a.bytes)
        return HStack(spacing: 10) {
            Group {
                if let app = a.app, let icon = app.icon { Image(nsImage: icon).resizable() }
                else if a.id.hasPrefix("/") { Image(nsImage: NSWorkspace.shared.icon(forFile: a.id)).resizable() }
                else { Image(systemName: "terminal").resizable().scaledToFit().padding(4).foregroundStyle(.secondary) }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).lineLimit(1)
                Text(grew ?? (a.processes > 1 ? "\(a.processes) processes" : "1 process"))
                    .font(.caption).foregroundStyle(grew == nil ? Color.secondary : Color.orange).lineLimit(1)
            }
            Spacer()
            Sparkline(values: samples.map(\.bytes) + [a.bytes]).frame(width: 80, height: 18).help("The last day, every five minutes")
            Text(bytes(a.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
            if let app = a.app, ![Bundle.main.bundleIdentifier, "com.apple.finder"].contains(app.bundleIdentifier) {
                if grew != nil {
                    Button("Restart") { restart(app, id: a.id) }.disabled(restarting.contains(a.id))
                }
                Button("Quit") { app.terminate() }
            }
        }
        .padding(.vertical, 2)
    }

    /// Quits, waits for it to close (it may ask to save), then opens it again.
    private func restart(_ app: NSRunningApplication, id: String) {
        guard let url = app.bundleURL else { return }
        restarting.insert(id)
        app.terminate()
        Task {
            for _ in 0..<60 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(500)) }
            if app.isTerminated { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            restarting.remove(id)
        }
    }
}

struct Sparkline: View {
    let values: [Int64]

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 2, let hi = values.max(), hi > 0 else { return } // from zero, so small wobbles look small
            let lo: Int64 = 0
            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                                y: size.height * (1 - CGFloat(v - lo) / CGFloat(hi - lo)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(.secondary), lineWidth: 1.2)
        }
    }
}
