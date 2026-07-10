import Foundation
import WhoopProtocol

/// Nightly heart-rate CURVE shape — the HR sibling of `ThermoCurveEngine` (same 24-bin model, same
/// gap interpolation), applied to the richer 1 Hz overnight HR stream.
///
/// Today the pipeline reduces the night's HR to a resting-HR scalar; the *trajectory* is discarded.
/// The trajectory is where the well-known insight lives: a heart rate that falls to its trough early
/// and then drifts gently up into wake ("hammock") means the body finished its recovery work with
/// hours to spare, while a trough that only arrives just before wake means something — a late meal,
/// alcohol, illness, stress — kept the system working through most of the night.
///
/// Also derives the **nocturnal dip**: how far sleeping HR drops below the daytime level. A healthy
/// autonomic system dips ~10%+ (the "dipper" pattern in the ambulatory-BP literature, mirrored in
/// HR); a shrinking dip is an early strain/illness flag.
///
/// APPROXIMATE / non-clinical. Pure/deterministic.
public enum SleepHRCurveEngine {

    /// Plausible sleeping-HR band (bpm) — a doffed strap or optical spike can't distort the curve.
    public static let minPlausibleBpm = 25
    public static let maxPlausibleBpm = 200
    /// Minimum accepted samples to model a curve (~5 worn minutes at 1 Hz per bin on average).
    public static let minSamples = 300
    /// Bin the night into this many equal-time buckets (matches ThermoCurveEngine).
    public static let binCount = 24
    /// A dip of at least this fraction is the healthy "dipper" pattern.
    public static let normalDipFraction = 0.10

    /// Where in the night the trough landed, by thirds — the shape label the UI can speak plainly.
    public enum TroughTiming: String, Equatable, Sendable {
        /// Trough in the first third: recovery work finished early.
        case early
        /// Trough in the middle third: the classic hammock.
        case mid
        /// Trough in the last third: the body was still working most of the night.
        case late

        public static func classify(troughFraction: Double) -> TroughTiming {
            if troughFraction < 1.0 / 3.0 { return .early }
            if troughFraction < 2.0 / 3.0 { return .mid }
            return .late
        }
    }

    public struct CurveFeatures: Equatable, Sendable {
        /// Per-bin mean bpm across the night (length == binCount); the display curve.
        public let curveBpm: [Double]
        /// The lowest bin's bpm — the nightly trough.
        public let troughBpm: Double
        /// Wall-clock unix seconds of the trough bin.
        public let troughTs: Int
        /// Fraction of the night [0,1] at which the trough falls (0 = sleep onset, 1 = wake).
        public let troughFraction: Double
        /// Peak-minus-trough swing of the nightly curve (bpm).
        public let amplitudeBpm: Double
        /// Mean bpm over the whole worn night.
        public let meanBpm: Double
        /// Linear slope of the FIRST half of the night (bpm/hour) — the settling descent (usually negative).
        public let declineSlopeBpmPerHour: Double
        /// Linear slope of the LAST third of the night (bpm/hour) — the natural pre-wake rise.
        public let preWakeRiseBpmPerHour: Double
        public let sampleCount: Int
        public init(curveBpm: [Double], troughBpm: Double, troughTs: Int, troughFraction: Double,
                    amplitudeBpm: Double, meanBpm: Double, declineSlopeBpmPerHour: Double,
                    preWakeRiseBpmPerHour: Double, sampleCount: Int) {
            self.curveBpm = curveBpm; self.troughBpm = troughBpm; self.troughTs = troughTs
            self.troughFraction = troughFraction; self.amplitudeBpm = amplitudeBpm
            self.meanBpm = meanBpm; self.declineSlopeBpmPerHour = declineSlopeBpmPerHour
            self.preWakeRiseBpmPerHour = preWakeRiseBpmPerHour; self.sampleCount = sampleCount
        }

        public var troughTiming: TroughTiming { TroughTiming.classify(troughFraction: troughFraction) }
    }

    /// Model the nightly curve from 1 Hz HR within `[sleepStart, sleepEnd)`. Returns nil when too few
    /// plausible worn samples fall inside the window.
    public static func analyze(hr: [HRSample], sleepStart: Int, sleepEnd: Int) -> CurveFeatures? {
        guard sleepEnd > sleepStart else { return nil }
        var pts: [(ts: Int, bpm: Double)] = []
        pts.reserveCapacity(hr.count)
        for s in hr where s.ts >= sleepStart && s.ts < sleepEnd
            && s.bpm >= minPlausibleBpm && s.bpm <= maxPlausibleBpm {
            pts.append((s.ts, Double(s.bpm)))
        }
        guard pts.count >= minSamples else { return nil }

        let spanSec = max(1, sleepEnd - sleepStart)
        var binSum = [Double](repeating: 0, count: binCount)
        var binN = [Int](repeating: 0, count: binCount)
        for p in pts {
            var idx = ((p.ts - sleepStart) * binCount) / spanSec
            if idx >= binCount { idx = binCount - 1 }
            if idx < 0 { idx = 0 }
            binSum[idx] += p.bpm
            binN[idx] += 1
        }
        var curve = [Double](repeating: Double.nan, count: binCount)
        for i in 0..<binCount where binN[i] > 0 { curve[i] = binSum[i] / Double(binN[i]) }
        curve = ThermoCurveEngine.interpolateGaps(curve)
        guard curve.allSatisfy({ $0.isFinite }) else { return nil }

        let mean = curve.reduce(0, +) / Double(binCount)
        let minBin = curve.enumerated().min { $0.element < $1.element }!
        let amplitude = curve.max()! - minBin.element
        let troughFraction = (Double(minBin.offset) + 0.5) / Double(binCount)
        let troughTs = sleepStart + Int(troughFraction * Double(spanSec))

        let hoursPerBin = (Double(spanSec) / 3600.0) / Double(binCount)
        let decline = ThermoCurveEngine.slopePerStep(Array(curve[0..<(binCount / 2)])) / hoursPerBin
        let preWake = ThermoCurveEngine.slopePerStep(Array(curve[(2 * binCount / 3)...])) / hoursPerBin

        return CurveFeatures(curveBpm: curve.map { ThermoCurveEngine.round2($0) },
                             troughBpm: ThermoCurveEngine.round2(minBin.element),
                             troughTs: troughTs,
                             troughFraction: ThermoCurveEngine.round3(troughFraction),
                             amplitudeBpm: ThermoCurveEngine.round2(amplitude),
                             meanBpm: ThermoCurveEngine.round2(mean),
                             declineSlopeBpmPerHour: ThermoCurveEngine.round3(decline),
                             preWakeRiseBpmPerHour: ThermoCurveEngine.round3(preWake),
                             sampleCount: pts.count)
    }

    /// Nocturnal dip: (day − sleep) / day, e.g. 72 bpm daytime → 58 bpm asleep = 0.194. Nil when
    /// either mean is missing or implausible, so a day the strap wasn't worn writes nothing.
    public static func nocturnalDip(daytimeMeanBpm: Double?, sleepMeanBpm: Double?) -> Double? {
        guard let day = daytimeMeanBpm, let night = sleepMeanBpm,
              day >= Double(minPlausibleBpm), day <= Double(maxPlausibleBpm),
              night >= Double(minPlausibleBpm), night <= Double(maxPlausibleBpm) else { return nil }
        return ThermoCurveEngine.round3((day - night) / day)
    }
}
