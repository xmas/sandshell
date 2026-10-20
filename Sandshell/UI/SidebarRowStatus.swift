import AppKit

/// What a session row's second line says — one grammar for every row:
/// `<glyph> <StatusWord> · <detail>` — and the rest of the row that follows
/// from the session's state (its time, its title's weight and colour, whether
/// the first instruction shows). Pure: the cell only draws it.
struct SessionRowStatus: Equatable {
    /// The states a session row can be in.
    enum State: Equatable, CaseIterable, Sendable {
        /// A question or a permission is waiting on the person.
        case needsYou
        case working
        /// Finished since the person last looked.
        case finishedUnread
        /// Finished, and seen.
        case finishedSeen
        /// Its agent exited or was stopped (`SessionRuntime.stoppedReason`).
        case stopped
        /// Running, waiting for a message: nothing new since it started.
        case ready
        /// Not running (not started since launch, or closed).
        case idle
    }

    /// What's drawn before the word: a 7 pt dot (at 45 % for `dimDot`), or
    /// the 10 pt spinner — the only animated thing in a row.
    enum Glyph: Equatable, Sendable { case dot, dimDot, spinner }

    /// The status colour, by role (`SidebarPalette.color(for:)` resolves it).
    enum Tone: Equatable, Sendable { case needsYou, working, fresh, live, muted, error }

    let state: State
    let word: String
    let detail: String?

    var glyph: Glyph {
        switch state {
        case .working: .spinner
        case .finishedSeen, .idle: .dimDot
        case .needsYou, .finishedUnread, .stopped, .ready: .dot
        }
    }

    var tone: Tone {
        switch state {
        case .needsYou: .needsYou
        case .working: .working
        case .finishedUnread: .fresh
        case .stopped: .error
        case .ready: .live
        case .finishedSeen, .idle: .muted
        }
    }

    /// The row's title is semibold only while it's unread.
    var titleIsEmphasized: Bool { state == .finishedUnread }

    /// Its agent is running: live, or busy with a turn or a question.
    func isRunning(live: Bool) -> Bool { live || [.needsYou, .working, .ready].contains(state) }

    /// The title's full-strength colour: a live, unread or selected row (else 80 %).
    func titleIsFullStrength(selected: Bool, live: Bool) -> Bool {
        selected || live || [.needsYou, .working, .finishedUnread].contains(state)
    }

    /// The time's colour: the status colour while it works or waits, the
    /// title's when unread, muted otherwise.
    var timeTone: TimeTone {
        switch state {
        case .needsYou: .status(.needsYou)
        case .working: .status(.working)
        case .finishedUnread: .foreground
        case .finishedSeen, .stopped, .ready, .idle: .muted
        }
    }
    enum TimeTone: Equatable, Sendable { case status(Tone), foreground, muted }

    // MARK: From the runtime

    static func state(of runtime: SessionRuntime?) -> State {
        guard let rt = runtime else { return .idle }
        if rt.stoppedReason != nil { return .stopped }
        if rt.isWaiting { return .needsYou }
        if rt.status == .working { return .working }
        if rt.isUnread { return .finishedUnread }
        if rt.workSecondsCompleted > 0 { return .finishedSeen }
        return rt.isLive ? .ready : .idle
    }

    /// The row's status for `runtime` (nil: not run since launch).
    static func of(_ runtime: SessionRuntime?, agent: AgentKind) -> SessionRowStatus {
        let state = state(of: runtime)
        let model = runtime?.claudeStatus?.model?.displayName.nonEmpty
        switch state {
        case .needsYou:
            return .init(state: state, word: "Needs you", detail: runtime?.waitingFor?.nonEmpty)
        case .working:
            // How far through its plan, when the turn has one ("3/6"): what
            // changes as it works, where the model doesn't.
            return .init(state: state, word: "Working", detail: runtime?.planProgress?.compact ?? model)
        case .finishedUnread, .finishedSeen:
            let worked = (runtime?.workSecondsCompleted ?? 0) >= 1
                ? "worked \(Format.workTime(runtime?.workSecondsCompleted ?? 0))" : nil
            let detail = [worked, model].compactMap { $0 }.joined(separator: " · ")
            return .init(state: state, word: "Finished", detail: detail.nonEmpty)
        case .stopped:
            let reason = runtime?.stoppedReason?.split(whereSeparator: \.isNewline).first.map(String.init)
            return .init(state: state, word: "Stopped", detail: reason?.nonEmpty)
        case .ready:
            return .init(state: state, word: "Ready", detail: agent == .claude ? model : agent.displayName)
        case .idle:
            // The badge says which agent; a non-Claude one says what it is ("Shell").
            return .init(state: state, word: "Not running", detail: agent == .claude ? nil : agent.displayName)
        }
    }

