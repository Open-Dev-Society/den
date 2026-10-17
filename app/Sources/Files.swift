import AppKit
import CoreServices
import FoundationModels
import PDFKit
import SQLite3
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Vision

// Everything here leans on what macOS already maintains: Spotlight's index, Quick Look, Vision and the
// on-device model. No crawler, no index of our own, nothing running in the background.

/// Paths nobody means when they search: app internals, caches, hidden and dependency folders.
func isNoise(_ path: String) -> Bool {
    path.hasSuffix(".app") || path.contains("/Library/") || path.contains("/.") || path.contains("/node_modules/")
}

/// macOS names some developer files wrongly (".ts" is "MPEG-2 Transport Stream" to it).
func kindName(_ path: String, _ system: String) -> String {
    ["ts": "TypeScript", "tsx": "TypeScript JSX", "mts": "TypeScript", "cts": "TypeScript"][(path as NSString).pathExtension.lowercased()] ?? system
}

/// The shelf a file belongs on: used to group lists and by "folders by kind".
func category(_ e: Entry) -> String {
    guard let path = e.path else { return Sources.label(e.source) }
    if e.isFolder { return "Folders" }
    let ext = (path as NSString).pathExtension.lowercased()
    if ["ts", "tsx", "mts", "cts"].contains(ext) { return "Code" }
    guard let t = UTType(filenameExtension: ext) else { return "Other" }
    let shelves: [(UTType, String)] = [(.image, "Images"), (.movie, "Videos"), (.audio, "Audio"), (.pdf, "PDFs"),
                                       (.sourceCode, "Code"), (.archive, "Archives"), (.presentation, "Documents"),
                                       (.spreadsheet, "Documents"), (.text, "Documents"), (.compositeContent, "Documents")]
    return shelves.first { t.conforms(to: $0.0) }?.1 ?? "Other"
}

/// Where a file came from, as Spotlight recorded it: download URL and page, or a mail sender.
func whereFroms(_ path: String) -> [String] {
    guard let md = MDItemCreate(nil, path as CFString) else { return [] }
    return MDItemCopyAttribute(md, kMDItemWhereFroms) as? [String] ?? []
}

func hostOf(_ origins: [String]) -> String? {
    guard let h = origins.compactMap({ URL(string: $0)?.host() }).first else { return nil }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
}

private func fileEntry(_ item: NSMetadataItem) -> Entry? {
    guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, !isNoise(path) else { return nil }
    let date = (item.value(forAttribute: "kMDItemLastUsedDate") ?? item.value(forAttribute: NSMetadataItemFSContentChangeDateKey)) as? Date
    let types = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
    return .file(path, date: date ?? .distantPast, kind: kindName(path, item.value(forAttribute: "kMDItemKind") as? String ?? "File"),
                 isFolder: types.contains("public.folder") && !types.contains("com.apple.package"))
}

// MARK: - Spotlight

enum Spotlight {
    static let relevance = [NSSortDescriptor(key: NSMetadataQueryResultContentRelevanceAttribute, ascending: false)]

    /// One-shot query over the home folder: gathers, stops (nothing left running), returns up to `limit` files.
    @MainActor static func find(_ query: String, sort: [NSSortDescriptor] = relevance, limit: Int = 200,
                                scopes: [Any] = [NSMetadataQueryUserHomeScope]) async -> [Entry] {
        guard let predicate = NSPredicate(fromMetadataQueryString: query) else { return [] }
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = scopes
        q.sortDescriptors = sort
        let gathered = NotificationCenter.default.notifications(named: .NSMetadataQueryDidFinishGathering).makeAsyncIterator()
        q.start() // listening already, so even an instant finish isn't missed
        while let done = await gathered.next(), done.object as? NSMetadataQuery !== q {} // other searches finish too
        q.stop()
        var out: [Entry] = []
        for i in 0..<q.resultCount where out.count < limit {
            if let item = q.result(at: i) as? NSMetadataItem, let e = fileEntry(item) { out.append(e) }
        }
        return out
    }
}

