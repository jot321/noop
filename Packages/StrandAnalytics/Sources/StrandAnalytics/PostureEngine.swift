import Foundation
import WhoopProtocol

/// Sleep POSITION / posture + actigraphy from the raw gravity vector
/// (docs/ADVANCED_ANALYTICS_PLAN.md §3).
///
/// `gravitySample` stores the 1 Hz gravity direction (x/y/z, in g), but the pipeline reduces it to a
/// single L2 stillness scalar (`SleepStager.gravityDeltas`). The gravity vector's *orientation* is the
/// wrist's orientation, which — worn on the wrist through the night — tracks body position well enough
/// to estimate supine / prone / left / right and to correlate a position with worse apnea (supine).
///
/// Wrist-on-body geometry is a convention, so the four classes are APPROXIMATE and relative to the
/// dominant "in-bed" orientation, not anatomically exact. Pure/deterministic.
public enum PostureEngine {

    public enum Position: String, Equatable, Sendable, CaseIterable {
        case supine, prone, left, right, upright
    }

    /// Actigraphy + position for the night.
    public struct Result: Equatable, Sendable {
        /// Seconds spent in each position (only positions with time appear).
        public let secondsByPosition: [Position: Int]
        /// The dominant position over the night.
        public let dominant: Position
        /// Number of distinct position changes (tossing/turning proxy).
        public let positionChanges: Int
        /// Actigraphy restlessness: fraction [0,1] of epochs with movement above the still threshold.
        public let restlessFraction: Double
        /// Discrete movement bursts across the night (a raw tossing/turning count).
        public let movementBursts: Int
        public init(secondsByPosition: [Position: Int], dominant: Position, positionChanges: Int,
                    restlessFraction: Double, movementBursts: Int) {
            self.secondsByPosition = secondsByPosition; self.dominant = dominant
            self.positionChanges = positionChanges; self.restlessFraction = restlessFraction
            self.movementBursts = movementBursts
        }
    }

    /// |Δgravity| above this (g) marks a moving epoch (matches SleepStager's move threshold).
    public static let moveDeltaThresholdG: Double = 0.02
    /// Segment aggregation window (s) — a position must persist this long to count as a change.
    public static let minSegmentSec: Int = 30
    public static let minSamples: Int = 60

    /// Classify a single gravity sample into a coarse posture from the vector direction.
    ///
    /// Convention (wrist-worn, screen facing out): the axis with the largest absolute gravity component
    /// names the orientation. This is intentionally simple and relative; downstream we report position
    /// *fractions* and *changes*, which are robust to the exact axis convention.
    public static func classify(_ s: GravitySample) -> Position {
        let mag = (s.x * s.x + s.y * s.y + s.z * s.z).squareRoot()
        guard mag > 0.3 else { return .upright } // near-zero gravity vector: indeterminate → treat as upright/active
        let nx = s.x / mag, ny = s.y / mag, nz = s.z / mag
        let ax = abs(nx), ay = abs(ny), az = abs(nz)
        if az >= ax && az >= ay {
            return nz >= 0 ? .supine : .prone
        } else if ay >= ax {
            return .upright // wrist vertical → likely awake/upright
        } else {
            return nx >= 0 ? .right : .left
        }
    }

    /// Analyze gravity samples over `[sleepStart, sleepEnd)`.
    public static func analyze(gravity: [GravitySample],
                               sleepStart: Int,
                               sleepEnd: Int) -> Result? {
        guard sleepEnd > sleepStart else { return nil }
        let samples = gravity.filter { $0.ts >= sleepStart && $0.ts < sleepEnd }.sorted { $0.ts < $1.ts }
        guard samples.count >= minSamples else { return nil }

        // Per-sample position + dwell time (time to the next sample, capped so a gap doesn't dominate).
        var seconds: [Position: Int] = [:]
        var movingEpochs = 0
        var movementBursts = 0
        var prev: GravitySample? = nil
        var lastPos: Position? = nil
        var lastPosStartTs = samples[0].ts
        var positionChanges = 0
        var inBurst = false

        for i in samples.indices {
            let s = samples[i]
            let pos = classify(s)
            let dwell = i + 1 < samples.count ? min(samples[i + 1].ts - s.ts, 5) : 1
            seconds[pos, default: 0] += max(0, dwell)

            if let p = prev {
                let dx = s.x - p.x, dy = s.y - p.y, dz = s.z - p.z
                let mag = (dx * dx + dy * dy + dz * dz).squareRoot()
                if mag >= moveDeltaThresholdG {
                    movingEpochs += 1
                    if !inBurst { movementBursts += 1; inBurst = true }
                } else {
                    inBurst = false
                }
            }
            prev = s

            // Debounced position changes: only count when a new position has held for >= minSegmentSec.
            if lastPos == nil {
                lastPos = pos; lastPosStartTs = s.ts
            } else if pos != lastPos {
                if s.ts - lastPosStartTs >= minSegmentSec {
                    positionChanges += 1
                }
                lastPos = pos
                lastPosStartTs = s.ts
            }
        }

        let dominant = seconds.max { $0.value < $1.value }?.key ?? .supine
        let restless = Double(movingEpochs) / Double(max(1, samples.count - 1))
        return Result(secondsByPosition: seconds, dominant: dominant,
                      positionChanges: positionChanges, restlessFraction: round3(restless),
                      movementBursts: movementBursts)
    }

    /// Fraction of the night spent supine — the input to positional-apnea correlation (supine worsens
    /// apnea). Returns 0 when unknown.
    public static func supineFraction(_ result: Result) -> Double {
        let total = result.secondsByPosition.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return round3(Double(result.secondsByPosition[.supine] ?? 0) / Double(total))
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
