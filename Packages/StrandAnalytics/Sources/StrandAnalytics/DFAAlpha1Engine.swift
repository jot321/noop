import Foundation
import WhoopProtocol

/// DFA-α1 — the short-term detrended-fluctuation scaling exponent of the beat-to-beat (R-R) series.
/// It is a lab-free proxy for exercise intensity thresholds: α1 falls through ~0.75 around the aerobic
/// (first ventilatory) threshold and through ~0.5 around the anaerobic threshold, so a single number
/// derived purely from HRV places the current effort in a training zone that otherwise needs gas-exchange
/// or lactate testing. WHOOP itself doesn't expose this.
///
/// ⚠️ EXPERIMENTAL / non-clinical. Unlike the nightly engines this is NOT pure math on data we already
/// trust: DFA-α1 needs clean R-R *during exercise*, and wrist-PPG beat detection under motion is heavily
/// artifact-laden (published DFA-α1 tooling assumes a chest strap). So the engine gates hard on artifact
/// fraction — if more than `maxArtifactFraction` of beats needed correction it returns nil and the metric
/// self-hides — and it is only meaningful for steady, low-motion cardio (cycling, easy runs). Treat the
/// output as experimental until validated against a chest strap.
///
/// Pure/deterministic.
public enum DFAAlpha1Engine {

    // MARK: - Tunables

    /// Box sizes (beats) the short-term exponent α1 is fit over — the standard 4…16 window.
    public static let minBox = 4
    public static let maxBox = 16
    /// Minimum beats for a stable α1 (need several non-overlapping max-size boxes). ~2 min of exercise HR.
    public static let minBeats = 120
    /// Artifact-correction threshold: a beat whose R-R differs from the running reference by more than
    /// this fraction is treated as an ectopic/missed beat and corrected (and counted).
    public static let artifactThreshold = 0.05
    /// Hard gate: if the corrected fraction exceeds this, the window is too noisy to trust — return nil.
    public static let maxArtifactFraction = 0.05
    /// Physiological R-R bounds (ms): ~250 ms (240 bpm) to ~2000 ms (30 bpm). Outside → artifact.
    public static let minRRms = 250.0
    public static let maxRRms = 2000.0

    // MARK: - Zones

    /// Intensity zone implied by α1 (the two published threshold crossings). Screening language only.
    public enum Zone: String, Equatable, Sendable {
        case belowAerobic     // α1 ≥ 0.75 — easy / below the aerobic threshold
        case aerobic          // 0.5 ≤ α1 < 0.75 — between aerobic and anaerobic thresholds ("tempo")
        case aboveAnaerobic   // α1 < 0.5 — above the anaerobic threshold (hard)

        public static func classify(_ alpha1: Double) -> Zone {
            if alpha1 >= 0.75 { return .belowAerobic }
            if alpha1 >= 0.5 { return .aerobic }
            return .aboveAnaerobic
        }
    }

    public struct Result: Equatable, Sendable {
        /// The short-term scaling exponent (typically ~0.5…1.5 for exercise HRV).
        public let alpha1: Double
        /// Implied intensity zone.
        public let zone: Zone
        /// Fraction of beats corrected as artifacts (≤ maxArtifactFraction, else no Result).
        public let artifactFraction: Double
        /// Clean beats that informed the fit (after correction).
        public let beatCount: Int
        public init(alpha1: Double, zone: Zone, artifactFraction: Double, beatCount: Int) {
            self.alpha1 = alpha1; self.zone = zone
            self.artifactFraction = artifactFraction; self.beatCount = beatCount
        }
    }

    // MARK: - Public entry

    /// Compute DFA-α1 from a window of R-R intervals. Returns nil when there are too few beats, or when
    /// the artifact fraction exceeds `maxArtifactFraction` (the wrist-PPG-under-motion gate), or when the
    /// series is degenerate (no variance). Convenience overload accepts decoded `[RRInterval]`.
    public static func analyze(rr: [RRInterval]) -> Result? {
        analyze(rrMs: rr.map { Double($0.rrMs) })
    }

