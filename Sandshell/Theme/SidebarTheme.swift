/// 53 perceptually-coordinated sidebar themes generated from a single OKLCH
/// recipe. Each theme provides exact hex values for five chrome roles so the
/// sidebar background, icon-badge accent, and detail-panel tint are always
/// harmonious — without further HSB math.
///
/// Role mapping:
///   deep   → sidebar background (carries white text/icons)
///   bright → icon badge / accent tile (carries white glyphs)
///   tint   → light detail-panel background
///   border → hairline divider on the light panel
///   ink    → body text drawn on the tint panel
struct SidebarTheme: Identifiable {
    let id: String
    let name: String
    let group: Group
    let deep: String    // RRGGBB lowercase, no '#'
    let bright: String
    let tint: String
    let border: String
    let ink: String

    enum Group: String, CaseIterable {
        case originals, core, pop, muted, neutrals
        var title: String {
            switch self {
            case .originals: "Originals"
            case .core:      "Core"
            case .pop:       "Pop"
            case .muted:     "Muted"
            case .neutrals:  "Neutrals"
            }
        }
    }
}

// MARK: - Lookup

extension SidebarTheme {
    static func find(bright hex: String) -> SidebarTheme? { all.first { $0.bright == hex } }
    static func find(deep hex: String)   -> SidebarTheme? { all.first { $0.deep   == hex } }
    static var `default`: SidebarTheme { msdgcNavy }
}

// MARK: - Themes

extension SidebarTheme {

    // Originals
    static let msdgcNavy  = SidebarTheme(id: "msdgcNavy",  name: "Navy",        group: .originals, deep: "27334d", bright: "6389de", tint: "f3f7ff", border: "d7deed", ink: "3a4c73")
    static let eggplant   = SidebarTheme(id: "eggplant",   name: "Eggplant",    group: .originals, deep: "48264d", bright: "b867c5", tint: "fbf4fd", border: "e5d9e7", ink: "5f4064")
    static let pmBlue     = SidebarTheme(id: "pmBlue",     name: "Blue",        group: .originals, deep: "1b4db0", bright: "4a86fb", tint: "f2f7ff", border: "d6deed", ink: "384d73")

    // Core
    static let rose       = SidebarTheme(id: "rose",       name: "Rose",        group: .core, deep: "96324c", bright: "e44f77", tint: "fff3f5", border: "f1d6da", ink: "7b3042")
    static let crimson    = SidebarTheme(id: "crimson",    name: "Crimson",     group: .core, deep: "983433", bright: "e75252", tint: "fff4f3", border: "f2d7d4", ink: "7c3230")
    static let ember      = SidebarTheme(id: "ember",      name: "Ember",       group: .core, deep: "973818", bright: "e55828", tint: "fff4f1", border: "f1d8d0", ink: "7b351e")
    static let sandshell  = SidebarTheme(id: "sandshell",  name: "Sandshell",   group: .core, deep: "854a00", bright: "ca7400", tint: "fff5ec", border: "eddaca", ink: "723f00")
    static let amber      = SidebarTheme(id: "amber",      name: "Amber",       group: .core, deep: "6e5800", bright: "a98800", tint: "fbf7e9", border: "e5dec8", ink: "5e4b00")
    static let citron     = SidebarTheme(id: "citron",     name: "Citron",      group: .core, deep: "426800", bright: "689f00", tint: "f3f9ed", border: "d7e2ce", ink: "39580d")
    static let fern       = SidebarTheme(id: "fern",       name: "Fern",        group: .core, deep: "006e35", bright: "00a855", tint: "eefbf1", border: "d0e4d4", ink: "0b5d2f")
    static let emerald    = SidebarTheme(id: "emerald",    name: "Emerald",     group: .core, deep: "006b50", bright: "00a57d", tint: "ecfbf4", border: "cce5da", ink: "005c44")
    static let teal       = SidebarTheme(id: "teal",       name: "Teal",        group: .core, deep: "006963", bright: "00a199", tint: "eafbf9", border: "c9e5e2", ink: "005a54")
    static let glacier    = SidebarTheme(id: "glacier",    name: "Glacier",     group: .core, deep: "00667a", bright: "009cba", tint: "eafaff", border: "c9e3eb", ink: "005768")
    static let cobalt     = SidebarTheme(id: "cobalt",     name: "Cobalt",      group: .core, deep: "0b5ca3", bright: "148df7", tint: "f1f8ff", border: "d0e0f2", ink: "194e84")
    static let indigo     = SidebarTheme(id: "indigo",     name: "Indigo",      group: .core, deep: "4551a5", bright: "6c7dfa", tint: "f4f6ff", border: "d7ddf3", ink: "3c4686")
    static let iris       = SidebarTheme(id: "iris",       name: "Iris",        group: .core, deep: "6d4396", bright: "a768e4", tint: "f9f4ff", border: "e2d9ee", ink: "5b3c7a")
    static let fuchsia    = SidebarTheme(id: "fuchsia",    name: "Fuchsia",     group: .core, deep: "883775", bright: "d057b2", tint: "fff3fb", border: "ecd7e5", ink: "703361")

