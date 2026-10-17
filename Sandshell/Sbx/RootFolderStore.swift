import AppKit

/// Per-root-folder identity: the SF-symbol icon, its color, and the sidebar
/// background the user picked for a workspace folder. Stored app-globally so the
/// same folder looks the same in any window and is listed in General.
struct RootProfile: Codable, Hashable, Identifiable {
    var path: String        // standardized root path
    var icon: String        // SF Symbol name
    var colorHex: String    // icon-mark fill / brand color
    var sidebarHex: String  // sidebar background
    /// When a window was last opened on this root (nil for roots registered
    /// before this was tracked). Drives "recent" ordering in the Open Workspace
    /// browser and the recents menus.
    var lastOpened: Date? = nil

    var id: String { path }
    var url: URL { URL(filePath: path, directoryHint: .checkFileSystem) }
    var name: String { url.lastPathComponent }

    /// Curated icon + color choices for the picker.
    static let symbols = [
        "folder.fill", "shippingbox.fill", "cube.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "terminal.fill", "globe", "network",
        "server.rack", "cpu", "book.fill", "briefcase.fill",
        "paintbrush.fill", "bolt.fill", "star.fill", "leaf.fill",
    ]
    /// Icon brand colors sourced from the 53-theme OKLCH palette. Each value is
    /// the `bright` role of a SidebarTheme (the icon-badge accent). Neutrals that
    /// share an identical bright are deduplicated; call `sidebarTone(forIcon:)` to
    /// get the coordinated sidebar background for any chosen color.
    static let colors: [String] = {
        var seen = Set<String>()
        return SidebarTheme.all.compactMap { t in
            seen.insert(t.bright).inserted ? t.bright : nil
        }
    }()
    /// The default icon brand color — msdgcNavy bright.
    static let defaultColor = SidebarTheme.default.bright

    /// Sidebar background for an icon color. When the color is a known theme
    /// `bright`, returns the theme's curated `deep`. Falls back to HSB math for
    /// any color the user has manually set outside the palette.
    static func sidebarTone(forIcon hex: String) -> String {
        SidebarTheme.find(bright: hex)?.deep
            ?? NSColor.hex(hex).withHSB(saturation: 0.85, brightness: 0.70).hexString
    }

    /// Light detail-panel background (`tint`) or dark near-black derived from the
    /// theme's `deep`. Falls back to HSB math for unknown icon colors.
    static func mainTone(forIcon hex: String, dark: Bool) -> String {
        if let t = SidebarTheme.find(bright: hex) {
            return dark ? NSColor.hex(t.deep).withHSB(saturation: 0.30, brightness: 0.10).hexString
                        : t.tint
        }
        let c = NSColor.hex(hex)
        return dark ? c.withHSB(saturation: 0.30, brightness: 0.10).hexString
                    : c.withHSB(saturation: 0.10, brightness: 0.97).hexString
    }

    /// Title-bar accent: theme `border` (light) or a mid-dark `deep` (dark).
    /// The border is slightly more saturated than the tint, giving the title bar a
    /// clear hue hit while staying light enough for dark text.
    static func mainBarTone(forIcon hex: String, dark: Bool) -> String {
        if let t = SidebarTheme.find(bright: hex) {
            return dark ? NSColor.hex(t.deep).withHSB(saturation: 0.52, brightness: 0.30).hexString
                        : t.border
        }
        let c = NSColor.hex(hex)
        return dark ? c.withHSB(saturation: 0.52, brightness: 0.30).hexString
                    : c.withHSB(saturation: 0.20, brightness: 0.90).hexString
    }

    static func makeDefault(path: String) -> RootProfile {
        RootProfile(path: RootFolderStore.standardize(path),
                    icon: "folder.fill", colorHex: defaultColor,
                    sidebarHex: sidebarTone(forIcon: defaultColor))
    }
}

/// App-global registry of root folders that have had a sandbox created, each
/// with its `RootProfile`, plus the launch default. Backed by `UserDefaults`.
enum RootFolderStore {
    private static let listKey = "rootProfiles"
    private static let defaultKey = "defaultRootPath"
    /// Posted when a profile is added, changed or removed, so every window on
    /// that folder shows its current look.
    static let didChange = Notification.Name("RootFolderStore.didChange")
    /// A defaults suite to keep the registry in instead of the app's own
    /// (a test binds its own).
    @TaskLocal static var suiteName: String? = nil
    private static var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    static func standardize(_ path: String) -> String {
        // Without a trailing slash, so "/a/b/" and "/a/b" are one key ("/" stays).
        var key = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        while key.count > 1, key.hasSuffix("/") { key.removeLast() }
        return key
    }

