import AppKit
import SwiftUI

// People: who you build with and keep up with, from commits in your repos, profiles you visit, your conversations
// and files. One person across all the places they show up; every page written on this Mac, linked to its evidence.

struct Person {
    var name: String
    var names: Set<String> // every way they appear: git author, @handle, real name
    var commits = 0
    var visits = 0
    var meetings = 0
    var meetingTitles: [String] = []
    var repos: Set<String> = []
    var profiles: [String] = []
    var last = Date.distantPast

    /// Stable across runs: the alphabetically first way they appear.
    var key: String { "person:" + (names.map(personNorm).filter { !$0.isEmpty }.sorted().first ?? personNorm(name)) }
    var score: Double { Double(commits) + Double(min(visits, 30)) / 2 + Double(meetings) * 3 }

    mutating func absorb(_ other: Person) {
        // the name on someone's profile beats a git handle; a full name beats a single word
        if (visits == 0 && other.visits > 0) || (!name.contains(" ") && other.name.contains(" ")) { name = other.name }
        names.formUnion(other.names)
        commits += other.commits
        visits += other.visits
        meetings += other.meetings
        meetingTitles += other.meetingTitles
        repos.formUnion(other.repos)
        profiles += other.profiles
        last = max(last, other.last)
    }
}

/// Accounts that are clearly organizations, not people. ponytail: a word list; Hide covers the rest.
func isOrganization(_ name: String) -> Bool {
    let n = " " + name.lowercased() + " "
    return n.hasPrefix(" the ") || [" studio ", " labs ", " designs ", " inc ", " hq ", " official ", " team ", " app ", " news "].contains { n.contains($0) }
}

/// Words of someone's names that would pick *them* out of text: not ordinary English ("Internet", "Noah"), which
/// would match everything. Uses the Mac's own dictionary.
@MainActor func distinctiveWords(_ names: some Sequence<String>) -> [String] {
    Set(names.flatMap { plainName($0).split(separator: " ").map { String($0).filter(\.isLetter) } })
        .filter { $0.count >= 4 && NSSpellChecker.shared.checkSpelling(of: $0.lowercased(), startingAt: 0).location != NSNotFound }
        .sorted()
}

/// Commit authors that are tools, not people.
func isBot(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.hasSuffix("[bot]") || n.hasSuffix("bot") || ["agent", "github-actions", "dependabot", "renovate", "copilot", "claude", "cursor"]
        .contains { n.contains($0) }
}

/// "𝐍𝐨𝐚𝐡" → "Noah": decorative Unicode letters back to plain ones.
func plainName(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces) }

/// "0xUrvish", "@urvish", "Urvish" → "urvish"
func personNorm(_ s: String) -> String {
    var t = plainName(s).lowercased()
    if t.hasPrefix("@") { t.removeFirst() }
    if t.hasPrefix("0x") { t.removeFirst(2) }
    return t.filter(\.isLetter)
}

/// Same person if the names match, or one contains the other and both are long enough not to collide by chance.
func sameIdentity(_ a: String, _ b: String) -> Bool {
    (a == b && a.count >= 3) || (min(a.count, b.count) >= 5 && (a.contains(b) || b.contains(a)))
}

/// Do these two share a run of at least `k` letters?
func sharesRun(_ a: String, _ b: String, _ k: Int) -> Bool {
    let chars = Array(a)
    guard chars.count >= k else { return false }
    return (0...(chars.count - k)).contains { b.contains(String(chars[$0..<($0 + k)])) }
}

/// A person from a profile page title: X "Name (@handle) / X", LinkedIn "Name | LinkedIn", GitHub "handle (Name) · GitHub".
func parseProfile(title: String, url: String) -> (name: String, handle: String?)? {
    if url.contains("linkedin.com/in/"), let m = title.firstMatch(of: #/^(?:\(\d+\) )?(.+?) \| LinkedIn$/#) {
        let name = String(m.1)
        return name.contains(" ") ? (name, nil) : nil
    }
    if url.contains("x.com/") || url.contains("twitter.com/"),
       let m = title.firstMatch(of: #/^(?:\(\d+\) )?(?:Replies by |Posts by |Media by |Likes by |Highlights by |People following |People followed by )?(.+?) \(@(\w+)\)/#) {
        return (String(m.1), "@" + m.2)
    }
    if url.contains("github.com/"), let m = title.firstMatch(of: #/^(\S+) \((.+)\) · GitHub$/#) {
        return (String(m.2), String(m.1))
    }
    return nil
}