/// What the person is looking for. Typed words become keywords; the on-device model fills in the rest.
struct Plan: Equatable {
    var keywords: [String] = []
    var kind = "any"
    var source = ""
    var after: Date?
    var before: Date? // exclusive
}

enum Query {
    static func clean(_ s: String) -> String { s.filter { !"\"*\\".contains($0) }.trimmingCharacters(in: .whitespaces) }

    static let kinds: [String: String] = [
        "pdf": #"kMDItemContentTypeTree == "com.adobe.pdf""#,
        "image": #"kMDItemContentTypeTree == "public.image""#,
        "screenshot": "kMDItemIsScreenCapture == 1",
        "document": #"(kMDItemContentTypeTree == "public.composite-content" || kMDItemContentTypeTree == "public.text")"#,
        "spreadsheet": #"kMDItemContentTypeTree == "public.spreadsheet""#,
        "presentation": #"kMDItemContentTypeTree == "public.presentation""#,
        "video": #"kMDItemContentTypeTree == "public.movie""#,
        "audio": #"kMDItemContentTypeTree == "public.audio""#,
        "code": #"kMDItemContentTypeTree == "public.source-code""#,
        "archive": #"kMDItemContentTypeTree == "public.archive""#,
        "folder": #"kMDItemContentTypeTree == "public.folder""#,
    ]

    static func time(_ d: Date) -> String { "$time.iso(\(ISO8601DateFormatter().string(from: d)))" }

