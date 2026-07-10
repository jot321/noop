import Foundation
import WhoopProtocol

/// Sleep-stage-resolved HRV + a nocturnal autonomic timeline
/// (docs/ADVANCED_ANALYTICS_PLAN.md §2).
///
/// The nightly recovery path collapses rich beat-to-beat R-R into a single RMSSD. The math to do more
/// already exists — `HRVAnalyzer` (time domain), `HRVFreqDomain` (Lomb–Scargle LF/HF), `RhythmScreener`
/// (Poincaré). This engine just *wires* that math to the sleep-stager's stage windows so parasympathetic
/// drive can be read per deep / REM / light, and surfaces a whole-night autonomic-balance summary.
///
/// Pure/deterministic; delegates the actual HRV computation to the existing engines (no new math).
public enum HRVByStage {

    /// HRV summary for one stage class over the night.
    public struct StageHRV: Equatable, Sendable {
        public let stage: String            // "deep" | "rem" | "light" | "wake"
        public let rmssd: Double?           // ms
        public let sdnn: Double?            // ms
        public let meanHR: Double?          // bpm derived from mean NN
        public let lf: Double?              // ms²
        public let hf: Double?              // ms²
        public let lfhf: Double?
        public let beatCount: Int
        public init(stage: String, rmssd: Double?, sdnn: Double?, meanHR: Double?,
                    lf: Double?, hf: Double?, lfhf: Double?, beatCount: Int) {
            self.stage = stage; self.rmssd = rmssd; self.sdnn = sdnn; self.meanHR = meanHR
            self.lf = lf; self.hf = hf; self.lfhf = lfhf; self.beatCount = beatCount
        }
    }

    public struct NightHRV: Equatable, Sendable {
        public let byStage: [StageHRV]
        /// Whole-night LF/HF autonomic balance (>1 sympathetic-leaning, <1 parasympathetic-leaning).
        public let nightLFHF: Double?
        /// Whole-night RMSSD (the legacy single number, kept for continuity/comparison).
        public let nightRMSSD: Double?
        /// Nocturnal RMSSD curve (rolling), the dip-and-rise across the night.
        public let rollingRMSSD: [HRVAnalyzer.RollingRmssdPoint]
        public init(byStage: [StageHRV], nightLFHF: Double?, nightRMSSD: Double?,
                    rollingRMSSD: [HRVAnalyzer.RollingRmssdPoint]) {
            self.byStage = byStage; self.nightLFHF = nightLFHF
            self.nightRMSSD = nightRMSSD; self.rollingRMSSD = rollingRMSSD
        }
    }

    /// Rolling-RMSSD window defaults for the nocturnal curve.
    public static let rollingWindowSec: Int = 120
    public static let rollingStepSec: Int = 120

    /// Compute stage-resolved HRV from R-R and the stager's stage segments.
    ///
    /// - `rr`: the night's R-R intervals.
    /// - `stages`: `SleepStager.StageSegment` runs (start/end/stage strings). Passed as plain tuples so
    ///   this engine has no ordering dependency on where `StageSegment` is declared.
    public static func analyze(rr: [RRInterval],
                               stages: [(start: Int, end: Int, stage: String)]) -> NightHRV {
        let sorted = rr.sorted { $0.ts < $1.ts }

        // Group R-R by stage class by testing each interval's ts against the stage runs.
        var byStageRR: [String: [RRInterval]] = ["deep": [], "rem": [], "light": [], "wake": []]
        if !stages.isEmpty {
            let ordered = stages.sorted { $0.start < $1.start }
            var si = 0
            for iv in sorted {
                while si < ordered.count && ordered[si].end <= iv.ts { si += 1 }
                if si < ordered.count, iv.ts >= ordered[si].start, iv.ts < ordered[si].end {
                    byStageRR[ordered[si].stage, default: []].append(iv)
                }
            }
        }

        var stageResults: [StageHRV] = []
        for stage in ["deep", "rem", "light", "wake"] {
            let group = byStageRR[stage] ?? []
            guard !group.isEmpty else { continue }
            let td = HRVAnalyzer.analyze(group)
            let bands = HRVFreqDomain.freqDomain(rr: group)
            let meanHR = td.meanNN.flatMap { $0 > 0 ? 60_000.0 / $0 : nil }
            stageResults.append(StageHRV(stage: stage,
                                         rmssd: td.rmssd.map(round2),
                                         sdnn: td.sdnn.map(round2),
                                         meanHR: meanHR.map(round1),
                                         lf: bands?.lf.map(round1),
                                         hf: bands.map { round1($0.hf) },
                                         lfhf: bands?.lfhf.map(round2),
                                         beatCount: td.nClean))
        }

        let nightBands = HRVFreqDomain.freqDomain(rr: sorted)
        let nightTD = HRVAnalyzer.analyze(sorted)
        let rolling = HRVAnalyzer.rollingRmssd(rr: sorted, windowSec: rollingWindowSec, stepSec: rollingStepSec)
        return NightHRV(byStage: stageResults,
                        nightLFHF: nightBands?.lfhf.map(round2),
                        nightRMSSD: nightTD.rmssd.map(round2),
                        rollingRMSSD: rolling)
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}
