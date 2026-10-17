import AppKit
import Carbon.HIToolbox

// What ⌥Space does besides search and Ask, so it can replace a launcher: open apps, do sums and unit conversions,
// run commands (sleep, dark mode, snap windows), and bring back anything you copied.

// MARK: - Apps

@MainActor final class AppIndex {
    static let shared = AppIndex()
    private var list: [(name: String, path: String)] = []
    private var at = Date.distantPast

    /// Installed apps, re-read at most every ten minutes.
    var apps: [(name: String, path: String)] {
        if at < .now - 600 {
            at = .now
            let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                        NSHomeDirectory() + "/Applications"]
            list = dirs.flatMap { dir in
                ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }
                    .map { (String($0.dropLast(4)), dir + "/" + $0) }
            } + [("Finder", "/System/Library/CoreServices/Finder.app")]
        }
        return list
    }

    func matching(_ words: [String]) -> [Entry] {
        apps.filter { app in words.allSatisfy { app.name.localizedCaseInsensitiveContains($0) } }
            .sorted { nameScore($0.name, words) > nameScore($1.name, words) }.prefix(3)
            .map { Entry(id: "app:" + $0.path, source: "app", kind: "app", date: .now, title: $0.name, context: tilde($0.path), path: $0.path) }
    }
}

// MARK: - Sums and units

