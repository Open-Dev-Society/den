import AppKit
import Darwin
import EventKit
import IOKit.ps
import SwiftUI

// Widgets for Den's Dock, as cards. Everything is read on this Mac (calendar, reminders, what's playing, battery,
// CPU, network, your Claude sessions); only Weather goes online, and only with the city you give it.

enum Widget: String, CaseIterable, Codable {
    case calendar, reminders, nowPlaying, focus, clock, countdown, timeProgress, system, network, battery, aiUsage, hydration,
         sticky, shortcut, weather, work, airdrop, ask

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .nowPlaying: "Now Playing"
        case .focus: "Focus Timer"
        case .clock: "Clock"
        case .countdown: "Countdown"
        case .timeProgress: "Time Progress"
        case .system: "System Activity"
        case .network: "Network Activity"
        case .battery: "Battery"
        case .aiUsage: "AI Usage"
        case .hydration: "Hydration"
        case .sticky: "Sticky Note"
        case .shortcut: "Shortcut"
        case .weather: "Weather"
        case .work: "Today's Work"
        case .airdrop: "AirDrop"
        case .ask: "Ask Den"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "list.bullet.circle"
        case .nowPlaying: "music.note"
        case .focus: "timer"
        case .clock: "clock"
        case .countdown: "hourglass"
        case .timeProgress: "chart.bar.xaxis"
        case .system: "cpu"
        case .network: "arrow.up.arrow.down"
        case .battery: "battery.75percent"
        case .aiUsage: "sparkles"
        case .hydration: "drop"
        case .sticky: "note.text"
        case .shortcut: "square.2.layers.3d"
        case .weather: "cloud.sun"
        case .work: "hammer"
        case .airdrop: "wave.3.right.circle"
        case .ask: "sparkle"
        }
    }

    /// What a new one starts with.
    var defaults: [String: String] {
        switch self {
        case .focus: ["minutes": "25"]
        case .countdown: ["to": ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: .now + 8 * 86400)), "label": "Launch"]
        case .timeProgress: ["span": "year"]
        case .hydration: ["every": "45", "last": String(Date.now.timeIntervalSince1970)]
        case .sticky: ["text": "Ship it.\nTake a walk."]
        default: [:]
        }
    }
}

struct WidgetConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: Widget
    var options: [String: String] = [:]
}

/// One card. `update` saves what a widget remembers (a note's text, when you last drank).
struct WidgetCard: View {
    let config: WidgetConfig
    var update: (WidgetConfig) -> Void = { _ in }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 64)
            .frame(minWidth: 64)
            .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.07)))
            .environment(\.colorScheme, config.kind == .sticky ? .light : .dark)
    }

    private var fill: AnyShapeStyle {
        switch config.kind {
        case .sticky: AnyShapeStyle(Color(red: 0.98, green: 0.84, blue: 0.36))
        case .hydration: AnyShapeStyle(Color.blue.opacity(0.18))
        default: AnyShapeStyle(Color.white.opacity(0.07))
        }
    }

    @ViewBuilder private var content: some View {
        let set = { (key: String, value: String) in var c = config; c.options[key] = value; update(c) }
        switch config.kind {
        case .calendar: CalendarWidget()
        case .reminders: RemindersWidget()
        case .nowPlaying: NowPlayingWidget()
        case .focus: FocusWidget(minutes: Double(config.options["minutes"] ?? "") ?? 25)
        case .clock: ClockWidget(zones: (config.options["zones"] ?? "").split(separator: ",").compactMap { TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) })
        case .countdown: CountdownWidget(to: ISO8601DateFormatter().date(from: config.options["to"] ?? ""), label: config.options["label"] ?? "")
        case .timeProgress: TimeProgressWidget(span: config.options["span"] ?? "year")
        case .system: SystemWidget()
        case .network: NetworkWidget()
        case .battery: BatteryWidget()
        case .aiUsage: AIUsageWidget()
        case .hydration:
            HydrationWidget(every: (Double(config.options["every"] ?? "") ?? 45) * 60,
                            last: Date(timeIntervalSince1970: Double(config.options["last"] ?? "") ?? Date.now.timeIntervalSince1970)) {
                set("last", String(Date.now.timeIntervalSince1970))
            }
        case .sticky: StickyWidget(text: config.options["text"] ?? "") { set("text", $0) }
        case .shortcut: ShortcutWidget(name: config.options["name"] ?? "")
        case .weather: WeatherWidget(city: config.options["city"] ?? "", lat: config.options["lat"], lon: config.options["lon"])
        case .work: WorkWidget()
        case .airdrop: AirDropWidget()
        case .ask: AskWidget()
        }
    }
}