    // Pop
    static let punch      = SidebarTheme(id: "punch",      name: "Punch",       group: .pop, deep: "d8003f", bright: "ff1a4f", tint: "fff4f4", border: "f4d6d5", ink: "7e2f36")
    static let coral      = SidebarTheme(id: "coral",      name: "Coral",       group: .pop, deep: "ee1300", bright: "ff2715", tint: "fff4f2", border: "f4d6d1", ink: "7e3126")
    static let tangerine  = SidebarTheme(id: "tangerine",  name: "Tangerine",   group: .pop, deep: "d15300", bright: "e35c00", tint: "fff4f0", border: "f3d7cc", ink: "7c3510")
    static let cosmic     = SidebarTheme(id: "cosmic",     name: "Cosmic",      group: .pop, deep: "bf5c00", bright: "d76900", tint: "fff4ee", border: "f1d8ca", ink: "793800")
    static let marigold   = SidebarTheme(id: "marigold",   name: "Marigold",    group: .pop, deep: "986b00", bright: "b68100", tint: "fef6e8", border: "eadcc5", ink: "664700")
    static let chartreuse = SidebarTheme(id: "chartreuse", name: "Chartreuse",  group: .pop, deep: "879f00", bright: "819800", tint: "f5f9ea", border: "dbe2c9", ink: "465400")
    static let acid       = SidebarTheme(id: "acid",       name: "Acid",        group: .pop, deep: "30a100", bright: "32a800", tint: "f0faee", border: "d3e4cf", ink: "275b1b")
    static let jade       = SidebarTheme(id: "jade",       name: "Jade",        group: .pop, deep: "009772", bright: "00a57d", tint: "ebfbf4", border: "c9e6da", ink: "005c44")
    static let turquoise  = SidebarTheme(id: "turquoise",  name: "Turquoise",   group: .pop, deep: "009a94", bright: "00a19b", tint: "e8fbfa", border: "c6e6e3", ink: "005956")
    static let electric   = SidebarTheme(id: "electric",   name: "Electric",    group: .pop, deep: "008a9d", bright: "009db3", tint: "e8fbff", border: "c5e5eb", ink: "005764")
    static let azure      = SidebarTheme(id: "azure",      name: "Azure",       group: .pop, deep: "007eb0", bright: "0097d2", tint: "eef9ff", border: "c9e2f2", ink: "005476")
    static let ultraviolet = SidebarTheme(id: "ultraviolet", name: "Ultraviolet", group: .pop, deep: "7539ff", bright: "8a6fff", tint: "f6f6ff", border: "dcdbf4", ink: "4b4185")
    static let magenta    = SidebarTheme(id: "magenta",    name: "Magenta",     group: .pop, deep: "ca00bc", bright: "e600d7", tint: "fff2fd", border: "ecd6e8", ink: "6e3367")
    static let hotPink    = SidebarTheme(id: "hotPink",    name: "Hot Pink",    group: .pop, deep: "db008a", bright: "f7009d", tint: "fff3f8", border: "f1d5e0", ink: "782f53")

