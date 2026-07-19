import SwiftUI

/// Converts between a chart's local x-coordinate and a Date, given the
/// chart's visible time domain and pixel width. Shared by the hover
/// crosshair and the drag-to-zoom gesture so both agree on where the mouse
/// is pointing in time.
struct ChartTimeMapper {
    let start: Date
    let end: Date
    let width: CGFloat

    func x(_ d: Date) -> CGFloat {
        guard end > start, width > 0 else { return 0 }
        let frac = d.timeIntervalSince(start) / end.timeIntervalSince(start)
        return CGFloat(frac) * width
    }

    func date(atX x: CGFloat) -> Date {
        guard width > 0, end > start else { return start }
        let frac = Double(max(0, min(x, width)) / width)
        return start.addingTimeInterval(end.timeIntervalSince(start) * frac)
    }
}

/// The larger, resizable "stock ticker" graph window (item 3): the same two
/// Canvas charts as the compact panel (reused, not duplicated), backed by
/// the same shared GraphModel — picking a period here also updates the
/// compact panel's Graph tab and vice versa, since both observe the same
/// @Published `period`. Zoom and hover state are local to this window only;
/// they aren't meaningful in the compact panel.
struct ExpandedGraphView: View {
    @ObservedObject var model: GraphModel

    /// nil = showing the full selected period. Set by a completed
    /// drag-to-zoom gesture on either chart; cleared by "Reset zoom".
    @State private var zoomRange: ClosedRange<Date>?

    /// Shared across both charts (as dates, not pixels) so the crosshair
    /// lines up at the same instant in time on both, even though each chart
    /// computes its own local x from its own GeometryReader width.
    @State private var hoverDate: Date?
    @State private var dragAnchorDate: Date?
    @State private var dragCurrentDate: Date?

