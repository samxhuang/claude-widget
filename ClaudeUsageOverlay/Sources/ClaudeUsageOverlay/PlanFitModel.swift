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

/// Parsed, defensively-decoded snapshot of ~/.claude-autoresume/usage/plan_fit.json.
/// Every field is optional except the ones structurally guaranteed by how we
/// build it — a missing/malformed key in the source JSON just means that
/// field (and, in the view, that row) is absent, never a crash.
struct PlanFitData {
    var currentPlan: String?
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
        guard let raw = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            DispatchQueue.main.async { self.data = nil }
            return
        }
        let parsed = Self.parse(json)
        DispatchQueue.main.async { self.data = parsed }
    }

    private static func parse(_ json: [String: Any]) -> PlanFitData {
        var d = PlanFitData()
        d.currentPlan = json["current_plan"] as? String

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
}
