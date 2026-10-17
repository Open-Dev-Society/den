import AppKit
import SQLite3

// MARK: - Entry

/// One row anywhere in the app: a file, or an activity item from the optional brain database.
struct Entry: Identifiable, Hashable {
    let id: String
    let source: String // "file", or an activity source: claude-code, browser, git, zsh
    var kind: String
    var date: Date
    var title: String
    var context: String = ""
    var url: String? = nil
    var dbID: Int64? = nil
    var path: String? = nil
    var isFolder = false

    var host: String? {
        guard let url, url.hasPrefix("http"), let h = URL(string: url)?.host() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    /// Repeat visits to one page share a key: same title on the same host.
    var pageKey: String? { source == "browser" ? "\(host ?? "") \(title)" : nil }

    static func file(_ path: String, date: Date, kind: String, isFolder: Bool = false) -> Entry {
        Entry(id: "file:" + path, source: "file", kind: kind, date: date, title: (path as NSString).lastPathComponent,
              context: tilde((path as NSString).deletingLastPathComponent), path: path, isFolder: isFolder)
    }
}

extension Entry {
    init(row r: [String: Any]) {
        let id = r["id"] as? Int64 ?? 0, source = r["source"] as? String ?? "", kind = r["kind"] as? String ?? ""
        var title = r["title"] as? String ?? "", project: String?
        if title.hasPrefix("["), let end = title.firstIndex(of: "]") { // "[project] text"
            project = String(title[title.index(after: title.startIndex)..<end])
            title = title[title.index(after: end)...].trimmingCharacters(in: .whitespaces)
        }
        self.init(id: "db:\(id)", source: source, kind: kind,
                  date: isoParser.date(from: r["ts"] as? String ?? "") ?? .distantPast,
                  title: title, url: r["url"] as? String, dbID: id)
        if self.title.isEmpty { self.title = url ?? "Untitled" }
        let who = kind == "prompt" ? "You" : kind == "reply" ? "Claude" : nil
        context = [project ?? host ?? Sources.label(source), who].compactMap { $0 }.joined(separator: " · ")
        if let subject = gmailSubject(title: self.title, url: url) { // an opened Gmail thread: the tab title is its subject
            self.kind = "email"
            self.title = subject
            context = "Email · Gmail"
        }
    }
}

/// "Helping with Onto - me@x.com - Gmail" on a thread URL → "Helping with Onto". Inbox and other list pages → nil.
func gmailSubject(title: String, url: String?) -> String? {
    guard let url, url.contains("mail.google.com"), let hash = url.split(separator: "#").last, hash.contains("/"),
          let m = title.firstMatch(of: #/^(.+?) - [^\s]+@[^\s]+ - Gmail$/#) else { return nil }
    return String(m.1)
}

/// Gmail's inbox, spam and label lists: where you went, not what you read.
func isMailListPage(_ e: Entry) -> Bool { e.kind != "email" && (e.url ?? "").contains("mail.google.com") }

func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

enum Sources {
    static let order = ["claude-code", "browser", "git", "zsh"]
    static func label(_ s: String) -> String {
        ["claude-code": "Claude", "browser": "Web", "git": "Commits", "zsh": "Terminal", "file": "File", "calendar": "Calendar",
         "app": "App", "calc": "Calculator", "command": "Command", "clipboard": "Clipboard"][s] ?? s
    }
    static func symbol(_ s: String) -> String {
        ["claude-code": "sparkle", "browser": "globe", "git": "arrow.triangle.branch", "zsh": "terminal", "calendar": "calendar",
         "calc": "equal", "command": "command", "clipboard": "doc.on.clipboard"][s] ?? "doc"
    }
}

enum Span: String, CaseIterable, Identifiable {
    case all = "Any time", today = "Today", yesterday = "Yesterday", week = "7 days", month = "30 days"
    var id: Self { self }
    var bounds: (since: Date?, until: Date?) {
        let cal = Calendar.current, start = cal.startOfDay(for: .now)
        let ago = { (n: Int) in cal.date(byAdding: .day, value: -n, to: start)! }
        switch self {
        case .all: return (nil, nil)
        case .today: return (start, nil)
        case .yesterday: return (ago(1), start)
        case .week: return (ago(6), nil)
        case .month: return (ago(29), nil)
        }
    }
}

private let isoParser = ISO8601DateFormatter()
private let utc: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f
}()
/// Stored ts is UTC ISO 8601, so this prefix compares correctly as a string.
func sqlTime(_ d: Date) -> String { utc.string(from: d) }

/// Any of the words, best matches first: for questions, where recall matters more than precision.
func ftsAny(_ words: [String]) -> String {
    words.filter { $0.contains { $0.isLetter || $0.isNumber } }
        .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " OR ")
}