// MARK: - Pieces

struct Ring<Inside: View>: View {
    let value: Double
    var color: Color = .green
    var width: CGFloat = 4
    @ViewBuilder var inside: Inside

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: width)
            Circle().trim(from: 0, to: max(0, min(value, 1))).stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90))
            inside
        }
    }
}

private func big(_ size: CGFloat = 24) -> Font { .system(size: size, weight: .semibold, design: .rounded).monospacedDigit() }
private func clock(_ t: TimeInterval) -> String {
    let s = Int(max(t, 0).rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Readings that need the last one to make sense (CPU use, network speed).
@MainActor final class Meters {
    static let shared = Meters()
    private var cpuLast: (busy: Double, all: Double)?
    private var netLast: (down: UInt64, up: UInt64, at: Date)?
    private var rates: (down: Double, up: Double) = (0, 0)
    private var cpuNow = 0.0

    func cpu() -> Double {
        var load = host_cpu_load_info()
        var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &load) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) }
        }
        guard ok == KERN_SUCCESS else { return cpuNow }
        let t = load.cpu_ticks // user, system, idle, nice
        let busy = Double(t.0) + Double(t.1) + Double(t.3), all = busy + Double(t.2)
        if let last = cpuLast, all - last.all > 50 { cpuNow = (busy - last.busy) / (all - last.all) } // ignore readings too close together
        if cpuLast == nil || all - cpuLast!.all > 50 { cpuLast = (busy, all) }
        return cpuNow
    }

    /// Bytes per second over Wi-Fi and Ethernet.
    func network() -> (down: Double, up: Double) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return rates }
        defer { freeifaddrs(list) }
        var down: UInt64 = 0, up: UInt64 = 0
        var p = list
        while let a = p?.pointee {
            if a.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: a.ifa_name).hasPrefix("en"),
               let data = a.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                down += UInt64(data.ifi_ibytes)
                up += UInt64(data.ifi_obytes)
            }
            p = a.ifa_next
        }
        if let last = netLast, Date.now.timeIntervalSince(last.at) > 0.5 {
            let dt = Date.now.timeIntervalSince(last.at)
            rates = (down >= last.down ? Double(down - last.down) / dt : 0, up >= last.up ? Double(up - last.up) / dt : 0)
        }
        if netLast == nil || Date.now.timeIntervalSince(netLast!.at) > 0.5 { netLast = (down, up, .now) }
        return rates
    }
}

// MARK: - Calendar and reminders