/// Every way *you* appear (Mac account, full name, git name), worked out once: asking git for each person took seconds.
private let myNames: (all: Set<String>, first: String) = {
    var mine = Set([NSUserName(), NSFullUserName()].map(personNorm))
    if hasGit { mine.insert(personNorm(runTool("/usr/bin/git", ["config", "--global", "user.name"]))) }
    return (mine, NSFullUserName().split(separator: " ").first.map { personNorm(String($0)) } ?? "")
}()

/// ponytail: a first-name prefix match also counts as you ("ravixalgorithm"), so someone sharing your first name is
/// hidden too; "Hide" covers the misses the other way.
func isYou(_ p: Person) -> Bool {
    p.names.map(personNorm).contains { n in myNames.all.contains(n) || (myNames.first.count >= 4 && n.hasPrefix(myNames.first)) }
}

/// One person across their names (transitively: one profile can join two git names), you and the hidden left out,
/// most active first. Pure work, off the main thread; each name is normalised once.
func mergePeople(_ found: [Person], hidden: Set<String>) -> [Person] {
    var people: [Person] = [], norms: [[String]] = []
    for var p in found where !isBot(p.name) && !isOrganization(p.name) {
        var mine = p.names.map(personNorm)
        let same = people.indices.filter { i in norms[i].contains { a in mine.contains { sameIdentity(a, $0) } } }
        for i in same.reversed() {
            p.absorb(people.remove(at: i))
            mine += norms.remove(at: i)
        }
        people.append(p)
        norms.append(mine)
    }
    // You under other handles: anyone sharing a 7+ letter run with one of your names ("ravixalgorithm", "Mr. Algorithm")
    let yours = people.indices.filter { isYou(people[$0]) }.flatMap { norms[$0] }
    return people.indices.filter { i in
        !isYou(people[i]) && !norms[i].contains { n in yours.contains { sharesRun(n, $0, 7) } }
            && !hidden.contains(people[i].key) && people[i].score >= 3
    }
    .map { people[$0] }.sorted { $0.score > $1.score }.prefix(20).map { $0 }
}

extension AppModel {

    /// The people worth a page: from the last 90 days, one person across their names, you left out, most active first.
    func discoverPeople() async -> [Person] {
        let since = Date.now - 90 * 86400, brain = brain
        var found = await Task.detached { // commit authors and profile pages, read and parsed off the main thread
            var found: [Person] = (brain?.gitAuthors(since: since) ?? []).map {
                Person(name: $0.author, names: [$0.author], commits: $0.commits, repos: Set($0.repos), last: $0.last)
            }
            for v in brain?.profileVisits(since: since) ?? [] {
                guard let p = parseProfile(title: v.title, url: v.url) else { continue }
                found.append(Person(name: plainName(p.name), names: Set([plainName(p.name)] + [p.handle].compactMap { $0 }), visits: v.visits,
                                    profiles: [plainName(v.title)], last: v.last))
            }
            return found
        }.value
        found += meetingPeople(since: since)
        let hidden = await MemoryStore.shared.hiddenPeople()
        return await Task.detached { [found] in mergePeople(found, hidden: hidden) }.value
    }

