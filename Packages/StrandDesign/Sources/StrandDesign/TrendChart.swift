#if !os(watchOS)
// TrendChart is a Swift Charts view with .onContinuousHover (unavailable on watchOS); the watch
// never shows it, so the whole file is excluded there. iOS/macOS unchanged.
import SwiftUI
import Charts

// MARK: - Trend Chart (§9.4 Trends)
//
// A line/area chart whose line is gradient-stroked by value — reusable for
// recovery / HRV / RHR / strain trends. The gradient defaults to the recovery
// scale (so a recovery-over-time line travels deep-gold → pale-gold by daily
// score), but any gradient + value-range can be supplied — pass the blue sleep
// ramp for sleep, the teal HRV scale for HRV, the amber strain ramp for strain.

/// One point on a trend line.
public struct TrendPoint: Identifiable, Sendable {
    public var date: Date
    public var value: Double

    /// Stable, content-derived identity (one point per date in a series). A random
    /// `UUID()` defeats Swift Charts' diffing — every render re-identifies all marks
    /// and replays the draw animation; keying on the date lets Charts diff by data.
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct TrendChart: View {

    public var points: [TrendPoint]
    /// The series' colour ramp; the line takes its top colour (with the minimal palette, the accent).
    public var gradient: Gradient
    /// The metric's full value range, used as the y domain when no `yDomain` is given.
    public var valueRange: ClosedRange<Double>
    /// Whether to draw the fading area fill below the line.
    public var showsArea: Bool
    public var height: CGFloat
    /// Whether the chart can be scrubbed (pointer hover on the Mac, press-and-drag on iPhone).
    public var showsHover: Bool
    /// Formats a point's value for the scrub bubble's bold line (default: rounded int).
    public var valueFormat: (Double) -> String
    /// Formats a point's date for the scrub bubble's second line.
    public var dateFormat: (Date) -> String
    /// Optional series name for VoiceOver (e.g. "HRV trend"); falls back to "Trend".
    public var accessibilityLabel: String?
    /// Colour of the ringed dot on the newest point; nil uses the line colour. The dot is always drawn
    /// unless `showsLastPoint` is false.
    public var nowCapColor: Color?
    /// Y-axis domain when it should differ from `valueRange`, e.g. fitted to the data with headroom.
    public var yDomain: ClosedRange<Double>?
    /// Personal normal range, drawn as a faint band under the line. nil = no band.
    public var baselineBand: ClosedRange<Double>?
    /// The personal baseline itself, drawn as a faint dashed rule. nil = no rule.
    public var baselineCenter: Double?
    /// Draw the ringed dot on the newest point.
    public var showsLastPoint: Bool

    /// One-line VoiceOver summary (count + mean + range), built once in `init`.
    private let a11ySummary: String
    /// The points handed to the marks (min/max-bucketed past a threshold), each tagged with its run:
    /// the line breaks across a gap in the data instead of drawing a straight bridge over it.
    private let drawn: [Drawn]
    /// Runs with a single point: drawn as a dot, since a one-point line is invisible.
    private let lonePoints: [TrendPoint]

    struct Drawn: Identifiable {
        let point: TrendPoint
        let run: Int
        var id: Date { point.date }
    }

    public init(
        points: [TrendPoint],
        gradient: Gradient = StrandPalette.recoveryGradient,
        valueRange: ClosedRange<Double> = 0...100,
        showsArea: Bool = true,
        height: CGFloat = 220,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { String(Int($0.rounded())) },
        dateFormat: @escaping (Date) -> String = { TrendChart.defaultDateString($0) },
        accessibilityLabel: String? = nil,
        nowCapColor: Color? = nil,
        yDomain: ClosedRange<Double>? = nil,
        baselineBand: ClosedRange<Double>? = nil,
        baselineCenter: Double? = nil,
        showsLastPoint: Bool = true,
        previewSelectedIndex: Int? = nil
    ) {
        let sorted = points.sorted { $0.date < $1.date }
        self.points = sorted
        self.gradient = gradient
        self.valueRange = valueRange
        self.showsArea = showsArea
        self.height = height
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
        self.accessibilityLabel = accessibilityLabel
        self.nowCapColor = nowCapColor
        self.yDomain = yDomain
        self.baselineBand = baselineBand
        self.baselineCenter = baselineCenter
        self.showsLastPoint = showsLastPoint
        // Screenshot/preview hook: start with a point selected so the scrub bubble can be checked.
        if let i = previewSelectedIndex, sorted.indices.contains(i) { _selected = State(initialValue: sorted[i]) }

        let display = ChartDownsample.minMaxBucketed(sorted, threshold: ChartDownsample.markThreshold,
                                                     targetCount: ChartDownsample.targetVertices)
        let breaks = Self.gapBreaks(sorted)
        var drawn: [Drawn] = []
        drawn.reserveCapacity(display.count)
        var b = 0
        for p in display {
            while b < breaks.count && breaks[b] < p.date { b += 1 }
            drawn.append(Drawn(point: p, run: b))
        }
        self.drawn = drawn
        let runSizes = Dictionary(grouping: drawn, by: \.run).mapValues(\.count)
        self.lonePoints = drawn.filter { runSizes[$0.run] == 1 }.map(\.point)

        if sorted.isEmpty {
            self.a11ySummary = String(localized: "No data", bundle: .module)
        } else {
            let vals = sorted.map(\.value)
            let avg = vals.reduce(0, +) / Double(vals.count)
            let lo = vals.min()!, hi = vals.max()!
            self.a11ySummary = String(localized: "\(sorted.count) points, mean \(valueFormat(avg)), range \(valueFormat(lo)) to \(valueFormat(hi))", bundle: .module)
        }
    }

    /// Dates where the line breaks: the midpoint of every gap longer than 3× the series' median
    /// spacing (so a daily series breaks over a missing 3+ days, a 5-minute series over 15+ minutes).
    /// Pure; exposed for tests.
    static func gapBreaks(_ sorted: [TrendPoint]) -> [Date] {
        guard sorted.count >= 3 else { return [] }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(sorted.count - 1)
        for i in 1..<sorted.count { deltas.append(sorted[i].date.timeIntervalSince(sorted[i - 1].date)) }
        let median = deltas.sorted()[deltas.count / 2]
        guard median > 0 else { return [] }
        let limit = median * 3
        var out: [Date] = []
        for i in 1..<sorted.count where deltas[i - 1] > limit {
            out.append(sorted[i - 1].date.addingTimeInterval(deltas[i - 1] / 2))
        }
        return out
    }

    /// The selected point while scrubbing (pointer hover or press-and-drag).
    @State private var selected: TrendPoint? = nil
    #if os(iOS)
    @State private var scrubbing = false
    #endif

    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()

    /// Default bubble date format ("EEE d MMM"), exposed so it can seed the `dateFormat` default.
    public static func defaultDateString(_ date: Date) -> String {
        sharedDateFormatter.string(from: date)
    }

    /// The point nearest a plot-local x. Binary search over the sorted dates.
    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> TrendPoint? {
        guard !points.isEmpty, let date: Date = proxy.value(atX: x - plot.minX) else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(points[lo - 1].date.timeIntervalSince(date)) < abs(points[lo].date.timeIntervalSince(date)) {
            return points[lo - 1]
        }
        return points[lo]
    }

    /// The single line colour: the top of the series' own ramp.
    private var lineColor: Color { StrandPalette.sample(stops: gradient.toStops(), at: 1.0) }

    /// The Y domain applied to the axis and plot clip. Exposed internally for a unit test.
    var resolvedYDomain: ClosedRange<Double> { yDomain ?? valueRange }

    private var areaFill: LinearGradient {
        LinearGradient(colors: [lineColor.opacity(0.26), lineColor.opacity(0.0)], startPoint: .top, endPoint: .bottom)
    }

    public var body: some View {
        Chart {
            if let band = baselineBand, let first = points.first, let last = points.last {
                RectangleMark(xStart: .value("Start", first.date), xEnd: .value("End", last.date),
                              yStart: .value("Band low", band.lowerBound), yEnd: .value("Band high", band.upperBound))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.08))
            }
            if let center = baselineCenter {
                RuleMark(y: .value("Baseline", center))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.45))
            }
            if showsArea {
                ForEach(drawn) { d in
                    AreaMark(x: .value("Date", d.point.date), yStart: .value("Floor", resolvedYDomain.lowerBound),
                             yEnd: .value("Value", d.point.value), series: .value("Run", d.run))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(areaFill)
                }
            }
            ForEach(drawn) { d in
                LineMark(x: .value("Date", d.point.date), y: .value("Value", d.point.value),
                         series: .value("Run", d.run))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(lineColor)
            }
            ForEach(lonePoints) { p in
                PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .symbolSize(22)
                    .foregroundStyle(lineColor)
            }
            if let s = selected {
                RuleMark(x: .value("Selected", s.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
            }
        }
        .chartYScale(domain: resolvedYDomain)
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(StrandPalette.hairlineStrong)
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    // The newest point (or the scrubbed one): a solid dot ringed in the card colour.
                    if let p = selected ?? (showsLastPoint ? points.last : nil),
                       let px = proxy.position(forX: p.date), let py = proxy.position(forY: p.value) {
                        HighlightDot(color: selected == nil ? (nowCapColor ?? lineColor) : lineColor, diameter: 8)
                            .position(x: px + plot.minX, y: py + plot.minY)
                    }
                    if let s = selected, let px = proxy.position(forX: s.date), let py = proxy.position(forY: s.value) {
                        PositionedTooltip(anchor: CGPoint(x: px + plot.minX, y: py + plot.minY), container: geo.size,
                                          tooltip: ChartTooltip(value: valueFormat(s.value), label: dateFormat(s.date)))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    switch phase {
                    case .active(let location): select(nearestPoint(toX: location.x, proxy: proxy, plot: plot))
                    case .ended: select(nil)
                    }
                }
                #if os(iOS)
                // Press briefly, then drag to scrub. The short hold keeps vertical scrolling free.
                .gesture(
                    LongPressGesture(minimumDuration: 0.18, maximumDistance: 10)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onChanged { value in
                            guard case .second(true, let drag) = value else { return }
                            if !scrubbing { scrubbing = true; StrandHaptic.selection.play() }
                            if let drag { select(nearestPoint(toX: drag.location.x, proxy: proxy, plot: plot)) }
                        }
                        .onEnded { _ in scrubbing = false; select(nil) },
                    including: showsHover ? .all : .subviews)
                #endif
            }
        }
        // Room for the top axis label, which centres on the top gridline. The plot itself is clipped
        // above; clipping the whole frame cut that label in half.
        .padding(.top, 8)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel ?? "Trend"))
        .accessibilityValue(Text(a11ySummary))
        .accessibilityHidden(!showsHover && accessibilityLabel == nil)
    }

    /// Move the selection without animation, with a light tick when it lands on a new point.
    private func select(_ p: TrendPoint?) {
        guard p?.date != selected?.date else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { selected = p }
        #if os(iOS)
        if p != nil, scrubbing { StrandHaptic.selection.play() }
        #endif
    }
}