struct CalendarWidget: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let next = CalendarSource.shared.events(from: ctx.date - 3600, to: ctx.date + 86400)
                .filter { !$0.isAllDay && $0.endDate > ctx.date }.min { $0.startDate < $1.startDate }
            HStack(spacing: 12) {
                VStack(spacing: -3) {
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated)).font(.caption2.weight(.bold)).foregroundStyle(.red).textCase(.uppercase)
                    Text(ctx.date, format: .dateTime.day()).font(big(26))
                }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 36)
                if let next {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(color(next)).frame(width: 7, height: 7)
                            Text(next.title ?? "Meeting").font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        Text(next.startDate > ctx.date ? "\(next.startDate.formatted(date: .omitted, time: .shortened)) · \(next.startDate.formatted(.relative(presentation: .named)))"
                                                     : "Now · until \(next.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 170, alignment: .leading)
                    if let link = Entry(event: next).url.flatMap(URL.init(string:)) {
                        Button { NSWorkspace.shared.open(link) } label: {
                            Image(systemName: "video.fill").frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if CalendarSource.shared.connected {
                    Text("Nothing else today").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Connect Calendar") { Task { _ = await CalendarSource.shared.connect() } }.buttonStyle(.borderless)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go("calendar") }
    }
}

struct RemindersWidget: View {
    @State private var open: [String] = []
    @State private var connected = CalendarSource.shared.remindersConnected

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: "list.bullet.circle.fill").font(.title2).foregroundStyle(.blue)
                Text("\(open.count)").font(big(20))
            }
            if connected {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(open.prefix(3), id: \.self) { Text($0).font(.caption).lineLimit(1) }
                    if open.isEmpty { Text("All done").font(.callout).foregroundStyle(.secondary) }
                }
                .frame(width: 160, alignment: .leading)
            } else {
                Button("Connect Reminders") { Task { connected = await CalendarSource.shared.connectReminders() } }.buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app")) }
        .task(id: connected) {
            while connected, !Task.isCancelled {
                open = await CalendarSource.shared.openReminders()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

// MARK: - Now playing (Spotify and Music announce what they play; no permission needed to listen)

@MainActor @Observable final class Player {
    static let shared = Player()
    var title: String?
    var artist = ""
    var duration = 0.0
    var position = 0.0
    var at = Date.now
    var playing = false
    var app = ""
    var art: NSImage?
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        for (name, app) in [("com.spotify.client.PlaybackStateChanged", "Spotify"), ("com.apple.Music.playerInfo", "Music")] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { Player.shared.update(info, app: app) }
            }
        }
    }

    private func update(_ info: [AnyHashable: Any], app: String) {
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let name = info["Name"] as? String else { title = nil; return }
        if name != title { art = nil; if UserDefaults.standard.bool(forKey: "controls" + app) { fetchArt(app) } }
        title = name
        artist = info["Artist"] as? String ?? ""
        duration = ((info["Duration"] ?? info["Total Time"]) as? Double ?? 0) / 1000
        position = info["Playback Position"] as? Double ?? 0
        at = .now
        playing = state == "Playing"
        self.app = app
    }

    var elapsed: Double { min(position + (playing ? Date.now.timeIntervalSince(at) : 0), max(duration, 0)) }

    /// "playpause", "next track", "previous track". The first time, macOS asks whether Den may control the app.
    func send(_ command: String) {
        let app = app.isEmpty ? "Spotify" : app
        Task.detached {
            _ = runTool("/usr/bin/osascript", ["-e", "tell application \"\(app)\" to \(command)"])
            await MainActor.run { UserDefaults.standard.set(true, forKey: "controls" + app) }
        }
    }

    private func fetchArt(_ app: String) {
        guard app == "Spotify" else { return } // ponytail: Music's artwork needs its raw image data over AppleScript; add if asked
        Task.detached {
            let link = runTool("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to artwork url of current track"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: link), url.scheme == "https", let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            await MainActor.run { Player.shared.art = image }
        }
    }
}

struct NowPlayingWidget: View {
    @State private var player = Player.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: player.playing ? 1 : 30)) { _ in
            HStack(spacing: 10) {
                Group {
                    if let art = player.art { Image(nsImage: art).resizable().scaledToFill() }
                    else { Image(systemName: "music.note").font(.title3).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.1)) }
                }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                if let title = player.title {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(player.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(clock(player.elapsed)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            GeometryReader { g in
                                Capsule().fill(.white.opacity(0.15)).overlay(alignment: .leading) {
                                    Capsule().fill(.white).frame(width: g.size.width * (player.duration > 0 ? player.elapsed / player.duration : 0))
                                }
                            }
                            .frame(height: 3)
                            Text(clock(player.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 180)
                    HStack(spacing: 12) {
                        Button { player.send("previous track") } label: { Image(systemName: "backward.fill") }
                        Button { player.send("playpause") } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3) }
                        Button { player.send("next track") } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Play something in Spotify or Music").font(.callout).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                }
            }
        }
        .onAppear { player.start() }
    }
}

// MARK: - Time

struct FocusWidget: View {
    let minutes: Double
    @State private var end: Date?
    @State private var left: TimeInterval?

    var body: some View {
        let length = minutes * 60
        TimelineView(.periodic(from: .now, by: end == nil ? 60 : 1)) { ctx in
            let remaining = end.map { max($0.timeIntervalSince(ctx.date), 0) } ?? left ?? length
            HStack(spacing: 10) {
                Ring(value: 1 - remaining / length, color: .orange, width: 5) { EmptyView() }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(clock(remaining)).font(big())
                    Text(end != nil ? "Focus" : remaining < length ? "Paused" : "Tap to focus").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: remaining <= 0) { _, done in
                guard done, end != nil else { return }
                NSSound(named: "Glass")?.play()
                end = nil
                left = nil
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let e = end { left = e.timeIntervalSinceNow; end = nil } else { end = .now + (left ?? minutes * 60) }
        }
        .contextMenu { Button("Reset") { end = nil; left = nil } }
    }
}

struct ClockWidget: View {
    let zones: [TimeZone]

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour().minute()).font(big(26))
                    Text(ctx.date, format: .dateTime.weekday(.wide).day().month()).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(zones.prefix(3), id: \.identifier) { zone in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ctx.date.formatted({ var f = Date.FormatStyle.dateTime.hour().minute(); f.timeZone = zone; return f }())).font(big(18))
                        Text(zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct CountdownWidget: View {
    let to: Date?
    let label: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: (to?.timeIntervalSinceNow ?? 0) < 86400 ? 1 : 60)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                if let to {
                    let left = to.timeIntervalSince(ctx.date)
                    Text(left > 2 * 86400 ? "\(Int(left / 86400)) days" : left > 0 ? clock(left) : "Now").font(big())
                    Text(label.isEmpty ? to.formatted(date: .abbreviated, time: .omitted) : label).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Set a date").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 90, alignment: .leading)
        }
    }
}

