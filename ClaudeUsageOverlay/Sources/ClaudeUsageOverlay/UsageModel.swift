import Foundation
import Combine

/// Holds the latest usage numbers pulled from claude.ai and formats them
/// for display. `now` is ticked by a lightweight timer so the "resets in
/// Xh Ym" labels count down live between network refreshes.
final class UsageModel: ObservableObject {
    @Published var sessionPercent: Int?
    @Published var sessionResetsAt: Date?

    @Published var weeklyPercent: Int?
    @Published var weeklyResetsAt: Date?

    @Published var isLoggedOut: Bool = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    @Published var now: Date = Date()

    func tick() {
        now = Date()
    }

    func apply(usage: [String: Any]) {
        if let five = usage["five_hour"] as? [String: Any] {
            sessionPercent = Self.intValue(five["utilization"])
            sessionResetsAt = Self.parseDate(five["resets_at"] as? String)
        }
        if let seven = usage["seven_day"] as? [String: Any] {
            weeklyPercent = Self.intValue(seven["utilization"])
            weeklyResetsAt = Self.parseDate(seven["resets_at"] as? String)
        }
        lastUpdated = Date()
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        return nil
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
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
