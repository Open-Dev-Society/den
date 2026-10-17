import AppKit
import EventKit
import SwiftUI

// The notch, put to work: hover it to see your next meeting (with Join), how much you've worked today, a shelf to
// drop files on and AirDrop or drag them out later, and a field to ask Den. Nothing shows until you hover, except a
// countdown when a meeting is about to start.

@MainActor @Observable final class NotchState {
    var open = false
    var dropping = false
    var shelf: [URL] = []
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true } // for the Ask field
}

@MainActor final class NotchController {
    static let shared = NotchController()
    let state = NotchState()
    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var notch = CGRect.zero
    private var watching = false
    static let size = CGSize(width: 600, height: 254)
    var window: NSWindow? { panel }
    var hold = false // stays open (for snapshots)

    /// Only on a screen with a notch; nothing to do elsewhere.
    func start(_ model: AppModel) {
        guard panel == nil, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return }
        let f = screen.frame
        let width = f.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)
        notch = CGRect(x: f.midX - width / 2, y: f.maxY - screen.safeAreaInsets.top, width: width, height: screen.safeAreaInsets.top)
        let p = NotchPanel(contentRect: CGRect(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height, width: Self.size.width, height: Self.size.height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: NotchView(notch: notch.size, state: state).environment(model))
        p.orderFrontRegardless()
        panel = p
        let track: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { NotchController.shared.track() } }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: track),
                    NSEvent.addLocalMonitorForEvents(matching: kinds) { track($0); return $0 }].compactMap { $0 }
        if !watching { // a display plugged in or the resolution changed: measure again
            watching = true
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchController.shared.stop(); NotchController.shared.start(model) }
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.close()
        panel = nil
        state.open = false
    }

    private func track() {
        let mouse = NSEvent.mouseLocation
        if !state.open, notch.insetBy(dx: -16, dy: -6).contains(mouse) { setOpen(true) }
        else if state.open, !hold, let p = panel, !p.frame.insetBy(dx: -12, dy: -12).contains(mouse),
                NSEvent.pressedMouseButtons & 1 == 0 { setOpen(false) } // not while something is being dragged out
    }

    func setOpen(_ open: Bool) {
        guard let p = panel, state.open != open else { return }
        state.open = open
        p.ignoresMouseEvents = !open
        if !open, p.isKeyWindow { p.orderOut(nil); p.orderFrontRegardless() } // hand typing back to where it was
    }
}

struct NotchView: View {
    @Environment(AppModel.self) private var model
    let notch: CGSize
    let state: NotchState
    @State private var question = ""
    @State private var worked: (time: TimeInterval, prompts: Int, commits: Int) = (0, 0, 0)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let next = upcoming()
            let soon = next.flatMap { e in e.startDate.timeIntervalSinceNow < 15 * 60 ? e : nil }
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: state.open ? 24 : 10, bottomTrailingRadius: state.open ? 24 : 10)
                    .fill(.black)
                    .frame(width: state.open ? NotchController.size.width - 20 : notch.width + (soon == nil ? 0 : 190),
                           height: state.open ? NotchController.size.height - 12 : notch.height)
                if state.open {
                    expanded(next).padding(.top, notch.height + 10).padding(.horizontal, 24)
                        .frame(width: NotchController.size.width - 20, alignment: .top)
                        .transition(.opacity)
                } else if let soon {
                    HStack { // either side of the camera
                        Label(soon.title ?? "", systemImage: "calendar").lineLimit(1)
                        Spacer(minLength: notch.width)
                        Text(soon.startDate > .now ? soon.startDate.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) : "now")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(width: notch.width + 190, height: notch.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.open)
        .environment(\.colorScheme, .dark)
        .task(id: state.open) {
            guard state.open else { return }
            let work = model.brain?.work(since: Calendar.current.startOfDay(for: .now), until: .now) ?? []
            worked = (sessions(work).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) },
                      work.filter { $0.kind == "prompt" }.count, work.filter { $0.source == "git" }.count)
        }
    }

    private func upcoming() -> EKEvent? {
        CalendarSource.shared.events(from: .now - 3600, to: .now + 12 * 3600)
            .filter { !$0.isAllDay && $0.endDate > .now }.min { $0.startDate < $1.startDate }
    }

    private func expanded(_ next: EKEvent?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide)).font(.caption).foregroundStyle(.secondary)
                    if let next {
                        Text(next.title ?? "Meeting").font(.headline).lineLimit(2)
                        Text(next.startDate > .now ? "\(next.startDate.formatted(.relative(presentation: .named))) · \(next.startDate.formatted(date: .omitted, time: .shortened))"
                                                   : "Now · until \(next.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                        if let link = Entry(event: next).url.flatMap(URL.init(string:)) {
                            Button("Join", systemImage: "video") { NSWorkspace.shared.open(link) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    } else {
                        Text(CalendarSource.shared.connected ? "No more meetings today" : "Connect your calendar in Den to see meetings here")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if worked.time > 0 {
                        Text("\(Duration.seconds(worked.time).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) of work today · \(worked.prompts) prompts · \(worked.commits) commits")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 250, alignment: .leading)
                shelf
            }
            .frame(height: 138)
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(.tint)
                TextField("Ask Den anything…", text: $question)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        guard !question.isEmpty else { return }
                        QuickPanelController.shared.show(model, text: question, ask: true)
                        question = ""
                        NotchController.shared.setOpen(false)
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .foregroundStyle(.white)
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shelf").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !state.shelf.isEmpty {
                    Button("AirDrop", systemImage: "airplayaudio") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: state.shelf) }
                    Button("Clear", systemImage: "xmark") { state.shelf = [] }
                }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.white.opacity(state.dropping ? 0.8 : 0.22))
                if state.shelf.isEmpty {
                    Text("Drop files here to keep them handy").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(state.shelf, id: \.self) { url in
                                VStack(spacing: 3) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40, height: 40)
                                    Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle)
                                }
                                .frame(width: 66)
                                .draggable(url) // drag it into any app or folder
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("Remove from Shelf") { state.shelf.removeAll { $0 == url } }
                                }
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                state.shelf += urls.filter { u in u.isFileURL && !state.shelf.contains(u) }
                return true
            } isTargeted: { state.dropping = $0 }
        }
    }
}