    // Muted
    static let dustyRose  = SidebarTheme(id: "dustyRose",  name: "Dusty Rose",  group: .muted, deep: "7e575d", bright: "be7381", tint: "fff4f5", border: "ebd9db", ink: "654248")
    static let clay       = SidebarTheme(id: "clay",       name: "Clay",        group: .muted, deep: "7e5950", bright: "bf7665", tint: "fff4f1", border: "ebdad5", ink: "65433b")
    static let mushroom   = SidebarTheme(id: "mushroom",   name: "Mushroom",    group: .muted, deep: "7b5c47", bright: "b97c52", tint: "fef5ef", border: "e9dbd2", ink: "634632")
    static let sand       = SidebarTheme(id: "sand",       name: "Sand",        group: .muted, deep: "746041", bright: "ac8545", tint: "fbf6ee", border: "e5ddd0", ink: "5c4a2d")
    static let olive      = SidebarTheme(id: "olive",      name: "Olive",       group: .muted, deep: "676542", bright: "958f47", tint: "f8f7ee", border: "e0dfd0", ink: "514f2e")
    static let moss       = SidebarTheme(id: "moss",       name: "Moss",        group: .muted, deep: "5b6949", bright: "7b9757", tint: "f4f8f0", border: "dae1d3", ink: "455235")
    static let sage       = SidebarTheme(id: "sage",       name: "Sage",        group: .muted, deep: "4e6c54", bright: "609d6d", tint: "f1f9f3", border: "d5e2d7", ink: "39553f")
    static let eucalyptus = SidebarTheme(id: "eucalyptus", name: "Eucalyptus",  group: .muted, deep: "426d61", bright: "419f89", tint: "effaf6", border: "d1e3dd", ink: "2d564b")
    static let mist       = SidebarTheme(id: "mist",       name: "Mist",        group: .muted, deep: "3d6d6c", bright: "329e9e", tint: "eef9f9", border: "d0e2e2", ink: "285655")
    static let fog        = SidebarTheme(id: "fog",        name: "Fog",         group: .muted, deep: "3d6c73", bright: "339caa", tint: "eef9fb", border: "d0e2e5", ink: "28555b")
    static let stoneBlue  = SidebarTheme(id: "stoneBlue",  name: "Stone Blue",  group: .muted, deep: "416a79", bright: "4098b7", tint: "eff9fd", border: "d1e1e8", ink: "2c5361")
    static let denim      = SidebarTheme(id: "denim",      name: "Denim",       group: .muted, deep: "4b6680", bright: "5b91c3", tint: "f1f8ff", border: "d4e0eb", ink: "375067")
    static let dusk       = SidebarTheme(id: "dusk",       name: "Dusk",        group: .muted, deep: "5c6181", bright: "7f86c5", tint: "f5f6ff", border: "daddec", ink: "464b68")
    static let heather    = SidebarTheme(id: "heather",    name: "Heather",     group: .muted, deep: "685d7d", bright: "957fbd", tint: "f8f5fe", border: "e0dbea", ink: "514765")
    static let plum       = SidebarTheme(id: "plum",       name: "Plum",        group: .muted, deep: "705a77", bright: "a479b2", tint: "faf4fc", border: "e4dae7", ink: "59445f")
    static let mauve      = SidebarTheme(id: "mauve",      name: "Mauve",       group: .muted, deep: "755871", bright: "ae76a6", tint: "fcf4fa", border: "e6d9e4", ink: "5d4359")

    // Neutrals
    static let pewter     = SidebarTheme(id: "pewter",     name: "Pewter",      group: .neutrals, deep: "727b88", bright: "808d9f", tint: "f4f7fb", border: "dadee5", ink: "454e59")
    static let slate      = SidebarTheme(id: "slate",      name: "Slate",       group: .neutrals, deep: "535c67", bright: "808d9f", tint: "f4f7fb", border: "dadee5", ink: "454e59")
    static let graphite   = SidebarTheme(id: "graphite",   name: "Graphite",    group: .neutrals, deep: "353e49", bright: "808d9f", tint: "f4f7fb", border: "dadee5", ink: "454e59")
    static let gunmetal   = SidebarTheme(id: "gunmetal",   name: "Gunmetal",    group: .neutrals, deep: "1f2731", bright: "808d9f", tint: "f4f7fb", border: "dadee5", ink: "454e59")
    static let onyx       = SidebarTheme(id: "onyx",       name: "Onyx",        group: .neutrals, deep: "0f141e", bright: "838c9f", tint: "f5f7fb", border: "dbdee5", ink: "474d59")
    static let espresso   = SidebarTheme(id: "espresso",   name: "Espresso",    group: .neutrals, deep: "231811", bright: "9b887b", tint: "faf6f3", border: "e4dcd8", ink: "574a42")

    static let all: [SidebarTheme] = [
        msdgcNavy, eggplant, pmBlue,
        rose, crimson, ember, sandshell, amber, citron, fern, emerald, teal, glacier, cobalt, indigo, iris, fuchsia,
        punch, coral, tangerine, cosmic, marigold, chartreuse, acid, jade, turquoise, electric, azure, ultraviolet, magenta, hotPink,
        dustyRose, clay, mushroom, sand, olive, moss, sage, eucalyptus, mist, fog, stoneBlue, denim, dusk, heather, plum, mauve,
        pewter, slate, graphite, gunmetal, onyx, espresso,
    ]
}