    /// A Spotlight query string; `anyWord` loosens keywords from all-must-match to any-may-match.
    static func build(_ p: Plan, anyWord: Bool = false) -> String? {
        var parts: [String] = []
        // ponytail: plural trim, not real stemming; "invoices" -> "invoice*" matches both forms
        let words = p.keywords.map(clean).filter { !$0.isEmpty }
            .map { $0.count > 4 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
        if !words.isEmpty {
            parts.append("(" + words.map { #"(kMDItemDisplayName == "*\#($0)*"cd || kMDItemTextContent == "\#($0)*"cdw)"# }
                .joined(separator: anyWord ? " || " : " && ") + ")")
        }
        if let kind = kinds[p.kind] { parts.append(kind) }
        let source = clean(p.source)
        if !source.isEmpty { parts.append(#"(kMDItemWhereFroms == "*\#(source)*"cd || kMDItemAuthors == "*\#(source)*"cd)"#) }
        if p.after != nil || p.before != nil { // when it entered your life, was made, or was last opened
            parts.append("(" + ["kMDItemDateAdded", "kMDItemContentCreationDate", "kMDItemLastUsedDate"].map { attr in
                "(" + [p.after.map { "\(attr) >= \(time($0))" }, p.before.map { "\(attr) < \(time($0))" }]
                    .compactMap { $0 }.joined(separator: " && ") + ")"
            }.joined(separator: " || ") + ")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }
}

// MARK: - On-device model (private, free, offline; nothing downloaded by us)

@Generable
struct PlanDraft {
    @Guide(description: "Distinctive words likely to appear in the file's name or text. Never filler words, and never the kind, source or time. Empty if none.")
    var keywords: [String]
    @Guide(description: "The kind of file, if mentioned.", .anyOf(["any", "pdf", "image", "screenshot", "document", "spreadsheet", "presentation", "video", "audio", "code", "archive", "folder"]))
    var kind: String
    @Guide(description: "The website, app or person it came from, lowercase, e.g. figma, slack, rahul. Empty if not mentioned.")
    var source: String
    @Guide(description: "First day of the time mentioned, yyyy-MM-dd. Empty if no time is mentioned.")
    var after: String
    @Guide(description: "Last day of the time mentioned, yyyy-MM-dd, inclusive. Empty if no time is mentioned.")
    var before: String
}

enum AI {
    static var available: Bool { SystemLanguageModel.default.isAvailable }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "the invoice from the figma guy in august" -> keywords [invoice], source figma, Aug 1 – Aug 31.
    static func plan(_ text: String, earlier: String? = nil) async -> Plan? {
        guard available else { return nil }
        let today = Date.now
        let session = LanguageModelSession(instructions: """
            You turn someone's description of a file they are looking for into search filters. \
            Today is \(day.string(from: today)), a \(today.formatted(.dateTime.weekday(.wide))). \
            Resolve relative times like "last week" or "in August" to dates; a month without a year means the most recent one. \
            When a format is named (PDF, screenshot, spreadsheet), use exactly that kind.\(earlier.map { " " + $0 } ?? "")
            """)
        let greedy = GenerationOptions(samplingMode: .greedy) // same description, same filters
        guard let d = try? await session.respond(to: text, generating: PlanDraft.self, options: greedy).content else { return nil }
        // the model sometimes repeats the kind or source as a keyword ("pdf"), which would demand it in the text
        let echoes = Set(Query.kinds.keys.flatMap { [$0, $0 + "s"] } + ["file", "files", "any", d.source.lowercased()])
        return Plan(keywords: d.keywords.map { $0.lowercased() }.filter { !$0.isEmpty && !echoes.contains($0) },
                    kind: Query.kinds[d.kind] == nil ? "any" : d.kind,
                    source: d.source.lowercased(),
                    after: day.date(from: d.after),
                    before: day.date(from: d.before).map { $0.addingTimeInterval(86400) })
    }

    enum Subject {
        case file, folder, selection, activity, day, project, person, lately
        var instructions: String {
            switch self {
            case .file: """
                Describe a file in one plain sentence, the way you would label it for someone searching for it later: \
                what it is, plus the specifics that identify it (names, amounts, dates, topic). No preamble. \
                Say what it is, then the specifics that identify it.
                """
            case .folder: """
                Say in one plain sentence what a folder is for, judging by its name and what's inside: the project, \
                topic or period it belongs to. Mention kinds of files only if they're the point. No preamble, no list. \
                Say what it is for, then the main things in it and when.
                """
            case .selection: """
                Say in one or two plain sentences what a group of files is about: the projects, people, topics or \
                sources they share, judging by their names and folders, and roughly when. Don't describe file types or \
                weekdays. If they don't share much, name the main groups. No preamble, no list. \
                Say what they are, what they are for, when and where.
                """
            case .activity: "Summarize this in one or two plain sentences. No preamble."
            case .day: """
                Write a short journal entry for one day, in the second person, two to four sentences: what you worked \
                on, made, read or decided, naming the projects and sites. Use only what's listed. No preamble. \
                Say what you did in which projects, then what else. Use only names that appear in the list.
                """
            case .person: """
                Describe who a person is to the reader in one to three plain sentences, addressing the reader as "you" (never \
                "I"), using only what's listed. Say you work with them only if commits in your repos or mentions are listed; \
                otherwise just say where you see them and how often. Don't claim anything that isn't listed. No preamble. \
                Start with their name. Use only facts in the list.
                """
            case .lately: """
                In one short sentence starting with "Lately:", say what these commits and mentions are about: the features, \
                fixes or topics. Use only what's listed. No preamble.
                """
            case .project: """
                Describe a project in two or three plain sentences: what it is, then what's been happening in it lately. \
                Use only what's given. No preamble. \
                Say what it is, then "Lately:" and what has been happening. Use only names that appear in the material.
                """
            }
        }
    }

    /// One short on-device summary of a file, folder, selection, activity item, day, project or person.
    static func summary(of material: String, _ subject: Subject) async -> String? {
        guard available, !material.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: subject.instructions)
        guard let text = try? await session.respond(to: String(material.prefix(6000))).content else { return nil }
        return text.contains(#/<[^<>\n]+>/#) ? nil : text // template-like output is thrown away, never stored
    }
}

// MARK: - Reading a file (only the one you're looking at)

func fileText(_ url: URL) async -> String? {
    guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return nil }
    if type.conforms(to: .pdf), let doc = PDFDocument(url: url) {
        return (0..<min(doc.pageCount, 5)).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }
    if type.conforms(to: .image) { return await imageText(url) }
    if type.conforms(to: .rtf) || ["docx", "doc", "odt"].contains(url.pathExtension.lowercased()) {
        return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }
    // Anything that reads as text is text, whatever its type claims (.ts, .toml, logs, extensionless files)
    let head = (try? FileHandle(forReadingFrom: url))?.readData(ofLength: 12_000) ?? Data()
    guard !head.isEmpty, !head.contains(0), let text = String(data: head, encoding: .utf8) ?? String(data: head.dropLast(3), encoding: .utf8)
    else { return nil }
    return text
}

/// Text in an image, read on demand with Vision. Spotlight doesn't index it, and we don't crawl.
func imageText(_ url: URL) async -> String? {
    let mtime = modified(url)
    if let cached = await ImageIndex.shared.text(url.path, mtime) { return cached }
    var text: String?
    await readInHelper([url.path], stall: .seconds(30)) { _, read in text = read }
    if let text { await ImageIndex.shared.store(url.path, mtime, text) }
    return text
}

/// Reads text in images in a short-lived helper: this same binary started with --read-text. Vision keeps
/// ~100 MB of models in whatever process uses it, so it never runs in the app itself; the helper exits and the
/// memory goes back. One result per image as it's read. The first read after install compiles the model for
/// the Neural Engine (seconds to over half a minute), and that can stall: if nothing arrives within `stall`,
/// the helper is ended instead of leaving the app waiting.
@MainActor func readInHelper(_ paths: [String], stall: Duration = .seconds(60), each: @escaping (String, String?) async -> Void) async {
    guard !paths.isEmpty, let exe = Bundle.main.executableURL else { return }
    let helper = Process(), input = Pipe(), output = Pipe()
    helper.executableURL = exe
    helper.arguments = ["--read-text"]
    helper.standardInput = input
    helper.standardOutput = output
    helper.standardError = FileHandle.nullDevice
    helper.qualityOfService = .utility
    guard (try? helper.run()) != nil else { return }
    input.fileHandleForWriting.write(Data(paths.joined(separator: "\n").utf8))
    try? input.fileHandleForWriting.close()

    var last = ContinuousClock.now
    let watchdog = Task {
        while !Task.isCancelled, helper.isRunning {
            try? await Task.sleep(for: .seconds(2))
            if ContinuousClock.now - last > stall { helper.terminate() }
        }
    }
    do {
        for try await line in output.fileHandleForReading.bytes.lines {
            last = .now
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String], let path = obj["path"] else { continue }
            await each(path, obj["text"].flatMap { $0.isEmpty ? nil : $0 })
        }
    } catch {}
    watchdog.cancel()
}

/// The helper's side: paths in on stdin, one JSON line out per image.
func readTextHelper() -> Never {
    while let path = readLine() {
        let text = OCR.read(URL(fileURLWithPath: path)) ?? ""
        if let data = try? JSONSerialization.data(withJSONObject: ["path": path, "text": text]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
    exit(0)
}

func modified(_ url: URL) -> Double {
    ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast).timeIntervalSince1970
}

// MARK: - Text in images: the one index we keep, because Spotlight doesn't read pixels

/// Text only, about a kilobyte per image, for screenshots and photos of text. Lives in Application Support.
actor ImageIndex {
    static let shared = ImageIndex(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Den/image-text.db"))
    private var db: OpaquePointer?

    init(at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        sqlite3_open(url.path, &db)
        for statement in ["pragma journal_mode = wal", "pragma cache_size = -512",
                          "create table if not exists seen (path text primary key, mtime real)",
                          "create virtual table if not exists texts using fts5 (path unindexed, text, tokenize = 'porter')"] {
            _ = query(db, statement)
        }
    }

    func isKnown(_ path: String, _ mtime: Double) -> Bool {
        (query(db, "select mtime from seen where path = ?", [path]).first?["mtime"] as? Double) == mtime
    }

    func text(_ path: String, _ mtime: Double) -> String? {
        guard isKnown(path, mtime) else { return nil }
        return query(db, "select text from texts where path = ?", [path]).first?["text"] as? String
    }

    /// Images without text are remembered too, so they're never read twice.
    func store(_ path: String, _ mtime: Double, _ text: String?) {
        _ = query(db, "insert or replace into seen values (?, ?)", [path, mtime])
        _ = query(db, "delete from texts where path = ?", [path])
        if let text, !text.isEmpty { _ = query(db, "insert into texts (path, text) values (?, ?)", [path, text]) }
    }

    func search(_ fts: String, limit: Int = 60) -> [(path: String, snippet: String)] {
        query(db, "select path, snippet(texts, 1, '', '', '…', 10) s from texts where texts match ? order by rank limit ?", [fts, limit])
            .compactMap { r in (r["path"] as? String).map { ($0, (r["s"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")) } }
    }

    var count: Int { Int(query(db, "select count(*) n from seen").first?["n"] as? Int64 ?? 0) }

    func forget(_ path: String) {
        _ = query(db, "delete from seen where path = ?", [path])
        _ = query(db, "delete from texts where path = ?", [path])
    }
}

/// The pictures worth reading, newest first: everything in the folders people keep things in, screenshots
/// anywhere, and any other picture you've actually opened. Not the frames a render pipeline writes and nobody views.
@MainActor func imagesToRead() async -> [Entry] {
    let since = Query.time(.now - 180 * 86400), home = FileManager.default.homeDirectoryForCurrentUser
    let picture = #"kMDItemContentTypeTree == "public.image" && kMDItemPixelWidth >= 300 && kMDItemPixelHeight >= 300"#
    let newest = [NSSortDescriptor(key: "kMDItemDateAdded", ascending: false)]
    let kept = await Spotlight.find("\(picture) && (kMDItemDateAdded >= \(since) || kMDItemContentCreationDate >= \(since))",
                                    sort: newest, limit: 500,
                                    scopes: ["Desktop", "Downloads", "Documents", "Pictures"].map { home.appending(path: $0) })
    let looked = await Spotlight.find("kMDItemIsScreenCapture == 1 || (\(picture) && kMDItemLastUsedDate >= \(since))", sort: newest, limit: 500)
    var seen = Set<String>()
    return (kept + looked).filter { seen.insert($0.id).inserted }.sorted { $0.date > $1.date }.prefix(500).map { $0 }
}

/// A file entry for a known path (used for image-text hits, which come from our index rather than Spotlight).
func fileEntry(path: String) -> Entry? {
    guard FileManager.default.fileExists(atPath: path), let md = MDItemCreate(nil, path as CFString) else { return nil }
    let date = (MDItemCopyAttribute(md, kMDItemLastUsedDate) ?? MDItemCopyAttribute(md, kMDItemContentCreationDate)) as? Date
    return .file(path, date: date ?? .distantPast, kind: kindName(path, MDItemCopyAttribute(md, kMDItemKind) as? String ?? "Image"))
}

func isScreenshot(_ path: String) -> Bool {
    guard let md = MDItemCreate(nil, path as CFString) else { return false }
    return (MDItemCopyAttribute(md, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue == true
}

enum OCR {
    /// Runs in the helper only. Shrinks first: faster, and huge images are where the model compile stalls.
    static func read(_ url: URL) -> String? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let request = VNRecognizeTextRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

// MARK: - Story: everything macOS already knows about a file

struct Story {
    var size: String?
    var facts: [(String, String)] = []
    var origins: [String] = [] // download URL and page, or mail sender, as Spotlight recorded them
    var downloaded: String?
    var history: [(String, String)] = []
    var repo: String?
    var commits: [(hash: String, subject: String, date: Date)] = []
    var anchor = Date.now // when it entered your life
}

func makeStory(_ path: String) -> Story {
    var s = Story()
    let url = URL(fileURLWithPath: path)
    guard let md = MDItemCreate(nil, path as CFString) else { return s }
    func attr<T>(_ key: CFString) -> T? { MDItemCopyAttribute(md, key) as? T }

    if let bytes: NSNumber = attr(kMDItemFSSize) { s.size = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file) }
    if let w: NSNumber = attr(kMDItemPixelWidth), let h: NSNumber = attr(kMDItemPixelHeight) { s.facts.append(("Dimensions", "\(w) × \(h)")) }
    if let pages: NSNumber = attr(kMDItemNumberOfPages) { s.facts.append(("Pages", "\(pages)")) }
    if let secs: NSNumber = attr(kMDItemDurationSeconds) {
        s.facts.append(("Duration", Duration.seconds(secs.doubleValue).formatted(.time(pattern: .minuteSecond))))
    }

    s.origins = whereFroms(path)
    if let q = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties {
        let agent = q["LSQuarantineAgentName"] as? String, when = q["LSQuarantineTimeStamp"] as? Date
        if agent != nil || when != nil {
            s.downloaded = ["Downloaded" + (agent.map { " with \($0)" } ?? ""), when?.formatted(date: .abbreviated, time: .shortened)]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    let created: Date? = attr(kMDItemContentCreationDate), added: Date? = attr(kMDItemDateAdded)
    let modified: Date? = attr(kMDItemContentModificationDate), used: Date? = attr(kMDItemLastUsedDate)
    for (label, date) in [("Created", created), ("Added", added), ("Modified", modified), ("Last opened", used)] {
        if let date { s.history.append((label, date.formatted(date: .abbreviated, time: .shortened))) }
    }
    if let days: [Date] = attr("kMDItemUsedDates" as CFString), days.count > 1 { s.history.append(("Opened on", "\(days.count) different days")) }
    if let n = NSFileVersion.otherVersionsOfItem(at: url)?.count, n > 0 { s.history.append(("Versions", "\(n) saved")) }
    s.anchor = used ?? added ?? created ?? modified ?? .now

    // Git, only when this file lives in a repo and git is installed (never trigger the developer-tools prompt)
    if let dir = repoRoot(url), hasGit {
        s.repo = dir.lastPathComponent
        let log = runTool("/usr/bin/git", ["-C", dir.path, "log", "-n", "5", "--format=%h%x1f%s%x1f%aI", "--", path])
        let iso = ISO8601DateFormatter()
        s.commits = log.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let date = iso.date(from: f[2]) else { return nil }
            return (f[0], f[1], date)
        }
    }
    return s
}

/// The git repository a path lives in, if any.
func repoRoot(_ url: URL) -> URL? {
    var dir = url
    while dir.path.count > 1 {
        if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { return dir }
        dir.deleteLastPathComponent()
    }
    return nil
}

let hasGit = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

func runTool(_ exe: String, _ args: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Thumbnails (Quick Look's own, kept in a small memory-capped cache)

@MainActor enum Thumbs {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 16 << 20 // ~16 MB of pixels, then the oldest go (Quick Look keeps its own cache on disk)
        return c
    }()

    static func image(_ path: String, size: CGFloat) async -> NSImage? {
        let key = "\(Int(size)) \(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 16)) // 2x scale, 4 bytes a pixel
        return img
    }
}

// MARK: - Browsing

func listFolder(_ url: URL) -> [Entry] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey]
    let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    return urls.map { u in
        let v = try? u.resourceValues(forKeys: Set(keys))
        var e = Entry.file(u.path, date: v?.contentModificationDate ?? .distantPast, kind: kindName(u.path, v?.localizedTypeDescription ?? "File"),
                           isFolder: v?.isDirectory == true && v?.isPackage != true)
        e.context = e.kind
        return e
    }.sorted { $0.date > $1.date }
}

/// Files you opened lately, live from Spotlight: updates the moment you open something.
@Observable final class Recents {
    private(set) var files: [Entry] = []
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let query = NSMetadataQuery()

    func start() {
        query.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@ AND kMDItemContentType != 'public.folder'", // files, like Finder
                                       Date(timeIntervalSinceNow: -90 * 86400) as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in self?.collect() }
        }
        query.start()
    }

    private func collect() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        files = query.results.compactMap { ($0 as? NSMetadataItem).flatMap(fileEntry) }.sorted { $0.date > $1.date }
        onChange()
    }
}
