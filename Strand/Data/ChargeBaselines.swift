import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Charge baselines for the screens (2026-10-21)
//
// The baselines a night's Charge was scored against, rebuilt from the dashboard's rows with the
// engine's own calendar fold (`Baselines.foldCalendar`): only nights before the shown one, missing
// calendar days counted as missing, and the recalibration epochs applied. The "What shaped your Charge"
// sheets used to fold every row, the shown night included and gaps ignored, so their drivers explained
// a different score from the ring.

enum ChargeBaselines {
    struct Set {
        let hrv: BaselineState
        let rhr: BaselineState
        let resp: BaselineState
    }

    static func before(_ day: String, days: [DailyMetric]) -> Set {
        func values(_ pick: (DailyMetric) -> Double?) -> [String: Double] {
            var out: [String: Double] = [:]
            for d in days { if let v = pick(d) { out[d.day] = v } }
            return out
        }
        let epoch = Baselines.recoveryBaselineEpoch()
        return Set(
            hrv: Baselines.foldCalendar(values: values(\.avgHrv), before: day, cfg: Baselines.hrvCfg),
            rhr: Baselines.foldCalendar(values: values { $0.restingHr.map(Double.init) }, before: day,
                                        cfg: Baselines.restingHRCfg, baselineEpoch: epoch),
            resp: Baselines.foldCalendar(values: values(\.respRateBpm), before: day,
                                         cfg: Baselines.respCfg, baselineEpoch: epoch))
    }

    /// The "What shaped it" rows for `row`, or [] when there's nothing to attribute (no HRV/RHR, or no
    /// usable HRV baseline: calibrating, or stale after a long gap).
    static func drivers(for row: DailyMetric?, days: [DailyMetric], restScore: Double?) -> [ChargeDriver] {
        guard let row, let hrv = row.avgHrv, let rhr = row.restingHr else { return [] }
        let b = before(row.day, days: days)
        guard b.hrv.usable else { return [] }
        return RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: b.hrv,
            rhrBaseline: b.rhr.usable ? b.rhr : nil,
            respBaseline: b.resp.usable ? b.resp : nil,
            sleepPerf: restScore.map { $0 / 100.0 }, skinTempDev: row.skinTempDevC)
    }

    /// True when the night has HRV but no Charge because the HRV baseline went stale over a long gap
    /// (the strap was off for more than two weeks): Charge is re-learning, not missing data.
    static func isRelearning(_ row: DailyMetric?, days: [DailyMetric]) -> Bool {
        guard let row, row.recovery == nil, row.avgHrv != nil else { return false }
        return before(row.day, days: days).hrv.status == .stale
    }
}
