import Foundation
import Combine

/// One moving-average window from plan_fit.json's `moving_averages` object
/// (keys "1d" / "7d" / "30d" / "90d"). `daysCovered` < `windowDays` means the
/// window is still filling up — the collector hasn't been running long
/// enough yet for the average to reflect a full window.
struct MovingAverageWindow {
    var valuePerDay: Double?
    var daysCovered: Int?
    var windowDays: Int?
}

/// One plan's line in plan_fit.json's `verdict.plans` object.
struct TierVerdict {
    var key: String
    var name: String
    var priceUsd: Double?
    var apiEquivRatio: Double?
    var projectedPeak7dUtil: Double?
    var projectedPeak5hUtil: Double?
    var viable: Bool
    var hasPeakData: Bool

    /// The backend's own `viable` flag is the primary signal, but we also
    /// flag locally if a projected peak utilization is over 100% even when
    /// `viable` wasn't (yet) updated to reflect it — belt and suspenders,
    /// since this is exactly the number a Max-20x user cares about most.
    var isFlagged: Bool {
        if !viable { return true }
        if let p5 = projectedPeak5hUtil, p5 > 100 { return true }
        if let p7 = projectedPeak7dUtil, p7 > 100 { return true }
        return false
    }
}

/// One budget period (weekly or monthly) from plan_fit.json's `budget` block
/// (contract C2). `nil` for the whole struct means the period is unconfigured
/// — the Python side emits `"weekly": null` / `"monthly": null` when there's
/// no dollar limit set, and old daemon builds emit no `budget` key at all;
/// both cases must degrade to today's percentage-bar UI (see PlanFitData.hasBudget).
///
/// `projected*` are `null` in the first hour of a period (too little elapsed
/// time to extrapolate) — decoded here as `nil`, which the view renders as no
/// projection dot / no "(N%)" annotation, exactly as UsageModel does for a
/// just-opened usage window.
struct BudgetWindow {
    var limitUsd: Double?
    var spentUsd: Double?
    var pct: Double?
    var projectedUsd: Double?
    var projectedPct: Double?
    var periodStart: Date?
    var periodEnd: Date?
    /// Whether the spend total already folds in remote-host Claude Code usage
    /// (WS-6). Purely informational for the widget — display-only.
    var includesRemote: Bool
}

/// Parsed, defensively-decoded snapshot of ~/.claude-autoresume/usage/plan_fit.json.
/// Every field is optional except the ones structurally guaranteed by how we
/// build it — a missing/malformed key in the source JSON just means that
/// field (and, in the view, that row) is absent, never a crash.
struct PlanFitData {
    var currentPlan: String?
    /// Contract C2's `account` block. `accountType` is `"max"` / `"api"`
    /// (config-sourced), `accountPlan` mirrors `current_plan` for API-tier
    /// comparison math. Both `nil` for an old daemon build with no `account`
    /// key — callers treat a nil/`"max"` type as today's Max-plan UI.
    var accountType: String?
    var accountPlan: String?
    var movingAverages: [String: MovingAverageWindow] = [:]
    var monthlyRunRateUsd: Double?
    var monthlyRunRateBasis: String?
    var peakOneHourUsd: Double?
    var peakFiveHourUsd: Double?
    var utilFiveHourPeakPct: Double?
    var utilSevenDayPeakPct: Double?
    var tiers: [TierVerdict] = []
    var recommendation: String?
    var dataMaturity: String?
    /// Contract C2 budget block. Either can be `nil` (period unconfigured or
    /// old daemon build with no `budget` key).
    var budgetWeekly: BudgetWindow?
    var budgetMonthly: BudgetWindow?

    /// True when this account is API-billed (config account.type == "api").
    /// Drives mainTabContent's dollar-budget-bars-instead-of-percent gating
    /// and planFitTabContent's tier-grid-hidden layout. A missing/`"max"`
    /// account block reads false ⇒ exactly today's UI.
    var isApiAccount: Bool { accountType == "api" }

    /// Whether at least one budget period is configured (has a dollar limit).
    /// API accounts with no budget set render the "No budget set" prompt
    /// instead of bars.
    var hasBudget: Bool {
        (budgetWeekly?.limitUsd != nil) || (budgetMonthly?.limitUsd != nil)
    }
}

