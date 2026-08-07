// Step 1+2 of the Windows spike. Drop in as Sources/Probe/Probe.swift of an
// `swift package init --type executable --name Probe` package, deleting any
// main.swift the toolchain generated (you can't have both).
//
// Nothing here is clever. Every line is a measurement of a Foundation
// behavior the shared-core plan depends on, chosen because the macOS answer
// is already known — see the baseline table in README.md.
import Foundation

@main
struct Probe {
    static func main() {
        // --- JSON scalar bridging. The whole JSONValue refactor rests on this.
        let s = #"{"b": true, "d": 1.5, "i": 7, "n": null, "big": 1753000000.0}"#
        let o = try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        print("b type       :", type(of: o["b"]!))
        print("b as? Bool   :", o["b"] as? Bool as Any)
        print("b as? NSNum  :", (o["b"] as? NSNumber)?.boolValue as Any)
        print("d as? Double :", o["d"] as? Double as Any)
        print("d as? NSNum  :", (o["d"] as? NSNumber)?.doubleValue as Any)
        print("i as? Int    :", o["i"] as? Int as Any)
        print("big as? Doubl:", o["big"] as? Double as Any)
        print("null isNSNull:", o["n"] is NSNull)
        print("validJSONObj :", JSONSerialization.isValidJSONObject(["a": NSNull()]))

        // --- Timezone + calendar. The daemon and the widget must agree on UTC
        // bucket keys or plan-fit/cost charts shift by a day.
        print("TZ UTC       :", TimeZone(identifier: "UTC") as Any)
        print("TZ gmt0      :", TimeZone(secondsFromGMT: 0) as Any)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // DateFormatter specifically: an open corelibs Windows crasher has a
        // reproducer that matches GraphModel.utcDailyKeyFormatter() line for
        // line. If this step crashes rather than prints, that IS the result.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        print("daily key    :", f.string(from: Date(timeIntervalSince1970: 1_753_000_000)))

        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        print("grouped      :", nf.string(from: NSNumber(value: 2786.17)) as Any)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        print("iso frac     :", iso.date(from: "2026-07-26T10:00:00.123Z") as Any)

        // --- Filesystem. .creationDateKey backs the cloud-echo dedupe join.
        let home = FileManager.default.homeDirectoryForCurrentUser
        print("home         :", home.path)
        let probe = home.appendingPathComponent("spike-probe.txt")
        try? Data("x".utf8).write(to: probe)
        let created = (try? probe.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        print("creationDate :", created as Any)
    }
}
