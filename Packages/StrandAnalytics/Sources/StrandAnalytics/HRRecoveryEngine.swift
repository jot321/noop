import Foundation
import WhoopProtocol

/// Post-workout heart-rate recovery (HRR): how many bpm the heart drops in the first 60/120 seconds
/// after exercise stops — one of the strongest longitudinal cardio-fitness markers in the literature
/// (a blunted 1-minute drop is a classic deconditioning / fatigue flag).
///
/// Method: median bpm in a short window straddling the workout end ("end HR"), minus the median bpm
/// in a ±10 s window centred on end+60 s (and end+120 s when covered). Medians, not single samples,
/// so one dropped packet or optical spike can't fabricate a recovery number. Gated on an ELEVATED end
/// HR — walking out of a stretch session at 85 bpm has no recovery to measure, and printing "HRR 4"
/// for it would be noise dressed as insight.
///
/// APPROXIMATE / non-clinical, like every derived metric in this package. Pure/deterministic.
public enum HRRecoveryEngine {

    /// Plausible worn HR band (bpm) — samples outside it are ignored, mirroring the funnel gates the
    /// nightly engines use so a doffed strap can't distort the medians.
    public static let minPlausibleBpm = 25
    public static let maxPlausibleBpm = 230
    /// End HR must be at least this for a recovery to be meaningful (a genuinely elevated finish).
    public static let minEndBpm = 100
    /// Minimum samples in the end window AND in each recovery window (1 Hz → most of the window).
    public static let minWindowSamples = 5
    /// End window: [end - 20 s, end + 5 s] — the strap keeps streaming through the stop tap.
    public static let endWindowBefore = 20
    public static let endWindowAfter = 5
    /// Recovery windows: ±10 s around end+60 / end+120.
    public static let recoveryHalfWindow = 10

    public struct Result: Equatable, Sendable {
        /// Median bpm across the end window — the elevated finish the drops are measured from.
        public let endBpm: Double
        /// Median bpm around end+60 s.
        public let bpmAt60: Double
        /// Median bpm around end+120 s, when the strap kept streaming that long.
        public let bpmAt120: Double?
        /// The headline: endBpm − bpmAt60 (bpm recovered in the first minute).
        public let drop60: Double
        /// endBpm − bpmAt120, when covered.
        public let drop120: Double?
        /// Plausible samples that informed the three windows.
        public let sampleCount: Int
        public init(endBpm: Double, bpmAt60: Double, bpmAt120: Double?, drop60: Double,
                    drop120: Double?, sampleCount: Int) {
            self.endBpm = endBpm; self.bpmAt60 = bpmAt60; self.bpmAt120 = bpmAt120
            self.drop60 = drop60; self.drop120 = drop120; self.sampleCount = sampleCount
        }
    }

    /// Fitness band for a 1-minute drop, for UI copy. Cut points follow the common exercise-physiology
    /// convention (≥12 bpm expected in healthy adults after moderate+ effort; well-trained ≥25).
    /// Screening language only — never a diagnosis.
    public enum Band: String, Equatable, Sendable {
        case excellent, good, fair, low

        public static func classify(drop60: Double) -> Band {
            switch drop60 {
            case 25...: return .excellent
            case 18..<25: return .good
            case 12..<18: return .fair
            default: return .low
            }
        }
    }

    /// Measure the recovery after a workout that ended at `workoutEnd` (unix seconds). `hr` may be any
    /// span covering the end; it is filtered to the three windows internally. Returns nil when the
    /// finish wasn't elevated (< `minEndBpm`) or any needed window lacks coverage — absent stays absent.
    public static func analyze(hr: [HRSample], workoutEnd: Int) -> Result? {
        let plausible = hr.filter { $0.bpm >= minPlausibleBpm && $0.bpm <= maxPlausibleBpm }

        func windowMedian(_ from: Int, _ to: Int) -> (bpm: Double, n: Int)? {
            let bpms = plausible.filter { $0.ts >= from && $0.ts <= to }.map { Double($0.bpm) }
            guard bpms.count >= minWindowSamples else { return nil }
            return (median(bpms), bpms.count)
        }

        guard let end = windowMedian(workoutEnd - endWindowBefore, workoutEnd + endWindowAfter),
              end.bpm >= Double(minEndBpm),
              let at60 = windowMedian(workoutEnd + 60 - recoveryHalfWindow,
                                      workoutEnd + 60 + recoveryHalfWindow) else { return nil }
        let at120 = windowMedian(workoutEnd + 120 - recoveryHalfWindow,
                                 workoutEnd + 120 + recoveryHalfWindow)

        return Result(endBpm: round1(end.bpm),
                      bpmAt60: round1(at60.bpm),
                      bpmAt120: at120.map { round1($0.bpm) },
                      drop60: round1(end.bpm - at60.bpm),
                      drop120: at120.map { round1(end.bpm - $0.bpm) },
                      sampleCount: end.n + at60.n + (at120?.n ?? 0))
    }

    /// The day's headline recovery: the workout with the LARGEST 1-minute drop (current capacity, the
    /// number worth trending) — a day of one hard run and one easy walk should report the run.
    public static func bestOfDay(_ results: [Result]) -> Result? {
        results.max { $0.drop60 < $1.drop60 }
    }

    // MARK: - Helpers

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
