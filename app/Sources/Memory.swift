import FoundationModels
import SQLite3
import SwiftUI

// Memory: pages that write themselves (your days, your projects), your notes and Claude's, each one linked to
// the evidence it came from. Ask answers questions only from what's here, with numbered sources.
// Everything is written on this Mac by the on-device model, a little at a time.

struct Note: Identifiable, Hashable {
    let id: Int64
    let kind: String // day, project, note (yours), claude (Claude Code's memory files)
    let key: String
    let title: String
    let body: String
    let evidence: [String] // entry ids: "db:12" (activity), "file:/path"
    let date: Date // what it's about: the day, or a project's last activity
    let made: Date // when it was written
    let source: String // auto, you, claude
}

extension Entry {
    init(note n: Note) {
        self.init(id: "mem:\(n.id)", source: "memory", kind: n.kind, date: n.date, title: n.title,
                  context: String((n.body.split(separator: "\n").first ?? "").prefix(160)), dbID: n.id)
    }
}

enum MemoryKind {
    static func symbol(_ kind: String) -> String {
        ["day": "book.closed", "project": "shippingbox", "person": "person.crop.circle", "note": "note.text", "claude": "sparkle"][kind] ?? "brain"
    }
    static func label(_ kind: String) -> String {
        ["day": "Journal", "project": "Project", "person": "Person", "note": "Your note", "claude": "Claude's note"][kind] ?? "Memory"
    }
}

// MARK: - Store (text only, in Application Support)

