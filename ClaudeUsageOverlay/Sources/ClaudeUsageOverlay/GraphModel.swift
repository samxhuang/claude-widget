import Foundation

/// Which top-level content the panel shows below the header.
enum PanelTab: String {
    case main
    case graph
    case planFit
}

/// Segmented period picker inside the Graph tab. Each case owns the target
/// bucket width for the utilization chart, chosen so a full period
/// downsamples to at most ~300 drawn points.
enum GraphPeriod: String, CaseIterable, Identifiable {
    // First in declaration order = first in GraphPeriod.allCases = first
    // (leftmost) segment in both period pickers. 5h matches Claude's
    // five-hour rate-limit window, making it the natural "current session"
    // view — hence it leads.
    case fiveHour = "5h"
    case day = "24h"
    case week = "7d"
    case month = "1mo"
    case threeMonth = "3mo"

    var id: String { rawValue }

    var durationSeconds: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        case .threeMonth: return 90 * 24 * 3600
        }
    }

    var utilBucketSeconds: TimeInterval {
        switch self {
        // Raw snapshots land roughly every 2 minutes (SnapshotLogger's
        // minInterval), so 2-min buckets are the finest granularity that
        // actually exists — a 5h window is ~150 of them, well under the
        // ~300-point downsampling target, so this never over-aggregates.
        case .fiveHour: return 2 * 60     // ~150 buckets
        case .day: return 5 * 60          // ~288 buckets
        case .week: return 30 * 60        // ~336 buckets
        case .month: return 3 * 3600      // ~240 buckets
        case .threeMonth: return 8 * 3600 // ~270 buckets
        }
    }

    /// 3mo cost is plotted from the daily series (forever-retained) at
    /// $/day; everything shorter is plotted from the hourly series at $/hr.
    var costUnitLabel: String {
        self == .threeMonth ? "$/day" : "$/hr"
    }
}

/// One plotted point on the utilization mini-chart. `fiveMax`/`sevenMax` are
/// drawn as dimmer lines above the avg lines so peaks survive downsampling —
/// that's the whole point of the graph.
struct UtilBucket: Identifiable {
    let id = UUID()
    var date: Date
    /// This bucket's actual width in seconds — i.e. it covers
    /// [date, date + bucketSeconds). Item 2: threaded through from wherever
    /// each bucket is built below (rather than the hover readout guessing a
    /// width from pixel distance), so the readout's displayed range always
    /// matches the granularity actually rendered. Usually equal to the
    /// period's nominal `utilBucketSeconds`, but the trailing bucket of a
    /// period is clamped to the real data window (typically "now"), so it
    /// carries its own possibly-shorter width instead of overstating one
    /// that hasn't happened yet.
    var bucketSeconds: TimeInterval
    var fiveAvg: Double?
    var fiveMax: Double?
    var sevenAvg: Double?
    var sevenMax: Double?
}

/// One plotted point on the API-equivalent-cost mini-chart.
struct CostBucket: Identifiable {
    let id = UUID()
    var date: Date
    /// This bucket's width in seconds (an hour, several hours, or a day —
    /// see hourlyCostBuckets/dailyCostBuckets below), threaded through for
    /// the same reason as UtilBucket.bucketSeconds.
    var bucketSeconds: TimeInterval
    var usd: Double
}

/// Reads the three tiered utilization jsonl files
/// (snapshots.jsonl / snapshots_15m.jsonl / snapshots_1h.jsonl) plus
/// plan_fit.json's `cost_series`, and republishes downsampled per-period
/// series for GraphView. Purely a reader — same spirit as PlanFitModel /
/// SessionsModel, this widget never writes any of these files.
final class GraphModel: Observable {
    private static let tabDefaultsKey = "panelTab"
    private static let periodDefaultsKey = "graphPeriod"

