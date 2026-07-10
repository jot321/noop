import Foundation
import WhoopProtocol

/// Nightly skin-temperature CURVE shape (docs/ADVANCED_ANALYTICS_PLAN.md §4).
///
/// Today the pipeline reduces `skinTempSample` to a single nightly mean → deviation scalar
/// (`AnalyticsEngine.wornNightlySkinTempC`), discarding the *shape* of the overnight curve. Skin
/// temperature normally rises after sleep onset, plateaus, then falls before wake — a proxy for the
/// circadian core-temperature rhythm. This engine models that curve and extracts its features
/// (nocturnal nadir time, amplitude, slope), which enrich illness lead-time and cycle-phase tracking.
///
/// Uses the existing device-family-aware `skinTempCelsius(raw:family:)` for ADC→°C. APPROXIMATE /
/// non-clinical; the 4.0 conversion is provisional (see WhoopProtocol). Pure/deterministic.
public enum ThermoCurveEngine {

    /// Plausible worn skin-temp band (°C) — mirrors the funnel gate in AnalyticsEngine so a doffed or
    /// bad-ADC sample can't distort the curve.
    public static let minWornC: Double = 28.0
    public static let maxWornC: Double = 42.0
    /// Minimum accepted samples to model a curve.
    public static let minSamples: Int = 120
    /// Bin the night into this many equal-time buckets for a smooth, sample-count-independent curve.
    public static let binCount: Int = 24

    public struct CurveFeatures: Equatable, Sendable {
        /// Per-bin mean °C across the night (length == binCount when present); the display curve.
        public let curveC: [Double]
        /// Wall-clock unix seconds of the coldest bin (nadir timing → circadian phase proxy).
        public let nadirTs: Int
        /// Fraction of the night [0,1] at which the nadir falls (0 = sleep onset, 1 = wake).
        public let nadirFraction: Double
        /// Peak-minus-trough amplitude of the nightly curve (°C).
        public let amplitudeC: Double
        /// Mean °C over the whole worn night (== the legacy scalar, kept for continuity).
        public let meanC: Double
        /// Linear slope of the FIRST half of the night (°C/hour) — the nocturnal rise.
        public let riseSlopeCPerHour: Double
        /// Linear slope of the LAST third of the night (°C/hour) — the pre-wake drop (usually negative).
        public let preWakeSlopeCPerHour: Double
        public let sampleCount: Int
        public init(curveC: [Double], nadirTs: Int, nadirFraction: Double, amplitudeC: Double,
                    meanC: Double, riseSlopeCPerHour: Double, preWakeSlopeCPerHour: Double, sampleCount: Int) {
            self.curveC = curveC; self.nadirTs = nadirTs; self.nadirFraction = nadirFraction
            self.amplitudeC = amplitudeC; self.meanC = meanC; self.riseSlopeCPerHour = riseSlopeCPerHour
            self.preWakeSlopeCPerHour = preWakeSlopeCPerHour; self.sampleCount = sampleCount
        }
    }

    /// Model the nightly curve from raw skin-temp samples within `[sleepStart, sleepEnd)`.
    ///
    /// - `skinTemp`: raw ADC samples (any span; filtered to the sleep window internally).
    /// - `family`: device family for the ADC→°C conversion.
    /// - `sleepStart/sleepEnd`: the main-night window (wall-clock unix seconds).
    /// Returns nil if too few plausible worn samples fall inside the window.
    public static func analyze(skinTemp: [SkinTempSample],
                               family: DeviceFamily,
                               sleepStart: Int,
                               sleepEnd: Int) -> CurveFeatures? {
        guard sleepEnd > sleepStart else { return nil }
        // Convert + gate to plausible worn °C inside the sleep window.
        var pts: [(ts: Int, c: Double)] = []
        pts.reserveCapacity(skinTemp.count)
        for s in skinTemp where s.ts >= sleepStart && s.ts < sleepEnd {
            let c = skinTempCelsius(raw: s.raw, family: family)
            if c >= minWornC && c <= maxWornC { pts.append((s.ts, c)) }
        }
        guard pts.count >= minSamples else { return nil }
        pts.sort { $0.ts < $1.ts }

        let spanSec = max(1, sleepEnd - sleepStart)
        // Bin into equal-time buckets; each bin's value is the mean of samples that land in it. Empty
        // bins are linearly interpolated from their neighbours so the curve is continuous.
        var binSum = [Double](repeating: 0, count: binCount)
        var binN = [Int](repeating: 0, count: binCount)
        for p in pts {
            var idx = ((p.ts - sleepStart) * binCount) / spanSec
            if idx >= binCount { idx = binCount - 1 }
            if idx < 0 { idx = 0 }
            binSum[idx] += p.c
            binN[idx] += 1
        }
        var curve = [Double](repeating: Double.nan, count: binCount)
        for i in 0..<binCount where binN[i] > 0 { curve[i] = binSum[i] / Double(binN[i]) }
        curve = interpolateGaps(curve)
        guard curve.allSatisfy({ $0.isFinite }) else { return nil }

        let meanC = curve.reduce(0, +) / Double(binCount)
        let minBin = curve.enumerated().min { $0.element < $1.element }!
        let maxV = curve.max()!
        let amplitude = maxV - minBin.element
        let nadirFraction = (Double(minBin.offset) + 0.5) / Double(binCount)
        let nadirTs = sleepStart + Int(nadirFraction * Double(spanSec))

        let hoursPerBin = (Double(spanSec) / 3600.0) / Double(binCount)
        let firstHalf = Array(curve[0..<(binCount / 2)])
        let lastThird = Array(curve[(2 * binCount / 3)...])
        let riseSlope = slopePerStep(firstHalf) / hoursPerBin
        let preWakeSlope = slopePerStep(lastThird) / hoursPerBin

        return CurveFeatures(curveC: curve.map { round2($0) },
                             nadirTs: nadirTs, nadirFraction: round3(nadirFraction),
                             amplitudeC: round2(amplitude), meanC: round2(meanC),
                             riseSlopeCPerHour: round3(riseSlope),
                             preWakeSlopeCPerHour: round3(preWakeSlope),
                             sampleCount: pts.count)
    }

    // MARK: - Helpers

    /// Fill NaN gaps by linear interpolation between the nearest finite neighbours; clamp-extends the
    /// first/last finite value to the ends.
    static func interpolateGaps(_ input: [Double]) -> [Double] {
        var out = input
        let firstFinite = out.firstIndex { $0.isFinite }
        let lastFinite = out.lastIndex { $0.isFinite }
        guard let lo = firstFinite, let hi = lastFinite else { return out }
        for i in 0..<lo { out[i] = out[lo] }
        for i in (hi + 1)..<out.count { out[i] = out[hi] }
        var i = lo
        while i <= hi {
            if out[i].isFinite { i += 1; continue }
            let gapStart = i - 1
            var j = i
            while j <= hi && !out[j].isFinite { j += 1 }
            let a = out[gapStart], b = out[j]
            let steps = j - gapStart
            for k in (gapStart + 1)..<j {
                out[k] = a + (b - a) * Double(k - gapStart) / Double(steps)
            }
            i = j
        }
        return out
    }

    /// Ordinary least-squares slope (Δvalue per index step) of an evenly-spaced series.
    static func slopePerStep(_ ys: [Double]) -> Double {
        let n = ys.count
        guard n >= 2 else { return 0 }
        let xs = (0..<n).map(Double.init)
        let mx = xs.reduce(0, +) / Double(n)
        let my = ys.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for i in 0..<n {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        return den == 0 ? 0 : num / den
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