/// Each word quoted (so FTS syntax can't error), the last a prefix (so search-as-you-type works). Mirrors brain.py.
func ftsQuery(_ q: String) -> String {
    let words = q.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }
    guard !words.isEmpty else { return "" }
    return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " ") + "*"
}

// MARK: - Activity (optional: ~/.brain/brain.db from brain.py; read-only)

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Gives freed heap pages back to macOS. Background jobs churn through a lot of short-lived data, and the allocator
/// otherwise keeps those pages, which counts against the app's memory.
func returnFreedMemory() { DispatchQueue.global(qos: .utility).async { malloc_zone_pressure_relief(nil, 0) } } // never on the main thread

/// Runs one statement with bound arguments and returns its rows (none for writes).
func query(_ handle: OpaquePointer?, _ sql: String, _ args: [Any?] = []) -> [[String: Any]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
        print("sql:", String(cString: sqlite3_errmsg(handle)))
        return []
    }
    defer { sqlite3_finalize(stmt) }
    for (i, arg) in args.enumerated() {
        let n = Int32(i + 1)
        switch arg {
        case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
        case let v as Int64: sqlite3_bind_int64(stmt, n, v)
        case let v as Double: sqlite3_bind_double(stmt, n, v)
        case let v as String: sqlite3_bind_text(stmt, n, v, -1, SQLITE_TRANSIENT)
        default: sqlite3_bind_null(stmt, n)
        }
    }
    var out: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: Any] = [:]
        for c in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, c))
            switch sqlite3_column_type(stmt, c) {
            case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
            case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
            case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
            default: break
            }
        }
        out.append(row)
    }
    return out
}

final class BrainDB {
    static let path = ProcessInfo.processInfo.environment["BRAIN_DB"] ?? NSHomeDirectory() + "/.brain/brain.db"
    private var handle: OpaquePointer?
    private static let cols = "i.id, i.source, i.kind, i.ts, i.title, i.url"

    init?() {
        guard FileManager.default.fileExists(atPath: Self.path),
              sqlite3_open_v2(Self.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return nil } // usable off the main thread
        sqlite3_busy_timeout(handle, 2000) // the 15-minute sync may be mid-write
        _ = query(handle, "pragma cache_size = -512") // 512 KB of pages, not the default 2 MB
    }

    func rows(_ sql: String, _ args: [Any?] = []) -> [[String: Any]] { query(handle, sql, args) }

    /// Newest first when browsing, best match first when searching.
    func page(query: String, source: String?, since: Date?, until: Date?, offset: Int, limit: Int, any: Bool = false) -> [Entry] {
        var clauses: [String] = [], args: [Any?] = []
        if let source { clauses.append("i.source = ?"); args.append(source) }
        if let since { clauses.append("i.ts >= ?"); args.append(sqlTime(since)) }
        if let until { clauses.append("i.ts < ?"); args.append(sqlTime(until)) }
        let fts = any ? ftsAny(query.split(separator: " ").map(String.init)) : ftsQuery(query), sql: String
        if fts.isEmpty {
            sql = "select \(Self.cols) from items i" + (clauses.isEmpty ? "" : " where " + clauses.joined(separator: " and "))
                + " order by i.ts desc limit ? offset ?"
        } else {
            sql = "select \(Self.cols) from items_fts join items i on i.id = items_fts.rowid where items_fts match ?"
                + clauses.map { " and " + $0 }.joined() + " order by items_fts.rank limit ? offset ?"
            args.insert(fts, at: 0)
        }
        args.append(limit)
        args.append(offset)
        return rows(sql, args).map(Entry.init(row:))
    }

    func counts() -> [String: Int] {
        var out: [String: Int] = [:]
        for r in rows("select source, count(*) n from items group by source") {
            if let s = r["source"] as? String { out[s] = Int(r["n"] as? Int64 ?? 0) }
        }
        return out
    }

    func item(_ id: Int64) -> [String: Any]? { rows("select * from items where id = ?", [id]).first }

