import Foundation

/// Centralized duration formatting for every "resets in …" / "resumes in …"
/// countdown and activity-age display in the widget.
///
/// Item 6: before this, UsageModel.resetText and SessionsModel's countdown
/// text each had their own hand-rolled hours/minutes breakdown that never
/// accounted for days — a 35-hour Weekly reset countdown rendered as
/// "resets in 35h 45m" instead of the much more readable "resets in 1d 11h
/// 45m". This is now the one place that breakdown logic lives, so every
/// duration/countdown/age display (including item 5's per-session activity
/// age) formats consistently: <1h -> "Xm", <24h -> "Xh Ym", >=24h -> "Xd Yh
/// Zm".
enum DurationFormat {
    /// `seconds` should be >= 0 — callers handle their own zero/negative
    /// "resets soon" / "ready to resume" / "<1m" text, since the right
    /// wording for a just-elapsed duration differs by call site.
    static func compact(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
