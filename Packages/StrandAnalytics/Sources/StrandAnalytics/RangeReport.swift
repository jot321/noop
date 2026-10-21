import Foundation

// RangeReport.swift — the data model for a shareable offline "trends report" over a
// date range. Pure aggregation ONLY — there is NO rendering here. The UI layer builds
// the PDF/PNG view from this struct; this file just turns sparse day→value series into
// a clean, explainable set of per-metric range statistics.
//
// Pure, deterministic, DB-free. Given each metric's daily series as a [dayKey: Double]
// map (any metric may be missing, any day may be absent) and an inclusive
// [start, end] "yyyy-MM-dd" range, this produces a RangeReport with, per metric that
// has at least one value in range:
//
//   • n            — days carrying a value inside the range
//   • mean         — average of those values
//   • min / max    — the lowest / highest value AND the day it fell on
//   • firstHalf vs secondHalf mean — the readings split at the midpoint date between the
//                    first and last one, so a reader can see whether the back half ran higher
//   • trend        — rising / falling / flat, from the OLS slope per calendar day of the
//                    values against a small per-metric threshold (so noise reads as "flat")
//   • latest       — the value on the latest day present in range
//
// Plus the range itself (start / end / totalDays covered) and a short headline stat set
// the UI can show at the top of the report.
//
// Day keys are the same "yyyy-MM-dd" strings AnalyticsEngine emits; lexicographic order
// IS chronological order for zero-padded ISO days, so we sort/compare on the raw string
// (exactly the way WeeklyDigest does) — no Date, no timezone, no locale. The engine is
// self-contained; only the shared DayWindow helpers at the end borrow WeeklyDigest's addDays.

// MARK: - Metric identity

/// The metrics a range report can summarise. `workouts` and `stress` (#457) lead the
/// list so they rank first in the report; the rest keep their established order.
public enum ReportMetric: String, CaseIterable, Sendable {
    case workouts     // logged workouts per day, count
    case stress       // daily stress score, 0–3 (lower is calmer)
    case recovery     // Charge / recovery, 0–100
    case sleepHours   // time asleep, hours
    case hrv          // heart-rate variability, ms
    case restingHr    // resting heart rate, bpm
    case strain       // Effort / strain, 0–100
    case respRate     // respiratory rate during sleep, breaths/min
    case skinTempDev  // skin-temperature deviation from baseline, °C (signed)

    /// Human label for the metric (matches the rest of the app's naming).
    public var label: String {
        switch self {
        case .workouts:    return "Workouts"
        case .stress:      return "Stress"
        case .recovery:    return "Recovery"
        case .sleepHours:  return "Sleep"
        case .hrv:         return "HRV"
        case .restingHr:   return "Resting HR"
        case .strain:      return "Strain"
        case .respRate:    return "Respiratory rate"
        case .skinTempDev: return "Skin temp"
        }
    }

    /// Display unit suffix (empty for the unitless 0–100 scores and the 0–3 stress index).
    public var unit: String {
        switch self {
        case .recovery, .strain, .stress: return ""
        case .workouts:          return "/day"
        case .sleepHours:        return "h"
        case .hrv:               return "ms"
        case .restingHr:         return "bpm"
        case .respRate:          return "br/min"
        case .skinTempDev:       return "°C"
        }
    }

    /// Whether the metric's values are shown to one decimal place (fractional scores /
    /// rates) rather than as whole numbers. Workouts is a whole count; stress is a 0–3
    /// index shown to one decimal so small moves read.
    public var usesOneDecimal: Bool {
        switch self {
        case .sleepHours, .respRate, .skinTempDev, .stress, .workouts: return true
        default:                                                       return false
        }
    }

    /// True when a HIGHER value is the better outcome. Resting HR, respiratory rate and
    /// stress are the metrics where lower is better. (Ignored for valence-free metrics —
    /// see `framesGoodBad`.)
    public var higherIsBetter: Bool {
        switch self {
        case .restingHr, .respRate, .stress: return false
        default:                             return true
        }
    }

    /// Whether a rising/falling move carries a clear good/bad valence. False for a signed
    /// deviation metric (skin-temp Δ), for workout count (more or fewer sessions is a
    /// lifestyle choice, not inherently good/bad) and for strain (Effort has no better
    /// direction in the metric catalog: more load is not a good sign by itself) — the report
    /// then shows the trend direction without a "good sign / worth a look" verdict, and
    /// colours the change chip neutrally.
    public var framesGoodBad: Bool {
        switch self {
        case .skinTempDev, .workouts, .strain: return false
        default:                               return true
        }
    }

