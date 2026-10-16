import SwiftUI
import Combine

/// Which segments of the title-strip readout are shown. Global (all windows),
/// persisted in UserDefaults; toggled from the detail popover.
enum ClaudeStatsSegment: String, CaseIterable, Identifiable {
    case gauge, percent, tokens, cost, model, effort
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gauge: return "Context gauge"
        case .percent: return "Context %"
        case .tokens: return "Tokens in / out"
        case .cost: return "Cost"
        case .model: return "Model"
        case .effort: return "Effort"
        }
    }
}

@MainActor
final class ClaudeStatsVisibility: ObservableObject {
    static let shared = ClaudeStatsVisibility()
    private static let key = "claudeStats.hiddenSegments"
    @Published private(set) var hidden: Set<ClaudeStatsSegment>

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        hidden = Set(raw.compactMap(ClaudeStatsSegment.init(rawValue:)))
    }
    func isVisible(_ s: ClaudeStatsSegment) -> Bool { !hidden.contains(s) }
    func set(_ s: ClaudeStatsSegment, visible: Bool) {
        if visible { hidden.remove(s) } else { hidden.insert(s) }
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Self.key)
    }
}

/// Colour roles of the title-strip readout. Each can be overridden from the
/// popover; otherwise it falls back to the terminal theme.
enum ClaudeStatsColorRole: String, CaseIterable, Identifiable {
    case low, mid, high, track, secondary, model
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "Context under 50%"
        case .mid: return "Context 50–80%"
        case .high: return "Context over 80%"
        case .track: return "Gauge track"
        case .secondary: return "Tokens & cost"
        case .model: return "Model name"
        }
    }
}

/// User colour overrides for the readout. Global, persisted as sRGB hex.
@MainActor
final class ClaudeStatsAppearance: ObservableObject {
    static let shared = ClaudeStatsAppearance()
    private static let key = "claudeStats.colors"
    @Published private(set) var overrides: [ClaudeStatsColorRole: NSColor]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        var map: [ClaudeStatsColorRole: NSColor] = [:]
        for (k, v) in raw {
            if let role = ClaudeStatsColorRole(rawValue: k), let c = NSColor.fromHex(v) { map[role] = c }
        }
        overrides = map
    }

    func color(_ role: ClaudeStatsColorRole, fallback: NSColor) -> NSColor { overrides[role] ?? fallback }
    func isOverridden(_ role: ClaudeStatsColorRole) -> Bool { overrides[role] != nil }

    /// `nil` clears the override (back to the theme colour).
    func set(_ role: ClaudeStatsColorRole, _ color: NSColor?) {
        if let color { overrides[role] = color } else { overrides.removeValue(forKey: role) }
        persist()
    }
    func resetAll() {
        overrides = [:]
        persist()
    }
    private func persist() {
        var raw: [String: String] = [:]
        for (role, c) in overrides { raw[role.rawValue] = c.toHex() }
        UserDefaults.standard.set(raw, forKey: Self.key)
    }
}