    /// The single UTC zone every bucket-key calendar/formatter below uses.
    ///
    /// Windows-port seam (docs/swift-windows-audit.md §1.4). These sites used
    /// to read `TimeZone(identifier: "UTC") ?? .current`, and the *fallback*
    /// was the landmine: `TimeZone.current` silently substitutes local time
    /// into UTC-keyed bucket math, so every daily/hourly key would shift by
    /// the local offset and the widget would look up `"2026-07-25"` for what
    /// the daemon wrote as `"2026-07-26"` — a $0 or off-by-one-day cost chart
    /// with no error anywhere. `TimeZone.current` is also actively buggy off
    /// Darwin (returns GMT on non-English Windows installs; concurrent use
    /// with `Calendar.current` corrupts the heap on Windows 11), and
    /// `refresh()` does parse work on a global queue while the main thread
    /// formats.
    ///
    /// The force-unwrap is safe unconditionally: `TimeZone(secondsFromGMT:)`
    /// constructs its zone arithmetically, with no tz-database or ICU lookup
    /// to fail, and an offset of 0 is always in range. That is the point of
    /// using it rather than an identifier lookup with a fallback.
    private static let utc = TimeZone(secondsFromGMT: 0)!

    @Observed var selectedTab: PanelTab {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.tabDefaultsKey) }
    }
    @Observed var period: GraphPeriod {
        didSet {
            UserDefaults.standard.set(period.rawValue, forKey: Self.periodDefaultsKey)
            recompute()
        }
    }

    @Observed var utilBuckets: [UtilBucket] = []
    @Observed var costBuckets: [CostBucket] = []
    @Observed var periodStart: Date = Date()
    @Observed var periodEnd: Date = Date()
    @Observed var latestFiveHour: Double?
    @Observed var latestSevenDay: Double?
    /// Muted "collecting since Jul 18" note shown when the earliest known
    /// data point covers less than half the selected period.
    @Observed var coverageNote: String?
    /// Header readout for the cost chart: the summed API-equivalent cost of
    /// the buckets actually plotted ("measured"), plus a linear full-period
    /// estimate when the cost data doesn't span the whole selected period
    /// (collection only started 2026-07-18, so the wider periods are partial
    /// for a while). e.g. "$18.42" (full coverage) or "$18.42 · est $210"
    /// (partial). nil when there's no cost data at all in the period.
    @Observed var costSummary: String?

    private let usageDir: URL
    private var lastToggleAt: Date = .distantPast

    // Cached raw parses from the last `refresh()`, recombined into
    // per-period buckets by `recompute()` without re-reading files — so
    // switching periods is instant even though refresh() itself hits disk.
    private var rawSnapshots: [(date: Date, five: Double?, seven: Double?)] = []
    private var bucket15m: [BucketRow] = []
    private var bucket1h: [BucketRow] = []
    private var hourlyCost: [Date: Double] = [:]
    private var dailyCost: [String: Double] = [:]
    private var earliestKnown: Date?

    struct BucketRow {
        var tsStart: Date
        var fiveAvg: Double?
        var fiveMax: Double?
        var sevenAvg: Double?
        var sevenMax: Double?
    }

    override init() {
        self.selectedTab = UserDefaults.standard.string(forKey: Self.tabDefaultsKey).flatMap(PanelTab.init) ?? .main
        self.period = UserDefaults.standard.string(forKey: Self.periodDefaultsKey).flatMap(GraphPeriod.init) ?? .day

        self.usageDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-autoresume")
            .appendingPathComponent("usage")
        super.init()
    }

    /// Debounced the same way Sessions/Chats/PlanFit's toggles are — a click
    /// delivered twice in quick succession inside a non-activating panel
    /// would otherwise re-select the tab twice in one frame. Now a direct
    /// three-way select (Main / Graph / Plan fit) rather than a two-way
    /// toggle, since the Plan fit tab (item 3) added a third case to
    /// PanelTab.
    func selectTab(_ tab: PanelTab) {
        guard selectedTab != tab else { return }
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.35 else { return }
        lastToggleAt = now
        selectedTab = tab
    }

    /// Re-reads all four source files off the main thread and republishes
    /// the currently-selected period's downsampled series. Safe to call on
    /// a timer even though most of these files only update every couple of
    /// minutes (snapshots.jsonl) or hourly (the rest) — missing files (a
    /// tier that hasn't been produced yet, e.g. snapshots_15m.jsonl before
    /// the compactor's first pass) just parse as empty and are silently
    /// skipped, same defensive spirit as PlanFitModel.
    func refresh() {
        let dir = usageDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raw = Self.parseRawSnapshots(dir.appendingPathComponent("snapshots.jsonl"))
            let b15 = Self.parseBucketFile(dir.appendingPathComponent("snapshots_15m.jsonl"))
            let b1h = Self.parseBucketFile(dir.appendingPathComponent("snapshots_1h.jsonl"))
            let (hourly, daily) = Self.parseCostSeries(dir.appendingPathComponent("plan_fit.json"))

            var earliest: Date?
            for d in (raw.map { $0.date } + b15.map { $0.tsStart } + b1h.map { $0.tsStart }) {
                if earliest == nil || d < earliest! { earliest = d }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.rawSnapshots = raw
                self.bucket15m = b15
                self.bucket1h = b1h
                self.hourlyCost = hourly
                self.dailyCost = daily
                self.earliestKnown = earliest
                self.recompute()
            }
        }
    }

    // MARK: - Recompute (cheap: cached parses only, runs on period switch too)

    private func recompute() {
        let end = Date()
        let start = end.addingTimeInterval(-period.durationSeconds)
        periodStart = start
        periodEnd = end

        utilBuckets = Self.mergeUtilBuckets(
            start: start, end: end, bucketSeconds: period.utilBucketSeconds,
            raw: rawSnapshots, b15: bucket15m, b1h: bucket1h
        )

        costBuckets = period == .threeMonth
            ? Self.dailyCostBuckets(start: start, end: end, daily: dailyCost)
            : Self.hourlyCostBuckets(start: start, end: end, hourly: hourlyCost)
        // Total measured cost comes from the RAW series, not the plotted
        // buckets: multi-hour buckets hold a per-hour average (the chart is a
        // rate), so summing bucket.usd undercounts any period whose step is
        // wider than an hour — 1mo's 3h steps read as a third of the truth.
        let measuredCost: Double
        if period == .threeMonth {
            // Daily tier: include days from the UTC start-of-day containing
            // `start` (boundary day counted whole — the daily series has no
            // finer resolution; today the data starts long after the window
            // boundary so nothing is actually clipped or double-counted).
            // R2-6: fixed-format "yyyy-MM-dd" needs en_US_POSIX + an explicit
            // Gregorian calendar — under a non-Gregorian system calendar
            // (Buddhist/Japanese) "yyyy" goes era-relative (e.g. 2569),
            // firstKey would match no daemon-written key, and the 3mo cost
            // would read $0.
            let fmt = Self.utcDailyKeyFormatter()
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Self.utc
            let firstKey = fmt.string(from: cal.startOfDay(for: start))
            measuredCost = dailyCost.filter { $0.key >= firstKey }.values.reduce(0, +)
        } else {
            // Filter from the UTC hour-floor of `start`, not `start` itself:
            // hourlyCostBuckets' first bar starts at that hour-floor, so the
            // raw `key >= start` filter excluded the boundary hour the chart
            // plots and the header total came up short of the visible bars.
            // Counting the boundary hour whole is the deliberate parallel of
            // the 3mo boundary-day-counted-whole semantics above.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Self.utc
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: start)
            let hourFloor = cal.date(from: comps) ?? start
            measuredCost = hourlyCost
                .filter { $0.key >= hourFloor && $0.key < end }
                .values.reduce(0, +)
        }
        costSummary = Self.costSummaryText(
            measured: measuredCost, start: start, end: end,
            earliest: costDataEarliest(for: period), duration: period.durationSeconds)

        if let last = rawSnapshots.last {
            latestFiveHour = last.five
            latestSevenDay = last.seven
        } else if let lastBucket = utilBuckets.last(where: { $0.fiveAvg != nil }) {
            latestFiveHour = lastBucket.fiveAvg
            latestSevenDay = lastBucket.sevenAvg
        } else {
            latestFiveHour = nil
            latestSevenDay = nil
        }

        if let earliest = earliestKnown {
            let covered = end.timeIntervalSince(max(earliest, start))
            let coverage = covered / period.durationSeconds
            if coverage < 0.5 {
                let f = DateFormatter()
                f.dateFormat = "MMM d"
                coverageNote = "collecting since \(f.string(from: earliest))"
            } else {
                coverageNote = nil
            }
        } else {
            coverageNote = "collecting…"
        }
    }

    /// Earliest instant the cost series has any data for — the boundary
    /// between "measured $0 because nothing ran" and "no measurement exists".
    ///
    /// The anchor MUST share a source with the period's measured sum.
    /// plan_fit.py prunes `cost_series.hourly` to a rolling ~35-day window
    /// while `daily` is forever-retained, so once history exceeds 35 days the
    /// two series' minima diverge permanently. The 3mo view sums the FULL
    /// daily history; anchoring its coverage on the hourly min would then
    /// credit only ~35 of the 90 days as "covered", inflating the linear
    /// estimate ~2.6x and showing an "est" even at 100% real coverage. So:
    /// - .threeMonth: anchor on the daily series' min key, parsed as UTC
    ///   midnight — consistent with the boundary-day-counted-whole daily sum.
    /// - all other periods: the hour-resolution series is authoritative when
    ///   present. A daily key ("YYYY-MM-DD") can only parse as UTC midnight,
    ///   and taking min() across both series let that midnight shave hours
    ///   off the true start (first data 04:00 → 4 phantom hours of
    ///   "coverage"), quietly deflating the estimate relative to plan_fit's
    ///   hourly-anchored run rate. Daily midnight remains the fallback for
    ///   the (currently hypothetical) case of daily-only data.
    private func costDataEarliest(for period: GraphPeriod) -> Date? {
        if period == .threeMonth {
            return Self.dailyKeyDate(dailyCost.keys.min())
        }
        if let earliest = hourlyCost.keys.min() { return earliest }
        return Self.dailyKeyDate(dailyCost.keys.min())
    }

    /// "YYYY-MM-DD" daily-series key → UTC midnight of that day (nil in, nil out).
    private static func dailyKeyDate(_ key: String?) -> Date? {
        guard let key = key else { return nil }
        return utcDailyKeyFormatter().date(from: key)
    }

    /// R2-6: the one way "yyyy-MM-dd" daemon-key formatters are built —
    /// en_US_POSIX locale + explicit Gregorian calendar + UTC, so keys
    /// parse/format identically to plan_fit.py's regardless of the system
    /// locale/calendar (a bare DateFormatter inherits both, and a
    /// non-Gregorian calendar makes "yyyy" era-relative).
    private static func utcDailyKeyFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        f.calendar = cal
        f.timeZone = Self.utc
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// "$18.42" when the cost data spans the whole period, "$18.42 · est $210"
    /// when it starts partway through (linear scale-up of the measured sum to
    /// the full period — same extrapolation style as the budget projection).
    /// The estimate needs at least an hour of measured data (the budget
    /// projection's suppression rule) — an absolute floor, NOT a fraction of
    /// the period: a percent floor made the est vanish on exactly the wide
    /// periods (1mo/3mo) where collection-started-Jul-18 coverage is thinnest
    /// and the estimate is most wanted. nil when nothing is measured and
    /// nothing can be estimated.
    static func costSummaryText(measured: Double, start: Date, end: Date,
                                earliest: Date?, duration: TimeInterval) -> String? {
        guard let earliest = earliest, earliest < end, duration > 0 else { return nil }
        let text = "$" + Self.compactDollars(measured)
        let covered = end.timeIntervalSince(max(earliest, start))
        let coverage = covered / duration
        if coverage >= 0.98 { return text }
        guard covered >= 3600 else { return text }
        let estimate = measured / coverage
        return "\(text) · est $\(Self.compactDollars(estimate))"
    }

    /// "0.42" / "8.5" / "210" — decimals only where they carry information,
    /// mirroring GraphView's axis-label style.
    private static func compactDollars(_ v: Double) -> String {
        if v < 1 { return String(format: "%.2f", v) }
        if v < 10 { return String(format: "%.1f", v) }
        return String(format: "%.0f", v)
    }

    // MARK: - Parsing

    private static func parseRawSnapshots(_ url: URL) -> [(date: Date, five: Double?, seven: Double?)] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [(date: Date, five: Double?, seven: Double?)] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let tsStr = obj["ts"] as? String,
                  let date = parseDate(tsStr) else { continue }
            let five = doubleValue((obj["five_hour"] as? [String: Any])?["utilization"])
            let seven = doubleValue((obj["seven_day"] as? [String: Any])?["utilization"])
            out.append((date, five, seven))
        }
        return out.sorted { $0.date < $1.date }
    }

    private static func parseBucketFile(_ url: URL) -> [BucketRow] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [BucketRow] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let tsStr = obj["ts_start"] as? String,
                  let date = parseDate(tsStr) else { continue }
            let five = obj["five_hour"] as? [String: Any]
            let seven = obj["seven_day"] as? [String: Any]
            out.append(BucketRow(
                tsStart: date,
                fiveAvg: doubleValue(five?["avg"]),
                fiveMax: doubleValue(five?["max"]),
                sevenAvg: doubleValue(seven?["avg"]),
                sevenMax: doubleValue(seven?["max"])
            ))
        }
        return out.sorted { $0.tsStart < $1.tsStart }
    }

    private static func parseCostSeries(_ url: URL) -> ([Date: Double], [String: Double]) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cs = json["cost_series"] as? [String: Any] else { return ([:], [:]) }

        var hourly: [Date: Double] = [:]
        if let h = cs["hourly"] as? [String: Any] {
            for (key, val) in h {
                guard let date = parseDate(key), let v = doubleValue(val) else { continue }
                hourly[date] = v
            }
        }
        var daily: [String: Double] = [:]
        if let d = cs["daily"] as? [String: Any] {
            for (key, val) in d {
                guard let v = doubleValue(val) else { continue }
                daily[key] = v
            }
        }
        return (hourly, daily)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        return nil
    }

    // MARK: - Bucketing / merging

    /// Merges the three tiers into one series, preferring the finest tier
    /// with data in each output bucket: raw 2-min snapshots first, then the
    /// 15-min tier, then the 1-hour tier. A bucket with no data in any tier
    /// is simply omitted (a gap), rather than interpolated or zero-filled —
    /// unlike cost, "no reading yet" isn't the same as "zero utilization".
    private static func mergeUtilBuckets(
        start: Date, end: Date, bucketSeconds: TimeInterval,
        raw: [(date: Date, five: Double?, seven: Double?)],
        b15: [BucketRow], b1h: [BucketRow]
    ) -> [UtilBucket] {
        guard end > start else { return [] }
        var buckets: [UtilBucket] = []
        var t = start
        while t < end {
            let bEnd = min(t.addingTimeInterval(bucketSeconds), end)

            // The trailing bucket of a period is often clamped against `end`
            // (usually "now"), so its real width can be shorter than the
            // nominal bucketSeconds — carry the actual width, not the
            // nominal one, so a hover readout over it doesn't show a range
            // extending past "now".
            let actualWidth = bEnd.timeIntervalSince(t)

            let rawSlice = raw.filter { $0.date >= t && $0.date < bEnd }
            if !rawSlice.isEmpty {
                let fiveVals = rawSlice.compactMap { $0.five }
                let sevenVals = rawSlice.compactMap { $0.seven }
                buckets.append(UtilBucket(
                    date: t, bucketSeconds: actualWidth,
                    fiveAvg: average(fiveVals), fiveMax: fiveVals.max(),
                    sevenAvg: average(sevenVals), sevenMax: sevenVals.max()
                ))
            } else {
                let rows15 = b15.filter { $0.tsStart >= t && $0.tsStart < bEnd }
                if !rows15.isEmpty {
                    buckets.append(combineBucketRows(rows15, date: t, bucketSeconds: actualWidth))
                } else {
                    let rows1h = b1h.filter { $0.tsStart >= t && $0.tsStart < bEnd }
                    if !rows1h.isEmpty {
                        buckets.append(combineBucketRows(rows1h, date: t, bucketSeconds: actualWidth))
                    }
                    // else: no data at any tier for this time range — leave a gap.
                }
            }
            t = bEnd
        }
        return buckets
    }

    private static func combineBucketRows(_ rows: [BucketRow], date: Date, bucketSeconds: TimeInterval) -> UtilBucket {
        UtilBucket(
            date: date, bucketSeconds: bucketSeconds,
            fiveAvg: average(rows.compactMap { $0.fiveAvg }),
            fiveMax: rows.compactMap { $0.fiveMax }.max(),
            sevenAvg: average(rows.compactMap { $0.sevenAvg }),
            sevenMax: rows.compactMap { $0.sevenMax }.max()
        )
    }

    private static func average(_ vals: [Double]) -> Double? {
        vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    /// Hourly-resolution cost bars for the 24h/7d/1mo views, downsampled by
    /// grouping consecutive hours only when the raw hour count would exceed
    /// ~300 (only 1mo needs this — 24h and 7d fit within 300 hours as-is).
    /// A missing hour key means genuinely $0 spent, so it's zero-filled
    /// rather than skipped — that's what keeps the average an honest $/hr
    /// rate instead of silently ignoring idle hours.
    private static func hourlyCostBuckets(start: Date, end: Date, hourly: [Date: Double]) -> [CostBucket] {
        guard end > start else { return [] }
        let totalHours = max(1, Int(ceil(end.timeIntervalSince(start) / 3600)))
        let stepHours = max(1, Int(ceil(Double(totalHours) / 300.0)))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: start)
        var t = cal.date(from: comps) ?? start

        let stepSeconds = Double(stepHours) * 3600

        var out: [CostBucket] = []
        while t < end {
            var sum = 0.0
            var slots = 0
            for h in 0..<stepHours {
                let hourDate = t.addingTimeInterval(Double(h) * 3600)
                if hourDate >= end { break }
                sum += hourly[hourDate] ?? 0
                slots += 1
            }
            out.append(CostBucket(date: t, bucketSeconds: stepSeconds, usd: slots > 0 ? sum / Double(slots) : 0))
            t = t.addingTimeInterval(stepSeconds)
        }
        return out
    }

    /// Daily cost bars for the 3mo view, straight from the forever-retained
    /// daily series. Missing days are zero-filled for the same "genuinely
    /// idle" reason as hourlyCostBuckets.
    private static func dailyCostBuckets(start: Date, end: Date, daily: [String: Double]) -> [CostBucket] {
        guard end > start else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        // R2-6: same daemon-key formatter as the 3mo sum/dailyKeyDate — a
        // bare formatter's keys wouldn't match daily[...] under a
        // non-Gregorian system calendar and every bar would read $0.
        let fmt = utcDailyKeyFormatter()

        var t = cal.startOfDay(for: start)
        var out: [CostBucket] = []
        while t < end {
            let key = fmt.string(from: t)
            out.append(CostBucket(date: t, bucketSeconds: 86400, usd: daily[key] ?? 0))
            t = cal.date(byAdding: .day, value: 1, to: t) ?? t.addingTimeInterval(86400)
        }
        return out
    }
}