    /// Sort rank for `SessionOrder.arrange`: whatever needs you first, then
    /// what's working, then the rest (by activity).
    static func rank(_ runtime: SessionRuntime?) -> Int {
        switch state(of: runtime) {
        case .needsYou: 0
        case .working: 1
        default: 2
        }
    }

    // MARK: Time

    /// The right-hand time: the live elapsed `m:ss` of the turn while it
    /// works, else how long ago it was last active ("3m"); nil if never.
    static func time(_ runtime: SessionRuntime?, lastActivity: Date?, now: Date = .now) -> String? {
        if state(of: runtime) == .working, let rt = runtime {
            let seconds = rt.workingSince.map { now.timeIntervalSince($0) } ?? rt.liveWorkSeconds(at: now)
            return elapsed(seconds)
        }
        return lastActivity.map { ago($0, now: now) }
    }

    /// 252 → "4:12", 3725 → "1:02:05".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(sec))" : "\(m):\(two(sec))"
    }

    /// `Format.ago` without its " ago" — the time column says it: "3m", "2d", "now".
    static func ago(_ date: Date, now: Date = .now) -> String {
        let text = Format.ago(date, now: now)
        if text == "just now" { return "now" }
        return text.hasSuffix(" ago") ? String(text.dropLast(4)) : text
    }

    // MARK: Instruction line

    /// The third line, “the first instruction”: only in comfortable density
    /// and only when the title isn't already it.
    static func showsInstruction(displayName: String, firstPrompt: String?, density: SidebarDensity) -> Bool {
        density == .comfortable && instruction(displayName: displayName, firstPrompt: firstPrompt) != nil
    }

    /// The first instruction on one line, when the title isn't it; nil otherwise.
    static func instruction(displayName: String, firstPrompt: String?) -> String? {
        guard let prompt = firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
              prompt != displayName.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// What a waiting agent is waiting for, in the row's words: "permission to
/// run swift test", "a question".
enum WaitingFor {
    /// From a permission request's title (the tool call's: "`swift test`",
    /// "Edit `Sources/App.swift`", "Fetch https://…").
    static func permission(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let plain = line.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        guard !plain.isEmpty, line != "Allow this action?" else { return "permission" }
        if line.hasPrefix("`") { return "permission to run \(plain)" }
        let first = plain.prefix { !$0.isWhitespace }
        // "Edit x" → "permission to edit x": a capitalized word is the tool's verb.
        if let initial = first.first, initial.isUppercase, first.dropFirst().allSatisfy(\.isLowercase), first.count > 1 {
            return "permission to \(first.lowercased())\(plain.dropFirst(first.count))"
        }
        return "permission for \(plain)"
    }

    /// From an agent's question: a sign-in link, one question, or several.
    static func question(_ q: AgentQuestion) -> String {
        if case .url = q.mode { return "a sign-in" }
        let n = q.questions.count
        return n > 1 ? "\(n) questions" : "a question"
    }
}

/// The sidebar's one tweak: how tall its rows are (View ▸ Comfortable / Compact).
enum SidebarDensity: String, CaseIterable, Sendable {
    case comfortable, compact

    static let defaultsKey = "SidebarDensity"
    /// Posted (object nil) when it changes: every sidebar re-lays its rows.
    static let didChange = Notification.Name("SidebarDensityDidChange")

    static var current: SidebarDensity {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(SidebarDensity.init(rawValue:)) ?? .comfortable }
        set {
            guard newValue != current else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    var title: String { self == .comfortable ? "Comfortable" : "Compact" }

    /// A session row's height: two lines (54 / 40), plus the instruction line
    /// when it shows (comfortable only).
    func sessionRowHeight(showsInstruction: Bool) -> CGFloat {
        switch self {
        case .comfortable: showsInstruction ? 68 : 54
        case .compact: 40
        }
    }
}

/// View ▸ Comfortable / Compact: the menu items' target (checkmark on the current one).
@MainActor
final class SidebarDensityMenu: NSObject, NSMenuItemValidation {
    static let shared = SidebarDensityMenu()

    func items() -> [NSMenuItem] {
        SidebarDensity.allCases.map { density in
            let item = NSMenuItem(title: density.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = density.rawValue
            return item
        }
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let density = SidebarDensity(rawValue: raw) else { return }
        SidebarDensity.current = density
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = (item.representedObject as? String) == SidebarDensity.current.rawValue ? .on : .off
        return true
    }
}

/// The sidebar's colours, derived from its theme's background and foreground
/// so any sidebar (vivid, light) gets the same relationships. On the default
/// dark sidebar (#2A2320 / #F2EDE8) these come out at the design's values.
struct SidebarPalette {
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    /// The title of a row that isn't live, unread or selected (#CFC5BC).
    let dimForeground: NSColor
    /// Details, the time, the chevron (#A89C92).
    let muted: NSColor
    /// The italic first instruction (#8E8278).
    let instruction: NSColor
    /// The search field's hint (#7F736A).
    let hint: NSColor
    /// The selected / focused-pane row, the + button (#3F3631).
    let selectedFill: NSColor
    /// A row open in another pane (#322B27).
    let otherPaneFill: NSColor
    /// Hover (#342C28).
    let hoverFill: NSColor
    /// The search field (#1F1A17).
    let searchFill: NSColor
    /// The rail child rows hang from (#4F443E).
    let rail: NSColor
    /// The footer's top border (#3A322D).
    let separator: NSColor

    init(background: NSColor, foreground: NSColor, isDark: Bool) {
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        func mix(_ t: CGFloat) -> NSColor { background.mixed(with: foreground, t) }
        dimForeground = mix(0.80)
        muted = mix(0.62)
        instruction = mix(0.47)
        hint = mix(0.40)
        selectedFill = mix(0.10)
        otherPaneFill = mix(0.045)
        hoverFill = mix(0.055)
        rail = mix(0.17)
        separator = mix(0.075)
        // A well below the sidebar on a dark one; a light tint on a light one.
        searchFill = isDark ? background.mixed(with: .black, 0.26) : mix(0.06)
    }

    init(_ theme: ThemeColors) {
        self.init(background: theme.sidebar, foreground: theme.sidebarFg, isDark: theme.isDark)
    }

    /// The fixed status colours (chosen to differ in lightness too), a
    /// little darker on a light sidebar so they read on it.
    func color(for tone: SessionRowStatus.Tone) -> NSColor {
        guard tone != .muted else { return muted }
        let base: NSColor = switch tone {
        case .needsYou: Self.needsYou
        case .working: .sessionWorking
        case .fresh: Self.fresh
        case .live: Self.live
        case .error, .muted: Self.error
        }
        return isDark ? base : base.mixed(with: .black, 0.25)
    }

    func color(for tone: SessionRowStatus.TimeTone) -> NSColor {
        switch tone {
        case .status(let t): color(for: t)
        case .foreground: foreground
        case .muted: muted
        }
    }

    static let needsYou = NSColor.hex("F2B13A")
    static let fresh = NSColor.hex("7FB3FF")
    /// Running and ready: green, lighter than the error red, darker than the amber.
    static let live = NSColor.hex("5CC98B")
    static let error = NSColor.hex("FF6B6B")
}

extension NSColor {
    /// This colour `t` of the way to `other` (sRGB, opaque).
    func mixed(with other: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        // A translucent foreground (e.g. white at 6 %) mixes as what it looks like over this.
        let bA = b.alphaComponent
        func channel(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + ((y * bA + x * (1 - bA)) - x) * t }
        return NSColor(srgbRed: channel(a.redComponent, b.redComponent), green: channel(a.greenComponent, b.greenComponent),
                       blue: channel(a.blueComponent, b.blueComponent), alpha: 1)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