    private var visibleStart: Date { zoomRange?.lowerBound ?? model.periodStart }
    private var visibleEnd: Date { zoomRange?.upperBound ?? model.periodEnd }
    private var isZoomed: Bool { zoomRange != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow

            HStack(spacing: 8) {
                Text("UTILIZATION")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                legend(color: .cyan, text: "5h avg")
                legend(color: .cyan.opacity(0.5), text: "5h peak")
                legend(color: .purple, text: "7d avg")
            }
            utilizationBlock
            timeAxisLabels

            HStack {
                Text("API-EQUIVALENT COST")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text(model.period.costUnitLabel)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
            costBlock
            timeAxisLabels

            readoutBar

            if let note = model.coverageNote {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.92))
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            ForEach(GraphPeriod.allCases) { p in
                Text(p.rawValue)
                    .font(.system(size: 11, weight: model.period == p ? .bold : .medium))
                    .foregroundColor(model.period == p ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(model.period == p ? Color.white.opacity(0.18) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.period = p
                        zoomRange = nil
                    }
            }
            Spacer()
            if isZoomed {
                Button(action: { zoomRange = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "minus.magnifyingglass")
                        Text("Reset zoom")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Utilization block

    /// minHeight covers the default 800x500 window comfortably alongside the
    /// cost block and every fixed-height row (header, labels, readout);
    /// maxHeight: .infinity lets it (and costBlock below) grow together as
    /// the user resizes the window larger, roughly 60/40 against the cost
    /// block, rather than leaving the extra space as dead padding.
    private var utilizationBlock: some View {
        HStack(spacing: 6) {
            PercentAxisGutter(width: 34)
            InteractiveChartArea(
                start: visibleStart, end: visibleEnd,
                hoverDate: $hoverDate, dragAnchorDate: $dragAnchorDate, dragCurrentDate: $dragCurrentDate,
                onZoomCommit: commitZoom
            ) { _ in
                UtilizationChartView(
                    buckets: model.utilBuckets,
                    start: visibleStart,
                    end: visibleEnd,
                    bucketSeconds: model.period.utilBucketSeconds
                )
            }
        }
        .frame(minHeight: 150, idealHeight: 220, maxHeight: .infinity)
    }

    // MARK: - Cost block

    private var costBlock: some View {
        let visibleCost = model.costBuckets.filter { $0.date >= visibleStart && $0.date <= visibleEnd }
        let niceMax = GraphMetrics.niceMax(visibleCost.map { $0.usd }.max() ?? 0)
        return HStack(spacing: 6) {
            CostAxisGutter(width: 34, niceMax: niceMax)
            InteractiveChartArea(
                start: visibleStart, end: visibleEnd,
                hoverDate: $hoverDate, dragAnchorDate: $dragAnchorDate, dragCurrentDate: $dragCurrentDate,
                onZoomCommit: commitZoom
            ) { _ in
                CostChartView(buckets: model.costBuckets, start: visibleStart, end: visibleEnd, maxValue: niceMax)
            }
        }
        .frame(minHeight: 90, idealHeight: 140, maxHeight: .infinity)
    }

    private func commitZoom(_ a: Date, _ b: Date) {
        guard b.timeIntervalSince(a) > 30 else { return } // ignore accidental micro-drags
        zoomRange = min(a, b)...max(a, b)
    }

    // MARK: - Floating readout

    /// A stock-chart-style readout: while hovering, shows the exact
    /// timestamp under the cursor plus the utilization (avg/peak/7d) and
    /// cost values nearest that instant. Rendered as a fixed bar under both
    /// charts rather than a tooltip that tracks the cursor pixel-for-pixel —
    /// simpler to keep legible at this window's default size, and it never
    /// occludes the chart it's describing.
    @ViewBuilder
    private var readoutBar: some View {
        HStack(spacing: 16) {
            if let hd = hoverDate {
                Text(readoutTimeFormatter.string(from: hd))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))

                let ub = nearestUtilBucket(to: hd)
                readoutValue("5h avg", ub?.fiveAvg.map { String(format: "%.0f%%", $0) } ?? "—", .cyan)
                readoutValue("5h peak", ub?.fiveMax.map { String(format: "%.0f%%", $0) } ?? "—", .cyan.opacity(0.6))
                readoutValue("7d avg", ub?.sevenAvg.map { String(format: "%.0f%%", $0) } ?? "—", .purple)

                let cb = nearestCostBucket(to: hd)
                readoutValue("cost", cb.map { GraphMetrics.dollarTick($0.usd) } ?? "—", .green)
            } else {
                Text("Hover a chart for details · drag to zoom")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(height: 16)
    }

    private func readoutValue(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) \(value)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private func nearestUtilBucket(to date: Date) -> UtilBucket? {
        model.utilBuckets.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func nearestCostBucket(to date: Date) -> CostBucket? {
        model.costBuckets.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private var readoutTimeFormatter: DateFormatter {
        let f = DateFormatter()
        switch model.period {
        case .day: f.dateFormat = "h:mm a"
        case .week: f.dateFormat = "EEE h:mm a"
        case .month, .threeMonth: f.dateFormat = "MMM d, h:mm a"
        }
        return f
    }

    // MARK: - Shared helpers

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private var timeAxisLabels: some View {
        let dates = axisTickDates()
        return HStack {
            ForEach(Array(dates.enumerated()), id: \.offset) { idx, d in
                Text(axisLabel(for: d))
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.35))
                if idx < dates.count - 1 { Spacer() }
            }
        }
        .padding(.leading, 34 + 6)
    }

    private func axisTickDates() -> [Date] {
        guard visibleEnd > visibleStart else { return [] }
        let steps = 6
        return (0...steps).map { i in
            visibleStart.addingTimeInterval(visibleEnd.timeIntervalSince(visibleStart) * Double(i) / Double(steps))
        }
    }

    private func axisLabel(for date: Date) -> String {
        let f = DateFormatter()
        // Zoomed into a sub-range narrower than a day benefits from a
        // time-of-day label regardless of the selected period's usual
        // date-oriented format.
        if visibleEnd.timeIntervalSince(visibleStart) < 36 * 3600 {
            f.dateFormat = "h:mm a"
        } else {
            switch model.period {
            case .day: f.dateFormat = "ha"
            case .week: f.dateFormat = "EEE"
            case .month, .threeMonth: f.dateFormat = "M/d"
            }
        }
        return f.string(from: date)
    }
}

/// Wraps chart content with a hover crosshair and a drag-to-zoom rectangle,
/// both tracked as Dates (via `ChartTimeMapper`) rather than raw pixels so
/// they stay correct regardless of the exact width this instance ends up
/// with. Used for both the utilization and cost blocks so a drag started on
/// either one zooms both in sync (`hoverDate`/`dragAnchorDate`/
/// `dragCurrentDate` are bindings owned by the parent view).
private struct InteractiveChartArea<Chart: View>: View {
    let start: Date
    let end: Date
    @Binding var hoverDate: Date?
    @Binding var dragAnchorDate: Date?
    @Binding var dragCurrentDate: Date?
    let onZoomCommit: (Date, Date) -> Void
    @ViewBuilder let chart: (CGFloat) -> Chart

    var body: some View {
        GeometryReader { geo in
            let mapper = ChartTimeMapper(start: start, end: end, width: geo.size.width)
            ZStack(alignment: .topLeading) {
                chart(geo.size.width)

                if let a = dragAnchorDate, let c = dragCurrentDate {
                    let x0 = mapper.x(a)
                    let x1 = mapper.x(c)
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: max(abs(x1 - x0), 1), height: geo.size.height)
                        .offset(x: min(x0, x1))
                        .allowsHitTesting(false)
                }

                if let hd = hoverDate, hd >= start, hd <= end {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: mapper.x(hd))
                        .allowsHitTesting(false)
                }

                // Transparent hit-testing surface: continuous hover for the
                // crosshair/readout, drag for zoom. macOS 13+.
                Rectangle()
                    .fill(Color.white.opacity(0.0001)) // .clear doesn't hit-test reliably for hover
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            hoverDate = mapper.date(atX: loc.x)
                        case .ended:
                            hoverDate = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .local)
                            .onChanged { value in
                                if dragAnchorDate == nil {
                                    dragAnchorDate = mapper.date(atX: value.startLocation.x)
                                }
                                dragCurrentDate = mapper.date(atX: value.location.x)
                            }
                            .onEnded { _ in
                                if let a = dragAnchorDate, let c = dragCurrentDate {
                                    onZoomCommit(a, c)
                                }
                                dragAnchorDate = nil
                                dragCurrentDate = nil
                            }
                    )
            }
        }
    }
}
