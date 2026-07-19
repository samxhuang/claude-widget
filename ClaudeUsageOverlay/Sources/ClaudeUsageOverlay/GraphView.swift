import SwiftUI

/// Activity-Monitor-style usage-over-time view: a period picker plus two
/// stacked mini-charts sharing the selected period's time axis. Hand-drawn
/// via Canvas (rather than the Charts framework) so the fill/peak-line/
/// avg-line/secondary-line overlay in the utilization chart stays simple to
/// read and control precisely at this compact size.
struct GraphView: View {
    @ObservedObject var model: GraphModel
    /// Opens the larger, resizable graph window (item 3). Defaults to a
    /// no-op so previews / tests that don't wire it up still compile.
    var onExpand: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            periodPicker

            utilizationSection
            costSection

            if let note = model.coverageNote {
                Text(note)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }

    // MARK: - Period picker

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(GraphPeriod.allCases) { p in
                Text(p.rawValue)
                    .font(.system(size: 9, weight: model.period == p ? .bold : .medium))
                    .foregroundColor(model.period == p ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(model.period == p ? Color.white.opacity(0.18) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.period = p }
            }
            Spacer()
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Open larger graph window")
        }
    }

    // MARK: - Utilization

    @ViewBuilder
    private var utilizationSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("UTILIZATION")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                legend(color: .cyan, text: "5h " + percentText(model.latestFiveHour))
                legend(color: .purple, text: "7d " + percentText(model.latestSevenDay))
            }
            HStack(spacing: 4) {
                PercentAxisGutter(width: GraphMetrics.gutterWidth)
                UtilizationChartView(
                    buckets: model.utilBuckets,
                    start: model.periodStart,
                    end: model.periodEnd,
                    bucketSeconds: model.period.utilBucketSeconds
                )
            }
            .frame(height: 72)
            timeAxisLabels
        }
    }

    // MARK: - Cost

    @ViewBuilder
    private var costSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("API-EQUIVALENT COST")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Text(model.period.costUnitLabel)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.4))
            }
            HStack(spacing: 4) {
                CostAxisGutter(width: GraphMetrics.gutterWidth, niceMax: GraphMetrics.niceMax(model.costBuckets.map { $0.usd }.max() ?? 0))
                CostChartView(
                    buckets: model.costBuckets,
                    start: model.periodStart,
                    end: model.periodEnd,
                    maxValue: GraphMetrics.niceMax(model.costBuckets.map { $0.usd }.max() ?? 0)
                )
            }
            .frame(height: 54)
            timeAxisLabels
        }
    }

    // MARK: - Shared helpers

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func percentText(_ v: Double?) -> String {
        guard let v = v else { return "—" }
        return String(format: "%.0f%%", v)
    }

    /// A handful of sparse, evenly-spaced tick labels spanning the period —
    /// hours for 24h, weekday for 7d, dates for 1mo/3mo. Indented by the
    /// y-axis gutter width so it lines up under the chart, not the gutter.
    private var timeAxisLabels: some View {
        let dates = axisTickDates()
        return HStack {
            ForEach(Array(dates.enumerated()), id: \.offset) { idx, d in
                Text(axisLabel(for: d))
                    .font(.system(size: 7.5))
                    .foregroundColor(.white.opacity(0.35))
                if idx < dates.count - 1 { Spacer() }
            }
        }
        .padding(.leading, GraphMetrics.gutterWidth + 4)
    }

    private func axisTickDates() -> [Date] {
        let start = model.periodStart
        let end = model.periodEnd
        guard end > start else { return [] }
        let steps = 4
        return (0...steps).map { i in
            start.addingTimeInterval(end.timeIntervalSince(start) * Double(i) / Double(steps))
        }
    }

    private func axisLabel(for date: Date) -> String {
        let f = DateFormatter()
        switch model.period {
        case .day: f.dateFormat = "ha"
        case .week: f.dateFormat = "EEE"
        case .month, .threeMonth: f.dateFormat = "M/d"
        }
        return f.string(from: date)
    }
}