    /// Your work in a window, oldest first: commits and the prompts you gave Claude (for the calendar's heat and lanes).
    func work(since: Date, until: Date) -> [Entry] {
        rows("""
            select \(Self.cols) from items i where i.ts >= ? and i.ts < ? and +i.source in ('git', 'claude-code')
            and i.kind in ('commit', 'prompt') order by i.ts limit 6000
            """, [sqlTime(since), sqlTime(until)]).map(Entry.init(row:))
    }

    /// Who committed in your repos lately, how much, where.
    func gitAuthors(since: Date) -> [(author: String, commits: Int, repos: [String], last: Date)] {
        rows("""
            select json_extract(raw, '$.author') a, count(*) n, group_concat(distinct dir) repos, max(ts) t from items
            where +source = 'git' and ts >= ? group by a order by n desc limit 40
            """, [sqlTime(since)]).compactMap { r in
            guard let a = r["a"] as? String else { return nil }
            return (a, Int(r["n"] as? Int64 ?? 0), (r["repos"] as? String ?? "").split(separator: ",").map(String.init),
                    isoParser.date(from: r["t"] as? String ?? "") ?? .distantPast)
        }
    }

    /// Profile pages you visited (X, LinkedIn, GitHub), one row per page title.
    func profileVisits(since: Date) -> [(title: String, url: String, visits: Int, last: Date)] {
        rows("""
            select title, min(url) url, count(*) n, max(ts) t from items where +source = 'browser' and ts >= ?
            and (url like 'https://x.com/%' or url like 'https://twitter.com/%' or url like '%linkedin.com/in/%' or url like 'https://github.com/%')
            and url not like '%/status/%' group by title order by n desc limit 300
            """, [sqlTime(since)]).compactMap { r in
            guard let t = r["title"] as? String, let u = r["url"] as? String else { return nil }
            return (t, u, Int(r["n"] as? Int64 ?? 0), isoParser.date(from: r["t"] as? String ?? "") ?? .distantPast)
        }
    }

    /// Commits by any of these author names, newest first.
    func commits(by authors: [String], since: Date?, until: Date?, limit: Int) -> [Entry] {
        guard !authors.isEmpty else { return [] }
        let marks = authors.map { _ in "?" }.joined(separator: ", ")
        return rows("""
            select \(Self.cols) from items i where +i.source = 'git' and json_extract(i.raw, '$.author') in (\(marks))
            and i.ts >= ? and i.ts < ? order by i.ts desc limit ?
            """, authors.map { $0 as Any? } + [sqlTime(since ?? .distantPast), sqlTime(until ?? .distantFuture), limit]).map(Entry.init(row:))
    }

    /// Folders you've worked in lately: where Claude Code sessions ran and which repos got commits.
    /// (`dir` is a column brain.py writes at ingest, so nothing here parses JSON.)
    func workDirs(since: Date, until: Date = .distantFuture) -> [String] {
        rows("""
            select dir, max(ts) t from items where dir is not null and ts >= ? and ts < ? group by dir order by t desc limit 60
            """, [sqlTime(since), sqlTime(until)]).compactMap { $0["dir"] as? String }
    }

    /// Claude prompts or commits made in a folder or anywhere below it, newest first, optionally within a time window.
    func items(under dir: String, source: String, since: Date? = nil, until: Date? = nil, limit: Int) -> [Entry] {
        rows("""
            select \(Self.cols) from items i where +i.source = ? and i.kind != 'reply' and (i.dir = ? or i.dir like ?)
            and i.ts >= ? and i.ts < ? order by i.ts desc limit ?
            """, [source, dir, dir + "/%", sqlTime(since ?? .distantPast), sqlTime(until ?? .distantFuture), limit]).map(Entry.init(row:))
    }

    /// The nearest items from one source within half an hour either side of `date`.
    func near(_ date: Date, source: String, limit: Int = 3) -> [Entry] {
        rows("select \(Self.cols) from items i where +i.source = ? and i.ts >= ? and i.ts < ? "
             + "order by abs(julianday(i.ts) - julianday(?)) limit ?",
             [source, sqlTime(date - 1800), sqlTime(date + 1800), sqlTime(date), limit]).map(Entry.init(row:))
    }

    // ponytail: no index on url, so this scans browser rows (tens of ms at 100k); add one if it shows up
    func visit(url: String) -> Entry? {
        rows("select \(Self.cols) from items i where i.source = 'browser' and i.url = ? order by i.ts desc limit 1", [url])
            .first.map(Entry.init(row:))
    }
}
