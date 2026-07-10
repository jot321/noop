import Foundation
import WhoopProtocol

/// Pulse-oximetry from the raw red/IR optical stream (docs/ADVANCED_ANALYTICS_PLAN.md §1).
///
/// APPROXIMATE / NON-CLINICAL. `spo2Sample` stores dual-wavelength ADC counts at ~1 Hz (WHOOP 4.0
/// and Oura-BLE only; the 5/MG never banks this stream), but nothing computes an SpO2 % from it —
/// `AnalyticsEngine` hard-codes `DailyMetric.spo2Pct = nil` for measured data, so a real % has only
/// ever come from an imported source. This engine is the first genuine consumer of the raw channels.
///
/// Method — the textbook ratio-of-ratios: over a short window, split each channel into its pulsatile
/// (AC) and steady (DC) parts, form `R = (AC_red/DC_red) / (AC_ir/DC_ir)`, and map `R → SpO2` with an
/// empirical linear curve seeded at `SpO2 ≈ 110 − 25·R`. The curve is a SEED: it must be calibrated
/// per-sensor against a trusted reference (the Apple Health SpO2 the app already imports) before the
/// number is shown as anything but approximate. A single ADC scale factor cancels in the AC/DC ratio,
/// so the absolute ADC units don't matter — only that red and IR share the same scale (they do).
///
/// Pure and deterministic; no DB access (persistence is wired in IntelligenceEngine). Kept in lockstep
/// with an eventual Android twin.
public enum SpO2Engine {

    // MARK: - Tunables (documented so calibration has one obvious home)

    /// Ratio-of-ratios seed curve `SpO2 = a − b·R` (Nonin/textbook empirical anchors). PROVISIONAL —
    /// replace `a`/`b` with a per-sensor fit once Bland–Altman agreement vs imported Apple Health exists.
    public static let seedA: Double = 110.0
    public static let seedB: Double = 25.0

    /// Window length for one R estimate. Long enough to hold several heartbeats at a resting rate.
    public static let windowSec: Int = 8
    /// Windows step by this stride (overlapping) so a per-window R stream is dense but not per-sample.
    public static let stepSec: Int = 4
    /// A window needs at least this many samples to be trusted (rejects sparse/dropped spans).
    public static let minSamplesPerWindow: Int = 6

    /// Perfusion-index gate: AC/DC on the IR channel must clear this (a too-flat pulse means no reliable
    /// oximetry — poor contact / low perfusion). PI is a fraction (e.g. 0.002 = 0.2 %).
    public static let minPerfusionIndex: Double = 0.001
    /// Reject a window whose R is outside a physiological envelope (maps to ~70–100 % under the seed).
    public static let minPlausibleR: Double = 0.4
    public static let maxPlausibleR: Double = 1.6
    /// Clamp the reported % to a physiological ceiling/floor so a noisy window can't print 105 % or 40 %.
    public static let minSpO2: Double = 70.0
    public static let maxSpO2: Double = 100.0

    // MARK: - Types

    /// One accepted per-window oximetry estimate.
    public struct SpO2Point: Equatable, Sendable {
        /// Wall-clock unix seconds — the right edge (last sample) of the window.
        public let ts: Int
        /// Estimated SpO2 %, clamped to `[minSpO2, maxSpO2]`.
        public let spo2: Double
        /// Ratio-of-ratios R for the window (kept for calibration / debugging).
        public let r: Double
        /// IR perfusion index (AC/DC) for the window.
        public let perfusionIndex: Double
        public init(ts: Int, spo2: Double, r: Double, perfusionIndex: Double) {
            self.ts = ts; self.spo2 = spo2; self.r = r; self.perfusionIndex = perfusionIndex
        }
    }

    // MARK: - Core

    /// Map a ratio-of-ratios `R` to SpO2 % via the (calibratable) seed curve, clamped to physiology.
    public static func spo2(fromR r: Double, a: Double = seedA, b: Double = seedB) -> Double {
        min(maxSpO2, max(minSpO2, a - b * r))
    }

    /// Estimate SpO2 over a red/IR window. Returns nil when the window fails a quality gate
    /// (too few samples, degenerate DC, insufficient perfusion, or a non-physiological R).
    public static func estimateWindow(_ samples: ArraySlice<SpO2Sample>,
                                      a: Double = seedA, b: Double = seedB) -> SpO2Point? {
        guard samples.count >= minSamplesPerWindow else { return nil }
        // Oura-BLE maps its single SpO2 channel to red=value, ir=0 — no true dual-wavelength ratio is
        // possible, so skip any window whose IR channel is the ir=0 sentinel.
        var reds: [Double] = []; reds.reserveCapacity(samples.count)
        var irs: [Double] = []; irs.reserveCapacity(samples.count)
        for s in samples {
            reds.append(Double(s.red))
            irs.append(Double(s.ir))
        }
        let dcRed = mean(reds), dcIr = mean(irs)
        guard dcRed > 0, dcIr > 0 else { return nil }
        // AC = peak-to-peak of the pulsatile component (robust, cheap; no filtering needed at this grain).
        let acRed = (reds.max()! - reds.min()!)
        let acIr = (irs.max()! - irs.min()!)
        guard acIr > 0 else { return nil }
        let piIr = acIr / dcIr
        guard piIr >= minPerfusionIndex else { return nil }
        let r = (acRed / dcRed) / (acIr / dcIr)
        guard r >= minPlausibleR, r <= maxPlausibleR else { return nil }
        let ts = samples[samples.startIndex + samples.count - 1].ts
        return SpO2Point(ts: ts, spo2: spo2(fromR: r, a: a, b: b), r: r, perfusionIndex: piIr)
    }