// MARK: - Shared axis metrics / helpers

/// Small helpers shared by the compact mini-charts and the larger expanded
/// window's charts, so both stay visually and numerically consistent.
enum GraphMetrics {
    /// Width of the y-axis label gutter to the left of each chart. Compact
    /// on purpose — these are tick labels, not a full axis.
    static let gutterWidth: CGFloat = 30

    /// Rounds a raw maximum up to a "nice" number (1/2/5 × 10^n) suitable
    /// for an axis tick, the same way a plotting library would pick gridline
    /// values — e.g. 27.4 -> 30, 3.1 -> 5, 0.4 -> 0.5.
    static func niceMax(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let exponent = floor(log10(raw))
        let magnitude = pow(10, exponent)
        let residual = raw / magnitude
        let niceResidual: Double
        if residual <= 1 { niceResidual = 1 }
        else if residual <= 2 { niceResidual = 2 }
        else if residual <= 5 { niceResidual = 5 }
        else { niceResidual = 10 }
        return niceResidual * magnitude
    }

    /// Compact "$0" / "$2.5" / "$30" style label — more decimals only when
    /// the scale is small enough that whole dollars would round every tick
    /// to the same value.
    static func dollarTick(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 1 { return String(format: "$%.2f", v) }
        if v < 10 { return String(format: "$%.1f", v) }
        return String(format: "$%.0f", v)
    }
}

/// Left-hand y-axis gutter for the utilization chart: fixed 0/50/100% ticks,
/// top/middle/bottom-anchored via a spacer VStack so they line up with the
/// matching gridlines Canvas draws at the same fractions of chart height.
struct PercentAxisGutter: View {
    var width: CGFloat = GraphMetrics.gutterWidth

    var body: some View {
        VStack(spacing: 0) {
            Text("100%").frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            Text("50%").frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            Text("0%").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 7.5).monospacedDigit())
        .foregroundColor(.white.opacity(0.35))
        .frame(width: width)
    }
}

/// Left-hand y-axis gutter for the cost chart: 0 / niceMax/2 / niceMax,
/// rounded to "nice" dollar values scaled to what's actually visible.
struct CostAxisGutter: View {
    var width: CGFloat = GraphMetrics.gutterWidth
    var niceMax: Double

    var body: some View {
        VStack(spacing: 0) {
            Text(GraphMetrics.dollarTick(niceMax)).frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            Text(GraphMetrics.dollarTick(niceMax / 2)).frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            Text(GraphMetrics.dollarTick(0)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 7.5).monospacedDigit())
        .foregroundColor(.white.opacity(0.35))
        .frame(width: width)
    }
}

// MARK: - Utilization chart

