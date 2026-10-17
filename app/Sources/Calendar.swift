import AppKit
import EventKit
import SwiftUI

// Calendar: read live from macOS's own calendar store (nothing copied), only after you choose to connect it.
// Meetings join the journal, people pages, answers and "around this time".

@MainActor final class CalendarSource {
    static let shared = CalendarSource()
    private let store = EKEventStore()

    var connected: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var undecided: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    /// Shows macOS's own Allow prompt (only ever from the Connect button).
    func connect() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }

    /// Meetings, not wallpaper: timed events, plus all-day ones only if they have people. No birthdays or holidays.
    func events(from: Date, to: Date) -> [EKEvent] {
        guard connected else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).filter { e in
            e.calendar.type != .birthday && !(e.calendar.type == .subscription && e.isAllDay) && (!e.isAllDay || e.hasAttendees)
        }
    }

    func event(_ id: String) -> EKEvent? { connected ? store.event(withIdentifier: id) : nil }

    var remindersConnected: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    func connectReminders() async -> Bool { (try? await store.requestFullAccessToReminders()) ?? false }

    /// What's still to do, soonest due first.
    func openReminders() async -> [String] {
        guard remindersConnected else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { found in
                let sorted = (found ?? []).sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                done.resume(returning: sorted.compactMap(\.title))
            }
        }
    }
}

/// The people in a meeting other than you: their names, or the address when there's no name.
func attendees(_ e: EKEvent) -> [(name: String, email: String?)] {
    (e.attendees ?? []).filter { !$0.isCurrentUser }.map { p in
        let email = p.url.absoluteString.hasPrefix("mailto:") ? String(p.url.absoluteString.dropFirst(7)) : nil
        return (p.name ?? email?.components(separatedBy: "@").first ?? "Someone", email)
    }
}

extension Entry {
    init(event e: EKEvent) {
        let people = attendees(e).map(\.name)
        let length = e.isAllDay ? "all day" : Duration.seconds(e.endDate.timeIntervalSince(e.startDate))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let with = people.isEmpty ? nil : "with " + people.prefix(3).joined(separator: ", ") + (people.count > 3 ? " +\(people.count - 3)" : "")
        self.init(id: "cal:\(e.eventIdentifier ?? ""):\(Int(e.startDate.timeIntervalSince1970))", source: "calendar", kind: "meeting",
                  date: e.startDate, title: e.title ?? "Untitled event",
                  context: [with, e.location?.isEmpty == false ? e.location : nil, length].compactMap { $0 }.joined(separator: " · "),
                  url: e.url?.absoluteString)
    }

    var eventID: String? {
        guard source == "calendar" else { return nil }
        return id.dropFirst(4).split(separator: ":").dropLast().joined(separator: ":")
    }
}

extension AppModel {
    /// Meetings in a window, as passages for answers and day notes.
    func meetings(since: Date, until: Date, matching words: [String] = []) -> [(entry: Entry, text: String)] {
        CalendarSource.shared.events(from: since, to: until).filter { e in
            words.isEmpty || words.contains { w in (e.title ?? "").localizedCaseInsensitiveContains(w) || (e.notes ?? "").localizedCaseInsensitiveContains(w) }
        }.map { e in
            let who = attendees(e).map(\.name)
            let entry = Entry(event: e)
            return (entry, "Meeting, \(e.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())): \(entry.title)"
                    + (who.isEmpty ? "" : " with \(who.joined(separator: ", "))") + (e.notes.map { " — " + $0.prefix(160) } ?? ""))
        }
    }

    /// People you've met with lately, as people signals.
    func meetingPeople(since: Date) -> [Person] {
        CalendarSource.shared.events(from: since, to: .now).flatMap { e in
            attendees(e).map { a in
                Person(name: a.name, names: Set([a.name] + [a.email, a.email?.components(separatedBy: "@").first].compactMap { $0 }),
                       meetings: 1, meetingTitles: [e.title ?? ""], last: e.startDate)
            }
        }
    }
}

/// A meeting: who, when, where, and the way back into it.
struct EventDetail: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    @State private var around: [Entry] = []

    var body: some View {
        let event = entry.eventID.flatMap(CalendarSource.shared.event)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Tile(entry: entry, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.title3.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                        Text(entry.date.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                    }
                }
                ActionRow(actions: actions(event))
                if let event {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        let people = attendees(event)
                        if !people.isEmpty { GridRow { Text("With").foregroundStyle(.secondary); Text(people.map(\.name).joined(separator: ", ")) } }
                        if let place = event.location, !place.isEmpty { GridRow { Text("Where").foregroundStyle(.secondary); Text(place) } }
                        GridRow { Text("Calendar").foregroundStyle(.secondary); Text(event.calendar.title) }
                    }
                    if let notes = event.notes, !notes.isEmpty {
                        Text(notes.prefix(4000)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if around.count > 1 {
                    Block(title: "Around this time", symbol: "clock") {
                        ForEach(around) { RelatedRow(entry: $0, current: $0.id == entry.id) }
                    }
                }
            }
            .padding(20)
        }
        .task { around = await model.around(entry, at: entry.date) }
    }

    private func actions(_ event: EKEvent?) -> [AppModel.Action] {
        var out: [AppModel.Action] = []
        if let link = entry.url.flatMap(URL.init(string:)) {
            out.append(AppModel.Action(title: "Join", symbol: "video") { NSWorkspace.shared.open(link) })
        }
        if let id = event?.calendarItemIdentifier, let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") {
            out.append(AppModel.Action(title: "Open in Calendar", symbol: "calendar") { NSWorkspace.shared.open(url) })
        }
        return out
    }
}