    /// Minimum |slope-per-day| (in the metric's own units) before a trend is called
    /// rising/falling rather than flat. Deliberately conservative, deterministic
    /// constants (not personal baselines) so the read is stable and explainable.
    public var trendSlopeThreshold: Double {
        switch self {
        case .workouts:    return 0.03  // workouts / day (~0.2/week — a clear shift in habit)
        case .stress:      return 0.02  // stress points / day (~0.14/week on the 0–3 scale)
        case .recovery:    return 0.5   // recovery points / day
        case .strain:      return 0.5   // Effort points / day
        case .sleepHours:  return 0.05  // hours / day (~3 min/day)
        case .hrv:         return 0.4   // ms / day
        case .restingHr:   return 0.2   // bpm / day
        case .respRate:    return 0.1   // breaths/min / day (~0.7/week flags illness onset)
        case .skinTempDev: return 0.03  // °C / day (~0.2°C/week)
        }
    }
}

/// Which way a metric moved across the range (by OLS slope vs a small threshold).
public enum ReportTrend: String, Equatable, Sendable {
    case rising
    case falling
    case flat
}

// MARK: - A day-stamped value

/// A value paired with the day it fell on ("yyyy-MM-dd").
public struct DayValue: Equatable, Sendable {
    public let day: String
    public let value: Double

    public init(day: String, value: Double) {
        self.day = day
        self.value = value
    }
}

// MARK: - Per-metric range statistics

/// One metric's summary over the report range. Only produced for metrics that carried
/// at least one value in range (so every field is meaningful — no fabricated zeros).
public struct MetricRangeStat: Equatable, Sendable {
    public let metric: ReportMetric
    /// Days carrying a value inside the range.
    public let n: Int
    /// Mean of the in-range values.
    public let mean: Double
    /// The lowest value and the day it fell on.
    public let min: DayValue
    /// The highest value and the day it fell on.
    public let max: DayValue
    /// Mean of the readings before the midpoint date of the in-range readings.
    public let firstHalfMean: Double
    /// Mean of the readings on or after that midpoint date.
    public let secondHalfMean: Double
    /// Trend direction over the range (rising / falling / flat).
    public let trend: ReportTrend
    /// The value on the latest day present in range.
    public let latest: DayValue

    public init(metric: ReportMetric, n: Int, mean: Double, min: DayValue, max: DayValue,
                firstHalfMean: Double, secondHalfMean: Double, trend: ReportTrend,
                latest: DayValue) {
        self.metric = metric
        self.n = n
        self.mean = mean
        self.min = min
        self.max = max
        self.firstHalfMean = firstHalfMean
        self.secondHalfMean = secondHalfMean
        self.trend = trend
        self.latest = latest
    }

    /// Signed first→second half change (secondHalfMean − firstHalfMean) in the metric's
    /// own units.
    public var halfDelta: Double { secondHalfMean - firstHalfMean }
}

// MARK: - Report

/// The complete shareable trends report over a date range.
public struct RangeReport: Equatable, Sendable {
    /// Inclusive start day of the range ("yyyy-MM-dd").
    public let start: String
    /// Inclusive end day of the range ("yyyy-MM-dd").
    public let end: String
    /// Number of calendar days the range spans (inclusive). 0 for an invalid range.
    public let totalDays: Int
    /// Per-metric stats, in ReportMetric.allCases order, for metrics that had ≥ 1 value
    /// in range. Metrics with no in-range data are OMITTED entirely.
    public let metrics: [MetricRangeStat]
    /// A short headline set the UI can show at the top — one line per present metric,
    /// most-improved/most-notable first, already plain-English.
    public let headlines: [String]

    public init(start: String, end: String, totalDays: Int,
                metrics: [MetricRangeStat], headlines: [String]) {
        self.start = start
        self.end = end
        self.totalDays = totalDays
        self.metrics = metrics
        self.headlines = headlines
    }

    /// Look up one metric's stat (nil when that metric had no in-range data).
    public func stat(_ metric: ReportMetric) -> MetricRangeStat? {
        metrics.first { $0.metric == metric }
    }

    /// True when no metric carried a single reading in range (caller can show an empty
    /// state instead of a report).
    public var isEmpty: Bool { metrics.isEmpty }
}

// MARK: - Engine

public enum RangeReportEngine {

    // MARK: - Entry point