/// "2 + 3 * (4 - 1)^2", "1,200 / 12", "20% * 80". Nothing else: no functions, no variables.
func calculate(_ text: String) -> Double? {
    let allowed = Set("0123456789.+-*/^()%x×÷ ,")
    guard text.contains(where: \.isNumber), text.contains(where: { "+*/^%x×÷".contains($0) } ) || text.dropFirst().contains("-"),
          text.allSatisfy(allowed.contains), text.firstMatch(of: #/^\d{4}-\d{1,2}-\d{1,2}$/#) == nil else { return nil } // not a date
    let s = Array(text.filter { $0 != " " && $0 != "," }.map { $0 == "x" || $0 == "×" ? "*" : $0 == "÷" ? "/" : $0 })
    var i = 0
    func peek() -> Character? { i < s.count ? s[i] : nil }
    func number() -> Double? {
        if peek() == "(" { i += 1; let v = sum(); guard peek() == ")" else { return nil }; i += 1; return v }
        if peek() == "-" { i += 1; return number().map { -$0 } }
        let start = i
        while let c = peek(), c.isNumber || c == "." { i += 1 }
        guard var v = Double(String(s[start..<i])) else { return nil }
        if peek() == "%" { i += 1; v /= 100 }
        return v
    }
    func power() -> Double? {
        guard let base = number() else { return nil }
        if peek() == "^" { i += 1; return power().map { pow(base, $0) } }
        return base
    }
    func product() -> Double? {
        guard var v = power() else { return nil }
        while let op = peek(), op == "*" || op == "/" { i += 1; guard let r = power() else { return nil }; v = op == "*" ? v * r : v / r }
        return v
    }
    func sum() -> Double? {
        guard var v = product() else { return nil }
        while let op = peek(), op == "+" || op == "-" { i += 1; guard let r = product() else { return nil }; v = op == "+" ? v + r : v - r }
        return v
    }
    guard let v = sum(), i == s.count, v.isFinite else { return nil }
    return v
}

private let units: [String: Dimension] = [
    "km": UnitLength.kilometers, "m": UnitLength.meters, "cm": UnitLength.centimeters, "mm": UnitLength.millimeters,
    "mi": UnitLength.miles, "mile": UnitLength.miles, "miles": UnitLength.miles, "ft": UnitLength.feet, "feet": UnitLength.feet,
    "foot": UnitLength.feet, "inch": UnitLength.inches, "inches": UnitLength.inches, "yd": UnitLength.yards,
    "kg": UnitMass.kilograms, "g": UnitMass.grams, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "oz": UnitMass.ounces,
    "c": UnitTemperature.celsius, "°c": UnitTemperature.celsius, "celsius": UnitTemperature.celsius,
    "f": UnitTemperature.fahrenheit, "°f": UnitTemperature.fahrenheit, "fahrenheit": UnitTemperature.fahrenheit,
    "l": UnitVolume.liters, "ml": UnitVolume.milliliters, "gal": UnitVolume.gallons, "cups": UnitVolume.cups,
    "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes, "gb": UnitInformationStorage.gigabytes,
    "tb": UnitInformationStorage.terabytes, "kmh": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour,
]

/// "5 km in miles", "100 f to c", "3.5 kg to lb".
func convert(_ text: String) -> String? {
    guard let m = text.lowercased().firstMatch(of: #/^\s*(-?[\d.,]+)\s*([a-z°]+)\s+(?:in|to|as)\s+([a-z°]+)\s*$/#),
          let n = Double(m.1.replacingOccurrences(of: ",", with: "")), let from = units[String(m.2)], let to = units[String(m.3)],
          ObjectIdentifier(type(of: from)) == ObjectIdentifier(type(of: to)) else { return nil }
    let v = Measurement(value: n, unit: from).converted(to: to).value
    return v.formatted(.number.precision(.significantDigits(1...6))) + " " + to.symbol
}

func answerRow(_ text: String) -> Entry? {
    if let v = calculate(text) {
        let value = v.formatted(.number.grouping(.never).precision(.fractionLength(0...10)))
        return Entry(id: "calc:" + value, source: "calc", kind: "calc", date: .now,
                     title: "= " + v.formatted(.number.precision(.fractionLength(0...10))), context: "Copy \(value)", url: value)
    }
    if let r = convert(text) {
        return Entry(id: "calc:" + r, source: "calc", kind: "calc", date: .now, title: "= " + r, context: "Copy", url: r)
    }
    return nil
}

// MARK: - Commands

enum Snap: String, CaseIterable { case left = "Left Half", right = "Right Half", maximize = "Maximize", center = "Center" }

struct Command {
    let title: String
    let symbol: String
    let words: [String]
    let run: @MainActor (AppModel) -> Void

    @MainActor static let all: [Command] = [
        Command(title: "Sleep", symbol: "moon", words: ["sleep"]) { _ in _ = runTool("/usr/bin/pmset", ["sleepnow"]) },
        Command(title: "Lock Screen", symbol: "lock", words: ["lock"]) { _ in _ = runTool("/usr/bin/pmset", ["displaysleepnow"]) },
        Command(title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled", words: ["dark", "light", "appearance", "theme"]) { _ in
            NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")?
                .executeAndReturnError(nil)
        },
        Command(title: "Free Up Space", symbol: "internaldrive", words: ["clean", "storage", "space", "disk", "free"]) { $0.go("mac:storage") },
        Command(title: "RAM", symbol: "memorychip", words: ["ram", "memory", "slow", "apps"]) { $0.go("mac:ram") },
        Command(title: "Calendar", symbol: "calendar", words: ["calendar", "meetings", "week", "month"]) { $0.go("calendar") },
    ] + Snap.allCases.map { how in
        Command(title: "Window: " + how.rawValue, symbol: "macwindow", words: ["window", "snap"] + how.rawValue.lowercased().split(separator: " ").map(String.init)) { _ in
            Windows.snap(how)
        }
    }

    @MainActor static func matching(_ words: [String]) -> [Entry] {
        let typed = words.map { $0.lowercased() }.filter { $0.count >= 2 }
        guard !typed.isEmpty else { return [] }
        return all.filter { c in typed.allSatisfy { w in c.title.lowercased().contains(w) || c.words.contains { $0.hasPrefix(w) } } }.prefix(3)
            .map { Entry(id: "cmd:" + $0.title, source: "command", kind: $0.symbol, date: .now, title: $0.title, context: "Command") }
    }
}

extension AppModel {
    /// Brings Den forward on a section.
    func go(_ scope: String) {
        QuickPanelController.shared.close()
        openMain?()
        NSApp.activate()
        query = ""
        self.scope = scope
    }
}

// MARK: - Windows

@MainActor enum Windows {
    /// Moves the frontmost window. Needs Accessibility access, asked for the first time it's used.
    static func snap(_ how: Snap) {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary),
              let app = NSWorkspace.shared.frontmostApplication else { return }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return }
        let window = ref as! AXUIElement
        var origin = CGPoint.zero, size = CGSize.zero, value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        // Accessibility measures from the top-left of the main screen; AppKit from the bottom-left
        let flip = NSScreen.screens[0].frame.maxY
        let center = CGPoint(x: origin.x + size.width / 2, y: flip - origin.y - size.height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let target = switch how {
        case .left: CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .right: CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .maximize: v
        case .center: CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        }
        var newOrigin = CGPoint(x: target.minX, y: flip - target.maxY), newSize = target.size
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &newSize)!)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &newOrigin)!)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &newSize)!) // again, once it has room
    }

    /// ⌃⌥← ⌃⌥→ halves, ⌃⌥↩ fills the screen, ⌃⌥C centres.
    static func registerKeys() {
        let keys: [(Int, Snap)] = [(kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_Return, .maximize), (kVK_ANSI_C, .center)]
        for (i, (key, how)) in keys.enumerated() {
            HotKey.register(UInt32(10 + i), keyCode: key, modifiers: controlKey | optionKey) { snap(how) }
        }
    }
}