// MARK: - Chart downsampling (pure)
//
// Reduces a dense point series to roughly the plot's pixel width BEFORE it reaches Swift Charts, so the
// GPU draws ~one vertex per pixel instead of hundreds it can't resolve. Uses MIN/MAX-per-bucket: each
// bucket contributes its lowest and highest sample (in time order), so every visible peak and trough
// survives and the rendered envelope is identical at normal chart widths. First and last points are
// always kept so the line spans the full domain. Pure + deterministic — same input → same output.

enum ChartDownsample {
    /// Above this many points we downsample; at or below it the series is passed through untouched (so
    /// the common 7/30/90-day trends and the ≤60-point dotted series are byte-for-byte unchanged).
    static let markThreshold = 120
    /// Target drawn-vertex budget — a touch above a typical ~360pt plot so the line stays crisp.
    static let targetVertices = 400

    /// Min/max-bucketed copy of `points` when it exceeds `threshold`, else `points` unchanged.
    /// Assumes `points` is already sorted by date (both chart callers sort in their init).
    static func minMaxBucketed(_ points: [TrendPoint], threshold: Int, targetCount: Int) -> [TrendPoint] {
        let n = points.count
        guard n > threshold, n > 2, targetCount >= 4 else { return points }

        // Reserve the first and last; bucket the interior. Each bucket yields up to 2 vertices (min+max),
        // so aim for ~targetCount/2 buckets to land near the vertex budget.
        let first = points[0]
        let last = points[n - 1]
        let interior = n - 2
        let bucketCount = max(1, (targetCount - 2) / 2)
        guard bucketCount < interior else { return points }

        var out: [TrendPoint] = []
        out.reserveCapacity(targetCount)
        out.append(first)

        var lastEmittedDate = first.date
        for b in 0..<bucketCount {
            // Interior indices [1 ... n-2] split into `bucketCount` contiguous ranges.
            let lo = 1 + (b * interior) / bucketCount
            let hi = 1 + ((b + 1) * interior) / bucketCount // exclusive
            guard lo < hi else { continue }

            // Find the min-value and max-value samples in this bucket.
            var minIdx = lo, maxIdx = lo
            var i = lo + 1
            while i < hi {
                if points[i].value < points[minIdx].value { minIdx = i }
                if points[i].value > points[maxIdx].value { maxIdx = i }
                i += 1
            }

            // Emit the two extremes in chronological order, skipping duplicates (monotone bucket → one
            // point) and any whose date would not advance (keeps `id: Date` unique for ForEach).
            let lowFirst = minIdx <= maxIdx
            let aIdx = lowFirst ? minIdx : maxIdx
            let bIdx = lowFirst ? maxIdx : minIdx
            for idx in [aIdx, bIdx] {
                let p = points[idx]
                if p.date > lastEmittedDate {
                    out.append(p)
                    lastEmittedDate = p.date
                }
            }
        }

        if last.date > lastEmittedDate { out.append(last) }
        return out
    }
}