    static var all: [RootProfile] {
        guard let data = defaults.data(forKey: listKey),
              let list = try? JSONDecoder().decode([RootProfile].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [RootProfile]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: listKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The stored profile for a path, or a fresh default (not yet persisted).
    static func profile(for path: String) -> RootProfile {
        let key = standardize(path)
        return all.first { $0.path == key } ?? RootProfile.makeDefault(path: key)
    }

    static func upsert(_ profile: RootProfile) {
        var p = profile
        p.path = standardize(p.path)
        save(all.filter { $0.path != p.path } + [p])
    }

    /// Track a root (with default look) the first time a sandbox is created for
    /// it; the first one tracked becomes the launch default.
    static func ensureRegistered(_ path: String) {
        let key = standardize(path)
        guard !all.contains(where: { $0.path == key }) else { return }
        upsert(RootProfile.makeDefault(path: key))
        adoptDefault(key)
    }

    static func remove(_ path: String) {
        let key = standardize(path)
        save(all.filter { $0.path != key })
        if defaultPath == key { defaultPath = existing().first?.path }
    }

    /// Whether `path` is a workspace the app already knows: registered here, or
    /// carrying a configured `.sandshell/config.json` from an earlier open.
    static func isKnown(_ path: String) -> Bool {
        let key = standardize(path)
        if all.contains(where: { $0.path == key }) { return true }
        return (try? WorkspaceConfig.load(root: URL(filePath: key, directoryHint: .checkFileSystem)))??.configured == true
    }

    /// Record that a window was opened on `path` (registering it with the
    /// default look if it's new). Every opened folder ends up in the registry,
    /// so the Open Workspace browser can list "all folders ever opened".
    static func touch(_ path: String, at date: Date = .now) {
        let key = standardize(path)
        var p = all.first { $0.path == key } ?? RootProfile.makeDefault(path: key)
        p.lastOpened = date
        upsert(p)
        adoptDefault(key)
    }

    /// Registered roots that still exist on disk, most recently opened first.
    /// Roots without a timestamp fall back to their `RecentRoots` position, then
    /// sort by name — so upgrading keeps a sensible order.
    static func byRecency() -> [RootProfile] {
        let recentOrder = RecentRoots.all.map { $0.standardizedFileURL.path }
        return existing().sorted { a, b in
            switch (a.lastOpened, b.lastOpened) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let ia = recentOrder.firstIndex(of: a.path), ib = recentOrder.firstIndex(of: b.path)
                switch (ia, ib) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
        }
    }

    /// Registered roots that still exist on disk, sorted by folder name.
    static func byName() -> [RootProfile] {
        existing().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func existing() -> [RootProfile] {
        all.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The root folder opened on launch when no windows are restored. Set to
    /// nil, it's kept as a choice of none (General ▸ "Open this folder at
    /// launch" turned off), which `adoptDefault` leaves alone.
    static var defaultPath: String? {
        get { defaults.string(forKey: defaultKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: defaultKey) }
    }

    /// Make `path` the launch default if none was ever chosen (the first
    /// folder opened). A choice already made, even of none, stays.
    static func adoptDefault(_ path: String) {
        guard defaults.object(forKey: defaultKey) == nil else { return }
        defaultPath = standardize(path)
    }

    /// The folder to open at launch when no windows are restored: the chosen
    /// one, else `fallback` (~/Sandshell, made if need be). Nil when the chosen
    /// folder is gone (an unplugged drive, a deleted folder): it isn't
    /// recreated empty as a brand-new workspace.
    static func launchFolder(fallback: URL = WorkspaceBootstrap.defaultRoot) -> URL? {
        guard let path = defaultPath else { return fallback }
        let chosen = URL(filePath: path, directoryHint: .checkFileSystem)
        let usable = FileManager.default.fileExists(atPath: path) || standardize(path) == standardize(fallback.path)
        return usable ? chosen : nil
    }
}

extension NSColor {
    /// Perceived luminance test, for choosing readable text over an arbitrary
    /// user-picked sidebar background.
    var perceivedIsDark: Bool {
        guard let c = usingColorSpace(.sRGB) else { return true }
        let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return l < 0.55
    }

    /// Same hue, with saturation and/or brightness overridden — used to derive
    /// the sidebar/main tones from an icon color so they share its hue.
    func withHSB(saturation: CGFloat? = nil, brightness: CGFloat? = nil) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else {
            // Gray colorspace: no meaningful hue. Treat white component as brightness.
            let w = whiteComponent
            return NSColor(hue: 0, saturation: saturation ?? 0, brightness: brightness ?? w, alpha: alphaComponent)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: saturation ?? s, brightness: brightness ?? b, alpha: a)
    }
}