    /// Core: `rrMs` is the ordered beat-to-beat interval series in milliseconds.
    public static func analyze(rrMs: [Double]) -> Result? {
        guard rrMs.count >= minBeats else { return nil }

        // 1) Artifact correction. Walk the series keeping a running reference (the last accepted beat);
        //    a beat outside the physiological bounds OR deviating > artifactThreshold from the reference
        //    is replaced by the reference (a conservative hold — never fabricates variability) and counted.
        var cleaned = [Double]()
        cleaned.reserveCapacity(rrMs.count)
        var artifacts = 0
        var reference = rrMs.first { $0 >= minRRms && $0 <= maxRRms } ?? rrMs[0]
        for v in rrMs {
            let plausible = v >= minRRms && v <= maxRRms
            let deviates = reference > 0 && abs(v - reference) / reference > artifactThreshold
            if !plausible || deviates {
                artifacts += 1
                cleaned.append(reference)          // hold the last good value
            } else {
                cleaned.append(v)
                reference = v
            }
        }

        let artifactFraction = Double(artifacts) / Double(rrMs.count)
        guard artifactFraction <= maxArtifactFraction else { return nil }

        guard let alpha1 = dfaAlpha(cleaned, minBox: minBox, maxBox: maxBox) else { return nil }
        return Result(alpha1: alpha1, zone: Zone.classify(alpha1),
                      artifactFraction: artifactFraction, beatCount: cleaned.count)
    }

    // MARK: - DFA core (pure)

    /// Detrended Fluctuation Analysis scaling exponent over box sizes [minBox, maxBox]. Returns nil if
    /// the series is too short for at least two distinct box sizes or has no fluctuation to scale.
    static func dfaAlpha(_ series: [Double], minBox: Int, maxBox: Int) -> Double? {
        let n = series.count
        guard n >= 2 * minBox else { return nil }

        // 1) Integrate the mean-removed series: y(k) = Σ_{i≤k}(x_i − mean).
        let mean = series.reduce(0, +) / Double(n)
        var y = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<n { acc += series[i] - mean; y[i] = acc }

        // 2) For each box size, F(n) = RMS of the per-box least-squares detrended residuals.
        var logN = [Double]()
        var logF = [Double]()
        let hi = Swift.min(maxBox, n / 2)   // need ≥2 boxes for a stable per-box fit
        guard hi >= minBox else { return nil }
        for box in minBox...hi {
            guard let f = fluctuation(y, box: box), f > 0 else { continue }
            logN.append(log(Double(box)))
            logF.append(log(f))
        }
        guard logN.count >= 2 else { return nil }

        // 3) α = slope of log F vs log n (least squares).
        return slope(x: logN, y: logF)
    }

    /// RMS fluctuation for one box size: split `y` into non-overlapping boxes of `box` samples, fit and
    /// remove a least-squares line in each, and RMS the residuals across all boxes. nil if no full box.
    static func fluctuation(_ y: [Double], box: Int) -> Double? {
        let boxes = y.count / box
        guard boxes >= 1 else { return nil }
        var sumSq = 0.0
        var count = 0
        for b in 0..<boxes {
            let lo = b * box
            // Local least-squares line over indices 0..<box within this box.
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for j in 0..<box {
                let x = Double(j), v = y[lo + j]
                sx += x; sy += v; sxx += x * x; sxy += x * v
            }
            let m = Double(box)
            let denom = m * sxx - sx * sx
            let slope = denom != 0 ? (m * sxy - sx * sy) / denom : 0
            let intercept = (sy - slope * sx) / m
            for j in 0..<box {
                let fit = slope * Double(j) + intercept
                let resid = y[lo + j] - fit
                sumSq += resid * resid
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sumSq / Double(count)).squareRoot()
    }

    /// Least-squares slope of y vs x.
    static func slope(x: [Double], y: [Double]) -> Double? {
        let n = Double(x.count)
        guard n >= 2 else { return nil }
        let sx = x.reduce(0, +), sy = y.reduce(0, +)
        var sxx = 0.0, sxy = 0.0
        for i in 0..<x.count { sxx += x[i] * x[i]; sxy += x[i] * y[i] }
        let denom = n * sxx - sx * sx
        guard denom != 0 else { return nil }
        return (n * sxy - sx * sy) / denom
    }
}