struct TimeProgressWidget: View {
    let span: String

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let unit: Calendar.Component = ["day": .day, "week": .weekOfYear, "month": .month][span] ?? .year
            let interval = Calendar.current.dateInterval(of: unit, for: ctx.date)!
            let done = ctx.date.timeIntervalSince(interval.start) / interval.duration
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(span == "year" ? ctx.date.formatted(.dateTime.year()) : span == "month" ? ctx.date.formatted(.dateTime.month(.wide))
                         : span == "week" ? "This week" : "Today").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Int(done * 100))%").font(.callout.weight(.semibold).monospacedDigit())
                }
                HStack(spacing: 2) {
                    ForEach(0..<44, id: \.self) { i in
                        Capsule().fill(Double(i) / 44 < done ? Color.white : Color.white.opacity(0.18)).frame(width: 2, height: 16)
                    }
                }
            }
            .frame(width: 176)
        }
    }
}

// MARK: - This Mac

struct SystemWidget: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let cpu = Meters.shared.cpu(), ram = RAM.system()
            HStack(spacing: 18) {
                stat("\(Int((cpu * 100).rounded()))%", "CPU", .pink)
                stat("\(Int((Double(ram.used) / Double(max(ram.total, 1)) * 100).rounded()))%", "Memory",
                     ram.pressure >= 4 ? .red : ram.pressure >= 2 ? .orange : .blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go("mac:ram") }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(big())
            HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(label).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct NetworkWidget: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let n = Meters.shared.network()
            VStack(alignment: .leading, spacing: 3) {
                Label(bytes(Int64(n.down)) + "/s", systemImage: "arrow.down").foregroundStyle(.blue)
                Label(bytes(Int64(n.up)) + "/s", systemImage: "arrow.up").foregroundStyle(.pink)
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            .frame(minWidth: 100, alignment: .leading)
        }
    }
}

struct PowerReading: Hashable { let name: String; let symbol: String; let percent: Int; let charging: Bool }

