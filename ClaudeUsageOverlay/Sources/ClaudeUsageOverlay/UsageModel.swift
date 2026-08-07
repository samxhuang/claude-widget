import Foundation
import BudgetMath
import ClaudeAPI

/// Holds the latest usage numbers pulled from claude.ai and formats them
/// for display. `now` is ticked by a lightweight timer so the "resets in
/// Xh Ym" labels count down live between network refreshes.
final class UsageModel: Observable {
    @Observed var sessionPercent: Int?
    @Observed var sessionResetsAt: Date?

    @Observed var weeklyPercent: Int?
    @Observed var weeklyResetsAt: Date?

    @Observed var isLoggedOut: Bool = false
    @Observed var lastError: String?
    @Observed var lastUpdated: Date?

    /// The account's dollar Spend Limit straight from the usage API
    /// (Enterprise / spend-capped plans), or nil on plans without one (Max/
    /// Pro). This is the authoritative figure Claude Desktop's usage tab shows
    /// — displayed as-is, never reconstructed from local token cost.
    @Observed var spendLimit: SpendLimit?

    @Observed var now: Date = Date()

    private static let sessionWindowDuration: TimeInterval = 5 * 3600
    private static let weeklyWindowDuration: TimeInterval = 7 * 24 * 3600

    func tick() {
        now = Date()
    }

    /// Projects where `percent` will land by `resetsAt` if usage keeps
    /// accruing at whatever rate it has so far this window: elapsed time is
    /// `windowDuration - remaining`, and the projection scales `percent` by
    /// `windowDuration / elapsed`. Nil in the first minute of a window,
    /// where a near-zero elapsed denominator would blow the projection up
    /// to something meaningless.
    private func estimatedPercent(percent: Int?, resetsAt: Date?, windowDuration: TimeInterval) -> Int? {
        guard let percent = percent, let resetsAt = resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining < windowDuration else { return nil }
        let elapsed = windowDuration - remaining
        guard elapsed > 60 else { return nil }
        let projected = Double(percent) * windowDuration / elapsed
        return Int(projected.rounded())
    }

    var sessionEstimatedPercent: Int? {
        estimatedPercent(percent: sessionPercent, resetsAt: sessionResetsAt, windowDuration: Self.sessionWindowDuration)
    }

    var weeklyEstimatedPercent: Int? {
        estimatedPercent(percent: weeklyPercent, resetsAt: weeklyResetsAt, windowDuration: Self.weeklyWindowDuration)
    }

    /// Field normalization (raw JSON → percents/dates) happens in the
    /// ClaudeAPI module; this model only republishes the typed report.
    /// Windows the API omitted keep their previous published values, same
    /// as the old dict-parsing behavior.
    func apply(report: UsageReport) {
        if report.session.percent != nil || report.session.resetsAt != nil {
            sessionPercent = report.session.percent
            sessionResetsAt = report.session.resetsAt
        }
        if report.weekly.percent != nil || report.weekly.resetsAt != nil {
            weeklyPercent = report.weekly.percent
            weeklyResetsAt = report.weekly.resetsAt
        }
        // Always reflect the current response: nil on Max/Pro (no spend block),
        // set on Enterprise. Every successful usage fetch carries the field.
        spendLimit = report.spendLimit
        lastUpdated = Date()
    }

    /// A display `BudgetWindow` for the API-provided spend limit, or nil when
    /// the plan has no active dollar limit. Lets the main usage rows render the
    /// authoritative spend with the same dollar-bar renderer as reconstructed
    /// budgets — but sourced from the API, no daemon/transcripts involved.
    ///
    /// The projection is computed HERE rather than carried by the payload: the
    /// usage API sends a bare spent/limit pair with no period and no rate. A
    /// monthly spend limit runs from the 1st of the month, which is the one
    /// assumption this makes — everything else (elapsed fraction, the
    /// calendar-vs-weekdays basis, the first-hour suppression) is the same
    /// math plan_fit.py applies to the budget windows it reconstructs.
    ///
    /// This used to return `projectedUsd: nil`, which read as a BUG at the
    /// row level: before the first usage fetch the monthly row falls back to
    /// the daemon-reconstructed window (which does project), so the projection
    /// dot appeared on launch and then vanished the moment the API answered
    /// and this window took over. Both sources must project, or neither.
    ///
    /// `pct` stays the API's own utilization figure, and the projected percent
    /// is that same figure scaled by the elapsed fraction — never
    /// spent/limit recomputed locally, so the dot can't disagree with the
    /// number printed next to it.
    func spendBudgetWindow(basis: BudgetProjectionBasis, timeZone: TimeZone) -> BudgetWindow? {
        guard let s = spendLimit, s.enabled, s.limitMinor > 0 else { return nil }
        let bounds = BudgetProjection.monthBounds(containing: now, timeZone: timeZone)
        let fraction = bounds.flatMap {
            BudgetProjection.elapsedFraction(start: $0.start, end: $0.end, now: now,
                                             basis: basis, timeZone: timeZone)
        }
        return BudgetWindow(
            limitUsd: s.limitAmount,
            spentUsd: s.spentAmount,
            pct: s.percent,
            projectedUsd: fraction.map { s.spentAmount / $0 },
            projectedPct: fraction.map { s.percent / $0 },
            periodStart: bounds?.start,
            periodEnd: bounds?.end,
            includesRemote: false,
            projectionBasis: basis.rawValue
        )
    }

    func resetText(for date: Date?) -> String {
        guard let date = date else { return "—" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "resets soon" }
        return "resets in \(DurationFormat.compact(interval))"
    }

    var lastUpdatedText: String {
        guard let lastUpdated = lastUpdated else { return "not yet updated" }
        let interval = now.timeIntervalSince(lastUpdated)
        if interval < 60 { return "updated just now" }
        let minutes = Int(interval) / 60
        return "updated \(minutes)m ago"
    }
}