extension NSColor {
    /// `#rrggbb` / `rrggbb` → sRGB colour.
    static func fromHex(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    func toHex() -> String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/// Popover content behind the title-strip readout: everything the status feed
/// knows (the full "status bar"), the visibility toggles, and colour overrides.
struct ClaudeStatsDetailView: View {
    var status: ClaudeSessionStatus?
    var defaultModel: String?
    var defaultEffort: String?
    /// Theme colours the pickers fall back to when a role isn't overridden.
    var theme: ThemeColors?
    @ObservedObject private var visibility = ClaudeStatsVisibility.shared
    @ObservedObject private var appearance = ClaudeStatsAppearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                rows(for: status)
            } else {
                Text("Waiting for Claude Code's first status report…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Show in title strip").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(ClaudeStatsSegment.allCases) { seg in
                Toggle(seg.title, isOn: Binding(
                    get: { visibility.isVisible(seg) },
                    set: { visibility.set(seg, visible: $0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            }
            Divider()
            usageSection
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
    }

    // MARK: All-time usage

    @ObservedObject private var usage = ClaudeUsageStore.shared

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude usage on this Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if usage.isScanning {
                    ProgressView().controlSize(.mini)
                } else if let t = usage.lastUpdated {
                    Text("updated \(t, style: .relative) ago").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button {
                        usage.refresh(force: true)
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Rescan transcripts")
                }
            }
            Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["Cost", "In", "Out", "Cache"], id: \.self) {
                        Text($0).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                ForEach(ClaudeUsagePeriod.allCases) { period in
                    let t = usage.totals[period] ?? ClaudeUsageTotals()
                    GridRow {
                        Text(period.title).font(.system(size: 11)).foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(Self.money(t.costUSD)).font(.system(size: 12, design: .monospaced))
                        Text(ClaudeStatsFormat.compact(t.input)).font(.system(size: 12, design: .monospaced))
                        Text(ClaudeStatsFormat.compact(t.output)).font(.system(size: 12, design: .monospaced))
                        Text(ClaudeStatsFormat.compact(t.cacheRead + t.cacheWrite)).font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            modelBreakdown
            Text(usageFootnote)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @State private var modelPeriod: ClaudeUsagePeriod = .week

    /// Per-model rows for the chosen period, most expensive first. Snapshot ids
    /// that share a display name (e.g. two Haiku 4.5 dates) are merged.
    private var modelRows: [(name: String, totals: ClaudeUsageTotals)] {
        var merged: [String: ClaudeUsageTotals] = [:]
        for (id, t) in usage.byModel[modelPeriod] ?? [:] {
            merged[ClaudeModelName.pretty(id), default: ClaudeUsageTotals()] += t
        }
        return merged.map { ($0.key, $0.value) }
            .sorted { $0.totals.costUSD != $1.totals.costUSD ? $0.totals.costUSD > $1.totals.costUSD
                                                              : $0.totals.totalTokens > $1.totals.totalTokens }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("By model").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $modelPeriod) {
                    Text("Week").tag(ClaudeUsagePeriod.week)
                    Text("Month").tag(ClaudeUsagePeriod.month)
                    Text("Year").tag(ClaudeUsagePeriod.year)
                    Text("All").tag(ClaudeUsagePeriod.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            let rows = modelRows
            let total = rows.reduce(0.0) { $0 + $1.totals.costUSD }
            if rows.isEmpty {
                Text("No Claude usage in this period.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Model").gridColumnAlignment(.leading)
                        Text("Cost"); Text("Share"); Text("Msgs"); Text("Out"); Text("Cache")
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(rows, id: \.name) { r in
                        let t = r.totals
                        GridRow {
                            Text(r.name).font(.system(size: 12, weight: .medium))
                                .gridColumnAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(t.unpriced == t.messages && t.messages > 0 ? "—" : Self.money(t.costUSD))
                            Text(total > 0 ? "\(Int((t.costUSD / total * 100).rounded()))%" : "—")
                                .foregroundStyle(.secondary)
                            Text(ClaudeStatsFormat.compact(t.messages)).foregroundStyle(.secondary)
                            Text(ClaudeStatsFormat.compact(t.output))
                            Text(ClaudeStatsFormat.compact(t.cacheRead + t.cacheWrite))
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private var usageFootnote: String {
        var s = "From \(usage.transcriptCount) transcripts in ~/.claude/projects, priced with \(usage.pricingSource). "
        if let all = usage.totals[.all], all.unpriced > 0 {
            s += "\(all.unpriced) messages used models without a price row. "
        }
        s += "Sessions run with plain sbx run keep transcripts inside the sandbox and aren't counted. "
        s += "Set modelPricing in ~/.claude/settings.json to use contracted rates."
        return s
    }

    private static func money(_ usd: Double) -> String {
        usd >= 100 ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }

    private struct Row: Identifiable {
        let label: String
        let value: String
        var detail: String? = nil
        var id: String { label }
    }

    private func rows(for s: ClaudeSessionStatus) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Self.rowData(for: s, conversation: s.sessionID.flatMap { usage.sessionTotals[$0] },
                                 defaultModel: defaultModel, defaultEffort: defaultEffort)) { r in
                row(r.label, r.value, detail: r.detail)
            }
        }
    }

    /// Plain data for the grid — assembled outside the result builder so the
    /// string building can use ordinary statements.
    private static func rowData(for s: ClaudeSessionStatus, conversation: ClaudeUsageTotals?,
                                defaultModel: String?, defaultEffort: String?) -> [Row] {
        let f = ClaudeStatsFormat.self
        var rows: [Row] = []
        if let m = s.model {
            rows.append(Row(label: "Model", value: m.displayName, detail: m.id))
        } else {
            rows.append(Row(label: "Model", value: ClaudeModelChoice.title(forID: defaultModel), detail: "workspace default"))
        }
        if let level = s.effort?.level {
            rows.append(Row(label: "Effort", value: ClaudeEffortChoice.title(forID: level), detail: level))
        } else {
            rows.append(Row(label: "Effort", value: ClaudeEffortChoice.title(forID: defaultEffort), detail: "workspace default"))
        }
        if let cw = s.contextWindow, let pct = cw.usedPercentage {
            let p = Int(pct.rounded(.down))
            var line = "\(p)%"
            if let used = s.contextTokens { line += " · \(f.compact(used))" }
            if let size = cw.contextWindowSize { line += " of \(f.compact(size)) tokens" }
            var detail: String? = nil
            if let u = cw.currentUsage {
                let parts = [("in", u.inputTokens), ("cache write", u.cacheCreationInputTokens),
                             ("cache read", u.cacheReadInputTokens), ("out", u.outputTokens)]
                    .compactMap { name, v in v.map { "\(name) \(f.compact($0))" } }
                if !parts.isEmpty { detail = parts.joined(separator: " · ") }
            }
            rows.append(Row(label: "Context", value: line, detail: detail))
        }
        if let cw = s.contextWindow, cw.totalInputTokens != nil || cw.totalOutputTokens != nil {
            rows.append(Row(label: "Tokens",
                            value: "↑\(f.compact(cw.totalInputTokens ?? 0)) ↓\(f.compact(cw.totalOutputTokens ?? 0))",
                            detail: "session totals"))
        }
        if let t = conversation, t.messages > 0 {
            // Claude Code's cost covers only this run (it restarts at $0 on
            // --resume); the transcript covers the whole conversation.
            var detail = ["\(t.messages) messages"]
            if t.unpriced > 0 { detail.append("\(t.unpriced) unpriced") }
            if let c = s.cost {
                var run = "this run " + String(format: "$%.4f", c.totalCostUSD ?? 0)
                if let ms = c.totalDurationMs { run += " · \(f.duration(ms))" }
                if let api = c.totalAPIDurationMs { run += " · API \(f.duration(api))" }
                detail.append(run)
            }
            rows.append(Row(label: "Cost", value: String(format: "$%.4f", t.costUSD),
                            detail: detail.joined(separator: " · ")))
        } else if let c = s.cost, let usd = c.totalCostUSD {
            var detail: [String] = []
            if let ms = c.totalDurationMs { detail.append(f.duration(ms)) }
            if let api = c.totalAPIDurationMs { detail.append("API \(f.duration(api))") }
            rows.append(Row(label: "Cost", value: String(format: "$%.4f", usd),
                            detail: detail.isEmpty ? nil : detail.joined(separator: " · ")))
        }
        if let c = s.cost, c.totalLinesAdded != nil || c.totalLinesRemoved != nil {
            rows.append(Row(label: "Lines", value: "+\(c.totalLinesAdded ?? 0) −\(c.totalLinesRemoved ?? 0)"))
        }
        if let sb = s.sandshell {
            var parts: [String] = []
            if let h = sb.host, !h.isEmpty { parts.append(h) }
            if let u = sb.memUsed, let t = sb.memTotal, t > 0 {
                parts.append(String(format: "mem %.1f/%.1fG", u / 1_073_741_824, t / 1_073_741_824))
            }
            if let l = sb.load { parts.append(String(format: "load %.2f", l)) }
            if !parts.isEmpty { rows.append(Row(label: "Sandbox", value: parts.joined(separator: " · "))) }
        }
        if let dir = s.workspace?.currentDir, !dir.isEmpty {
            rows.append(Row(label: "Directory", value: dir))
        }
        if let rl = s.rateLimits {
            var parts: [String] = []
            if let p = rl.fiveHour?.usedPercentage { parts.append("5h \(Int(p))%") }
            if let p = rl.sevenDay?.usedPercentage { parts.append("7d \(Int(p))%") }
            if let p = rl.spendLimit?.usedPercentage { parts.append("spend \(Int(p))%") }
            var detail: [String] = []
            if let r = rl.fiveHour?.resetsAt { detail.append("5h resets \(Format.relative(Date(timeIntervalSince1970: r)))") }
            if let r = rl.sevenDay?.resetsAt { detail.append("7d resets \(Format.relative(Date(timeIntervalSince1970: r)))") }
            if !parts.isEmpty {
                rows.append(Row(label: "Plan limits", value: parts.joined(separator: " · "),
                                detail: detail.isEmpty ? nil : detail.joined(separator: " · ")))
            }
        }
        if s.sessionID != nil || s.version != nil {
            rows.append(Row(label: "Session", value: s.sessionID.map { String($0.prefix(8)) } ?? "—",
                            detail: s.version.map { "Claude Code v\($0)" }))
        }
        return rows
    }

    private func row(_ label: String, _ value: String, detail: String? = nil) -> some View {
        GridRow {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            // Wrap, never truncate: multi-line values grow the row.
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Number formatting shared by the strip and the popover.
enum ClaudeStatsFormat {
    static func compact(_ n: Int) -> String { Format.tokens(n) }
    static func duration(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

/// The readout colour pickers — lives in Settings ▸ Terminal. Unset roles follow
/// the terminal palette; a set one shows an undo arrow back to the theme.
struct ClaudeReadoutColorsView: View {
    var theme: ThemeColors?
    @ObservedObject private var appearance = ClaudeStatsAppearance.shared

    var body: some View {
        ForEach(ClaudeStatsColorRole.allCases) { role in
            HStack(spacing: 8) {
                ColorPicker(role.title, selection: Binding(
                    get: { Color(nsColor: appearance.color(role, fallback: fallback(role))) },
                    set: { appearance.set(role, NSColor($0)) }),
                    supportsOpacity: false)
                if appearance.isOverridden(role) {
                    Button {
                        appearance.set(role, nil)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to the theme colour")
                }
            }
        }
        if !appearance.overrides.isEmpty {
            Button("Reset All to Theme") { appearance.resetAll() }
        }
    }

    private func fallback(_ role: ClaudeStatsColorRole) -> NSColor {
        ClaudeStatsView.themeFallback(role, theme)
    }
}