    /// Build a RangeReport over the inclusive [start, end] day range from each metric's
    /// day→value series.
    ///
    /// - Parameters:
    ///   - metrics: per-metric day→value maps ("yyyy-MM-dd" → value). Missing metrics
    ///     and missing days are simply absent; this is robust to sparse data.
    ///   - start: inclusive range start, "yyyy-MM-dd".
    ///   - end: inclusive range end, "yyyy-MM-dd".
    ///
    /// If `end` sorts before `start` the range is treated as empty (no metrics, 0 days).
    public static func build(metrics: [ReportMetric: [String: Double]],
                             start: String, end: String) -> RangeReport {
        // A valid window requires start <= end (ISO string compare == chronological).
        guard start <= end else {
            return RangeReport(start: start, end: end, totalDays: 0,
                               metrics: [], headlines: [])
        }
        let totalDays = dayCount(start: start, end: end)

        var stats: [MetricRangeStat] = []
        for metric in ReportMetric.allCases {
            let series = metrics[metric] ?? [:]
            // In-range entries, ordered chronologically by their day string.
            let ordered = series
                .filter { $0.key >= start && $0.key <= end }
                .sorted { $0.key < $1.key }
            guard !ordered.isEmpty else { continue }   // omit metrics with no data

            let days = ordered.map { $0.key }
            let values = ordered.map { $0.value }
            let n = values.count

            let mn = mean(values)

            // Min / max carry the day they fell on. On ties, the EARLIEST day wins
            // (values are already in chronological order, so the first hit is earliest).
            var minDV = DayValue(day: days[0], value: values[0])
            var maxDV = DayValue(day: days[0], value: values[0])
            for i in 1..<n {
                if values[i] < minDV.value { minDV = DayValue(day: days[i], value: values[i]) }
                if values[i] > maxDV.value { maxDV = DayValue(day: days[i], value: values[i]) }
            }

            // Split at the midpoint DATE between the first and last reading, so a gap in the
            // data can't put old readings in the "recent" half (DayWindow.halfMeans). With a
            // single reading both halves fall back to it (equal, so no fabricated movement).
            let halves = DayWindow.halfMeans(days: days, values: values)
            let firstMean = halves?.earlier ?? mn
            let secondMean = halves?.later ?? mn

            // Slope per calendar day, matching the per-day thresholds; per reading, a month-long
            // gap counted as one step.
            let slope = DayWindow.slopePerDay(days: days, values: values)
            let trend = trendFromSlope(slope, threshold: metric.trendSlopeThreshold)

            let latest = DayValue(day: days[n - 1], value: values[n - 1])

            stats.append(MetricRangeStat(
                metric: metric, n: n, mean: mn, min: minDV, max: maxDV,
                firstHalfMean: firstMean, secondHalfMean: secondMean,
                trend: trend, latest: latest))
        }

        let headlines = makeHeadlines(stats)
        return RangeReport(start: start, end: end, totalDays: totalDays,
                           metrics: stats, headlines: headlines)
    }

    // MARK: - Headlines

    /// One plain-English line per present metric, ranked most-notable first. "Notable"
    /// is the absolute first→second-half change scaled by the metric's trend threshold,
    /// so movers on different units are comparable. Folds in good/bad framing.
    static func makeHeadlines(_ stats: [MetricRangeStat]) -> [String] {
        let ranked = stats.sorted { salience($0) > salience($1) }
        return ranked.map { headline($0) }
    }

    /// |half delta| normalised by the metric's trend threshold (a units-agnostic move).
    static func salience(_ s: MetricRangeStat) -> Double {
        let t = s.metric.trendSlopeThreshold
        return t > 0 ? abs(s.halfDelta) / t : abs(s.halfDelta)
    }

    /// Render one metric's headline. Trend word + good/bad framing + the two half means.
    static func headline(_ s: MetricRangeStat) -> String {
        let word: String
        switch s.trend {
        case .rising:  word = "trending up"
        case .falling: word = "trending down"
        case .flat:    word = "holding steady"
        }
        let frame: String
        if s.trend == .flat || !s.metric.framesGoodBad {
            // Flat, or a signed-deviation metric with no inherent good/bad direction.
            frame = ""
        } else {
            let up = s.trend == .rising
            let good = (up == s.metric.higherIsBetter)
            frame = good ? " - a good sign" : " - worth a look"
        }
        let unit = s.metric.unit.isEmpty ? "" : " \(s.metric.unit)"
        return "\(s.metric.label) is \(word) (avg \(round1(s.firstHalfMean))\(unit) → "
            + "\(round1(s.secondHalfMean))\(unit))\(frame)."
    }