    /// The facts are written by plain code, so they can't be wrong; the model adds one "Lately:" line from their
    /// recent commits and mentions, and only when there are some.
    func personPage(_ p: Person) async -> (body: String, evidence: [String], last: Date) {
        let since = Date.now - 90 * 86400
        let commits = brain?.commits(by: Array(p.names), since: since, until: nil, limit: 12) ?? []
        let words = distinctiveWords(p.names)
        let mentions = words.isEmpty ? [] : brain?.page(query: words.joined(separator: " "), source: "claude-code", since: since,
                                                        until: nil, offset: 0, limit: 6, any: true) ?? []
        let day = { (d: Date) in d.formatted(.dateTime.month(.abbreviated).day()) }
        var facts: [String] = []
        if p.commits > 0 {
            let repos = p.repos.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted().joined(separator: ", ")
            facts.append("Works in \(repos) with you: \(p.commits) commits in the last 90 days" + (commits.first.map { ", latest \(day($0.date))" } ?? "") + ".")
        }
        if p.meetings > 0 { facts.append("You've met \(p.meetings) \(p.meetings == 1 ? "time" : "times") in 90 days" + (p.meetingTitles.last.map { ", latest: \($0)" } ?? "") + ".") }
        if p.visits > 0 { facts.append("You've opened their profile \(p.visits) times in 90 days, most recently \(day(p.last)).") }
        if !mentions.isEmpty { facts.append("You've mentioned them to Claude \(mentions.count == 6 ? "6+" : "\(mentions.count)") times, latest \(day(mentions[0].date)).") }
        var body = facts.joined(separator: " ")
        if !commits.isEmpty || !mentions.isEmpty || p.meetings > 0 {
            let material = (commits.map { "- Commit: \($0.title)" } + mentions.map { "- Mentioned to Claude: \($0.title.prefix(160))" }
                            + p.meetingTitles.suffix(6).map { "- Meeting: \($0)" }).joined(separator: "\n")
            if let lately = await AI.summary(of: material, .lately) { body += "\n\n" + lately }
        }
        let others = p.names.filter { $0 != p.name }.sorted()
        if !others.isEmpty { body += "\n\nAlso appears as " + others.joined(separator: ", ") + "." }
        let evidence = Array(commits.prefix(4)) + Array(mentions.prefix(3))
        return (body, evidence.map(\.id), max(p.last, evidence.map(\.date).max() ?? .distantPast))
    }

    func describePeople() async {
        let people = await discoverPeople()
        await MemoryStore.shared.setPeople(people.map { ($0.key, Array($0.names)) })
        for p in people {
            if let old = await MemoryStore.shared.note(key: p.key),
               old.made > p.last || Date.now.timeIntervalSince(old.made) < 24 * 3600 { continue } // nothing new, or written today
            memoryStatus = "Getting to know \(p.name)"
            let page = await personPage(p)
            await MemoryStore.shared.save(kind: "person", key: p.key, title: p.name, body: page.body, evidence: page.evidence,
                                          date: page.last, source: "auto")
            await refreshMemory()
            if remembering { reloadList() }
            returnFreedMemory()
        }
    }

    /// A person named in a question, by any of their names or a first name.
    func personNamed(in lower: String) async -> (name: String, key: String, names: [String])? {
        for (key, names) in await MemoryStore.shared.people() {
            let keys = Set(names + names.flatMap { $0.split(separator: " ").map(String.init) }).filter { $0.count >= 3 }
            let named = keys.contains { n in
                lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: n.lowercased()) + "\\b", options: .regularExpression) != nil
            }
            if named, let page = await MemoryStore.shared.note(key: key) { return (page.title, key, names) }
        }
        return nil
    }

    /// What a person did and where they came up, for an answer about them.
    func personActivity(_ person: (name: String, key: String, names: [String]), since: Date?, until: Date?) -> [(entry: Entry, text: String)] {
        guard let brain else { return meetings(since: since ?? .now - 90 * 86400, until: until ?? .now) }
        let when = { (e: Entry) in e.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }
        let dated = since != nil || until != nil
        let commits = brain.commits(by: person.names, since: since, until: until, limit: dated ? 30 : 12)
        let words = distinctiveWords(person.names)
        let mentions = words.isEmpty ? [] : brain.page(query: words.joined(separator: " "), source: "claude-code", since: since, until: until,
                                                      offset: 0, limit: 8, any: true)
        let met = meetings(since: since ?? .now - 90 * 86400, until: until ?? .now).filter { m in
            person.names.contains { n in n.count >= 3 && m.text.localizedCaseInsensitiveContains(n) }
        }
        return ((commits + mentions).map { e in
            (e, e.source == "git" ? "Commit by \(person.name) to \(e.context), \(when(e)): \(e.title)"
                                  : "You mentioned \(person.name) to Claude, \(when(e)): \(e.title.prefix(200))")
        } + met).sorted { $0.0.date < $1.0.date }
    }
}
