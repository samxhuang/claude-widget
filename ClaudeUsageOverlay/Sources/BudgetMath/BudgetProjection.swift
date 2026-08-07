import Foundation

/// Which elapsed clock a dollar-budget projection extrapolates on
/// (config.json `budget.projection_basis`).
///
/// The Swift twin of plan_fit.py's `BUDGET_PROJECTION_BASES`. Two independent
/// implementations exist on purpose: the daemon projects the budget windows it
/// reconstructs from local token cost, and the widget projects the API's own
/// Spend Limit (which arrives as a bare spent/limit pair with no period and no
/// rate). Both must answer "how far through the period are we" the same way,
/// or the same account would read differently depending on which source fed
/// the bar.
public enum BudgetProjectionBasis: String, Equatable {
    /// Every hour of the period counts.
    case calendar
    /// Only Mon–Fri hours count, on BOTH sides of the elapsed/total ratio, so
    /// a weekday-only workload isn't projected as if the weekend were going to
    /// carry spend. Weekend spend still counts toward the total — only the
    /// extrapolation changes.
    case weekdays

    /// Anything unrecognized (an old or hand-edited config) reads as
    /// `.calendar`, matching autoresume_config's fallback.
    public init(configValue: String?) {
        self = BudgetProjectionBasis(rawValue: configValue ?? "") ?? .calendar
    }
}

/// Pure date math for dollar-budget projections. No I/O, no UI, no clock of
/// its own — `now` is always passed in, which is what makes it testable.
public enum BudgetProjection {
    /// Mirrors plan_fit.BUDGET_PROJECTION_MIN_ELAPSED_SECONDS: under an hour
    /// of elapsed time (measured in whichever clock is in use) there is no
    /// rate worth quoting, so the projection is suppressed rather than
    /// computed against a near-zero denominator.
    public static let minElapsedSeconds: TimeInterval = 3600

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// The calendar month containing `date`, as [start, end) in `timeZone`.
    ///
    /// The API's Spend Limit payload carries no period at all — this is the
    /// widget's stated assumption that a monthly spend limit runs from the 1st
    /// of the month. nil only if the calendar can't build the bounds, which
    /// callers treat as "no projection" rather than guessing.
    public static func monthBounds(containing date: Date, timeZone: TimeZone) -> (start: Date, end: Date)? {
        let cal = gregorian(timeZone)
        let comps = cal.dateComponents([.year, .month], from: date)
        guard let start = cal.date(from: comps),
              let end = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// Seconds of [from, to) falling on a Mon–Fri date in `timeZone`.
    ///
    /// Walks whole calendar days and intersects each with the interval, so a
    /// DST day is counted at its true 23/25h length (`date(byAdding: .day)`
    /// lands on the next local midnight, not +86400s). 0 for an empty or
    /// inverted interval.
    public static func weekdaySeconds(from: Date, to: Date, timeZone: TimeZone) -> TimeInterval {
        guard to > from else { return 0 }
        let cal = gregorian(timeZone)
        var dayStart = cal.startOfDay(for: from)
        var total: TimeInterval = 0
        while dayStart < to {
            guard let next = cal.date(byAdding: .day, value: 1, to: dayStart), next > dayStart else { break }
            // Calendar weekday: 1 = Sunday … 7 = Saturday.
            let weekday = cal.component(.weekday, from: dayStart)
            if weekday >= 2 && weekday <= 6 {
                let lo = max(dayStart, from)
                let hi = min(next, to)
                if hi > lo { total += hi.timeIntervalSince(lo) }
            }
            dayStart = next
        }
        return total
    }

    /// How far through [start, end) `now` is, on the given basis: 0…1, or nil
    /// when there isn't enough elapsed time to extrapolate from (under
    /// `minElapsedSeconds` in the active clock — e.g. a month opening on a
    /// Saturday has no weekday time until Monday), or when the period is
    /// degenerate.
    public static func elapsedFraction(start: Date, end: Date, now: Date,
                                       basis: BudgetProjectionBasis,
                                       timeZone: TimeZone) -> Double? {
        guard end > start, now > start else { return nil }
        let cappedNow = min(now, end)
        let elapsed: TimeInterval
        let total: TimeInterval
        switch basis {
        case .calendar:
            elapsed = cappedNow.timeIntervalSince(start)
            total = end.timeIntervalSince(start)
        case .weekdays:
            elapsed = weekdaySeconds(from: start, to: cappedNow, timeZone: timeZone)
            total = weekdaySeconds(from: start, to: end, timeZone: timeZone)
        }
        guard elapsed >= minElapsedSeconds, total > 0 else { return nil }
        return elapsed / total
    }

    /// Where a value accruing at the rate observed so far lands by `end`.
    /// nil whenever `elapsedFraction` is nil.
    public static func project(_ value: Double, start: Date, end: Date, now: Date,
                               basis: BudgetProjectionBasis,
                               timeZone: TimeZone) -> Double? {
        guard let fraction = elapsedFraction(start: start, end: end, now: now,
                                             basis: basis, timeZone: timeZone),
              fraction > 0 else { return nil }
        return value / fraction
    }
}