/// Bluetooth accessories' charge, as System Information reports it (AirPods, keyboards, mice). Slow-ish: call rarely.
func accessoryBatteries() -> [PowerReading] {
    let out = runTool("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
    guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
          let bt = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
          let connected = bt["device_connected"] as? [[String: Any]] else { return [] }
    var found: [PowerReading] = []
    for device in connected {
        for (name, value) in device {
            guard let info = value as? [String: Any] else { continue }
            let lower = name.lowercased()
            let symbol = lower.contains("keyboard") ? "keyboard" : lower.contains("mouse") ? "magicmouse" : lower.contains("trackpad") ? "hand.point.up.left" : "airpodspro"
            for (key, part, sym) in [("device_batteryLevelLeft", " Left", "airpod.left"), ("device_batteryLevelRight", " Right", "airpod.right"),
                                     ("device_batteryLevelCase", " Case", "airpodspro.chargingcase.wireless"), ("device_batteryLevelMain", "", symbol)] {
                if let s = info[key] as? String, let n = Int(s.filter(\.isNumber)) { found.append(PowerReading(name: name + part, symbol: sym, percent: n, charging: false)) }
            }
        }
    }
    return found
}

struct BatteryWidget: View {
    @State private var readings: [PowerReading] = []

    var body: some View {
        HStack(spacing: 12) {
            ForEach(readings, id: \.self) { r in
                VStack(spacing: 3) {
                    Ring(value: Double(r.percent) / 100, color: r.percent < 20 ? .red : .green) {
                        Image(systemName: r.charging ? "bolt.fill" : r.symbol).font(.system(size: 13))
                    }
                    .frame(width: 34, height: 34)
                    Text("\(r.percent)%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .help(r.name)
            }
            if readings.isEmpty { Image(systemName: "powerplug").foregroundStyle(.secondary) }
        }
        .task {
            var accessories: [PowerReading] = [], checked = Date.distantPast
            while !Task.isCancelled {
                if checked < .now - 300 { // accessories every five minutes, the Mac every minute
                    accessories = await Task.detached { accessoryBatteries() }.value
                    checked = .now
                }
                readings = (battery().map { [PowerReading(name: "This Mac", symbol: "laptopcomputer", percent: $0.percent, charging: $0.charging)] } ?? [])
                    + accessories
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

// MARK: - You

struct AIUsageWidget: View {
    @Environment(AppModel.self) private var model
    @State private var week: [Int] = Array(repeating: 0, count: 7) // prompts a day, oldest first
    @State private var time: TimeInterval = 0

    var body: some View {
        let today = week.last ?? 0
        HStack(spacing: 12) {
            Ring(value: Double(today) / Double(max(week.max() ?? 1, 1)), color: .orange, width: 5) {
                Text("\(today)").font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .frame(width: 42, height: 42)
            .help("Today's prompts, against your busiest day this week")
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude").font(.callout.weight(.semibold))
                Text("\(today) prompts · \(Duration.seconds(time).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(week.enumerated()), id: \.offset) { i, n in
                        Capsule().fill(i == 6 ? Color.orange : Color.white.opacity(0.35))
                            .frame(width: 5, height: max(2, 12 * CGFloat(n) / CGFloat(max(week.max() ?? 1, 1))))
                    }
                }
                .frame(height: 12)
            }
        }
        .task {
            while !Task.isCancelled {
                let cal = Calendar.current, start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now))!
                let prompts = (model.brain?.work(since: start, until: .now) ?? []).filter { $0.kind == "prompt" }
                week = (0..<7).map { d in prompts.filter { cal.dateComponents([.day], from: start, to: $0.date).day == d }.count }
                time = sessions(prompts.filter { cal.isDateInToday($0.date) }).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}

struct HydrationWidget: View {
    let every: TimeInterval
    let last: Date
    let drank: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            let left = (last + every).timeIntervalSince(ctx.date)
            VStack(spacing: 0) {
                Text(left > 0 ? "\(Int((left / 60).rounded(.up))) min" : "Now").font(big())
                Text(left > 0 ? "Next drink" : "Time to drink").font(.caption).foregroundStyle(left > 0 ? Color.secondary : Color.cyan)
            }
            .frame(width: 110)
            .background(alignment: .bottom) { // the water level drops as time passes
                Wave(phase: ctx.date.timeIntervalSinceReferenceDate)
                    .fill(Color.blue.opacity(0.45))
                    .frame(height: 64 * max(0.08, min(left / every, 1)))
                    .padding(.horizontal, -12)
            }
            .frame(height: 64)
            .clipped()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: drank)
        .help("Tap when you've had a glass")
    }
}

struct Wave: Shape {
    var phase: Double

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: r.maxY))
        for x in stride(from: 0, through: r.width, by: 2) {
            p.addLine(to: CGPoint(x: x, y: 3 + 3 * sin(x / 18 + phase * 2)))
        }
        p.addLine(to: CGPoint(x: r.width, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct StickyWidget: View {
    let text: String
    let save: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("A note", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(.black.opacity(0.85))
            .lineLimit(3)
            .frame(width: 150, alignment: .leading)
            .onAppear { draft = text }
            .onChange(of: draft) { _, new in if new != text { save(new) } }
    }
}

struct ShortcutWidget: View {
    let name: String
    @State private var ran = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: ran ? "checkmark.circle.fill" : "square.2.layers.3d.fill").font(.title2)
                .foregroundStyle(LinearGradient(colors: [.pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(name.isEmpty ? "Choose a shortcut" : name).font(.caption).lineLimit(1)
        }
        .frame(minWidth: 90)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !name.isEmpty else { return }
            Task.detached { _ = runTool("/usr/bin/shortcuts", ["run", name]) }
            ran = true
            Task { try? await Task.sleep(for: .seconds(2)); ran = false }
        }
    }
}

/// The weather from Open-Meteo (free, no account): only the city's coordinates are sent.
struct WeatherWidget: View {
    let city: String
    let lat: String?
    let lon: String?
    @State private var reading: (temp: Double, code: Int)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(reading?.code ?? 0)).symbolRenderingMode(.multicolor).font(.system(size: 28))
            VStack(alignment: .leading, spacing: 0) {
                Text(reading.map { "\(Int($0.temp.rounded()))°" } ?? "–").font(big(24))
                Text(city.isEmpty ? "Choose a city" : city).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 100)
        .task(id: "\(lat ?? "")\(lon ?? "")") {
            guard let lat, let lon else { return }
            let unit = Locale.current.measurementSystem == .us ? "&temperature_unit=fahrenheit" : ""
            while !Task.isCancelled {
                if let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code\(unit)"),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let now = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["current"] as? [String: Any],
                   let temp = now["temperature_2m"] as? Double {
                    reading = (temp, now["weather_code"] as? Int ?? 0)
                }
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1...3: "cloud.sun.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 80...82: "cloud.heavyrain.fill"
        case 95...: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    /// "Oslo" → its coordinates and proper name.
    static func find(_ city: String) async -> (name: String, lat: Double, lon: Double)? {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        guard let url = parts.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let first = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return nil }
        return (first["name"] as? String ?? city, lat, lon)
    }
}

struct WorkWidget: View {
    @Environment(AppModel.self) private var model
    @State private var worked: TimeInterval = 0
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Duration.seconds(worked).formatted(.units(allowed: [.hours, .minutes], width: .narrow))).font(big())
            Text("worked today · \(count) sessions").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go("calendar") }
        .task {
            while !Task.isCancelled {
                let today = sessions(model.brain?.work(since: Calendar.current.startOfDay(for: .now), until: .now) ?? [])
                worked = today.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                count = today.count
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}

struct AirDropWidget: View {
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "wave.3.right.circle.fill").font(.title2).foregroundStyle(.blue)
            Text("AirDrop").font(.caption2).foregroundStyle(.secondary)
        }
        .scaleEffect(dropping ? 1.15 : 1)
        .animation(.snappy, value: dropping)
        .help("Drop files here to AirDrop them")
        .dropDestination(for: URL.self) { urls, _ in
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
            return true
        } isTargeted: { dropping = $0 }
    }
}

struct AskWidget: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "sparkle").font(.title2).foregroundStyle(.tint)
            Text("Ask").font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { QuickPanelController.shared.show(model) }
    }
}