/// Reads ~/.claude-autoresume/usage/plan_fit.json — written hourly by the
/// Python usage daemon — and republishes it for OverlayView's "Plan fit"
/// section. Purely a reader: this widget never writes plan_fit.json.
final class PlanFitModel: ObservableObject {
    @Published var data: PlanFitData?

    private let fileURL: URL

    static let planDisplayNames: [String: String] = [
        "pro": "Pro",
        "max_5x": "Max 5x",
        "max_20x": "Max 20x"
    ]

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-autoresume")
            .appendingPathComponent("usage")
        self.fileURL = dir.appendingPathComponent("plan_fit.json")
    }

    /// Re-reads plan_fit.json. Safe to call on a timer even though the
    /// backing file is only written hourly — a missing or unparsable file
    /// (daemon hasn't run yet, mid-write, etc.) just clears `data`, which
    /// the view renders as "collecting data…" rather than an error.
    func refresh() {
        lastSeenMtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? nil
        guard let raw = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            DispatchQueue.main.async { self.data = nil }
            return
        }
        let parsed = Self.parse(json)
        DispatchQueue.main.async { self.data = parsed }
    }

    /// mtime of plan_fit.json at the last `refresh()`. Used by
    /// `refreshIfChanged()` so cheap high-frequency lanes (30s UI tick,
    /// post-config-change burst) can poll without re-parsing an unchanged
    /// file.
    private var lastSeenMtime: Date?

    /// `refresh()` only if plan_fit.json's mtime moved since the last read —
    /// a single stat() in the common no-change case. A missing file counts as
    /// changed only if we previously had data (so it clears once, not every
    /// tick).
    func refreshIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? nil
        if mtime == lastSeenMtime { return }
        refresh()
    }

    private static func parse(_ json: [String: Any]) -> PlanFitData {
        var d = PlanFitData()
        d.currentPlan = json["current_plan"] as? String

        // Contract C2: new `account` block. Backward compatible — an old
        // plan_fit.json without this key leaves both nil, and isApiAccount
        // (accountType == "api") then reads false, so the whole account is
        // treated as a Max plan exactly as before.
        if let account = json["account"] as? [String: Any] {
            d.accountType = account["type"] as? String
            d.accountPlan = account["plan"] as? String
        }

        // Contract C2: new `budget` block. Each period is `null` when
        // unconfigured (decoded as nil here) and the whole block is absent on
        // old daemon builds — both leave budgetWeekly/budgetMonthly nil, which
        // hasBudget/mainTabContent read as "no budget bars, show today's UI".
        if let budget = json["budget"] as? [String: Any] {
            d.budgetWeekly = parseBudget(budget["weekly"])
            d.budgetMonthly = parseBudget(budget["monthly"])
        }

        if let ma = json["moving_averages"] as? [String: Any] {
            for key in ["1d", "7d", "30d", "90d"] {
                guard let w = ma[key] as? [String: Any] else { continue }
                d.movingAverages[key] = MovingAverageWindow(
                    valuePerDay: doubleValue(w["value_usd_per_day"]),
                    daysCovered: intValue(w["days_covered"]),
                    windowDays: intValue(w["window_days"])
                )
            }
        }

        if let mrr = json["monthly_run_rate"] as? [String: Any] {
            d.monthlyRunRateUsd = doubleValue(mrr["value_usd_per_month"])
            d.monthlyRunRateBasis = mrr["basis"] as? String
        }

        if let peaks = json["cost_peaks"] as? [String: Any] {
            if let oh = peaks["one_hour"] as? [String: Any] {
                d.peakOneHourUsd = doubleValue(oh["value_usd"])
            }
            if let fh = peaks["rolling_five_hour"] as? [String: Any] {
                d.peakFiveHourUsd = doubleValue(fh["value_usd"])
            }
        }

        if let util = json["utilization_observed"] as? [String: Any] {
            if let five = util["five_hour"] as? [String: Any] {
                d.utilFiveHourPeakPct = doubleValue(five["peak_pct"])
            }
            if let seven = util["seven_day"] as? [String: Any] {
                d.utilSevenDayPeakPct = doubleValue(seven["peak_pct"])
            }
        }

        if let verdict = json["verdict"] as? [String: Any] {
            d.recommendation = verdict["recommendation"] as? String
            d.dataMaturity = verdict["data_maturity"] as? String
            if let plans = verdict["plans"] as? [String: Any] {
                for key in ["pro", "max_5x", "max_20x"] {
                    guard let p = plans[key] as? [String: Any] else { continue }
                    d.tiers.append(TierVerdict(
                        key: key,
                        name: planDisplayNames[key] ?? key,
                        priceUsd: doubleValue(p["price_usd"]),
                        apiEquivRatio: doubleValue(p["api_equiv_ratio"]),
                        projectedPeak7dUtil: doubleValue(p["projected_peak_7d_util"]),
                        projectedPeak5hUtil: doubleValue(p["projected_peak_5h_util"]),
                        viable: p["viable"] as? Bool ?? true,
                        hasPeakData: p["has_peak_data"] as? Bool ?? false
                    ))
                }
            }
        }

        return d
    }

    /// One period out of the `budget` block. Returns nil when the value is
    /// JSON `null`/absent/malformed (period unconfigured), so hasBudget
    /// reflects only genuinely-configured periods.
    private static func parseBudget(_ any: Any?) -> BudgetWindow? {
        guard let b = any as? [String: Any] else { return nil }
        return BudgetWindow(
            limitUsd: doubleValue(b["limit_usd"]),
            spentUsd: doubleValue(b["spent_usd"]),
            pct: doubleValue(b["pct"]),
            projectedUsd: doubleValue(b["projected_usd"]),
            projectedPct: doubleValue(b["projected_pct"]),
            periodStart: dateValue(b["period_start"]),
            periodEnd: dateValue(b["period_end"]),
            includesRemote: b["includes_remote"] as? Bool ?? false
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFraction = ISO8601DateFormatter()

    /// Period bounds arrive as ISO8601 strings (C2's "..." placeholders), but
    /// tolerate an epoch number too — same defensive spirit as doubleValue.
    private static func dateValue(_ any: Any?) -> Date? {
        if let s = any as? String {
            return isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
        }
        if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        return nil
    }

    // MARK: - Display formatting

    func displayName(forPlanKey key: String) -> String {
        Self.planDisplayNames[key] ?? key
    }

    /// "7d: $103.72/day (2/7 days)" — coverage annotation only appears when
    /// the window hasn't fully filled yet.
    func movingAverageLine(key: String, window: MovingAverageWindow) -> String {
        let valueText = window.valuePerDay.map { String(format: "$%.2f/day", $0) } ?? "—"
        var line = "\(key): \(valueText)"
        if let covered = window.daysCovered, let total = window.windowDays, covered < total {
            line += " (\(covered)/\(total) days)"
        }
        return line
    }

    private static let thousandsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    /// "API equivalent: $2,786.17/mo (basis: 7d)"
    func apiEquivalentText(_ data: PlanFitData) -> String? {
        guard let v = data.monthlyRunRateUsd else { return nil }
        let numStr = Self.thousandsFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
        var s = "API equivalent: $\(numStr)/mo"
        if let basis = data.monthlyRunRateBasis {
            s += " (basis: \(basis))"
        }
        return s
    }

    /// "5h $30.79" / "5h 24%" — one cell of the peaks grid (item 6). `spec`
    /// is a single-value format string (`"$%.2f"` or `"%.0f%%"`); returns
    /// "label —" when the value itself is missing, so the row's column
    /// alignment holds even with partial data.
    func formatPeak(_ label: String, _ spec: String, _ value: Double?) -> String {
        guard let value = value else { return "\(label) —" }
        return "\(label) " + String(format: spec, value)
    }

    func priceText(_ tier: TierVerdict) -> String? {
        guard let price = tier.priceUsd else { return nil }
        return "$\(Int(price))"
    }

    /// "163×" — the tier's price expressed as a multiple of what the same
    /// usage would cost metered through the API. Item 4a: the "× API"
    /// column header (see OverlayView.tierGrid) supplies the "of API value"
    /// half of the label so each cell can stay this short.
    func ratioText(_ tier: TierVerdict) -> String? {
        guard let ratio = tier.apiEquivRatio else { return nil }
        return String(format: "%.0f×", ratio)
    }

    // MARK: - Budget display formatting

    /// "$61.34 / $200" — spent vs. limit for a budget bar's caption. Spent
    /// keeps cents (it's the live, moving number the user watches); the limit
    /// shows whole dollars when it's a round figure (most budgets are) and
    /// cents otherwise. Missing spend reads as "$0.00"; a period with no
    /// limit shouldn't reach here (hasBudget gates it), but degrades to
    /// "$X / —" rather than crashing if it does.
    func budgetSpentText(_ w: BudgetWindow) -> String {
        let spent = String(format: "$%.2f", w.spentUsd ?? 0)
        guard let limit = w.limitUsd else { return "\(spent) / —" }
        let limitText = (limit == limit.rounded())
            ? String(format: "$%.0f", limit)
            : String(format: "$%.2f", limit)
        return "\(spent) / \(limitText)"
    }

    /// The integer percent for reusing OverlayView.row(...)'s bar — pct is a
    /// Double in the JSON, the bar takes Int. nil when the period reports no
    /// pct (e.g. limit present but spend not yet computed).
    func budgetPct(_ w: BudgetWindow) -> Int? {
        w.pct.map { Int($0.rounded()) }
    }

    /// Integer projected percent for the bar's projection dot / "(N%)"
    /// annotation. nil in the first hour of a period (Python suppresses it),
    /// which row(...) renders as no dot, same as UsageModel's first-minute
    /// suppression.
    func budgetProjectedPct(_ w: BudgetWindow) -> Int? {
        w.projectedPct.map { Int($0.rounded()) }
    }

    /// "resets in 3d 4h" from a period's `period_end`, reusing the same
    /// DurationFormat every other countdown in the widget uses. `now` is
    /// passed in (PlanFitModel holds no clock of its own) so the caller can
    /// tick it off the shared UI timer. nil period_end ⇒ no countdown text.
    func budgetResetText(_ w: BudgetWindow, now: Date) -> String {
        guard let end = w.periodEnd else { return "" }
        let interval = end.timeIntervalSince(now)
        if interval <= 0 { return "resets now" }
        return "resets in \(DurationFormat.compact(interval))"
    }

    /// When the linear projection lands past the limit: "proj $612 (+$112)" —
    /// the dollar figure the period is on track to reach and how far over the
    /// budget that is. nil when there's no projection or it's within budget,
    /// so callers can append it only in the overrun case. Whole dollars — a
    /// projection is an estimate, cents would be false precision.
    /// R2-4: the guard and the display round the overrun ONCE, together, and
    /// require the rounded value to be a nonzero whole dollar. The previous
    /// `>= 0.5` threshold admitted exactly $0.50, which "%.0f" (banker's
    /// rounding, half-to-even) rendered as "+$0" — an overrun caption whose
    /// displayed numbers say there's no overrun. Rendering the pre-rounded
    /// `overDollars` keeps the guard and the shown figure agreeing by
    /// construction, whatever rounding mode either uses.
    func budgetOverrunText(_ w: BudgetWindow) -> String? {
        guard let projected = w.projectedUsd, let limit = w.limitUsd else { return nil }
        let overDollars = (projected - limit).rounded()
        guard overDollars >= 1 else { return nil }
        let proj = String(format: "$%.0f", projected)
        let over = String(format: "$%.0f", overDollars)
        return "proj \(proj) (+\(over))"
    }

    /// Compact one-liner for the Plan-fit tab's API-account budget summary,
    /// e.g. "Weekly $61 / $200 (31%)", plus the projected overrun when the
    /// period is on track to blow through the limit. Whole dollars only — the
    /// tab is a reference view, not the live bar. Returns nil when the period
    /// is unconfigured so the caller can omit the line.
    func budgetSummaryLine(label: String, window: BudgetWindow?) -> String? {
        guard let w = window, let limit = w.limitUsd else { return nil }
        let spent = String(format: "$%.0f", w.spentUsd ?? 0)
        let limitText = String(format: "$%.0f", limit)
        var line = "\(label) \(spent) / \(limitText)"
        if let pct = w.pct {
            line += String(format: " (%.0f%%)", pct)
        }
        // No trailing "over": budgetOverrunText's "(+$N)" parenthetical
        // already says how far over — "proj $612 (+$112) over" read as if
        // "(+$112) over" were one phrase.
        if let overrun = budgetOverrunText(w) {
            line += " — \(overrun)"
        }
        return line
    }
}
