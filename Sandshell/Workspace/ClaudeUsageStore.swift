import Foundation
import Combine

/// Token totals for a set of Claude Code assistant messages. Cost is derived
/// at display time from the current `ClaudePriceBook`, so a price update never
/// requires re-parsing transcripts.
struct ClaudeUsageTotals: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var messages = 0
    /// Messages whose model had no price row (tokens counted, cost not).
    var unpriced = 0
    var costUSD: Double = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var totalTokens: Int { input + output + cacheWrite + cacheRead }

    static func += (lhs: inout ClaudeUsageTotals, rhs: ClaudeUsageTotals) {
        lhs.input += rhs.input; lhs.output += rhs.output
        lhs.cacheWrite5m += rhs.cacheWrite5m; lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheRead += rhs.cacheRead
        lhs.messages += rhs.messages; lhs.unpriced += rhs.unpriced
        lhs.costUSD += rhs.costUSD
    }
}

enum ClaudeUsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: return "This week"
        case .month: return "This month"
        case .year: return "This year"
        case .all: return "All time"
        }
    }
}

/// "claude-fable-5-1" → "Fable 5.1", "claude-3-5-sonnet-20241022" → "Sonnet 3.5",
/// "claude-haiku-4-5-20251001" → "Haiku 4.5". Unknown shapes pass through.
enum ClaudeModelName {
    static func pretty(_ id: String) -> String {
        let parts = ClaudePriceBook.normalize(id).split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return id }
        var family: String?
        var version: [String] = []
        for p in parts.dropFirst() {
            if p.allSatisfy(\.isNumber) {
                if p.count < 8 { version.append(p) }   // drop dated snapshot suffixes
            } else if family == nil {
                family = p.prefix(1).uppercased() + p.dropFirst()
            }
        }
        guard let family else { return id }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }
}

// MARK: - Pricing

/// USD per million tokens for one model.
struct ClaudeRate: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double

    /// List-price convention: 5m writes 1.25× input, 1h writes 2× input,
    /// reads 0.1× input unless the model publishes its own read rate.
    static func list(_ input: Double, _ output: Double, cacheRead: Double? = nil) -> ClaudeRate {
        ClaudeRate(input: input, output: output, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2,
                   cacheRead: cacheRead ?? input * 0.1)
    }

    func cost(_ t: ClaudeUsageTotals) -> Double {
        (Double(t.input) * input + Double(t.output) * output
         + Double(t.cacheWrite5m) * cacheWrite5m + Double(t.cacheWrite1h) * cacheWrite1h
         + Double(t.cacheRead) * cacheRead) / 1_000_000
    }
}

/// Layered price lookup. Precedence per model:
///   1. Claude Code `modelPricing.overrides` (contracted rates; also `multiplier`)
///   2. the LiteLLM community price feed, refreshed daily
///   3. the built-in list-price table (checked against platform.claude.com, 2026-09)
struct ClaudePriceBook: Sendable {
    var rates: [String: ClaudeRate]          // model id / family prefix → rate
    var overrides: [String: ClaudeRate] = [:] // Claude Code modelPricing rows
    var multiplier: Double = 1
    var source: String