/// What a widget can be set to, shown under it in Dock settings.
struct WidgetSettings: View {
    let config: WidgetConfig
    let update: (WidgetConfig) -> Void
    @State private var city = ""
    @State private var looking = false
    @State private var shortcuts: [String] = []

    var body: some View {
        let option = { (key: String) in Binding(get: { config.options[key] ?? "" }, set: { var c = config; c.options[key] = $0; update(c) }) }
        switch config.kind {
        case .focus:
            Stepper("\(config.options["minutes"] ?? "25") minutes", value: Binding(get: { Int(config.options["minutes"] ?? "") ?? 25 },
                                                                                    set: { option("minutes").wrappedValue = String($0) }), in: 5...120, step: 5)
        case .clock:
            TextField("Other time zones, e.g. Europe/London, America/New_York", text: option("zones"))
        case .countdown:
            HStack {
                TextField("Label", text: option("label"))
                DatePicker("", selection: Binding(get: { ISO8601DateFormatter().date(from: config.options["to"] ?? "") ?? .now },
                                                  set: { option("to").wrappedValue = ISO8601DateFormatter().string(from: $0) }))
                    .labelsHidden()
            }
        case .timeProgress:
            Picker("", selection: option("span")) {
                Text("Year").tag("year"); Text("Month").tag("month"); Text("Week").tag("week"); Text("Day").tag("day")
            }
            .pickerStyle(.segmented).labelsHidden()
        case .hydration:
            Stepper("Every \(config.options["every"] ?? "45") minutes", value: Binding(get: { Int(config.options["every"] ?? "") ?? 45 },
                                                                                        set: { option("every").wrappedValue = String($0) }), in: 15...180, step: 15)
        case .shortcut:
            Picker("Shortcut", selection: option("name")) {
                Text("Choose…").tag("")
                ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
            }
            .task { shortcuts = await Task.detached { runTool("/usr/bin/shortcuts", ["list"]).split(separator: "\n").map(String.init) }.value }
        case .weather:
            HStack {
                TextField("City", text: $city).onSubmit(find)
                Button(looking ? "Looking…" : "Set", action: find).disabled(city.isEmpty || looking)
            }
            .onAppear { city = config.options["city"] ?? "" }
        default:
            EmptyView()
        }
    }

    private func find() {
        looking = true
        Task {
            if let place = await WeatherWidget.find(city) {
                var c = config
                c.options["city"] = place.name
                c.options["lat"] = String(place.lat)
                c.options["lon"] = String(place.lon)
                update(c)
            }
            looking = false
        }
    }
}