    /// Sweep overlapping windows across a red/IR series, restricted to `epochs` (still/asleep spans —
    /// motion corrupts optical oximetry, so callers pass the sleep-stager's asleep epochs). When
    /// `epochs` is empty every window is considered. Returns accepted per-window points in time order.
    public static func analyze(spo2: [SpO2Sample],
                               asleepRanges epochs: [(start: Int, end: Int)] = [],
                               a: Double = seedA, b: Double = seedB) -> [SpO2Point] {
        guard spo2.count >= minSamplesPerWindow else { return [] }
        let sorted = spo2.sorted { $0.ts < $1.ts }
        // A window is accepted only if its right edge falls inside an asleep/still range (when given).
        func inRange(_ ts: Int) -> Bool {
            guard !epochs.isEmpty else { return true }
            for e in epochs where ts >= e.start && ts < e.end { return true }
            return false
        }
        var out: [SpO2Point] = []
        var windowStartTs = sorted.first!.ts
        let lastTs = sorted.last!.ts
        var lo = 0
        while windowStartTs <= lastTs {
            let windowEndTs = windowStartTs + windowSec
            while lo < sorted.count && sorted[lo].ts < windowStartTs { lo += 1 }
            var hi = lo
            while hi < sorted.count && sorted[hi].ts < windowEndTs { hi += 1 }
            if hi > lo, inRange(sorted[hi - 1].ts),
               let p = estimateWindow(sorted[lo..<hi], a: a, b: b) {
                out.append(p)
            }
            windowStartTs += stepSec
        }
        return out
    }

    // MARK: - Nightly summary

    /// Nightly oximetry roll-up for the persisted `DailyMetric` + Sleep UI.
    public struct NightSummary: Equatable, Sendable {
        /// Mean SpO2 across accepted windows (the value that fills `DailyMetric.spo2Pct`).
        public let meanPct: Double
        public let medianPct: Double
        public let minPct: Double
        /// Time below 90 % as a fraction of the analyzed span (T90).
        public let t90Fraction: Double
        /// Oxygen Desaturation Index — desaturations ≥ 3 % per hour (ODI).
        public let odi: Double
        /// Count of accepted windows (a coverage/confidence proxy).
        public let sampleCount: Int
        public init(meanPct: Double, medianPct: Double, minPct: Double,
                    t90Fraction: Double, odi: Double, sampleCount: Int) {
            self.meanPct = meanPct; self.medianPct = medianPct; self.minPct = minPct
            self.t90Fraction = t90Fraction; self.odi = odi; self.sampleCount = sampleCount
        }
    }

    /// Roll accepted per-window points into a nightly summary, or nil if there is too little coverage.
    public static func nightSummary(points: [SpO2Point], minPoints: Int = 20) -> NightSummary? {
        guard points.count >= minPoints else { return nil }
        let sorted = points.sorted { $0.ts < $1.ts }
        let values = sorted.map(\.spo2)
        let mean = self.mean(values)
        let median = self.median(values)
        let minV = values.min()!
        let below90 = values.filter { $0 < 90.0 }.count
        let t90 = Double(below90) / Double(values.count)
        // ODI: count discrete drops ≥3% from a short rolling baseline, normalized to events/hour.
        let desats = desaturationCount(sorted, dropThreshold: 3.0)
        let spanSec = max(1, sorted.last!.ts - sorted.first!.ts)
        let odi = Double(desats) / (Double(spanSec) / 3600.0)
        return NightSummary(meanPct: round1(mean), medianPct: round1(median), minPct: round1(minV),
                            t90Fraction: round3(t90), odi: round2(odi), sampleCount: values.count)
    }

    /// Count discrete desaturation events: a drop of ≥ `dropThreshold` % below a trailing baseline
    /// (the running max of the last ~2 minutes), re-armed after each detected event and after recovery.
    static func desaturationCount(_ points: [SpO2Point], dropThreshold: Double,
                                  baselineWindowSec: Int = 120) -> Int {
        guard points.count > 2 else { return 0 }
        var events = 0
        var inEvent = false
        for i in points.indices {
            // Trailing baseline = max SpO2 in the window preceding this point.
            var baseline = points[i].spo2
            var j = i - 1
            while j >= 0, points[i].ts - points[j].ts <= baselineWindowSec {
                baseline = max(baseline, points[j].spo2)
                j -= 1
            }
            let drop = baseline - points[i].spo2
            if !inEvent, drop >= dropThreshold {
                events += 1
                inEvent = true
            } else if inEvent, drop < dropThreshold - 1.0 {
                // Hysteresis: only re-arm once SpO2 has recovered to within 1% of a new baseline.
                inEvent = false
            }
        }
        return events
    }

    // MARK: - Small numeric helpers (kept local so the engine is self-contained)

    static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