// MARK: - Clipboard

/// What you copy, kept on this Mac (text only, the last 100). Passwords from password managers are never kept: they
/// mark them concealed. Things that look like keys or tokens aren't kept either.
@MainActor final class ClipboardHistory {
    static let shared = ClipboardHistory()
    struct Clip: Codable { let text: String; let at: Date }
    private(set) var clips: [Clip] = []
    private var seen = NSPasteboard.general.changeCount
    private let file = URL.applicationSupportDirectory.appending(path: "Den/clipboard.json")

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        clips = (try? JSONDecoder().decode([Clip].self, from: Data(contentsOf: file))) ?? []
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in MainActor.assumeIsolated { ClipboardHistory.shared.check() } }
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != seen else { return }
        seen = board.changeCount
        let private_ = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !(board.types ?? []).contains(where: { private_.contains($0.rawValue) }),
              let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count < 20_000, !looksSecret(text) else { return }
        remember(text)
    }

    private func remember(_ text: String) {
        clips.removeAll { $0.text == text }
        clips.insert(Clip(text: text, at: .now), at: 0)
        clips = Array(clips.prefix(100))
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(clips).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Puts it back on the clipboard, ready for ⌘V.
    func copy(_ id: String) {
        guard let clip = clips.first(where: { "clip:" + stableHash($0.text) == id }) else { return }
        Den.copy(clip.text)
        seen = NSPasteboard.general.changeCount
        remember(clip.text)
    }

    func entries(_ words: [String]) -> [Entry] {
        let typed = words.joined(separator: " ")
        let picked = typed.isEmpty || (typed.count >= 3 && "clipboard".hasPrefix(typed.lowercased()))
            ? Array(clips.prefix(8)) : Array(clips.filter { $0.text.localizedCaseInsensitiveContains(typed) }.prefix(2))
        return picked.map { c in
            let lines = c.text.split(separator: "\n").count
            return Entry(id: "clip:" + stableHash(c.text), source: "clipboard", kind: "clip", date: c.at,
                         title: c.text.split(separator: "\n").first.map { String($0.prefix(140)) } ?? "",
                         context: (lines > 1 ? "\(lines) lines · " : "") + "copied " + c.at.formatted(.relative(presentation: .named)))
        }
    }
}

/// One unbroken run of 24+ letters and digits (API keys, tokens): not worth remembering.
func looksSecret(_ t: String) -> Bool {
    t.firstMatch(of: #/^[A-Za-z0-9_\-\.=+]{24,}$/#) != nil && t.contains(where: \.isNumber) && t.contains(where: \.isLetter)
}