// MARK: - Gradient → stops bridge

extension Gradient {
    /// Reconstruct ordered stops from a Gradient. SwiftUI does not expose `.stops`
    /// directly on all paths, so we use the public `stops` mirror when present.
    func toStops() -> [Gradient.Stop] {
        // `Gradient.stops` is public on macOS 13+; expose for our sampler.
        self.stops
    }
}

#if DEBUG
private func sampleTrend(days: Int, base: Double, swing: Double) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<days).map { i in
        let date = cal.date(byAdding: .day, value: -(days - 1 - i), to: today)!
        let v = base + swing * sin(Double(i) / 3.0) + Double((i * 17) % 9) - 4
        return TrendPoint(date: date, value: max(0, v))
    }
}

#Preview("TrendChart — recovery") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recovery — 30 days").strandOverline()
        Text("Hover the line: crosshair + dot + date/value tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(points: sampleTrend(days: 30, base: 62, swing: 22))
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("TrendChart — HRV") {
    VStack(alignment: .leading, spacing: 12) {
        Text("HRV (ms) — 30 days").strandOverline()
        Text("Hover to read each day's HRV in ms.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(
            points: sampleTrend(days: 30, base: 58, swing: 14),
            gradient: StrandPalette.recoveryGradient,
            valueRange: 20...100,
            showsArea: true,
            valueFormat: { "\(Int($0.rounded())) ms" }
        )
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
