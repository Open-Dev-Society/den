import EventKit
import SwiftUI

// A calendar that shows what you planned and what you actually did: meetings from macOS's calendar, and every commit
// and Claude prompt from your activity, side by side. Month, Week and Day.

enum CalMode: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"
    var id: Self { self }
}

/// A day, as something you can select and inspect.
extension Entry {
    init(day: Date) {
        self.init(id: "day:\(Int(day.timeIntervalSince1970))", source: "day", kind: "day", date: day,
                  title: day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }
}

struct CalendarPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("calendarMode") private var mode = CalMode.week // remembered; also settable with -calendarMode Month
    @State private var anchor = Calendar.current.startOfDay(for: .now)
    @State private var events: [EKEvent] = []
    @State private var work: [Date: [Entry]] = [:] // by local day
    @State private var journals: [Date: Note] = [:]
    @State private var connected = CalendarSource.shared.connected
    private let cal = Calendar.current

    private var range: (from: Date, to: Date) {
        switch mode {
        case .day: return (anchor, cal.date(byAdding: .day, value: 1, to: anchor)!)
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: anchor)!.start
            return (start, cal.date(byAdding: .day, value: 7, to: start)!)
        case .month: // whole weeks around the month, as the grid shows them
            let month = cal.dateInterval(of: .month, for: anchor)!
            let start = cal.dateInterval(of: .weekOfYear, for: month.start)!.start
            return (start, cal.date(byAdding: .day, value: 42, to: start)!)
        }
    }

    private var title: String {
        switch mode {
        case .day: return anchor.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week, .month: return anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                ControlGroup {
                    Button("Previous", systemImage: "chevron.left") { move(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("Today") { anchor = cal.startOfDay(for: .now) }.keyboardShortcut("t", modifiers: .command)
                    Button("Next", systemImage: "chevron.right") { move(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
                }
                .fixedSize()
                Picker("View", selection: $mode) { ForEach(CalMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if !connected { connectBanner }
            Divider()

            switch mode {
            case .month:
                MonthGrid(anchor: anchor, start: range.from, events: events, work: work, journals: journals) { day in
                    anchor = day
                    mode = .day
                }
            case .week, .day:
                HourGrid(start: range.from, days: mode == .day ? 1 : 7, events: events, work: work)
            }
        }
        .task(id: "\(mode.rawValue) \(range.from.timeIntervalSince1970) \(connected)") { await load() }
    }

    private var connectBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus").foregroundStyle(.tint)
            Text("Showing your work. Connect your calendar to see meetings beside it.").foregroundStyle(.secondary)
            Spacer()
            if CalendarSource.shared.undecided {
                Button("Connect Calendar") {
                    Task {
                        connected = await CalendarSource.shared.connect()
                        if connected { await MemoryStore.shared.forgetDays(); Task { await model.growMemory() } }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.06))
    }

    private func move(_ step: Int) {
        let unit: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        anchor = cal.date(byAdding: unit, value: step, to: anchor)!
    }

    private func load() async {
        let (from, to) = range
        events = CalendarSource.shared.events(from: from, to: to)
        let brain = model.brain
        work = Dictionary(grouping: await Task.detached { brain?.work(since: from, until: to) ?? [] }.value) { cal.startOfDay(for: $0.date) }
        journals = Dictionary(await MemoryStore.shared.days(from: from, to: to).map { (cal.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Colour of an event's calendar, as macOS shows it.
func color(_ e: EKEvent) -> Color { e.calendar.cgColor.map { Color(cgColor: $0) } ?? .accentColor }

// MARK: - Month

struct MonthGrid: View {
    @Environment(AppModel.self) private var model
    let anchor: Date
    let start: Date
    let events: [EKEvent]
    let work: [Date: [Entry]]
    let journals: [Date: Note]
    let openDay: (Date) -> Void
    private let cal = Calendar.current

    var body: some View {
        let days = (0..<42).map { cal.date(byAdding: .day, value: $0, to: start)! }
        let busiest = max(work.values.map(\.count).max() ?? 1, 1)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(days[i].formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            Divider()
            GeometryReader { geo in
                let h = geo.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                cell(days[row * 7 + col], busiest: busiest).frame(maxWidth: .infinity).frame(height: h)
                                if col < 6 { Divider() }
                            }
                        }
                        if row < 5 { Divider() }
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, busiest: Int) -> some View {
        let today = cal.isDateInToday(day), inMonth = cal.isDate(day, equalTo: anchor, toGranularity: .month)
        let todays = events.filter { cal.isDate($0.startDate, inSameDayAs: day) }.sorted { $0.startDate < $1.startDate }
        let did = work[day] ?? []
        let selected = model.inspected?.id == Entry(day: day).id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(today ? Color.red : .clear, in: Capsule())
                Spacer()
                if !did.isEmpty {
                    Text("\(did.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .help("\(did.filter { $0.source == "git" }.count) commits, \(did.filter { $0.kind == "prompt" }.count) prompts to Claude")
                }
            }
            ForEach(todays.prefix(3), id: \.eventIdentifier) { e in
                Button { model.inspected = Entry(event: e) } label: {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(color(e)).frame(width: 3)
                        Text(e.title ?? "").font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .background(color(e).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
            if todays.count > 3 { Text("\(todays.count - 3) more").font(.caption2).foregroundStyle(.secondary) }
            if todays.isEmpty, let journal = journals[day] {
                Text((try? AttributedString(markdown: journal.body)) ?? AttributedString(journal.body)).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.orange.opacity(did.isEmpty ? 0 : 0.04 + 0.16 * Double(did.count) / Double(busiest))) // how much you worked
        .overlay { if selected { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .opacity(inMonth ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openDay(day) }
        .onTapGesture { model.inspected = Entry(day: day) }
    }
}

// MARK: - Week and Day

struct HourGrid: View {
    @Environment(AppModel.self) private var model
    let start: Date
    let days: Int
    let events: [EKEvent]
    let work: [Date: [Entry]]
    private let hour: CGFloat = 46
    private let cal = Calendar.current

    var body: some View {
        let columns = (0..<days).map { cal.date(byAdding: .day, value: $0, to: start)! }
        VStack(spacing: 0) {
            HStack(spacing: 0) { // day headers, then all-day events
                Color.clear.frame(width: 52)
                ForEach(columns, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated))).foregroundStyle(.secondary)
                            Text(day.formatted(.dateTime.day())).fontWeight(.semibold)
                                .foregroundStyle(cal.isDateInToday(day) ? Color.white : Color.primary)
                                .padding(.horizontal, 6).background(cal.isDateInToday(day) ? Color.red : .clear, in: Capsule())
                        }
                        ForEach(events.filter { $0.isAllDay && cal.isDate($0.startDate, inSameDayAs: day) }, id: \.eventIdentifier) { e in
                            Text(e.title ?? "").font(.caption).lineLimit(1).padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(color(e).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                                .onTapGesture { model.inspected = Entry(event: e) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { model.inspected = Entry(day: day) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollViewReader { scroller in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) { // hour labels
                            ForEach(0..<24, id: \.self) { h in
                                Text(h == 0 ? "" : cal.date(bySettingHour: h, minute: 0, second: 0, of: start)!.formatted(.dateTime.hour()))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 52, height: hour, alignment: .topTrailing).padding(.trailing, 6).offset(y: -6)
                                    .id(h)
                            }
                        }
                        ForEach(columns, id: \.self) { day in
                            column(day).frame(maxWidth: .infinity)
                        }
                    }
                }
                .onAppear { scroller.scrollTo(max(cal.component(.hour, from: .now) - 2, 7), anchor: .top) }
            }
        }
    }

    private func column(_ day: Date) -> some View {
        let meetings = events.filter { !$0.isAllDay && cal.isDate($0.startDate, inSameDayAs: day) }
            .map { Slot(id: "cal:" + ($0.eventIdentifier ?? ""), start: $0.startDate, end: $0.endDate, event: $0) }
        let placed = sideBySide(meetings + sessions(work[day] ?? []))
        let y = { (d: Date) in CGFloat(d.timeIntervalSince(day) / 3600) * self.hour }
        return GeometryReader { geo in
            let width = geo.size.width - 6
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) { // hour lines
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle().fill(.quaternary).frame(height: 0.5).frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                Rectangle().fill(.quaternary).frame(width: 0.5).frame(maxHeight: .infinity)

                ForEach(placed, id: \.slot.id) { p in
                    let w = width / CGFloat(p.of), slot = p.slot
                    Button { model.inspected = slot.event.map(Entry.init(event:)) ?? Entry(day: day) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slot.event?.title ?? slot.projects).font(.caption.weight(.semibold)).lineLimit(2)
                            Text(slot.event == nil ? slot.tally : slot.start.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).opacity(0.8).lineLimit(1)
                        }
                        .padding(4).padding(.leading, 2)
                        .frame(width: w - 2, height: max(min(y(slot.end), hour * 24) - y(slot.start) - 1, 18), alignment: .topLeading)
                        .background(slot.tint.opacity(slot.event == nil ? 0.1 : 0.22), in: RoundedRectangle(cornerRadius: 4))
                        .overlay { // planned: solid edge in its calendar's colour; did: dashed outline
                            if slot.event == nil {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(slot.tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            } else {
                                Rectangle().fill(slot.tint).frame(width: 3).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(slot.event == nil ? slot.work.prefix(8).map { "\($0.date.formatted(date: .omitted, time: .shortened))  \($0.title)" }.joined(separator: "\n") : "")
                    .offset(x: 3 + CGFloat(p.col) * w, y: y(slot.start))
                }

                if cal.isDateInToday(day) { // now
                    Rectangle().fill(Color.red).frame(height: 1.5).offset(y: y(.now))
                    Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -3, y: y(.now) - 3)
                }
            }
        }
        .frame(height: hour * 24)
    }
}

/// A block in the hour grid: a meeting (planned), or a stretch of work (what you did).
struct Slot {
    let id: String
    let start: Date
    let end: Date
    var event: EKEvent? = nil
    var work: [Entry] = []

    var tint: Color { event.map(color) ?? .orange }
    /// The projects worked on, busiest first.
    var projects: String {
        let counts = Dictionary(grouping: work) { $0.context.components(separatedBy: " · ")[0] }.mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.prefix(2).map(\.key).joined(separator: ", ")
    }
    var tally: String {
        let commits = work.filter { $0.source == "git" }.count, prompts = work.count - commits
        return [commits == 0 ? nil : "\(commits) commit\(commits == 1 ? "" : "s")", prompts == 0 ? nil : "\(prompts) prompt\(prompts == 1 ? "" : "s")"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Commits and prompts with less than 45 minutes between them are one stretch of work (at least 15 minutes tall).
func sessions(_ items: [Entry]) -> [Slot] {
    var runs: [[Entry]] = []
    for e in items.sorted(by: { $0.date < $1.date }) {
        if let last = runs.last?.last, e.date.timeIntervalSince(last.date) < 45 * 60 { runs[runs.count - 1].append(e) } else { runs.append([e]) }
    }
    return runs.map { run in
        Slot(id: "work:" + run[0].id, start: run[0].date, end: max(run.last!.date, run[0].date + 15 * 60), work: run)
    }
}

/// Blocks whose times overlap share the column side by side: each gets a place and knows how many share its time.
func sideBySide(_ slots: [Slot]) -> [(slot: Slot, col: Int, of: Int)] {
    var out: [(slot: Slot, col: Int, of: Int)] = [], group: [(slot: Slot, col: Int)] = [], ends: [Date] = []
    func flush() { let n = (group.map(\.col).max() ?? 0) + 1; out += group.map { ($0.slot, $0.col, n) }; group = []; ends = [] }
    for s in slots.sorted(by: { $0.start < $1.start }) {
        if let last = ends.max(), s.start >= last { flush() } // nothing still running: a new group
        let col = ends.firstIndex { $0 <= s.start } ?? ends.count
        if col < ends.count { ends[col] = s.end } else { ends.append(s.end) }
        group.append((s, col))
    }
    flush()
    return out
}

// MARK: - A day's page

struct DayDetail: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    @State private var journal: Note?
    @State private var meetings: [Entry] = []
    @State private var work: [Entry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "calendar").font(.system(size: 22)).foregroundStyle(.red)
                        .frame(width: 48, height: 48).background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.title3.weight(.semibold))
                        Text(summary).foregroundStyle(.secondary)
                    }
                }
                Button("Ask about this day", systemImage: "sparkle") {
                    let question = "what did I do on \(entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))?"
                    model.scope = "mem:ask"
                    Task { await model.ask(question) }
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                if let journal { SummaryCard(text: journal.body) }
                if !meetings.isEmpty {
                    Block(title: "Meetings", symbol: "calendar") { ForEach(meetings) { RelatedRow(entry: $0, current: false) } }
                }
                ForEach(byProject, id: \.name) { group in
                    Block(title: "\(group.name) · \(group.items.count)", symbol: "hammer") {
                        ForEach(group.items.prefix(8)) { RelatedRow(entry: $0, current: false) }
                        if group.items.count > 8 { Text("\(group.items.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(20)
        }
        .task {
            let next = Calendar.current.date(byAdding: .day, value: 1, to: entry.date)!
            journal = await MemoryStore.shared.note(key: "day:" + model.dayKey(entry.date))
            meetings = model.meetings(since: entry.date, until: next).map(\.entry)
            work = model.brain?.work(since: entry.date, until: next) ?? []
        }
    }

    private var summary: String {
        let commits = work.filter { $0.source == "git" }.count, prompts = work.filter { $0.kind == "prompt" }.count
        return [meetings.isEmpty ? nil : "\(meetings.count) meetings", commits == 0 ? nil : "\(commits) commits",
                prompts == 0 ? nil : "\(prompts) prompts to Claude"].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "A quiet day"
    }

    private var byProject: [(name: String, items: [Entry])] {
        Dictionary(grouping: work) { $0.context.components(separatedBy: " · ")[0] }
            .map { ($0.key, $0.value.sorted { $0.date < $1.date }) }.sorted { $0.items.count > $1.items.count }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