    /// Built-in list prices, verified against platform.claude.com/docs/en/about-claude/pricing.
    static let builtIn: [String: ClaudeRate] = [
        "claude-fable-5-1":  .list(10, 50, cacheRead: 0.25),
        "claude-mythos-5-1": .list(10, 50, cacheRead: 0.25),
        "claude-fable-5":    .list(10, 50, cacheRead: 1.0),
        "claude-mythos-5":   .list(10, 50, cacheRead: 1.0),
        "claude-opus-5-5":   .list(4, 20, cacheRead: 0.20),
        "claude-opus-5":     .list(5, 25),
        "claude-opus-4-8":   .list(5, 25),
        "claude-opus-4-7":   .list(5, 25),
        "claude-opus-4-6":   .list(5, 25),
        "claude-opus-4-5":   .list(5, 25),
        "claude-opus-4-1":   .list(15, 75),
        "claude-opus-4-0":   .list(15, 75),
        "claude-opus-4-2":   .list(15, 75),   // claude-opus-4-20250514
        "claude-3-opus":     .list(15, 75),
        "claude-sonnet-5-5": .list(2, 10),
        "claude-sonnet-5":   .list(2, 10),
        "claude-sonnet-4-6": .list(3, 15),
        "claude-sonnet-4-5": .list(3, 15),
        "claude-sonnet-4-0": .list(3, 15),
        "claude-sonnet-4-2": .list(3, 15),    // claude-sonnet-4-20250514
        "claude-3-7-sonnet": .list(3, 15),
        "claude-3-5-sonnet": .list(3, 15),
        "claude-3-sonnet":   .list(3, 15),
        "claude-haiku-4-5":  .list(1, 5),
        "claude-3-5-haiku":  .list(0.8, 4),
        "claude-3-haiku":    .list(0.25, 1.25),
    ]

    static let fallback = ClaudePriceBook(rates: builtIn, source: "built-in list prices")

    /// Docker's effective rates relative to list, calibrated from the company
    /// weekly cost report of 2026-09-28 against this Mac's transcripts for the
    /// same 7 days: Fable $222.70 billed vs $340.55 at list (×0.654). Sonnet,
    /// Opus and Haiku billed at or slightly above list, which is explained by
    /// usage this Mac can't see (sandbox-local transcripts, background Haiku
    /// calls), so they stay at list rather than inventing a markup.
    /// Applied after the feed/built-in rate, before any `modelPricing` override.
    static let companyCalibration: [(prefix: String, factor: Double)] = [
        ("claude-fable-", 0.654),
        ("claude-mythos-", 0.654),
    ]
    static let companyCalibrationLabel = "Docker rates (Fable ×0.654, from the 2026-09-28 cost report)"

    /// Normalise a transcript model id: drop provider prefixes and Claude Code's
    /// "[1m]" long-context suffix.
    static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        if let r = m.range(of: "anthropic.") { m = String(m[r.upperBound...]) }
        if let r = m.range(of: "anthropic/") { m = String(m[r.upperBound...]) }
        if let r = m.range(of: "[") { m = String(m[..<r.lowerBound]) }
        return m
    }

    /// Exact id first, then longest key that prefixes the id (families cover
    /// their dated snapshots, matching Claude Code's own `modelPricing` rule).
    private static func lookup(_ m: String, in table: [String: ClaudeRate]) -> ClaudeRate? {
        if let r = table[m] { return r }
        var best: (String, ClaudeRate)?
        for (k, r) in table where m.hasPrefix(k) {
            if best == nil || k.count > best!.0.count { best = (k, r) }
        }
        return best?.1
    }

    func rate(for model: String) -> ClaudeRate? {
        let m = Self.normalize(model)
        var r: ClaudeRate?
        if let o = Self.lookup(m, in: overrides) {
            r = o   // contracted rates are used exactly as written
        } else if var base = Self.lookup(m, in: rates) {
            if let f = Self.companyCalibration.first(where: { m.hasPrefix($0.prefix) })?.factor {
                base.input *= f; base.output *= f
                base.cacheWrite5m *= f; base.cacheWrite1h *= f; base.cacheRead *= f
            }
            r = base
        }
        if multiplier != 1, var x = r {
            x.input *= multiplier; x.output *= multiplier
            x.cacheWrite5m *= multiplier; x.cacheWrite1h *= multiplier; x.cacheRead *= multiplier
            r = x
        }
        return r
    }
}

/// Fetches and caches the LiteLLM price feed (the same source ccusage uses) and
/// reads Claude Code's `modelPricing` from managed + user settings.
enum ClaudePriceSources {
    static let feedURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let feedMaxAge: TimeInterval = 24 * 3600

