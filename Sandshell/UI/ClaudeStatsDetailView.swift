import SwiftUI

/// Session details, behind the composer's readout (`ⓘ $0.47 · 38%`):
/// everything the status feed knows (the full "status bar"), the context
/// gauge, and Claude usage on this Mac.
struct ClaudeStatsDetailView: View {
    var status: ClaudeSessionStatus?
    var defaultModel: String?
    var defaultEffort: String?
    /// The conversation's priced totals (the Cost row).
    @ObservedObject private var usage = ClaudeUsageStore.shared
    /// The context levels' colours (Settings ▸ Terminal can override them).
    @ObservedObject private var appearance = ClaudeStatsAppearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session Details").font(.role(.title))
            if let status {
                rows(for: status)
            } else {
                Text("Waiting for Claude Code's first status report…")
                    .font(.role(.body))
                    .foregroundStyle(.secondary)
            }
            Divider()
            ClaudeUsageSummaryView()
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
    }

    private struct Row: Identifiable {
        let label: String
        let value: String
        var detail: String? = nil
        /// A context gauge under the value (0…1).
        var gauge: Double? = nil
        var id: String { label }
    }

    private func rows(for s: ClaudeSessionStatus) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Self.rowData(for: s, conversation: s.sessionID.flatMap { usage.sessionTotals[$0] },
                                 defaultModel: defaultModel, defaultEffort: defaultEffort)) { r in
                row(r.label, r.value, detail: r.detail, gauge: r.gauge)
            }
        }
    }

    /// Green → orange → red as the context window fills (the kit status
    /// line's thresholds); each level can be overridden.
    private func levelColor(_ fraction: Double) -> Color {
        let role: ClaudeStatsColorRole = fraction >= 0.8 ? .high : fraction >= 0.5 ? .mid : .low
        let fallback: NSColor = switch role {
        case .high: .systemRed
        case .mid: .systemOrange
        default: .systemGreen
        }
        return Color(nsColor: appearance.color(role, fallback: fallback))
    }

    private func gaugeBar(_ fraction: Double) -> some View {
        let f = min(max(fraction, 0), 1)
        return Capsule().fill(.quaternary)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(levelColor(f)).frame(width: max(6, geo.size.width * f))
                }
            }
            .frame(maxWidth: 220)
            .accessibilityElement()
            .accessibilityLabel("Context used")
            .accessibilityValue("\(Int((f * 100).rounded())) percent")
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
            var line = p.formatted(.percent)
            if let used = s.contextTokens { line += " · \(f.compact(used))" }
            if let size = cw.contextWindowSize { line += " of \(f.compact(size)) tokens" }
            var detail: String? = nil
            if let u = cw.currentUsage {
                let parts = [("in", u.inputTokens), ("cache write", u.cacheCreationInputTokens),
                             ("cache read", u.cacheReadInputTokens), ("out", u.outputTokens)]
                    .compactMap { name, v in v.map { "\(name) \(f.compact($0))" } }
                if !parts.isEmpty { detail = parts.joined(separator: " · ") }
            }
            rows.append(Row(label: "Context", value: line, detail: detail, gauge: pct / 100))
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
                var run = "this run " + f.usd(c.totalCostUSD ?? 0, fractionDigits: 4)
                if let ms = c.totalDurationMs { run += " · \(f.duration(ms))" }
                if let api = c.totalAPIDurationMs { run += " · API \(f.duration(api))" }
                detail.append(run)
            }
            rows.append(Row(label: "Cost", value: f.usd(t.costUSD, fractionDigits: 4),
                            detail: detail.joined(separator: " · ")))
        } else if let c = s.cost, let usd = c.totalCostUSD {
            var detail: [String] = []
            if let ms = c.totalDurationMs { detail.append(f.duration(ms)) }
            if let api = c.totalAPIDurationMs { detail.append("API \(f.duration(api))") }
            rows.append(Row(label: "Cost", value: f.usd(usd, fractionDigits: 4),
                            detail: detail.isEmpty ? nil : detail.joined(separator: " · ")))
        }
        if let c = s.cost, c.totalLinesAdded != nil || c.totalLinesRemoved != nil {
            rows.append(Row(label: "Lines", value: "+\(c.totalLinesAdded ?? 0) −\(c.totalLinesRemoved ?? 0)"))
        }
        if let sb = s.sandshell {
            var parts: [String] = []
            if let h = sb.host, !h.isEmpty { parts.append(h) }
            if let u = sb.memUsed, let t = sb.memTotal, t > 0 {
                // GiB, kept in Double: the sandbox writes these numbers.
                let gib = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
                parts.append("mem \((u / 1_073_741_824).formatted(gib))/\((t / 1_073_741_824).formatted(gib))G")
            }
            if let l = sb.load { parts.append("load \(l.formatted(.number.precision(.fractionLength(2))))") }
            if !parts.isEmpty { rows.append(Row(label: "Sandbox", value: parts.joined(separator: " · "))) }
        }
        if let dir = s.workspace?.currentDir, !dir.isEmpty {
            rows.append(Row(label: "Directory", value: dir))
        }
        if let rl = s.rateLimits {
            var parts: [String] = []
            if let p = rl.fiveHour?.usedPercentage { parts.append("5h \(Int(p).formatted(.percent))") }
            if let p = rl.sevenDay?.usedPercentage { parts.append("7d \(Int(p).formatted(.percent))") }
            if let p = rl.spendLimit?.usedPercentage { parts.append("spend \(Int(p).formatted(.percent))") }
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

    private func row(_ label: String, _ value: String, detail: String? = nil, gauge: Double? = nil) -> some View {
        GridRow {
            Text(label).font(.role(.meta)).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            // Wrap, never truncate: multi-line values grow the row.
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.role(.code))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let gauge { gaugeBar(gauge).padding(.vertical, 3) }
                if let detail {
                    Text(detail).font(.role(.meta)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - All-time usage

/// Claude usage on this Mac, from every transcript: totals per period and the
/// per-model breakdown. Its own view, so the popover's status updates leave it be.
private struct ClaudeUsageSummaryView: View {
    @ObservedObject private var usage = ClaudeUsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude usage on this Mac").font(.role(.title)).foregroundStyle(.secondary)
                Spacer()
                if usage.isScanning {
                    ProgressView().controlSize(.mini)
                } else if let t = usage.lastUpdated {
                    Text("updated \(t, style: .relative) ago").font(.role(.meta)).foregroundStyle(.tertiary)
                    Button("Rescan Transcripts", systemImage: "arrow.clockwise") {
                        usage.refresh(force: true)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Rescan transcripts")
                }
            }
            Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["Cost", "In", "Out", "Cache"], id: \.self) {
                        Text($0).font(.role(.meta)).foregroundStyle(.secondary)
                    }
                }
                ForEach(ClaudeUsagePeriod.allCases) { period in
                    let t = usage.totals[period] ?? ClaudeUsageTotals()
                    GridRow {
                        Text(period.title).font(.role(.meta)).foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(ClaudeStatsFormat.money(t.costUSD)).font(.role(.code))
                        Text(ClaudeStatsFormat.compact(t.input)).font(.role(.code))
                        Text(ClaudeStatsFormat.compact(t.output)).font(.role(.code))
                        Text(ClaudeStatsFormat.compact(t.cacheRead + t.cacheWrite)).font(.role(.code))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ClaudeModelBreakdownView(byModel: usage.byModel)
            Text(footnote)
                .font(.role(.meta)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: String {
        var s = "From \(usage.transcriptCount) transcripts in ~/.claude/projects, priced with \(usage.pricingSource). "
        if let all = usage.totals[.all], all.unpriced > 0 {
            s += "\(all.unpriced) messages used models without a price row. "
        }
        s += "Sessions run with plain sbx run keep transcripts inside the sandbox and aren't counted. "
        s += "Set modelPricing in ~/.claude/settings.json to use contracted rates."
        return s
    }
}

/// Per-model rows for a chosen period, most expensive first.
private struct ClaudeModelBreakdownView: View {
    let byModel: [ClaudeUsagePeriod: [String: ClaudeUsageTotals]]
    @State private var period: ClaudeUsagePeriod = .week

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("By model").font(.role(.title)).foregroundStyle(.secondary)
                Spacer()
                Picker("Period", selection: $period) {
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
            let rows = rows
            let total = rows.reduce(0.0) { $0 + $1.totals.costUSD }
            if rows.isEmpty {
                Text("No Claude usage in this period.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Model").gridColumnAlignment(.leading)
                        Text("Cost"); Text("Share"); Text("Msgs"); Text("Out"); Text("Cache")
                    }
                    .font(.role(.meta)).foregroundStyle(.secondary)
                    ForEach(rows, id: \.name) { r in
                        let t = r.totals
                        GridRow {
                            Text(r.name).font(.role(.body))

                                .gridColumnAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(t.unpriced == t.messages && t.messages > 0 ? "—" : ClaudeStatsFormat.money(t.costUSD))
                            Text(total > 0 ? Int((t.costUSD / total * 100).rounded()).formatted(.percent) : "—")
                                .foregroundStyle(.secondary)
                            Text(ClaudeStatsFormat.compact(t.messages)).foregroundStyle(.secondary)
                            Text(ClaudeStatsFormat.compact(t.output))
                            Text(ClaudeStatsFormat.compact(t.cacheRead + t.cacheWrite))
                        }
                        .font(.role(.code))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    /// Snapshot ids that share a display name (e.g. two Haiku 4.5 dates) are merged.
    private var rows: [(name: String, totals: ClaudeUsageTotals)] {
        var merged: [String: ClaudeUsageTotals] = [:]
        for (id, t) in byModel[period] ?? [:] {
            merged[ClaudeModelName.pretty(id), default: ClaudeUsageTotals()] += t
        }
        return merged.map { ($0.key, $0.value) }
            .sorted { $0.totals.costUSD != $1.totals.costUSD ? $0.totals.costUSD > $1.totals.costUSD
                                                              : $0.totals.totalTokens > $1.totals.totalTokens }
    }
}

private extension ClaudeStatsFormat {
    /// The usage tables' dollars: whole ones from $100 up.
    static func money(_ amount: Double) -> String { usd(amount, fractionDigits: amount >= 100 ? 0 : 2) }
}