    // MARK: - Trend

    /// Map an OLS slope-per-day to a direction against a small threshold. Within ±
    /// threshold reads as flat (noise), so a near-level series never fakes a trend.
    static func trendFromSlope(_ slope: Double, threshold: Double) -> ReportTrend {
        if slope > threshold { return .rising }
        if slope < -threshold { return .falling }
        return .flat
    }

    // MARK: - Day math (timezone/locale-free, ISO string in → integer out)

    /// Inclusive day count between two "yyyy-MM-dd" days. 1 for the same day. 0 when
    /// either day is unparseable or end sorts before start.
    static func dayCount(start: String, end: String) -> Int {
        guard let (sy, sm, sd) = parseYMD(start),
              let (ey, em, ed) = parseYMD(end) else { return 0 }
        let diff = julianDayNumber(ey, em, ed) - julianDayNumber(sy, sm, sd)
        return diff < 0 ? 0 : diff + 1
    }

    /// Parse "yyyy-MM-dd" into validated integer components (real calendar date only).
    static func parseYMD(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        return (y, m, d)
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11:           return 30
        case 2: return isLeap(y) ? 29 : 28
        default: return 0
        }
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) }

    /// Proleptic-Gregorian date → Julian Day Number (integer-only, timezone-free).
    static func julianDayNumber(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let a = (14 - m) / 12
        let yy = y + 4800 - a
        let mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    // MARK: - Stats (self-contained so the Kotlin mirror is line-for-line)

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}

// MARK: - Calendar-day windows (shared)

/// Calendar-day arithmetic on "yyyy-MM-dd" keys, shared by the report and the trend screens so every
/// window, half split and slope counts DAYS, not readings. With the strap off for weeks, counting
/// readings squeezed a month into one step and mixed July into a "recent" half (2026-10-21). Pure and
/// timezone-free: callers anchor a window on the local today key (or the latest reading) themselves.
public enum DayWindow {

    /// The day's position on a continuous day line (its Julian Day Number), nil when unparseable.
    public static func dayNumber(_ day: String) -> Int? {
        guard let (y, m, d) = RangeReportEngine.parseYMD(day) else { return nil }
        return RangeReportEngine.julianDayNumber(y, m, d)
    }

    /// `day` moved by `n` calendar days.
    public static func addDays(_ day: String, _ n: Int) -> String { WeeklyDigestEngine.addDays(day, n) }

    /// First day of the trailing `days`-day window that ends on `end` (inclusive).
    public static func windowStart(endingOn end: String, days: Int) -> String {
        addDays(end, -(Swift.max(1, days) - 1))
    }

    /// The window of the same length that ends the day before `start`. nil for an invalid range.
    public static func previousWindow(start: String, end: String) -> (start: String, end: String)? {
        guard let a = dayNumber(start), let b = dayNumber(end), b >= a else { return nil }
        let length = b - a + 1
        return (addDays(start, -length), addDays(start, -1))
    }

    /// Means of the earlier and later halves, split at the midpoint DATE between the first and last
    /// day; a day exactly on the midpoint joins the later half (an odd run gives the extra day to the
    /// recent side). nil when either half is empty. `days` and `values` are parallel.
    public static func halfMeans(days: [String], values: [Double]) -> (earlier: Double, later: Double)? {
        let xs = days.compactMap(dayNumber)
        guard xs.count == values.count, let lo = xs.min(), let hi = xs.max(), hi > lo else { return nil }
        let mid = Double(lo + hi) / 2
        var early: [Double] = [], late: [Double] = []
        for (x, v) in zip(xs, values) {
            if Double(x) < mid { early.append(v) } else { late.append(v) }
        }
        guard !early.isEmpty, !late.isEmpty else { return nil }
        return (RangeReportEngine.mean(early), RangeReportEngine.mean(late))
    }

    /// OLS slope of value against calendar day (units per day). 0 with fewer than two distinct days.
    public static func slopePerDay(days: [String], values: [Double]) -> Double {
        let xs = days.compactMap(dayNumber)
        guard xs.count == values.count, xs.count >= 2, let x0 = xs.first else { return 0 }
        let fx = xs.map { Double($0 - x0) }
        let meanX = RangeReportEngine.mean(fx)
        let meanY = RangeReportEngine.mean(values)
        var num = 0.0, den = 0.0
        for (x, v) in zip(fx, values) {
            num += (x - meanX) * (v - meanY)
            den += (x - meanX) * (x - meanX)
        }
        return den == 0 ? 0 : num / den
    }
}