    struct FeedCache: Codable, Sendable {
        var fetchedAt: Date
        var rates: [String: ClaudeRate]
        /// First-party Anthropic chat model ids not yet past their deprecation
        /// date — the dynamic part of the model chooser. Nil in caches written
        /// before the chooser used the feed (forces one refetch).
        var models: [String]?
    }

    /// Cached feed if fresh, else download; on any failure keep the stale cache.
    static func loadFeed(cacheURL: URL) async -> FeedCache? {
        var cached: FeedCache?
        if let data = try? Data(contentsOf: cacheURL) {
            cached = try? JSONDecoder().decode(FeedCache.self, from: data)
        }
        if let cached, cached.models != nil, Date().timeIntervalSince(cached.fetchedAt) < feedMaxAge { return cached }
        do {
            var req = URLRequest(url: feedURL)
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cached }
            var rates: [String: ClaudeRate] = [:]
            var models: [String] = []
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            for (key, v) in obj {
                // Raw key test: "anthropic.claude-…" (Bedrock) and "vertex_ai/claude-…"
                // are priced below but aren't ids `claude --model` takes.
                if key.hasPrefix("claude-"), !key.contains("/"), !key.contains("."),
                   let row = v as? [String: Any],
                   row["litellm_provider"] as? String == "anthropic",
                   (row["mode"] as? String ?? "chat") == "chat" {
                    let retired = (row["deprecation_date"] as? String).flatMap { day.date(from: $0) }
                        .map { $0 <= Date() } ?? false
                    if !retired { models.append(key) }
                }
                let k = ClaudePriceBook.normalize(key)
                guard k.hasPrefix("claude-"), !k.contains("/"),
                      let row = v as? [String: Any],
                      let i = row["input_cost_per_token"] as? Double,
                      let o = row["output_cost_per_token"] as? Double else { continue }
                let w5 = row["cache_creation_input_token_cost"] as? Double ?? i * 1.25
                let w1h = row["cache_creation_input_token_cost_above_1hr"] as? Double ?? i * 2
                let cr = row["cache_read_input_token_cost"] as? Double ?? i * 0.1
                rates[k] = ClaudeRate(input: i * 1e6, output: o * 1e6, cacheWrite5m: w5 * 1e6,
                                      cacheWrite1h: w1h * 1e6, cacheRead: cr * 1e6)
            }
            guard rates.count >= 5 else { return cached }   // sanity: don't trust a near-empty feed
            let fresh = FeedCache(fetchedAt: Date(), rates: rates, models: models.sorted())
            if let out = try? JSONEncoder().encode(fresh) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? out.write(to: cacheURL, options: .atomic)
            }
            return fresh
        } catch {
            return cached
        }
    }

    /// Claude Code honours `modelPricing` only from managed settings; Sandshell
    /// also reads the user file so a personal override works without MDM.
    /// Rates are USD per MTok; `cacheWrite` covers both TTLs.
    static func loadOverrides(home: URL) -> (rows: [String: ClaudeRate], multiplier: Double, found: Bool) {
        let candidates = [
            home.appendingPathComponent(".claude/settings.json"),
            URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
        ]
        var rows: [String: ClaudeRate] = [:]
        var multiplier = 1.0
        var found = false
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mp = obj["modelPricing"] as? [String: Any] else { continue }
            found = true
            if let m = mp["multiplier"] as? Double, m > 0, m <= 10 { multiplier = m }
            if let ov = mp["overrides"] as? [String: Any] {
                for (k, v) in ov {
                    guard let r = v as? [String: Any],
                          let i = r["input"] as? Double, let o = r["output"] as? Double,
                          let cr = r["cacheRead"] as? Double, let cw = r["cacheWrite"] as? Double else { continue }
                    rows[ClaudePriceBook.normalize(k)] = ClaudeRate(input: i, output: o, cacheWrite5m: cw,
                                                                    cacheWrite1h: cw, cacheRead: cr)
                }
            }
        }
        return (rows, multiplier, found)
    }
}