/// CPU-load-style mini chart: a translucent filled area under the
/// five_hour avg line, a dimmer five_hour max/peak line above it so peaks
/// survive downsampling, and a thinner seven_day avg overlay. Gaps in the
/// underlying data (time ranges with no snapshot at any tier) break the
/// line rather than bridging across them with a misleading diagonal.
///
/// Parameterized purely by `buckets`/`start`/`end`/`bucketSeconds` (plus its
/// own frame size, set by the caller) so the same view is reused both by the
/// compact panel and the expanded window — the expanded window just passes a
/// taller frame and, when zoomed, a narrower start/end.
struct UtilizationChartView: View {
    let buckets: [UtilBucket]
    let start: Date
    let end: Date
    let bucketSeconds: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard end > start, size.width > 0 else { return }
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            let domain = end.timeIntervalSince(start)
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / domain) * size.width }
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100) }

            // Faint gridlines at 0/50/100% — matches PercentAxisGutter's
            // three tick labels.
            for pct in [0.0, 50.0, 100.0] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y(pct)))
                grid.addLine(to: CGPoint(x: size.width, y: y(pct)))
                context.stroke(grid, with: .color(.white.opacity(pct == 50 ? 0.1 : 0.06)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }

            for seg in contiguousSegments() {
                let fivePts = seg.compactMap { b -> CGPoint? in
                    guard let v = b.fiveAvg else { return nil }
                    return CGPoint(x: x(b.date), y: y(v))
                }
                if fivePts.count > 1 {
                    var fill = Path()
                    fill.move(to: CGPoint(x: fivePts[0].x, y: size.height))
                    fivePts.forEach { fill.addLine(to: $0) }
                    fill.addLine(to: CGPoint(x: fivePts.last!.x, y: size.height))
                    fill.closeSubpath()
                    context.fill(fill, with: .color(.cyan.opacity(0.18)))
                }

                let fiveMaxPts = seg.compactMap { b -> CGPoint? in
                    guard let v = b.fiveMax else { return nil }
                    return CGPoint(x: x(b.date), y: y(v))
                }
                strokeLine(context: context, points: fiveMaxPts, color: .cyan.opacity(0.32), width: 1)
                strokeLine(context: context, points: fivePts, color: .cyan, width: 1.4)

                let sevenPts = seg.compactMap { b -> CGPoint? in
                    guard let v = b.sevenAvg else { return nil }
                    return CGPoint(x: x(b.date), y: y(v))
                }
                strokeLine(context: context, points: sevenPts, color: .purple.opacity(0.85), width: 1)
            }
        }
    }

    /// Splits `buckets` into runs with no gap wider than 1.5 bucket widths,
    /// so lines aren't drawn bridging stretches with no data.
    private func contiguousSegments() -> [[UtilBucket]] {
        guard !buckets.isEmpty else { return [] }
        var segments: [[UtilBucket]] = []
        var current: [UtilBucket] = [buckets[0]]
        let maxGap = bucketSeconds * 1.5
        for b in buckets.dropFirst() {
            if let last = current.last, b.date.timeIntervalSince(last.date) > maxGap {
                segments.append(current)
                current = [b]
            } else {
                current.append(b)
            }
        }
        segments.append(current)
        return segments
    }

    private func strokeLine(context: GraphicsContext, points: [CGPoint], color: Color, width: CGFloat) {
        guard points.count > 1 else { return }
        var path = Path()
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        context.stroke(path, with: .color(color), lineWidth: width)
    }
}

// MARK: - Cost chart

/// Filled-step / bar chart of API-equivalent cost. Missing slots are
/// genuinely $0 (already zero-filled by GraphModel), so this never needs to
/// deal with gaps the way the utilization chart does.
///
/// `maxValue` is the caller-supplied "nice" axis max (see
/// `GraphMetrics.niceMax`) rather than the raw bucket max, so the drawn bar
/// heights agree with the y-axis gutter's tick labels instead of always
/// touching the top of the frame.
struct CostChartView: View {
    let buckets: [CostBucket]
    let start: Date
    let end: Date
    let maxValue: Double

    var body: some View {
        Canvas { context, size in
            guard end > start, size.width > 0, !buckets.isEmpty else { return }
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            let domain = end.timeIntervalSince(start)
            let maxVal = max(maxValue, 0.01)
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / domain) * size.width }
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(min(v / maxVal, 1))) }

            // Faint gridlines at 0 / max/2 / max — matches CostAxisGutter's
            // three tick labels.
            for frac in [0.0, 0.5, 1.0] {
                var grid = Path()
                let gy = size.height * CGFloat(1 - frac)
                grid.move(to: CGPoint(x: 0, y: gy))
                grid.addLine(to: CGPoint(x: size.width, y: gy))
                context.stroke(grid, with: .color(.white.opacity(frac == 0.5 ? 0.1 : 0.06)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }

            let barWidth = max(size.width / CGFloat(buckets.count) - 1, 1)
            for b in buckets {
                let top = y(b.usd)
                let h = size.height - top
                guard h > 0 else { continue }
                let rect = CGRect(x: x(b.date), y: top, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(.green.opacity(0.55)))
            }
        }
    }
}
