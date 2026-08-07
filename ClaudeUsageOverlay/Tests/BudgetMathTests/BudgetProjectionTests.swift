import Foundation
import Testing
@testable import BudgetMath

/// The widget's half of the budget projection — the arithmetic that has to
/// agree with plan_fit.py's independent implementation (test_plan_fit.py's
/// BudgetProjectionBasisTests is the mirror of this file).
///
/// Calendar facts the cases below lean on:
///   July 2026 opens on a Wednesday and holds 23 weekdays of 31 days.
///   August 2026 opens on a Saturday and holds 21 weekdays of 31 days.
@Suite("Budget projection")
struct BudgetProjectionTests {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let newYork = TimeZone(identifier: "America/New_York")!

    /// A UTC instant, built without relying on the host's calendar settings.
    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0,
                   _ tz: TimeZone = utc) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - Month bounds

    @Test("month bounds run from the 1st to the 1st")
    func monthBounds() throws {
        let b = try #require(BudgetProjection.monthBounds(containing: Self.at(2026, 8, 6, 23, 32), timeZone: Self.utc))
        #expect(b.start == Self.at(2026, 8, 1))
        #expect(b.end == Self.at(2026, 9, 1))
    }

    @Test("month bounds land on LOCAL midnight, and absorb a DST transition")
    func monthBoundsLocal() throws {
        let march = try #require(BudgetProjection.monthBounds(containing: Self.at(2026, 3, 20, 12, 0, Self.newYork),
                                                             timeZone: Self.newYork))
        #expect(march.start == Self.at(2026, 3, 1, 0, 0, Self.newYork))
        // March in New York is 31 days minus the hour lost to DST.
        #expect(march.end.timeIntervalSince(march.start) == 31 * 86400 - 3600)
    }

    // MARK: - Weekday seconds

    @Test("weekday seconds count Mon–Fri only")
    func weekdaySecondsWholeMonths() {
        #expect(BudgetProjection.weekdaySeconds(from: Self.at(2026, 7, 1), to: Self.at(2026, 8, 1),
                                                timeZone: Self.utc) == 23 * 86400)
        #expect(BudgetProjection.weekdaySeconds(from: Self.at(2026, 8, 1), to: Self.at(2026, 9, 1),
                                                timeZone: Self.utc) == 21 * 86400)
    }

    @Test("a weekend contributes nothing; a partial weekday contributes its part")
    func weekdaySecondsPartials() {
        // Sat 07-04 00:00 → Mon 07-06 00:00 is pure weekend.
        #expect(BudgetProjection.weekdaySeconds(from: Self.at(2026, 7, 4), to: Self.at(2026, 7, 6),
                                                timeZone: Self.utc) == 0)
        // Six hours into Monday.
        #expect(BudgetProjection.weekdaySeconds(from: Self.at(2026, 7, 6), to: Self.at(2026, 7, 6, 6),
                                                timeZone: Self.utc) == 6 * 3600)
        // Fri 18:00 → Mon 06:00 keeps only Friday's tail and Monday's head.
        #expect(BudgetProjection.weekdaySeconds(from: Self.at(2026, 7, 3, 18), to: Self.at(2026, 7, 6, 6),
                                                timeZone: Self.utc) == 12 * 3600)
    }

    @Test("empty and inverted intervals are zero, never negative")
    func weekdaySecondsDegenerate() {
        let d = Self.at(2026, 7, 6, 9)
        #expect(BudgetProjection.weekdaySeconds(from: d, to: d, timeZone: Self.utc) == 0)
        #expect(BudgetProjection.weekdaySeconds(from: Self.at(2026, 7, 8), to: Self.at(2026, 7, 6),
                                                timeZone: Self.utc) == 0)
    }

    @Test("weekday-ness follows the given timezone, not the host's")
    func weekdaySecondsTimezoneSensitive() {
        // Sat 2026-07-04 03:00 UTC is still Fri 23:00 in New York, so the
        // same instants read as one weekday hour there and none in UTC.
        let from = Self.at(2026, 7, 4, 2)
        let to = Self.at(2026, 7, 4, 3)
        #expect(BudgetProjection.weekdaySeconds(from: from, to: to, timeZone: Self.utc) == 0)
        #expect(BudgetProjection.weekdaySeconds(from: from, to: to, timeZone: Self.newYork) == 3600)
    }

    // MARK: - Elapsed fraction

    @Test("calendar basis measures wall-clock elapsed over the whole period")
    func calendarFraction() throws {
        let f = try #require(BudgetProjection.elapsedFraction(
            start: Self.at(2026, 7, 1), end: Self.at(2026, 8, 1), now: Self.at(2026, 7, 16, 12),
            basis: .calendar, timeZone: Self.utc))
        #expect(abs(f - 15.5 / 31.0) < 1e-9)
    }

    @Test("weekdays basis divides weekday-elapsed by weekday-total")
    func weekdayFraction() throws {
        // Mon 07-06 12:00: 3.5 weekdays elapsed (07-01..03 plus half of 07-06)
        // of 23 — where the calendar basis would say 5.5 of 31.
        let f = try #require(BudgetProjection.elapsedFraction(
            start: Self.at(2026, 7, 1), end: Self.at(2026, 8, 1), now: Self.at(2026, 7, 6, 12),
            basis: .weekdays, timeZone: Self.utc))
        #expect(abs(f - 3.5 / 23.0) < 1e-9)
        #expect(f < 5.5 / 31.0)  // projects HIGHER than calendar
    }

    @Test("weekdays basis holds steady across a weekend")
    func weekendFreeze() throws {
        let start = Self.at(2026, 7, 1), end = Self.at(2026, 8, 1)
        let sat = try #require(BudgetProjection.elapsedFraction(
            start: start, end: end, now: Self.at(2026, 7, 11, 12), basis: .weekdays, timeZone: Self.utc))
        let sun = try #require(BudgetProjection.elapsedFraction(
            start: start, end: end, now: Self.at(2026, 7, 12, 18), basis: .weekdays, timeZone: Self.utc))
        #expect(sat == sun)
        #expect(abs(sat - 8.0 / 23.0) < 1e-9)
        // The calendar basis keeps diluting over that same weekend.
        let calSat = try #require(BudgetProjection.elapsedFraction(
            start: start, end: end, now: Self.at(2026, 7, 11, 12), basis: .calendar, timeZone: Self.utc))
        let calSun = try #require(BudgetProjection.elapsedFraction(
            start: start, end: end, now: Self.at(2026, 7, 12, 18), basis: .calendar, timeZone: Self.utc))
        #expect(calSun > calSat)
    }

    @Test("no projection until an hour has elapsed on the active clock")
    func firstHourSuppression() {
        let start = Self.at(2026, 8, 1), end = Self.at(2026, 9, 1)  // opens on a Saturday
        // Half an hour in: too little on either basis.
        #expect(BudgetProjection.elapsedFraction(start: start, end: end, now: Self.at(2026, 8, 1, 0, 30),
                                                 basis: .calendar, timeZone: Self.utc) == nil)
        // 36 calendar hours in, the calendar basis projects...
        #expect(BudgetProjection.elapsedFraction(start: start, end: end, now: Self.at(2026, 8, 2, 12),
                                                 basis: .calendar, timeZone: Self.utc) != nil)
        // ...but no weekday time has elapsed at all yet.
        #expect(BudgetProjection.elapsedFraction(start: start, end: end, now: Self.at(2026, 8, 2, 12),
                                                 basis: .weekdays, timeZone: Self.utc) == nil)
        // Half an hour into Monday is still under the floor; 90 minutes clears it.
        #expect(BudgetProjection.elapsedFraction(start: start, end: end, now: Self.at(2026, 8, 3, 0, 30),
                                                 basis: .weekdays, timeZone: Self.utc) == nil)
        #expect(BudgetProjection.elapsedFraction(start: start, end: end, now: Self.at(2026, 8, 3, 1, 30),
                                                 basis: .weekdays, timeZone: Self.utc) != nil)
    }

    @Test("a `now` past the period end reads as fully elapsed, not over-elapsed")
    func clampedNow() throws {
        let f = try #require(BudgetProjection.elapsedFraction(
            start: Self.at(2026, 7, 1), end: Self.at(2026, 8, 1), now: Self.at(2026, 8, 15),
            basis: .calendar, timeZone: Self.utc))
        #expect(f == 1.0)
        #expect(BudgetProjection.elapsedFraction(start: Self.at(2026, 7, 1), end: Self.at(2026, 8, 1),
                                                 now: Self.at(2026, 6, 20), basis: .calendar,
                                                 timeZone: Self.utc) == nil)
    }

    // MARK: - Projection

    @Test("project scales the value by the elapsed fraction")
    func projectValue() throws {
        // Halfway through July: $100 spent projects to $200.
        let p = try #require(BudgetProjection.project(100, start: Self.at(2026, 7, 1), end: Self.at(2026, 8, 1),
                                                      now: Self.at(2026, 7, 16, 12), basis: .calendar,
                                                      timeZone: Self.utc))
        #expect(abs(p - 100 * 31.0 / 15.5) < 0.01)
        // Same instant, weekday basis: 11.5 of 23 weekdays is also half.
        let w = try #require(BudgetProjection.project(100, start: Self.at(2026, 7, 1), end: Self.at(2026, 8, 1),
                                                      now: Self.at(2026, 7, 16, 12), basis: .weekdays,
                                                      timeZone: Self.utc))
        #expect(abs(w - 200) < 0.01)
        // Suppressed elapsed time means no projection at all.
        #expect(BudgetProjection.project(100, start: Self.at(2026, 8, 1), end: Self.at(2026, 9, 1),
                                         now: Self.at(2026, 8, 1, 0, 10), basis: .calendar,
                                         timeZone: Self.utc) == nil)
    }

    // MARK: - Basis decoding

    @Test("unknown or missing basis strings read as calendar")
    func basisDecoding() {
        #expect(BudgetProjectionBasis(configValue: "weekdays") == .weekdays)
        #expect(BudgetProjectionBasis(configValue: "calendar") == .calendar)
        for junk in ["business_days", "Weekdays", "", nil] {
            #expect(BudgetProjectionBasis(configValue: junk) == .calendar)
        }
    }
}