// MARK: - Store

/// Aggregates every Claude Code transcript under `~/.claude/projects` on this
/// Mac into per-day, per-model token totals, then rolls them up by week /
/// month / year / all time and prices them with the current price book.
/// Dedupes streamed duplicates by message id + request id. Per-file results
/// are cached (`~/.sandshell/claude-usage-cache.json`) keyed by mtime + size so
/// a refresh only re-parses transcripts that changed.
///
/// Scope: transcripts on the host only. Sessions launched by Sandshell write
/// here (CLAUDE_CONFIG_DIR points at the host ~/.claude); sessions started with
/// plain `sbx run` keep theirs in the container's volumes and aren't counted.
@MainActor
final class ClaudeUsageStore: ObservableObject {
    static let shared = ClaudeUsageStore()

    @Published private(set) var totals: [ClaudeUsagePeriod: ClaudeUsageTotals] = [:]
    /// Per-period, per-model totals (model ids normalised, snapshots kept distinct).
    @Published private(set) var byModel: [ClaudeUsagePeriod: [String: ClaudeUsageTotals]] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isScanning = false
    @Published private(set) var transcriptCount = 0
    @Published private(set) var pricingSource = ClaudePriceBook.fallback.source
    /// Whole-conversation totals keyed by Claude session id (= transcript file
    /// name), priced like the period totals. Claude Code's own `cost` block
    /// only covers the current process, so it reads $0 after a `--resume`.
    @Published private(set) var sessionTotals: [String: ClaudeUsageTotals] = [:]

    /// Per-transcript cache entry: local day → model id → token totals.
    struct FileState: Codable, Sendable {
        var mtime: TimeInterval
        var size: Int
        var days: [String: [String: ClaudeUsageTotals]]
    }
    private struct Cache: Codable, Sendable {
        var version: Int
        var files: [String: FileState]
    }
    private static let cacheVersion = 2

    private var files: [String: FileState] = [:]
    private var priceBook = ClaudePriceBook.fallback
    private var scanTask: Task<Void, Never>?
    private var sessionFiles: [String: FileState] = [:]
    private var sessionScans: Set<String> = []
    private var sessionRescan: Set<String> = []
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var cacheURL: URL { home.appendingPathComponent(".sandshell/claude-usage-cache.json") }
    private var feedCacheURL: URL { home.appendingPathComponent(".sandshell/model-prices.json") }

