import AppKit
import EventKit

// Dev tools, not shipped behaviour:
//   Den --check                                   drive the real model headless and assert on it
//   Den --snapshot out.png [--scope s] [--query q] save a picture of the window (no screen-recording permission needed)

@MainActor func runCheck() {
    var finished = false
    Task { await selfCheck(); finished = true }
    while !finished { RunLoop.main.run(until: .now + 0.05) }
    exit(0)
}

@MainActor func selfCheck() async {
    // Query building: valid Spotlight syntax for every filter
    let aug = DateComponents(calendar: .current, year: 2026, month: 8, day: 1).date!
    let full = Plan(keywords: ["invoice", "acme"], kind: "pdf", source: "figma", after: aug, before: aug + 31 * 86400)
    let q = Query.build(full)!
    precondition(q.contains("com.adobe.pdf") && q.contains("*figma*") && q.contains("$time.iso("), q)
    precondition(NSPredicate(fromMetadataQueryString: q) != nil, "Spotlight rejects: \(q)")
    precondition(Query.build(Plan(keywords: [#"bad"*\"#])).map { NSPredicate(fromMetadataQueryString: $0) != nil } ?? true, "quotes leak")
    precondition(Query.build(Plan()) == nil)

    // Spotlight finds a file by name and by content
    let byName = await Spotlight.find(Query.build(Plan(keywords: ["brain.py"]))!)
    precondition(byName.contains { $0.path?.hasSuffix("/personal/brain/brain.py") == true }, "name search missed brain.py")
    let byContent = await Spotlight.find(Query.build(Plan(keywords: ["scrub", "redact"]))!)
    precondition(byContent.contains { $0.path?.hasSuffix("brain.py") == true }, "content search missed brain.py")

    // Story: dates always; git history when the file is in a repo
    let s = makeStory(NSHomeDirectory() + "/personal/brain/brain.py")
    precondition(s.history.contains { $0.0 == "Modified" } && s.size != nil, "story lacks basics")
    if let repo = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/personal")
        .map({ NSHomeDirectory() + "/personal/" + $0 })
        .first(where: { FileManager.default.fileExists(atPath: $0 + "/.git") && FileManager.default.fileExists(atPath: $0 + "/package.json") }) {
        precondition(!makeStory(repo + "/package.json").commits.isEmpty, "no commits for \(repo)/package.json")
    }

    // Browsing
    let home = listFolder(URL(fileURLWithPath: NSHomeDirectory()))
    precondition(home.contains { $0.isFolder && $0.title == "personal" }, "home listing missed ~/personal")

    // The model: recents, a location, search, navigation
    let m = AppModel()
    try? await Task.sleep(for: .seconds(2)) // let Spotlight gather recents
    m.scope = "recents" // Home is where the app opens now
    m.reloadList()
    precondition(!m.sections.isEmpty, "Recents is empty")
    m.grouping = .kind; m.regroup()
    precondition(m.sections.allSatisfy { s in s.entries.allSatisfy { category($0) == s.title } }, "group by kind mixed shelves")
    m.grouping = .day
    m.scope = "loc:" + NSHomeDirectory() + "/personal"; m.scopeChanged(); m.reloadList()
    precondition(m.entries.contains { $0.title == "brain" }, "can't browse ~/personal")
    m.open(folder: URL(fileURLWithPath: NSHomeDirectory() + "/personal/brain")); m.reloadList()
    precondition(m.entries.contains { $0.title == "brain.py" } && m.canGoBack, "can't enter a folder")
    m.goBack(); m.reloadList()
    precondition(m.entries.contains { $0.title == "brain" }, "back failed")
    m.query = "brain.py"; await m.search()
    precondition(m.sections.first { $0.title == "Files" }?.entries.first?.title == "brain.py",
                 "search didn't rank the name match first: \(m.sections.map { "\($0.title): \($0.entries.prefix(3).map(\.title))" })")

    // Organize: plan, apply, never overwrite, undo puts everything back and removes only the folders it made
    let fm = FileManager.default, box = fm.temporaryDirectory.appending(path: "brain-organize-check")
    try? fm.removeItem(at: box)
    try? fm.createDirectory(at: box.appending(path: "Images"), withIntermediateDirectories: true)
    for name in ["notes.txt", "photo.png", "clip.mov", "Images/photo.png"] {
        fm.createFile(atPath: box.appending(path: name).path, contents: Data(name.utf8))
    }
    let loose = listFolder(box).filter { !$0.isFolder }
    let moves = await Organizer.plan(.kind, folder: "", files: loose) { _ in }
    precondition(Set(moves.compactMap { $0.to.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent } })
                 == ["Documents/notes.txt", "Images/photo 2.png", "Videos/clip.mov"], "plan: \(moves.map { $0.to?.path ?? "-" })")
    let batch = Organizer.apply(moves.compactMap { m in m.to.map { (from: m.from, to: $0) } })
    precondition(batch.moves.count == 3 && String(decoding: fm.contents(atPath: box.appending(path: "Images/photo.png").path)!, as: UTF8.self)
                 == "Images/photo.png", "apply moved wrongly or overwrote")
    _ = Organizer.undo(batch)
    precondition(listFolder(box).map(\.title).sorted() == ["Images", "clip.mov", "notes.txt", "photo.png"], "undo: \(listFolder(box).map(\.title))")
    try? fm.removeItem(at: box)

    // Reading text out of an image (Vision, on demand)
    let img = FileManager.default.temporaryDirectory.appending(path: "brain-ocr-check.png")
    let canvas = NSImage(size: NSSize(width: 900, height: 160))
    canvas.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 160).fill()
    ("request blocked by CORS policy" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 40)])
    canvas.unlockFocus()
    try? NSBitmapImageRep(data: canvas.tiffRepresentation!)?.representation(using: .png, properties: [:])?.write(to: img)
    var ocr = "" // through the helper process, with room for a fresh build's one-time model compile
    await readInHelper([img.path], stall: .seconds(150)) { _, text in ocr = text ?? "" }
    precondition(ocr.localizedCaseInsensitiveContains("CORS policy"), "helper read: \(ocr)")
    let first = await imageText(img) // reads and remembers
    let searchable = await ImageIndex.shared.search(ftsQuery("cors polic")).contains { $0.path == img.path }
    let clock = ContinuousClock.now
    let again = await imageText(img) // from the index: no helper, no Vision
    precondition(first == ocr && searchable, "read text isn't kept or searchable")
    precondition(again == ocr && ContinuousClock.now - clock < .milliseconds(200), "second read should come from the index")
    await ImageIndex.shared.forget(img.path)

    // The image-text index on its own: store, find with a snippet, notice a changed file
    let idx = ImageIndex(at: fm.temporaryDirectory.appending(path: "brain-index-check.db"))
    await idx.store("/tmp/shot.png", 1, "TypeError: cannot read properties of undefined (reading 'map')")
    let found = await idx.search(ftsQuery("properties undefined"))
    precondition(found.first?.path == "/tmp/shot.png" && found.first!.snippet.contains("undefined"), "index search: \(found)")
    let same = await idx.isKnown("/tmp/shot.png", 1), changed = await idx.isKnown("/tmp/shot.png", 2)
    precondition(same && !changed, "index ignores file changes")
    await idx.forget("/tmp/shot.png")
    try? fm.removeItem(at: fm.temporaryDirectory.appending(path: "brain-index-check.db"))

    // Memory: rewriting a page keeps its id and its search text current; days are found by date
    let mem = MemoryStore(at: fm.temporaryDirectory.appending(path: "brain-memory-check.db"))
    let day = Calendar.current.startOfDay(for: .now)
    let id1 = await mem.save(kind: "day", key: "day:x", title: "Today", body: "You fixed the flaky upload test.",
                             evidence: ["file:/x"], date: day, source: "auto")
    let id2 = await mem.save(kind: "day", key: "day:x", title: "Today", body: "You shipped the pricing page.",
                             evidence: [], date: day, source: "auto")
    let stale = await mem.search(ftsQuery("flaky")), fresh = await mem.search(ftsQuery("pricing"))
    let inRange = await mem.days(from: day, to: day + 86400), counted = await mem.counts()
    precondition(id1 == id2 && stale.isEmpty && fresh.first?.id == id1, "rewrite left stale text or a duplicate")
    precondition(inRange.count == 1 && counted["day"] == 1, "days/counts")
    try? fm.removeItem(at: fm.temporaryDirectory.appending(path: "brain-memory-check.db"))
    let parsed = parseMemoryFile("---\nname: deploys\ndescription: How deploys work\ntype: project\n---\n\nMerge to main.\n")
    precondition(parsed.title == "How deploys work" && parsed.body == "Merge to main.", "front matter: \(parsed)")
    precondition(stableHash("abc") == stableHash("abc") && stableHash("abc") != stableHash("abd"), "stable hash")
    let projects = m.projectDirs()
    precondition(!projects.contains(NSHomeDirectory()) && !projects.contains(NSHomeDirectory() + "/personal")
                 && !projects.contains { p in projects.contains { p.hasPrefix($0 + "/") } }, "project folders: \(projects)")
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)!
    let (dayText, dayEvidence) = await m.dayMaterial(yesterday, day)
    print("memory: \(projects.count) projects (\(projects.prefix(4).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))), "
          + "yesterday has \(dayText.split(separator: "\n").count - 1) things and \(dayEvidence.count) pieces of evidence")
    // Citations: each line is matched to the note it echoes, whatever number the model wrote
    let lines = groundLines(["Added Sparkle Intensity to Particles [9]", "Felt good about it"],
                            ["Commit to thrine: Liquid Metal, five metals", "Commit to thrine: Particles, Sparkle Intensity, Mode Drift"])
    precondition(lines[0].index == 1 && lines[0].text == "Added Sparkle Intensity to Particles" && lines[1].index == nil, "grounding: \(lines)")

    if AI.available { // the follow-up from real use: "that day" and a project name must be understood
        await m.ask("what did I work on yesterday?")
        let follow = await m.understand("what were my work in thrine that day ??")
        let hasThrine = await MemoryStore.shared.note(key: "project:" + NSHomeDirectory() + "/work/thrine") != nil
        print("follow-up: about \(follow.about)")
        precondition(follow.plan.after.map { Calendar.current.isDate($0, inSameDayAs: yesterday) } == true
                     && follow.plan.before == day, "follow-up should be exactly that day: \(follow.about)")
        precondition(!hasThrine || follow.project?.name == "thrine", "follow-up missed the project")

        // Prepared ahead of time, then asked: one step instead of reading the whole day while you wait
        let thrine = NSHomeDirectory() + "/work/thrine"
        let preparing = ContinuousClock.now
        await m.prepare(days: 3, only: thrine)
        print("prepared thrine's last 3 days in \(ContinuousClock.now - preparing)")
        await m.ask("what did I do in thrine on saturday?")
        let a = m.answers.last!
        let listed = (a.text ?? "").split(separator: "\n").filter { $0.hasPrefix("- ") }
        let saturday = ["Particles", "Liquid Metal", "Cosmic Orb", "Lego", "Synapse", "Kaiju", "Mosaic", "Cover Star"]
        print("ask (first words \(a.firstWords.map { "\($0)" } ?? "-"), done \(a.took.map { "\($0)" } ?? "-"), prepared: \(a.prepared)): \(listed.count) lines, \(a.cited.count) sources cited; "
              + "names \(saturday.filter { a.text?.contains($0) == true }.count) of \(saturday.count) of Saturday's presets")
        for line in listed.prefix(5) { print("   " + line) }
        precondition(!hasThrine || a.prepared, "Saturday's thrine question should come from prepared notes")
    }

    // People: names from profile titles, one person across their names, never you
    precondition(parseProfile(title: "(2) Replies by Urvish (@0xUrvish) / X", url: "https://x.com/0xUrvish/with_replies").map { "\($0.name) \($0.handle ?? "")" } == "Urvish @0xUrvish")
    precondition(parseProfile(title: "Shreya Shivratriwar | LinkedIn", url: "https://www.linkedin.com/in/shreya").map(\.name) == "Shreya Shivratriwar")
    precondition(parseProfile(title: "Feed | LinkedIn", url: "https://www.linkedin.com/in/x") == nil)
    precondition(parseProfile(title: "torvalds (Linus Torvalds) · GitHub", url: "https://github.com/torvalds").map(\.name) == "Linus Torvalds")
    var urvish = Person(name: "iurvish", names: ["iurvish"], commits: 5)
    let profile = Person(name: "Urvish", names: ["Urvish", "@0xUrvish"], visits: 4)
    precondition(urvish.names.map(personNorm).contains { a in profile.names.map(personNorm).contains { sameIdentity(a, $0) } }, "git and X should be one person")
    urvish.absorb(profile)
    precondition(urvish.name == "Urvish" && urvish.commits == 5 && urvish.visits == 4, "merge")
    precondition(sharesRun("mralgorithm", "ravixalgorithm", 7) && !sharesRun("shashank", "ravixalgorithm", 7), "runs")
    let people = await m.discoverPeople()
    print("people: " + people.prefix(10).map { "\($0.name) (\($0.commits)c \($0.visits)v)" }.joined(separator: ", "))
    precondition(!people.contains { p in p.names.contains { ["ravi", "lander", "algorithm"].contains(where: $0.lowercased().contains) } }, "you got a people page")
    precondition(people.filter { $0.names.contains { $0.lowercased().contains("urvish") } }.count <= 1, "one Urvish, not several")
    precondition(!people.contains { isBot($0.name) } && plainName("𝐍𝐨𝐚𝐡") == "Noah", "bots or decorative names")
    precondition(distinctiveWords(["The Internet Designs", "Urvish Mali"]) == ["Mali", "Urvish"] || distinctiveWords(["Urvish"]) == ["Urvish"],
                 "ordinary words shouldn't identify a person: \(distinctiveWords(["The Internet Designs", "Urvish Mali"]))")
    precondition(isOrganization("The Internet Designs") && !isOrganization("Ada Park"), "organizations")
    if AI.available {
        let start = ContinuousClock.now
        await m.describePeople()
        let pages = await MemoryStore.shared.notes(["person"])
        print("people pages: \(pages.count) in \(ContinuousClock.now - start)")
        for page in pages.prefix(4) { print("   \(page.title): \(page.body)") }
        let leaked = pages.filter { p in ["shopfront", "Maya", "followed them", "follow her", "<"].contains(where: p.body.contains) }
        precondition(leaked.isEmpty, "example text leaked into: \(leaked.map(\.title))")
        if let first = pages.first(where: { $0.title.lowercased().contains("urvish") }) ?? pages.first {
            await m.ask("what has \(first.title.split(separator: " ")[0].lowercased()) been working on lately?")
            let a = m.answers.last!
            print("ask about \(first.title): \(a.text?.prefix(500) ?? "-")")
            print("   (from \(a.sources.count) sources: \(a.sources.prefix(4).map { $0.title.prefix(50) }))")
            precondition(!(a.text ?? "").contains("Liquid Metal"), "the previous answer leaked into a question about someone else")
        }
    }

    // The ⌥Space panel's as-you-type results: a file by name, and memory pages by their words
    let quick = await m.quickResults("brain.py")
    precondition(quick.contains { $0.title == "brain.py" }, "panel missed brain.py: \(quick.map(\.title))")
    let shot = await m.quickResults("star history")
    precondition(shot.first?.title.hasPrefix("star-history") == true || !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Downloads/star-history-20261010.png"),
                 "name match should lead: \(shot.prefix(3).map(\.title))")
    precondition(looksLikeQuestion("what did I do yesterday") && looksLikeQuestion("thrine status?") && !looksLikeQuestion("star history"), "question detection")
    let quickMemory = await m.quickResults("urvish")
    print("panel: \"urvish\" → \(quickMemory.prefix(4).map { "\($0.title) (\($0.source))" })")

    // Launcher: sums, units, secrets
    precondition(calculate("2 + 3 * (4 - 1)^2") == 29 && calculate("1,200 / 12") == 100 && calculate("20% * 80") == 16
                 && calculate("2026-10-12") == nil && calculate("hello") == nil && calculate("12") == nil && calculate("3 -") == nil, "calculator")
    precondition(convert("5 km in miles")?.hasPrefix("3.10686") == true && convert("100 f to c")?.hasPrefix("37.7778") == true
                 && convert("5 kg in miles") == nil, "units: \(convert("5 km in miles") ?? "nil")")
    precondition(looksSecret("sk_live_51HxY2eKq8w9ZpQ3rT7uV0aB") && !looksSecret("hello world") && !looksSecret("https://example.com/a1b2c3d4e5f6g7h8i9j0k"),
                 "secrets")
    // RAM: helpers count as their app
    precondition(owner(ofProcessAt: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/x")
                 == ("/Applications/Google Chrome.app", "Google Chrome") && owner(ofProcessAt: "/opt/homebrew/bin/node") == ("node", "node")
                 && owner(ofProcessAt: "/Users/x/.local/share/claude/versions/2.1.296") == ("claude", "claude"), "process owner")
    precondition(RAM.growth([(.now - 7200, 1_000_000_000)], now: 3_000_000_000) != nil && RAM.growth([(.now - 7200, 1_000_000_000)], now: 1_100_000_000) == nil,
                 "growth")
    let ram = RAM.system()
    precondition(ram.used > 0 && ram.used < ram.total && !RAM.byApp().isEmpty, "RAM readings")
    // Storage: installers, rebuildable folders, duplicates
    precondition(Scan.installerApp("Figma-124.3.dmg") == "figma" && Scan.installerApp("Raycast_v1.2.dmg") == "raycast"
                 && Scan.installerApp("googlechrome.dmg") == "googlechrome" && Scan.installerApp("Docker-arm64.dmg") == "docker", "installer names")
    let proj = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "brain-clean-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: proj.appending(path: "web/node_modules/left-pad"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: proj.appending(path: "target"), withIntermediateDirectories: true) // no Cargo.toml: not a build
    FileManager.default.createFile(atPath: proj.appending(path: "web/pnpm-lock.yaml").path, contents: Data())
    let a = proj.appending(path: "a.bin"), b = proj.appending(path: "b.bin"), c = proj.appending(path: "c.bin")
    try? Data(repeating: 7, count: 4096).write(to: a); try? Data(repeating: 7, count: 4096).write(to: b); try? Data(repeating: 8, count: 4096).write(to: c)
    let builds = Scan.buildFolders(in: proj).map(\.lastPathComponent)
    precondition(builds == ["node_modules"] && Scan.rebuilds(proj.appending(path: "web/node_modules")) == "pnpm install", "build folders: \(builds)")
    let dupes = Scan.duplicates([a.path, b.path, c.path])
    precondition(dupes.count == 1 && [a.path, b.path].contains(dupes[0].path), "duplicates")
    try? FileManager.default.removeItem(at: proj)


    // Calendar grid: prompts close together are one stretch of work; overlapping blocks sit side by side
    let at = { (m: Double, src: String) in Entry(id: "w\(m)", source: src, kind: src == "git" ? "commit" : "prompt", date: day + 10 * 3600 + m * 60,
                                                   title: "x", context: "Den · You") }
    let runs = sessions([at(0, "claude-code"), at(30, "git"), at(120, "claude-code")])
    precondition(runs.count == 2 && runs[0].work.count == 2 && runs[0].tally == "1 commit · 1 prompt" && runs[0].projects == "Den"
                 && runs[1].end == runs[1].start + 15 * 60, "work sessions")
    let laid = sideBySide(runs + [Slot(id: "m", start: day + 10 * 3600 + 10 * 60, end: day + 11 * 3600)])
    precondition(laid.first { $0.slot.id == "m" }!.col == 1 && laid.allSatisfy { $0.slot.id == runs[1].id ? $0.of == 1 : $0.of == 2 }, "side by side")

    // Calendar: a meeting's row, days ahead, and an attendee joining the same person's git name
    let ek = EKEvent(eventStore: EKEventStore())
    ek.title = "Launch review"
    ek.startDate = day + 15 * 3600
    ek.endDate = day + 16 * 3600
    ek.location = "Studio"
    let row = Entry(event: ek)
    precondition(row.source == "calendar" && row.title == "Launch review" && row.context.contains("Studio") && row.context.contains("1 hr"), "meeting row: \(row.context)")
    precondition(dayLabel(day + 86400 + 3600) == "Tomorrow" && dayLabel(day + 3 * 86400 + 3600) != "Today", "days ahead")
    var attendee = Person(name: "Ada Park", names: ["Ada Park", "ada@example.com", "ada"], meetings: 2, meetingTitles: ["Launch review"])
    let gitName = Person(name: "Ada0324", names: ["Ada0324"], commits: 198)
    precondition(attendee.names.map(personNorm).contains { a in gitName.names.map(personNorm).contains { sameIdentity(a, $0) } }, "attendee and git name")
    attendee.absorb(gitName)
    precondition(attendee.name == "Ada Park" && attendee.commits == 198 && attendee.meetings == 2, "merged person")
    print(CalendarSource.shared.connected ? "calendar: \(CalendarSource.shared.events(from: .now - 30 * 86400, to: .now).count) meetings in 30 days"
                                          : "calendar: not connected for this binary (click Connect Calendar in Den.app)")

    // Gmail threads you opened become emails; inbox pages don't
    let thread = Entry(row: ["id": Int64(1), "source": "browser", "kind": "visit", "ts": "2026-10-10T10:00:00+00:00",
                             "title": "Weekly sync notes - me@example.com - Gmail",
                             "url": "https://mail.google.com/mail/u/3/#inbox/FMfcgzQxAbCdEfGhIjKl"])
    let inbox = Entry(row: ["id": Int64(2), "source": "browser", "kind": "visit", "ts": "2026-10-10T10:00:00+00:00",
                            "title": "Inbox (154) - me@example.com - Gmail", "url": "https://mail.google.com/mail/u/3/#inbox"])
    precondition(thread.kind == "email" && thread.title == "Weekly sync notes" && !isMailListPage(thread), "gmail thread")
    precondition(inbox.kind == "visit" && isMailListPage(inbox), "gmail inbox")

    // Organize's "only the PDFs" filter
    let mixed = [Entry.file("/x/a.pdf", date: .now, kind: "PDF"), Entry.file("/x/b.png", date: .now, kind: "PNG"),
                 Entry.file("/x/c", date: .now, kind: "Folder", isFolder: true)]
    precondition(mixed.filter { Organizer.matches($0, "pdf") }.map(\.title) == ["a.pdf"]
                 && mixed.filter { Organizer.matches($0, "folder") }.map(\.title) == ["c"], "kind filter")
    if AI.available, let u = await Organizer.interpret("put the PDFs in a folder called Invoices") {
        print("organize: op=\(u.op.rawValue) folder=\(u.folder) kind=\(u.kind)")
    }
    try? FileManager.default.removeItem(at: img)

    // The on-device model reading a description (output varies, so report rather than assert)
    if AI.available, let p = await AI.plan("pdf invoices from figma in august") {
        print("ai: keywords=\(p.keywords) kind=\(p.kind) source=\(p.source) after=\(p.after.map { "\($0)" } ?? "-")")
        precondition(Query.build(p).map { NSPredicate(fromMetadataQueryString: $0) != nil } ?? true, "AI plan built a bad query")
    }
    print("ok: \(byName.count) name hits, \(byContent.count) content hits, \(m.recents.files.count) recents, \(s.history.count) history facts")
}

