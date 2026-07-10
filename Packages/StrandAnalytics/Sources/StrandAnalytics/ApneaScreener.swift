import Foundation
import WhoopProtocol

/// Sleep-apnea SCREENING (docs/ADVANCED_ANALYTICS_PLAN.md §1) — explicitly NON-DIAGNOSTIC.
///
/// Fuses three overnight proxies into an estimated AHI band and a "consider screening" flag:
///  1. ODI (oxygen desaturation index) from `SpO2Engine.NightSummary` — the primary signal.
///  2. HR-surge microarousals from the R-R stream — apneic events end in a sympathetic surge, visible
///     as a short spike in heart rate / drop in R-R.
///  3. Movement bursts from the gravity stream — post-apnea arousals often come with a body jerk.
///
/// The output is a coarse band (`normal / mild / moderate / severe`) and a boolean flag, framed the
/// same "APPROXIMATE / non-clinical" way as the rest of the pipeline. Pure/deterministic.
public enum ApneaScreener {

    // MARK: - Tunables

    /// AHI-band cut points (events/hour), the conventional clinical bands used purely as labels here.
    public static let mildAHI: Double = 5.0
    public static let moderateAHI: Double = 15.0
    public static let severeAHI: Double = 30.0
    /// Suggest screening at/above this estimated AHI.
    public static let screenAtAHI: Double = 15.0

    /// R-R microarousal: a beat-to-beat shortening of at least this fraction vs a trailing baseline
    /// counts as an autonomic surge (heart speeding up).
    public static let rrSurgeDropFraction: Double = 0.15
    public static let rrBaselineWindowSec: Int = 60
    /// Refractory: don't count two surges closer than this (one arousal, not many).
    public static let surgeRefractorySec: Int = 20

    /// Movement burst: per-second |Δgravity| above this (g) is a jerk.
    public static let motionBurstG: Double = 0.08
    public static let motionRefractorySec: Int = 20

    // MARK: - Types

    public enum Band: String, Equatable, Sendable {
        case normal, mild, moderate, severe
    }

    public struct Result: Equatable, Sendable {
        /// Estimated apnea-hypopnea index (events/hour) — a fused proxy, NOT a measured AHI.
        public let estimatedAHI: Double
        public let band: Band
        /// True when the estimate crosses the screening threshold.
        public let suggestScreening: Bool
        /// Contributing rates (events/hour) for transparency in the UI.
        public let odi: Double
        public let microarousalIndex: Double
        public let movementIndex: Double
        /// Analyzed sleep span in hours (coverage).
        public let hoursAnalyzed: Double
        public init(estimatedAHI: Double, band: Band, suggestScreening: Bool,
                    odi: Double, microarousalIndex: Double, movementIndex: Double, hoursAnalyzed: Double) {
            self.estimatedAHI = estimatedAHI; self.band = band; self.suggestScreening = suggestScreening
            self.odi = odi; self.microarousalIndex = microarousalIndex
            self.movementIndex = movementIndex; self.hoursAnalyzed = hoursAnalyzed
        }
    }

    // MARK: - Component detectors

    /// Count HR-surge microarousals in an R-R series: each interval that is at least
    /// `rrSurgeDropFraction` shorter than the trailing-window median R-R (heart accelerating),
    /// de-duplicated by a refractory period.
    public static func microarousalCount(rr: [RRInterval]) -> Int {
        guard rr.count > 4 else { return 0 }
        let sorted = rr.sorted { $0.ts < $1.ts }
        var events = 0
        var lastEventTs: Int? = nil
        var left = 0
        for i in sorted.indices {
            let ts = sorted[i].ts
            while left < i && ts - sorted[left].ts > rrBaselineWindowSec { left += 1 }
            guard i - left >= 3 else { continue }
            let baseline = median(sorted[left..<i].map { Double($0.rrMs) })
            guard baseline > 0 else { continue }
            let drop = (baseline - Double(sorted[i].rrMs)) / baseline
            if drop >= rrSurgeDropFraction, lastEventTs.map({ ts - $0 >= surgeRefractorySec }) ?? true {
                events += 1
                lastEventTs = ts
            }
        }
        return events
    }

    /// Count movement bursts in a gravity series: a per-second |Δgravity| above `motionBurstG`,
    /// de-duplicated by a refractory period.
    public static func movementBurstCount(gravity: [GravitySample]) -> Int {
        guard gravity.count > 2 else { return 0 }
        let sorted = gravity.sorted { $0.ts < $1.ts }
        var events = 0
        var lastEventTs: Int? = nil
        var prev = sorted[0]
        for i in 1..<sorted.count {
            let s = sorted[i]
            let dx = s.x - prev.x, dy = s.y - prev.y, dz = s.z - prev.z
            let mag = (dx * dx + dy * dy + dz * dz).squareRoot()
            if mag >= motionBurstG, lastEventTs.map({ s.ts - $0 >= motionRefractorySec }) ?? true {
                events += 1
                lastEventTs = s.ts
            }
            prev = s
        }
        return events
    }

    // MARK: - Fusion

    /// Fuse ODI + microarousals + movement into an estimated AHI band.
    ///
    /// ODI is the strongest single predictor of AHI, so it dominates; the arousal and movement indices
    /// corroborate. The blend is deliberately conservative (weighted toward ODI) and coarsely banded so
    /// the number is never mistaken for a measured AHI.
    public static func screen(nightSpO2: SpO2Engine.NightSummary?,
                              rr: [RRInterval],
                              gravity: [GravitySample],
                              sleepSpanSec: Int) -> Result {
        let hours = max(0.001, Double(sleepSpanSec) / 3600.0)
        let odi = nightSpO2?.odi ?? 0
        let arousalIndex = Double(microarousalCount(rr: rr)) / hours
        let movementIndex = Double(movementBurstCount(gravity: gravity)) / hours

        // Estimated AHI: ODI carries most of the weight; arousal + movement each contribute a fraction,
        // since not every arousal/jerk is respiratory. Clamped at 0.
        let estimatedAHI = max(0, 0.7 * odi + 0.2 * arousalIndex + 0.1 * movementIndex)
        let band: Band
        switch estimatedAHI {
        case ..<mildAHI: band = .normal
        case ..<moderateAHI: band = .mild
        case ..<severeAHI: band = .moderate
        default: band = .severe
        }
        return Result(estimatedAHI: round1(estimatedAHI), band: band,
                      suggestScreening: estimatedAHI >= screenAtAHI,
                      odi: round1(odi), microarousalIndex: round1(arousalIndex),
                      movementIndex: round1(movementIndex), hoursAnalyzed: round2(hours))
    }

    // MARK: - Helpers

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}