actor MemoryStore {
    static let shared = MemoryStore(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Den/memory.db"))
    private var db: OpaquePointer?

    init(at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        sqlite3_open(url.path, &db)
        for statement in ["pragma journal_mode = wal", "pragma cache_size = -512",
                          """
                          create table if not exists notes (id integer primary key, kind text, key text unique, title text,
                          body text, evidence text, date real, made real, source text)
                          """,
                          "create virtual table if not exists notes_fts using fts5 (title, body, tokenize = 'porter')",
                          "create table if not exists people (key text primary key, names text)",
                          "create table if not exists hidden_people (key text primary key)"] {
            _ = query(db, statement)
        }
    }

    /// Writes or rewrites the note with this key, keeping its id.
    @discardableResult
    func save(kind: String, key: String, title: String, body: String, evidence: [String], date: Date, source: String) -> Int64 {
        let ev = String(decoding: (try? JSONSerialization.data(withJSONObject: evidence)) ?? Data("[]".utf8), as: UTF8.self)
        _ = query(db, """
            insert into notes (kind, key, title, body, evidence, date, made, source) values (?, ?, ?, ?, ?, ?, ?, ?)
            on conflict(key) do update set title = excluded.title, body = excluded.body, evidence = excluded.evidence,
            date = excluded.date, made = excluded.made
            """, [kind, key, title, body, ev, date.timeIntervalSince1970, Date.now.timeIntervalSince1970, source])
        guard let id = query(db, "select id from notes where key = ?", [key]).first?["id"] as? Int64 else { return 0 }
        _ = query(db, "delete from notes_fts where rowid = ?", [id])
        _ = query(db, "insert into notes_fts (rowid, title, body) values (?, ?, ?)", [id, title, body])
        return id
    }

    private func decode(_ r: [String: Any]) -> Note? {
        guard let id = r["id"] as? Int64 else { return nil }
        let ev = (r["evidence"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
        return Note(id: id, kind: r["kind"] as? String ?? "", key: r["key"] as? String ?? "", title: r["title"] as? String ?? "",
                    body: r["body"] as? String ?? "", evidence: ev,
                    date: Date(timeIntervalSince1970: r["date"] as? Double ?? 0), made: Date(timeIntervalSince1970: r["made"] as? Double ?? 0),
                    source: r["source"] as? String ?? "")
    }

    func notes(_ kinds: [String]) -> [Note] {
        let marks = kinds.map { _ in "?" }.joined(separator: ", ")
        return query(db, "select * from notes where kind in (\(marks)) order by date desc", kinds).compactMap(decode)
    }

    func note(id: Int64) -> Note? { query(db, "select * from notes where id = ?", [id]).first.flatMap(decode) }
    func note(key: String) -> Note? { query(db, "select * from notes where key = ?", [key]).first.flatMap(decode) }

    func search(_ fts: String, limit: Int = 6) -> [Note] {
        query(db, "select n.* from notes_fts join notes n on n.id = notes_fts.rowid where notes_fts match ? order by notes_fts.rank limit ?",
              [fts, limit]).compactMap(decode)
    }

    func days(from: Date, to: Date) -> [Note] {
        query(db, "select * from notes where kind = 'day' and date >= ? and date < ? order by date desc",
              [from.timeIntervalSince1970, to.timeIntervalSince1970]).compactMap(decode)
    }

    func delete(_ id: Int64) {
        _ = query(db, "delete from notes where id = ?", [id])
        _ = query(db, "delete from notes_fts where rowid = ?", [id])
    }

    /// Who has a page, and every name they go by (so Ask can recognise them).
    func setPeople(_ people: [(key: String, names: [String])]) {
        _ = query(db, "delete from people")
        for p in people {
            let names = String(decoding: (try? JSONSerialization.data(withJSONObject: p.names)) ?? Data("[]".utf8), as: UTF8.self)
            _ = query(db, "insert or replace into people values (?, ?)", [p.key, names])
        }
    }

    func people() -> [(key: String, names: [String])] {
        query(db, "select key, names from people").compactMap { r in
            guard let k = r["key"] as? String else { return nil }
            return (k, (r["names"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? [])
        }
    }

    func hiddenPeople() -> Set<String> { Set(query(db, "select key from hidden_people").compactMap { $0["key"] as? String }) }

    /// "Not someone I know" or "this is me": the page goes and isn't written again.
    func hidePerson(_ key: String) {
        _ = query(db, "insert or replace into hidden_people values (?)", [key])
        _ = query(db, "delete from people where key = ?", [key])
        if let id = query(db, "select id from notes where key = ?", [key]).first?["id"] as? Int64 { delete(id) }
    }

    /// A new source joined (Calendar): the journal and each day's "everything else" notes are written again with it.
    func forgetDays() {
        _ = query(db, "delete from notes where (kind = 'day' and source = 'auto') or (kind = 'digest' and key like 'digest:elsewhere:%')")
        _ = query(db, "delete from notes_fts where rowid not in (select id from notes)")
    }

    func counts() -> [String: Int] {
        var out: [String: Int] = [:]
        for r in query(db, "select kind, count(*) n from notes group by kind") {
            if let k = r["kind"] as? String { out[k] = Int(r["n"] as? Int64 ?? 0) }
        }
        return out
    }
}

/// Claude Code memory files: optional front matter (name, description), then the note.
func parseMemoryFile(_ text: String) -> (title: String?, body: String) {
    guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
        return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var fields: [String: String] = [:]
    for line in text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound].split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 { fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
    }
    return (fields["description"] ?? fields["name"], String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Same text, same key, across launches (Swift's hashValue changes every run).
func stableHash(_ s: String) -> String {
    String(s.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 36)
}

struct Answer: Identifiable {
    let id = UUID()
    let question: String
    var text: String?
    var status: String? // what it's doing while the answer is being written
    var took: Duration? // shown under the answer: detail over speed, but visible
    var prepared = false // answered from notes read ahead of time
    var firstWords: Duration? // when the streamed answer started showing
    var sources: [Entry] = []

    /// The sources the answer actually cites ("[2]"), in order; the rest were only looked at.
    var cited: [Int] {
        guard let text else { return [] }
        var seen = Set<Int>()
        return text.matches(of: #/\[(\d+)\]/#).compactMap { Int($0.1) }.filter { (1...sources.count).contains($0) && seen.insert($0).inserted }
    }
}

// MARK: - Growing

extension AppModel {
    func refreshMemory() async { memoryCounts = await MemoryStore.shared.counts() }

    /// Growth shows as it happens: counts update and an open Memory view picks up the new page.
    private func wrote() async {
        await refreshMemory()
        if remembering { reloadList() }
    }

    /// A little at a time: Claude's notes, then missing journal days, then project pages with something new.
    func growMemory() async {
        guard !growing else { return }
        growing = true
        defer { growing = false; memoryStatus = nil; returnFreedMemory() }
        await importClaudeNotes()
        await wrote()
        if AI.available {
            await writeJournal()
            await describeProjects()
            await describePeople()
            await prepare() // the slow part, last: so Ask can answer from it in one step
        }
        await wrote()
    }

    func importClaudeNotes() async {
        let fm = FileManager.default, base = fm.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        for project in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: project.appending(path: "memory"), includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "md" && file.lastPathComponent != "MEMORY.md" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let parsed = parseMemoryFile(text)
                guard !parsed.body.isEmpty else { continue }
                let key = "claude:" + stableHash(parsed.body) // the same note saved by several sessions is one note
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
                if let old = await MemoryStore.shared.note(key: key), old.date >= mtime { continue }
                await MemoryStore.shared.save(kind: "claude", key: key, title: parsed.title ?? file.deletingPathExtension().lastPathComponent,
                                              body: parsed.body, evidence: ["file:" + file.path], date: mtime, source: "claude")
            }
        }
    }

    // MARK: journal

    func writeJournal() async {
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        var written = 0
        for n in 0..<30 where written < 30 { // a month at most per pass, a few seconds a day, in the background
            let day = cal.date(byAdding: .day, value: -n, to: today)!, next = cal.date(byAdding: .day, value: 1, to: day)!
            let key = "day:" + dayKey(day)
            if let old = await MemoryStore.shared.note(key: key),
               old.made >= next || (n == 0 && Date.now.timeIntervalSince(old.made) < 3 * 3600) { continue } // done, or today's is fresh
            let (material, evidence) = await dayMaterial(day, next)
            guard evidence.count >= 3 else { continue }
            memoryStatus = "Writing your journal · \(day.formatted(.dateTime.month(.abbreviated).day()))"
            guard let body = await AI.summary(of: material, .day) else { continue }
            await MemoryStore.shared.save(kind: "day", key: key, title: day.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                                          body: body, evidence: evidence, date: day, source: "auto")
            written += 1
            await wrote()
        }
    }

    func dayMaterial(_ start: Date, _ end: Date) async -> (String, [String]) {
        let activity = brain?.page(query: "", source: nil, since: start, until: end, offset: 0, limit: 500) ?? []
        let span = { (attr: String) in "(\(attr) >= \(Query.time(start)) && \(attr) < \(Query.time(end)))" }
        let files = await Spotlight.find(span("kMDItemLastUsedDate") + " || " + span("kMDItemDateAdded"), sort: [], limit: 40).filter { !$0.isFolder }
        let prompts = activity.filter { $0.kind == "prompt" }, commits = activity.filter { $0.source == "git" }
        let met = meetings(since: start, until: end)
        var seen = Set<String>()
        let pages = activity.filter { $0.source == "browser" && !isMailListPage($0) && seen.insert($0.pageKey ?? $0.id).inserted }
        var lines = ["Day: " + start.formatted(date: .complete, time: .omitted)]
        lines += met.prefix(10).map { "- " + $0.text }
        lines += prompts.prefix(15).map { "- Asked Claude in \($0.context.components(separatedBy: " · ")[0]): \($0.title.prefix(140))" }
        lines += commits.prefix(12).map { "- Committed to \($0.context): \($0.title)" }
        lines += files.prefix(12).map { "- Opened or saved \($0.title) in \($0.context)" }
        lines += pages.prefix(15).map { $0.kind == "email" ? "- Read the email \"\($0.title.prefix(90))\"" : "- Read \"\($0.title.prefix(90))\" on \($0.host ?? "the web")" }
        let evidence = met.prefix(3).map(\.entry) + Array(prompts.prefix(4)) + Array(commits.prefix(3)) + Array(files.prefix(3)) + Array(pages.prefix(3))
        return (lines.joined(separator: "\n"), evidence.map(\.id))
    }

    // MARK: projects

    /// Where you've been working: folders of Claude sessions and commits, and repos of files you opened. Merged up
    /// to the repo root; a top-level folder that only holds projects (~/personal) isn't one; subfolders join their project.
    func projectDirs() -> [String] {
        projectRoots((brain?.workDirs(since: .now - 30 * 86400) ?? []) + recents.files.compactMap { $0.path.flatMap { repoRoot(URL(fileURLWithPath: $0))?.path } })
    }

    func projectRoots(_ raw: [String]) -> [String] {
        let fm = FileManager.default, home = NSHomeDirectory()
        var dirs: [String] = []
        for d in raw where d != home && d.hasPrefix(home + "/") && !isNoise(d + "/") && fm.fileExists(atPath: d) {
            let root = repoRoot(URL(fileURLWithPath: d))?.path ?? d
            let topLevel = !root.dropFirst(home.count + 1).contains("/")
            if topLevel, repoRoot(URL(fileURLWithPath: root)) == nil { continue } // ~/personal, ~/work…
            if !dirs.contains(root) { dirs.append(root) }
        }
        return dirs.filter { d in !dirs.contains { d.hasPrefix($0 + "/") } }
    }

    func projectMaterial(_ dir: String) async -> (String, [String], Date) {
        let url = URL(fileURLWithPath: dir)
        // the database, the README and git, all read off the main thread
        let brain = brain
        let (prompts, commits) = await Task.detached {
            (brain?.items(under: dir, source: "claude-code", limit: 10) ?? [], brain?.items(under: dir, source: "git", limit: 8) ?? [])
        }.value
        var lines = await Task.detached { [commits] in
            var lines = ["Project folder: \(url.lastPathComponent) (\(tilde(dir)))"]
            for name in ["README.md", "readme.md", "README", "README.txt"] {
                if let text = try? String(contentsOf: url.appending(path: name), encoding: .utf8) { lines.append("README:\n" + text.prefix(1500)); break }
            }
            if commits.isEmpty, hasGit, repoRoot(url) != nil {
                lines.append("Recent commits:\n" + runTool("/usr/bin/git", ["-C", dir, "log", "-n", "8", "--format=- %s (%ar)"]))
            }
            return lines
        }.value
        if !commits.isEmpty {
            lines.append("Recent commits:\n" + commits.map { "- \($0.title) (\(dayLabel($0.date)))" }.joined(separator: "\n"))
        }
        if !prompts.isEmpty { lines.append("Recently asked Claude:\n" + prompts.map { "- \($0.title.prefix(140))" }.joined(separator: "\n")) }
        let files = Array(recents.files.filter { $0.path?.hasPrefix(dir + "/") == true }.prefix(8))
        if !files.isEmpty { lines.append("Recently opened files:\n" + files.map { "- \($0.title)" }.joined(separator: "\n")) }
        let evidence = Array(prompts.prefix(4)) + Array(commits.prefix(4)) + Array(files.prefix(4))
        let last = evidence.map(\.date).max() ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return (lines.joined(separator: "\n\n"), evidence.map(\.id), last)
    }

    func describeProjects() async {
        for dir in projectDirs().prefix(12) {
            let key = "project:" + dir, name = URL(fileURLWithPath: dir).lastPathComponent
            let (material, evidence, last) = await projectMaterial(dir)
            if let old = await MemoryStore.shared.note(key: key),
               old.made > last || Date.now.timeIntervalSince(old.made) < 6 * 3600 { continue } // nothing new, or written lately
            memoryStatus = "Learning about \(name)"
            guard let body = await AI.summary(of: material, .project) else { continue }
            await MemoryStore.shared.save(kind: "project", key: key, title: name, body: body, evidence: evidence, date: last, source: "auto")
            await wrote()
        }
    }

    // MARK: asking

    /// A question, understood: what to look for, when, in which project, and in words for the answer.
    struct Question {
        var text: String
        var plan: Plan
        var project: (name: String, dir: String)?
        var person: (name: String, key: String, names: [String])?
        var words: [String] // what's left to search for once time, project and filler are taken out
        var about: String // "thrine, on Saturday, 10 October"
    }

    /// Words that say nothing about *what* is being asked.
    private static let filler: Set<String> = ["work", "worked", "working", "works", "did", "do", "done", "doing", "what", "which",
        "when", "where", "who", "how", "my", "me", "i", "day", "days", "today", "yesterday", "week", "month", "thing", "things",
        "stuff", "file", "files", "project", "projects", "were", "was", "is", "are", "on", "in", "at", "that", "the", "a", "about",
        "lately", "recently", "recent", "latest", "last", "been", "has", "have", "had", "up", "to", "with", "for", "of", "and", "or",
        "they", "them", "their", "he", "she", "his", "her", "doing", "going", "much", "any", "some", "all"]

    /// Refers back ("that day", "there", "it", "them") without naming a new person or project of its own.
    func isFollowUp(_ lower: String, _ q: Question) -> Bool {
        guard let prev = lastQuestion else { return false }
        if let person = q.person, person.key != prev.person?.key { return false }
        if let project = q.project, project.dir != prev.project?.dir { return false }
        return lower.contains(#/\b(that day|same day|then|there|it|that|those|them|they|he|she|his|her)\b/#)
    }

    /// Days people name all the time, worked out exactly: "that day" is the earlier question's day, nothing wider.
    func exactDates(_ lower: String) -> (Date, Date)? {
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        let day = { (d: Date) in (d, cal.date(byAdding: .day, value: 1, to: d)!) }
        if ["that day", "same day", "that morning", "that evening", "that night"].contains(where: lower.contains),
           let prev = lastQuestion?.plan, let a = prev.after {
            return (a, prev.before ?? day(a).1)
        }
        if lower.contains("yesterday") { return day(cal.date(byAdding: .day, value: -1, to: today)!) }
        if lower.contains("today") || lower.contains("this morning") { return day(today) }
        let week = cal.dateInterval(of: .weekOfYear, for: .now)!.start
        if lower.contains("last week") { return (cal.date(byAdding: .day, value: -7, to: week)!, week) }
        if lower.contains("this week") { return (week, day(today).1) }
        for (i, name) in cal.weekdaySymbols.enumerated() where lower.contains(name.lowercased()) { // the most recent one
            let back = (cal.component(.weekday, from: today) - (i + 1) + 7) % 7
            return day(cal.date(byAdding: .day, value: -back, to: today)!)
        }
        return nil
    }

    func understand(_ text: String) async -> Question {
        let earlier = lastQuestion.map { "An earlier question, for words like \"that day\" or \"it\": \"\($0.text)\" (about \($0.about))." }
        var plan = await AI.plan(text, earlier: earlier) ?? Plan(keywords: text.split(whereSeparator: \.isWhitespace).map(String.init))
        let lower = text.lowercased()
        if let (a, b) = exactDates(lower) { plan.after = a; plan.before = b } // the model guesses ranges; these are certain
        // A project you've worked on, named in the question (the longest name wins: onto-mcp over onto)
        let projects = await MemoryStore.shared.notes(["project"])
        var project = projects.filter { lower.contains($0.title.lowercased()) }.max { $0.title.count < $1.title.count }
            .map { (name: $0.title, dir: String($0.key.dropFirst("project:".count))) }
        if project == nil, let prev = lastQuestion?.project, ["there", "that project", " it", "same project"].contains(where: lower.contains) {
            project = prev
        }
        let person = await personNamed(in: lower)
        let theirs = Set((person?.names ?? []).flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        let words = plan.keywords.map { $0.lowercased() }
            .filter { !Self.filler.contains($0) && $0 != project?.name.lowercased() && !theirs.contains($0) && $0.count > 1 }
        var about: [String] = []
        if let person { about.append(person.name) }
        if let project { about.append(project.name) }
        if let a = plan.after {
            let one = plan.before.map { $0.timeIntervalSince(a) <= 86400 } ?? false
            about.append(one ? "on " + a.formatted(.dateTime.weekday(.wide).day().month(.wide))
                             : "from " + a.formatted(.dateTime.day().month()) + (plan.before.map { " to " + $0.addingTimeInterval(-1).formatted(.dateTime.day().month()) } ?? " on"))
        }
        return Question(text: text, plan: plan, project: project, person: person, words: words,
                        about: about.isEmpty ? "anything" : about.joined(separator: ", "))
    }

    /// "remember …" saves a note; anything else is answered from memory, activity, files and picture text.
    func ask(_ input: String) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.lowercased().hasPrefix("remember") {
            let body = String(text.dropFirst("remember".count)).trimmingCharacters(in: CharacterSet(charactersIn: " :,-").union(.whitespacesAndNewlines))
            guard !body.isEmpty else { return }
            await MemoryStore.shared.save(kind: "note", key: "you:" + UUID().uuidString, title: String(body.prefix(70)), body: body,
                                          evidence: [], date: .now, source: "you")
            answers.append(Answer(question: text, text: "Saved to your notes."))
            await refreshMemory()
            return
        }
        answers.append(Answer(question: text))
        let i = answers.count - 1
        asking = true
        defer { asking = false; returnFreedMemory() }
        let q = await understand(text)
        let ready = await prepared(q)
        var found = ready ?? []
        if ready == nil { found = await gather(q) }
        answers[i].prepared = ready != nil
        guard !found.isEmpty else {
            answers[i].text = "Nothing in your memory, files or activity matches that yet."
            lastQuestion = q
            return
        }
        // The previous exchange only for a real follow-up: otherwise the model takes it as facts about the new subject
        let earlier = isFollowUp(text.lowercased(), q) ? lastQuestion.flatMap { prev in
            answers.dropLast().last?.text.map { "Earlier, they asked \"\(prev.text)\" and were told: \($0.prefix(600))" }
        } : nil
        let started = ContinuousClock.now
        answers[i].sources = found.map(\.entry)
        let written = await AI.answerInDepth(text, about: q.about, earlier: earlier, passages: found.map(\.text), prepared: ready != nil,
                                             progress: { [weak self] in self?.answers[i].status = $0 },
                                             partial: { [weak self] words in
                                                 guard let self else { return }
                                                 if self.answers[i].firstWords == nil { self.answers[i].firstWords = ContinuousClock.now - started }
                                                 self.answers[i].text = words
                                             })
        answers[i].text = written.map { ground($0, found.map(\.text)) } ?? "I couldn't work that out from what's here."
        answers[i].took = ContinuousClock.now - started
        answers[i].sources = found.map(\.entry)
        lastQuestion = q
    }

    // MARK: activity, as passages (shared by Ask and the prepared notes)

    private static func says(_ e: Entry) -> Bool { // prompts like "next:" or "continue" carry nothing
        e.title.count >= 15 && !e.title.hasPrefix("[Request") && !e.title.hasPrefix("<")
    }
    private static func when(_ e: Entry) -> String { e.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }

    /// Everything done in a project in a window, in time order: every commit, every real prompt.
    func projectActivity(_ name: String, _ dir: String, since: Date?, until: Date?, dated: Bool) -> [(entry: Entry, text: String)] {
        guard let brain else { return [] }
        let commits = brain.items(under: dir, source: "git", since: since, until: until, limit: dated ? 60 : 10)
        let prompts = brain.items(under: dir, source: "claude-code", since: since, until: until, limit: dated ? 120 : 20).filter(Self.says)
        return (commits + Array(prompts.prefix(dated ? 60 : 8))).sorted { $0.date < $1.date }.map { e in
            (e, e.source == "git" ? "Commit to \(name), \(Self.when(e)): \(e.title)" : "You asked Claude in \(name), \(Self.when(e)): \(e.title.prefix(220))")
        }
    }

    /// A day's activity in time order (optionally leaving out some projects): commits, real prompts, pages, files.
    func dayActivity(since: Date, until: Date, outside projects: Set<String> = []) async -> [(entry: Entry, text: String)] {
        let day = brain?.page(query: "", source: nil, since: since, until: until, offset: 0, limit: 400) ?? []
        let project = { (e: Entry) in e.context.components(separatedBy: " · ")[0] }
        var seen = Set<String>()
        let picked = day.filter { $0.source == "git" && !projects.contains($0.context) }.prefix(40)
            + day.filter { $0.kind == "prompt" && Self.says($0) && !projects.contains(project($0)) }.prefix(40)
            + day.filter { $0.source == "browser" && !isMailListPage($0) && seen.insert($0.pageKey ?? $0.id).inserted }.prefix(25)
        let span = { (attr: String) in "(\(attr) >= \(Query.time(since)) && \(attr) < \(Query.time(until)))" }
        let files = await Spotlight.find(span("kMDItemLastUsedDate") + " || " + span("kMDItemDateAdded"), sort: [], limit: 15).filter { !$0.isFolder }
        return ((Array(picked) + files).map { e in
            let what = e.path != nil ? "You opened or saved \(e.title) in \(e.context)" : e.source == "git" ? "Commit to \(e.context)"
                : e.kind == "prompt" ? "You asked Claude in \(project(e))" : e.kind == "email" ? "You read the email" : "You read \(e.host ?? "a page")"
            return (e, e.path != nil ? "\(what), \(Self.when(e))" : "\(what), \(Self.when(e)): \(e.title.prefix(200))")
        } + meetings(since: since, until: until)).sorted { $0.0.date < $1.0.date }
    }

    /// The evidence for an answer, most specific first and complete: for a project on a day, every commit and every
    /// real prompt in time order; for a day, all of its activity; otherwise the best matches for the words.
    func gather(_ q: Question) async -> [(entry: Entry, text: String)] {
        var out: [(entry: Entry, text: String)] = []
        let p = q.plan, dated = p.after != nil || p.before != nil, store = MemoryStore.shared

        if let person = q.person {
            if let page = await store.note(key: person.key) { out.append((Entry(note: page), "Who \(page.title) is: \(page.body)")) }
            out += personActivity(person, since: p.after, until: p.before)
        }
        if let project = q.project {
            if let page = await store.note(key: "project:" + project.dir) {
                out.append((Entry(note: page), "Project page for \(page.title): \(page.body)"))
            }
            out += projectActivity(project.name, project.dir, since: p.after, until: p.before, dated: dated)
        }
        if dated, q.person == nil { // a person's question is about them, not your days
            for n in await store.days(from: p.after ?? .distantPast, to: p.before ?? .distantFuture).prefix(q.project == nil ? 7 : 1) {
                out.append((Entry(note: n), "Journal for \(n.title): \(n.body)"))
            }
        }
        if !q.words.isEmpty, q.person == nil || out.isEmpty { // about a person: their material, not loose matches
            let any = ftsAny(q.words)
            for n in await store.search(any, limit: 5) where n.kind != "digest" && !(dated && n.kind == "claude") { // undated facts don't answer "when"
                out.append((Entry(note: n), "\(MemoryKind.label(n.kind)) \"\(n.title)\": \(n.body.prefix(400))"))
            }
            for e in brain?.page(query: q.words.joined(separator: " "), source: nil, since: p.after, until: p.before, offset: 0, limit: 10, any: true) ?? [] {
                let body = (e.dbID.flatMap { brain?.item($0) }?["body"] as? String).map { " — " + $0.prefix(240) } ?? ""
                out.append((e, "\(Sources.label(e.source)), \(Self.when(e)): \(e.title)\(body)"))
            }
            for hit in await ImageIndex.shared.search(any, limit: 3) {
                if let e = fileEntry(path: hit.path) { out.append((e, "Picture \(e.title) in \(e.context)\(provenance(hit.path)) shows: \(hit.snippet)")) }
            }
            out += meetings(since: p.after ?? .now - 90 * 86400, until: p.before ?? .now + 14 * 86400, matching: q.words).prefix(6)
            var filePlan = p
            filePlan.keywords = q.words
            if let query = Query.build(filePlan, anyWord: true) {
                for e in await Spotlight.find(query, limit: 5) {
                    out.append((e, "File \(e.title) in \(e.context), \(e.kind), last opened \(e.date.formatted(date: .abbreviated, time: .omitted))"
                                   + provenance(e.path ?? "")))
                }
            }
        } else if dated, q.project == nil, q.person == nil, let a = p.after, let b = p.before { // "what did I do yesterday?": the whole day
            out += await dayActivity(since: a, until: b)
        }
        var seen = Set<String>() // one row per page, however often it was visited
        return Array(out.filter { seen.insert($0.entry.pageKey ?? $0.entry.id).inserted }.prefix(120))
    }

    // MARK: prepared notes: each project's day, and the rest of each day, read ahead of time

    func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    /// What gets prepared for a day: one unit per project worked in, and one for everything else.
    func preparedUnits(_ start: Date, _ end: Date) -> [(key: String, name: String, dir: String?)] {
        let day = dayKey(start)
        return projectRoots(brain?.workDirs(since: start, until: end) ?? []).map {
            (key: "digest:\($0):\(day)", name: URL(fileURLWithPath: $0).lastPathComponent, dir: $0)
        } + [(key: "digest:elsewhere:\(day)", name: "everything else", dir: nil)]
    }

    private func isCurrent(_ note: Note?, dayEnd: Date) -> Bool {
        guard let note else { return false }
        return note.made >= dayEnd || (dayEnd > .now && Date.now.timeIntervalSince(note.made) < 2 * 3600) // finished, or today's is fresh
    }

    /// Reads each project's day (and the rest of the day) ahead of time, newest first, into dense lines that each
    /// point at the commit, prompt, page or file they came from. Waits whenever you're asking something.
    func prepare(days: Int = 30, only dir: String? = nil) async {
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        for n in 0..<days {
            let day = cal.date(byAdding: .day, value: -n, to: today)!, next = cal.date(byAdding: .day, value: 1, to: day)!
            let units = preparedUnits(day, next)
            let projects = Set(units.compactMap { $0.dir == nil ? nil : $0.name })
            for unit in units where dir == nil || unit.dir == dir {
                while asking { try? await Task.sleep(for: .seconds(1)) } // Ask gets the model first
                guard await !isCurrent(MemoryStore.shared.note(key: unit.key), dayEnd: next) else { continue }
                let label = "\(unit.name) · \(day.formatted(.dateTime.month(.abbreviated).day()))"
                memoryStatus = "Preparing \(label)"
                let passages = if let d = unit.dir { projectActivity(unit.name, d, since: day, until: next, dated: true) }
                               else { await dayActivity(since: day, until: next, outside: projects) }
                var lines: [(text: String, index: Int?)] = passages.enumerated().map { ($0.element.text, $0.offset) }
                if passages.map(\.text.count).reduce(0, +) > 2500 { // long: keep every concrete thing, drop the chatter
                    let read = await AI.readInPasses(numbered(passages.map(\.text)), focus: "Everything concrete that happened: \(unit.name), \(day.formatted(date: .complete, time: .omitted))") {
                        [weak self] in self?.memoryStatus = "Preparing \(label) · \($0)"
                    }
                    lines = groundLines(read, passages.map(\.text))
                }
                let body = lines.map { "- " + $0.text + ($0.index.map { " ⟦\(passages[$0].entry.id)⟧" } ?? "") }.joined(separator: "\n")
                await MemoryStore.shared.save(kind: "digest", key: unit.key, title: label, body: body,
                                              evidence: lines.compactMap { $0.index.map { passages[$0].entry.id } }, date: day, source: "auto")
                returnFreedMemory() // each unit's scratch goes back right away, so the work never piles up
            }
        }
    }

    /// The prepared lines for a question about a day (or a few days), if every unit it needs is ready; otherwise nil
    /// and Ask reads the raw activity instead, so answers are never worse for it.
    func prepared(_ q: Question) async -> [(entry: Entry, text: String)]? {
        guard let a = q.plan.after, let b = q.plan.before, b.timeIntervalSince(a) <= 7 * 86400 + 3600,
              q.person == nil, q.words.isEmpty || q.project != nil else { return nil } // a person, or extra words: search serves those better
        let cal = Calendar.current, store = MemoryStore.shared
        var out: [(entry: Entry, text: String)] = []
        var day = cal.startOfDay(for: a)
        while day < b {
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            if q.project == nil, let journal = await store.note(key: "day:" + dayKey(day)) {
                out.append((Entry(note: journal), "Journal for \(journal.title): \(journal.body)"))
            }
            for unit in preparedUnits(day, next) where q.project == nil || unit.dir == q.project?.dir {
                let note = await store.note(key: unit.key)
                guard isCurrent(note, dayEnd: next), let note else { return nil }
                for line in note.body.split(separator: "\n") {
                    var text = String(line.dropFirst(2)), entry = Entry(note: note)
                    if let m = text.firstMatch(of: #/ ⟦([^⟧]+)⟧$/#) {
                        if let source = resolve([String(m.1)]).first { entry = source }
                        text = String(text[..<m.range.lowerBound])
                    }
                    out.append((entry, text))
                }
            }
            day = next
        }
        if let project = q.project, let page = await store.note(key: "project:" + project.dir) {
            out.insert((Entry(note: page), "Project page for \(page.title): \(page.body)"), at: 0)
        }
        return out.isEmpty ? nil : out
    }

    /// Where a file came from, in words: the page (titled, from your history), the app that downloaded it, when.
    func provenance(_ path: String) -> String {
        let origins = whereFroms(path)
        var parts: [String] = []
        if let page = origins.compactMap(visit).first { parts.append("came from the page \"\(page.title)\" (\(page.host ?? ""))") }
        else if let host = hostOf(origins) { parts.append("came from \(host)") }
        if let q = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties,
           let agent = q["LSQuarantineAgentName"] as? String {
            let when = (q["LSQuarantineTimeStamp"] as? Date).map { " on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            parts.append("downloaded with \(agent)\(when)")
        }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    func saveAnswer(_ a: Answer) async {
        guard let text = a.text else { return }
        await MemoryStore.shared.save(kind: "note", key: "you:" + UUID().uuidString, title: a.question, body: text,
                                      evidence: a.sources.map(\.id), date: .now, source: "you")
        await refreshMemory()
        show("Saved to your notes")
    }

    /// Evidence ids back to rows you can click.
    func resolve(_ ids: [String]) -> [Entry] {
        ids.compactMap { id in
            if id.hasPrefix("db:"), let n = Int64(id.dropFirst(3)), let row = brain?.item(n) { return Entry(row: row) }
            if id.hasPrefix("file:") { return fileEntry(path: String(id.dropFirst(5))) }
            if id.hasPrefix("cal:"), let e = CalendarSource.shared.event(String(id.dropFirst(4).split(separator: ":").dropLast().joined(separator: ":"))) {
                return Entry(event: e)
            }
            return nil
        }
    }
}

func numbered(_ passages: [String]) -> [String] { passages.enumerated().map { "[\($0.offset + 1)] \($0.element)" } }

extension AI {
    /// The on-device model reads about a page at a time, so long material is read in passes, each writing down every
    /// concrete thing it finds (keeping the note numbers). Returns those lines.
    @MainActor
    static func readInPasses(_ numbered: [String], focus: String, progress: @escaping (String) -> Void) async -> [String] {
        var chunks: [String] = [], current = ""
        for line in numbered {
            if current.count + line.count > 4200, !current.isEmpty { chunks.append(current); current = "" }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        var lines: [String] = []
        for (i, chunk) in chunks.enumerated() {
            progress("pass \(i + 1) of \(chunks.count)")
            let session = LanguageModelSession(instructions: """
                From the numbered notes, write down every concrete thing that matters for the focus: what was done, made, \
                fixed, decided or read, with its names and specifics. One short line each, in time order, each ending with \
                its note number like [12]. Leave out what doesn't relate. No preamble.
                """)
            if let read = try? await session.respond(to: "Focus: \(focus)\n\nNotes:\n\(chunk)").content {
                lines += read.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespaces)) }.filter { !$0.isEmpty }
            }
        }
        return lines
    }

    /// Detail over speed: reads in passes when the evidence is long (prepared notes usually aren't), then writes one
    /// detailed answer from what it found.
    @MainActor
    static func answerInDepth(_ question: String, about: String, earlier: String?, passages: [String], prepared: Bool = false,
                              progress: @escaping (String) -> Void, partial: @escaping (String) -> Void = { _ in }) async -> String? {
        guard available else { return nil }
        let lines = numbered(passages)
        var material = lines.joined(separator: "\n")
        if material.count > (prepared ? 7000 : 4200) {
            material = await readInPasses(lines, focus: "\(question) (about \(about))") { progress("Reading \(lines.count) notes · \($0)…") }
                .joined(separator: "\n")
        }
        progress("Writing the answer…")
        let instructions = """
            Answer a person's question about their own work, files and days, in detail, using only the notes. Start with \
            one sentence that sums it up. Then list the concrete things, one per line starting with "- ", in the order they \
            happened, each naming the specific feature, commit, file or page and ending with its note number like [12]. \
            Keep every distinct thing; only merge lines that repeat the same thing. If the notes don't answer it, say so plainly. \
            Today is \(Date.now.formatted(date: .complete, time: .omitted)).
            """
        let context = (earlier.map { $0 + "\n" } ?? "") + "This question is about: \(about)."
        for budget in [7000, 4500] { // if it doesn't fit the model's window, try again with less
            let session = LanguageModelSession(instructions: instructions)
            var text = ""
            do { // streamed: the answer shows as it's written
                for try await snapshot in session.streamResponse(to: "\(context)\n\nNotes:\n\(material.prefix(budget))\n\nQuestion: \(question)") {
                    text = snapshot.content
                    partial(text)
                }
                return text
            } catch { continue }
        }
        return nil
    }
}

/// The model's note numbers drift over a long answer; each listed line is re-pointed at the note it actually
/// echoes (most shared words), so every citation can be trusted. Lines that echo nothing get none.
func ground(_ answer: String, _ passages: [String]) -> String {
    answer.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard line.hasPrefix("- ") else { return String(line) }
        let (text, index) = groundLines([String(line.dropFirst(2))], passages)[0]
        return "- " + text + (index.map { " [\($0 + 1)]" } ?? "")
    }.joined(separator: "\n")
}

/// Each line, its model-written numbers removed, paired with the passage it shares the most words with (if any).
func groundLines(_ lines: [String], _ passages: [String]) -> [(text: String, index: Int?)] {
    let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }.map(String.init)) }
    let notes = passages.map(words)
    return lines.map { line in
        let text = line.replacing(#/\s*(\[\d+\]\s*)+/#, with: " ").trimmingCharacters(in: .whitespaces)
        let mine = words(text)
        let best = notes.indices.max { mine.intersection(notes[$0]).count < mine.intersection(notes[$1]).count }
        return (text, best.flatMap { mine.intersection(notes[$0]).count >= 2 ? $0 : nil })
    }
}

/// Answers keep their line breaks and **bold**; lists stay lists.
func rich(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

// MARK: - Views

/// Ask: questions and answers, each with the numbered sources it used.
struct AskPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if model.answers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Ask about your work, files and days", systemImage: "sparkle").font(.title3.weight(.semibold))
                        Text("Answers come only from what's on this Mac: your journal, projects, notes, activity, files and the text in your pictures. Nothing leaves it.")
                            .foregroundStyle(.secondary)
                        ForEach(["What did I work on yesterday?", "What did I download this week?", "What was I reading about Claude?"], id: \.self) { q in
                            Button(q) { Task { await model.ask(q) } }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.top, 24)
                }
                ForEach(model.answers) { a in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(a.question).font(.headline)
                        if let text = a.text {
                            Text(rich(text)).textSelection(.enabled).lineSpacing(3)
                            if a.took == nil { ProgressView().controlSize(.mini) } // still writing
                        } else {
                            ProgressView(a.status ?? "Looking through your memory…").controlSize(.small)
                        }
                        if !a.sources.isEmpty {
                            let cited = a.cited, rest = (1...a.sources.count).filter { !cited.contains($0) }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(cited, id: \.self) { source(a, $0) }
                                if !rest.isEmpty {
                                    DisclosureGroup("Also looked at \(rest.count)") { ForEach(rest, id: \.self) { source(a, $0) } }
                                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                                }
                            }
                            HStack {
                                Button("Save to memory", systemImage: "square.and.arrow.down") { Task { await model.saveAnswer(a) } }
                                    .buttonStyle(.borderless).font(.callout)
                                Spacer()
                                if let took = a.took {
                                    Text("\(a.sources.count) notes\(a.prepared ? ", prepared" : "") · \(took.formatted(.units(allowed: [.seconds], width: .abbreviated))) on this Mac")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(.bottom)
    }

    private func source(_ a: Answer, _ n: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
            RelatedRow(entry: a.sources[n - 1], current: false, showDay: true)
        }
    }
}

/// The input under every Memory view: questions go to Ask; "remember …" becomes a note.
struct AskBar: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").foregroundStyle(.tint)
            TextField("Ask your memory, or “remember …”", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
            if model.asking { ProgressView().controlSize(.small) }
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(draft.isEmpty ? Color.secondary : Color.accentColor).disabled(draft.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .padding(12)
        .background(.bar)
    }

    private func send() {
        let text = draft
        draft = ""
        if model.scope != "mem:ask" { model.scope = "mem:ask" }
        Task { await model.ask(text) }
    }
}

/// A memory page: what it says, and everything it was made from.
struct MemoryDetail: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    @State private var note: Note?
    @State private var evidence: [Entry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Tile(entry: entry, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.title3.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Ask about this", systemImage: "sparkle") {
                        let title = entry.title
                        model.scope = "mem:ask"
                        Task { await model.ask("Tell me about \(title)") }
                    }
                    .buttonStyle(.borderedProminent)
                    if note?.kind == "person", let key = note?.key {
                        Button("Hide", systemImage: "eye.slash") {
                            Task {
                                await MemoryStore.shared.hidePerson(key)
                                model.selection = []
                                model.inspected = nil
                                await model.refreshMemory()
                                model.reloadList()
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Not someone you know, or it's you: the page goes and won't be written again")
                    }
                    if note?.source == "you", let id = entry.dbID {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task {
                                await MemoryStore.shared.delete(id)
                                model.selection = []
                                model.inspected = nil
                                await model.refreshMemory()
                                model.reloadList()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .buttonBorderShape(.capsule)
                if let note { Text(note.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if !evidence.isEmpty {
                    Block(title: "Made from", symbol: "link") {
                        ForEach(evidence) { RelatedRow(entry: $0, current: false, showDay: true) }
                    }
                }
            }
            .padding(20)
        }
        .task {
            note = await MemoryStore.shared.note(id: entry.dbID ?? 0)
            evidence = model.resolve(note?.evidence ?? [])
        }
    }

    private var subtitle: String {
        guard let note else { return MemoryKind.label(entry.kind) }
        let made = note.source == "auto" ? " · written \(note.made.formatted(.relative(presentation: .named)))" : ""
        return MemoryKind.label(note.kind) + made
    }
}