    private init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.version == Self.cacheVersion {
            files = cache.files
            recomputeTotals()
            ClaudeModelCatalog.shared.setUsedModels(Array(byModel[.month, default: [:]].keys))
        }
    }

    /// Rescan changed transcripts and refresh prices. Cheap when nothing
    /// changed; skipped while a scan is running, and (unless forced) when the
    /// last one is under 60s old.
    func refresh(force: Bool = false) {
        guard scanTask == nil else { return }
        if !force, let last = lastUpdated, Date().timeIntervalSince(last) < 60 { return }
        isScanning = true
        let home = self.home
        let cached = self.files
        let feedCacheURL = self.feedCacheURL
        scanTask = Task { [weak self] in
            let (fresh, book) = await Task.detached(priority: .utility) {
                let files = Self.scan(home: home, cached: cached)
                let book = await Self.buildPriceBook(home: home, feedCacheURL: feedCacheURL)
                return (files, book)
            }.value
            guard let self else { return }
            self.files = fresh
            self.priceBook = book
            self.pricingSource = book.source
            self.recomputeTotals()
            self.recomputeSessionTotals()
            ClaudeModelCatalog.shared.setUsedModels(Array(self.byModel[.month, default: [:]].keys))
            self.lastUpdated = Date()
            self.isScanning = false
            self.scanTask = nil
            self.persist()
        }
    }

    private nonisolated static func buildPriceBook(home: URL, feedCacheURL: URL) async -> ClaudePriceBook {
        var book = ClaudePriceBook.fallback
        var parts: [String] = []
        if let feed = await ClaudePriceSources.loadFeed(cacheURL: feedCacheURL) {
            if let models = feed.models {
                await MainActor.run { ClaudeModelCatalog.shared.setFeedModels(models) }
            }
            // Feed rows win over built-in rows for the same key; built-in fills gaps.
            book.rates = ClaudePriceBook.builtIn.merging(feed.rates) { _, feed in feed }
            let age = Date().timeIntervalSince(feed.fetchedAt)
            parts.append("LiteLLM feed (\(ClaudeStatsFormat.duration(age * 1000)) old)")
        } else {
            parts.append("built-in list prices")
        }
        let ov = ClaudePriceSources.loadOverrides(home: home)
        if ov.found {
            book.overrides = ov.rows
            book.multiplier = ov.multiplier
            var s = "modelPricing"
            if !ov.rows.isEmpty { s += " \(ov.rows.count) row\(ov.rows.count == 1 ? "" : "s")" }
            if ov.multiplier != 1 { s += String(format: " ×%.2f", ov.multiplier) }
            parts.insert(s, at: 0)
        }
        parts.insert(ClaudePriceBook.companyCalibrationLabel, at: ov.found ? 1 : 0)
        book.source = parts.joined(separator: " + ")
        return book
    }

    /// Re-read one session's transcript if it changed since the last read.
    /// Called on every status report; coalesces while a read is in flight.
    func refreshSession(_ id: String) {
        guard !id.isEmpty else { return }
        if sessionScans.contains(id) { sessionRescan.insert(id); return }
        sessionScans.insert(id)
        let home = self.home
        let old = sessionFiles[id]
        Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) { Self.readSession(id, home: home, old: old) }.value
            guard let self else { return }
            self.sessionScans.remove(id)
            if let fresh, fresh.mtime != old?.mtime || fresh.size != old?.size {
                self.sessionFiles[id] = fresh
                self.recomputeSessionTotals()
            }
            if self.sessionRescan.remove(id) != nil { self.refreshSession(id) }
        }
    }

    private func recomputeSessionTotals() {
        var out: [String: ClaudeUsageTotals] = [:]
        for (id, state) in sessionFiles {
            var sum = ClaudeUsageTotals()
            for models in state.days.values {
                for (model, tokens) in models {
                    var t = tokens
                    if let rate = priceBook.rate(for: model) { t.costUSD = rate.cost(t) } else { t.unpriced = t.messages }
                    sum += t
                }
            }
            out[id] = sum
        }
        sessionTotals = out
    }

    /// `~/.claude/projects/<project>/<id>.jsonl`, parsed unless unchanged from `old`.
    private nonisolated static func readSession(_ id: String, home: URL, old: FileState?) -> FileState? {
        let fm = FileManager.default
        let projects = home.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let url = dir.appendingPathComponent("\(id).jsonl")
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = attrs.contentModificationDate?.timeIntervalSince1970,
                  let size = attrs.fileSize else { continue }
            if let old, old.mtime == mtime, old.size == size { return old }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return FileState(mtime: mtime, size: size,
                             days: parse(url: url, iso: iso, isoPlain: ISO8601DateFormatter(), day: dayFormatter()))
        }
        return nil
    }

    private func persist() {
        let cache = Cache(version: Self.cacheVersion, files: files)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func recomputeTotals() {
        let cal = Calendar.current
        let now = Date()
        let fmt = Self.dayFormatter()
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now).map { fmt.string(from: $0.start) } ?? ""
        let monthStart = cal.dateInterval(of: .month, for: now).map { fmt.string(from: $0.start) } ?? ""
        let yearStart = cal.dateInterval(of: .year, for: now).map { fmt.string(from: $0.start) } ?? ""
        var out: [ClaudeUsagePeriod: ClaudeUsageTotals] = [:]
        var models: [ClaudeUsagePeriod: [String: ClaudeUsageTotals]] = [:]
        for p in ClaudeUsagePeriod.allCases { out[p] = ClaudeUsageTotals(); models[p] = [:] }
        func add(_ p: ClaudeUsagePeriod, _ model: String, _ t: ClaudeUsageTotals) {
            out[p]! += t
            models[p]![model, default: ClaudeUsageTotals()] += t
        }
        var rateCache: [String: ClaudeRate?] = [:]
        for state in files.values {
            for (day, models) in state.days {
                for (model, tokens) in models {
                    var t = tokens
                    let rate: ClaudeRate?
                    if let cached = rateCache[model] { rate = cached } else {
                        rate = priceBook.rate(for: model); rateCache[model] = rate
                    }
                    if let rate { t.costUSD = rate.cost(t) } else { t.unpriced = t.messages }
                    add(.all, model, t)
                    if day >= yearStart { add(.year, model, t) }
                    if day >= monthStart { add(.month, model, t) }
                    if day >= weekStart { add(.week, model, t) }
                }
            }
        }
        totals = out
        byModel = models
        transcriptCount = files.count
    }

    // MARK: Scanning (off the main actor)

    private nonisolated static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private nonisolated static func scan(home: URL, cached: [String: FileState]) -> [String: FileState] {
        let fm = FileManager.default
        let projects = home.appendingPathComponent(".claude/projects")
        guard let e = fm.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles]) else { return cached }
        var result: [String: FileState] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let day = dayFormatter()
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = attrs.contentModificationDate?.timeIntervalSince1970,
                  let size = attrs.fileSize else { continue }
            let key = url.path
            if let old = cached[key], old.mtime == mtime, old.size == size {
                result[key] = old
                continue
            }
            result[key] = FileState(mtime: mtime, size: size,
                                    days: parse(url: url, iso: iso, isoPlain: isoPlain, day: day))
        }
        return result
    }

    /// One transcript → day → model → token totals. Only `"type":"assistant"`
    /// lines carry usage; a streamed message can appear on several lines with
    /// the same message id + request id, so count each pair once.
    private nonisolated static func parse(url: URL, iso: ISO8601DateFormatter,
                                          isoPlain: ISO8601DateFormatter,
                                          day: DateFormatter) -> [String: [String: ClaudeUsageTotals]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var days: [String: [String: ClaudeUsageTotals]] = [:]
        var seen = Set<String>()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"type\":\"assistant\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            // Claude Code's own synthetic assistant messages carry no real usage.
            let model = message["model"] as? String ?? ""
            if model.isEmpty || model == "<synthetic>" { continue }
            let mid = message["id"] as? String ?? obj["uuid"] as? String ?? ""
            let rid = obj["requestId"] as? String ?? ""
            if !mid.isEmpty, !seen.insert("\(mid):\(rid)").inserted { continue }

            var t = ClaudeUsageTotals()
            t.messages = 1
            t.input = usage["input_tokens"] as? Int ?? 0
            t.output = usage["output_tokens"] as? Int ?? 0
            t.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let write = usage["cache_creation_input_tokens"] as? Int ?? 0
            // Split cache writes by TTL when Claude Code recorded the breakdown.
            if let cc = usage["cache_creation"] as? [String: Any] {
                t.cacheWrite1h = cc["ephemeral_1h_input_tokens"] as? Int ?? 0
                t.cacheWrite5m = max(0, write - t.cacheWrite1h)
            } else {
                t.cacheWrite5m = write
            }

            let stamp = obj["timestamp"] as? String ?? ""
            let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp) ?? Date(timeIntervalSince1970: 0)
            days[day.string(from: date), default: [:]][ClaudePriceBook.normalize(model), default: ClaudeUsageTotals()] += t
        }
        return days
    }
}