@MainActor func snapshotIfAsked(_ model: AppModel) async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
    func arg(_ key: String) -> String? { args.firstIndex(of: key).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    if arg("--appearance") == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
    if arg("--appearance") == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
    if let s = arg("--scope") { model.scope = s }
    if let q = arg("--query") { model.query = q }
    if let question = arg("--ask") { model.scope = "mem:ask"; Task { await model.ask(question) } }
    try? await Task.sleep(for: .seconds(Double(arg("--wait") ?? "") ?? 4))
    let pick = arg("--select").map { Int($0) ?? 0 } ?? (arg("--ask") == nil ? 1 : 0) // "none", or how many from the top
    if pick > 0 { model.selection = Set(model.entries.prefix(pick).map(\.id)); model.selectionChanged() }
    if let layout = arg("--layout").flatMap(AppModel.Layout.init(rawValue:)) { model.layout = layout }
    if let ago = arg("--day").flatMap(Int.init) { // a day's page, so many days back
        model.inspected = Entry(day: Calendar.current.date(byAdding: .day, value: -ago, to: Calendar.current.startOfDay(for: .now))!)
    }
    if let g = arg("--group").flatMap(AppModel.Grouping.init(rawValue:)) { model.grouping = g; model.regroup() }
    if args.contains("--notch") { NotchController.shared.start(model); NotchController.shared.hold = true; NotchController.shared.setOpen(true) }
    if let text = arg("--panel") ?? arg("--panel-ask") ?? (args.contains("--notch") ? "" : nil) { // a panel
        if !args.contains("--notch") { QuickPanelController.shared.show(model, text: text, ask: arg("--panel-ask") != nil) }
        try? await Task.sleep(for: .seconds(Double(arg("--settle") ?? "") ?? 4))
        let panel = args.contains("--notch") ? NotchController.shared.window : QuickPanelController.shared.window
        if let frame = panel?.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }
    if let op = arg("--organize").flatMap(OrganizeOp.init(rawValue:)) {
        model.organize(Set(model.entries.filter { $0.path != nil }.prefix(8).map(\.id)), op)
    }
    try? await Task.sleep(for: .seconds(Double(arg("--settle") ?? "") ?? 4))
    let window = NSApp.windows.first(where: \.isVisible)
    guard let frame = (window?.attachedSheet ?? window)?.contentView?.superview,
          let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { exit(1) }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

// MARK: - Timing what runs on the main thread (Den --perf)

@MainActor func runPerf() {
    var finished = false
    Task {
        let m = AppModel()
        func time(_ label: String, _ work: () -> Void) {
            let t = ContinuousClock.now
            work()
            print(String(format: "%7.1f ms  %@", Double((ContinuousClock.now - t).components.attoseconds) / 1e15 + Double((ContinuousClock.now - t).components.seconds) * 1000, label))
        }
        func timeAsync(_ label: String, _ work: () async -> Void) async {
            // pings from another thread: how long each waits for the main thread is how long a click would wait
            final class Probe: @unchecked Sendable { var worst = 0.0; var running = true }
            let probe = Probe()
            Thread.detachNewThread {
                while probe.running {
                    let sent = Date.now, done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { done.signal() }
                    done.wait()
                    probe.worst = max(probe.worst, Date.now.timeIntervalSince(sent))
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            let t = ContinuousClock.now
            await work()
            probe.running = false
            let worst = probe.worst
            let d = ContinuousClock.now - t
            print(String(format: "%7.1f ms  %@ (async total; longest freeze %.0f ms)", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000,
                         label, worst * 1000))
        }
        try? await Task.sleep(for: .seconds(2)) // recents settle
        await timeAsync("calibration: idle sleep 1 s") { try? await Task.sleep(for: .seconds(1)) }
        time("activity counts (on every return to the app)") { m.refresh() }
        for scope in ["recents", "activity", "claude-code", "browser", "loc:" + NSHomeDirectory() + "/Downloads", "loc:" + NSHomeDirectory()] {
            m.scope = scope; m.scopeChanged()
            await timeAsync("open \(scope.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") {
                m.reloadList()
                while m.entries.isEmpty, !scope.hasPrefix("loc:") { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        let file = NSHomeDirectory() + "/personal/brain/app/Sources/Shell.swift"
        time("file story (git log + Spotlight)") { _ = makeStory(file) }
        if let e = fileEntry(path: file) { await timeAsync("around this time") { _ = await m.around(e, at: e.date) } }
        await timeAsync("quick results 'brain'") { _ = await m.quickResults("brain") }
        let today = Calendar.current.startOfDay(for: .now)
        time("today's work (Home)") { _ = sessions(m.brain?.work(since: today, until: .now) ?? []) }
        await timeAsync("day material (journal)") { _ = await m.dayMaterial(today - 86400, today) }
        await timeAsync("discover people") { _ = await m.discoverPeople() }
        await timeAsync("ask: what did I do yesterday") { await m.ask("what did I do yesterday") }
        await timeAsync("project material") { _ = await m.projectMaterial(NSHomeDirectory() + "/personal/brain") }
        time("free memory") { returnFreedMemory() }
        await timeAsync("disk use by kind") { print(await Task.detached { DiskUse.measure() }.value.map { "\($0.name) \(bytes($0.bytes))" }) }
        finished = true
    }
    while !finished { RunLoop.main.run(until: .now + 0.05) }
    exit(0)
}
