import SwiftUI

/// Activity-Monitor-style usage-over-time view: a period picker plus two
/// stacked mini-charts sharing the selected period's time axis. Hand-drawn
/// via Canvas (rather than the Charts framework) so the fill/peak-line/
/// avg-line/secondary-line overlay in the utilization chart stays simple to
/// read and control precisely at this compact size.
struct GraphView: View {
    @ObservedObject var model: GraphModel

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
            UtilizationChartView(
                buckets: model.utilBuckets,
                start: model.periodStart,
                end: model.periodEnd,
                bucketSeconds: model.period.utilBucketSeconds
            )
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
            CostChartView(buckets: model.costBuckets, start: model.periodStart, end: model.periodEnd)
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
    /// hours for 24h, weekday for 7d, dates for 1mo/3mo.
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

// MARK: - Utilization chart

/// CPU-load-style mini chart: a translucent filled area under the
/// five_hour avg line, a dimmer five_hour max/peak line above it so peaks
/// survive downsampling, and a thinner seven_day avg overlay. Gaps in the
/// underlying data (time ranges with no snapshot at any tier) break the
/// line rather than bridging across them with a misleading diagonal.
struct UtilizationChartView: View {
    let buckets: [UtilBucket]
    let start: Date
    let end: Date
    let bucketSeconds: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard end > start, size.width > 0 else { return }
            let domain = end.timeIntervalSince(start)
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / domain) * size.width }
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100) }

            // Subtle 50% gridline.
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: y(50)))
            grid.addLine(to: CGPoint(x: size.width, y: y(50)))
            context.stroke(grid, with: .color(.white.opacity(0.1)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

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
struct CostChartView: View {
    let buckets: [CostBucket]
    let start: Date
    let end: Date

    var body: some View {
        Canvas { context, size in
            guard end > start, size.width > 0, !buckets.isEmpty else { return }
            let domain = end.timeIntervalSince(start)
            let maxVal = max(buckets.map { $0.usd }.max() ?? 0, 0.01)
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / domain) * size.width }
            func barHeight(_ v: Double) -> CGFloat { size.height * CGFloat(min(v / maxVal, 1)) }

            let barWidth = max(size.width / CGFloat(buckets.count) - 1, 1)
            for b in buckets {
                let h = barHeight(b.usd)
                guard h > 0 else { continue }
                let rect = CGRect(x: x(b.date), y: size.height - h, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(.green.opacity(0.55)))
            }
        }
    }
}
