import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Charge is scored against baselines folded over the calendar, so a long gap off the wrist turns the
/// baseline stale (audit I4), and the fold runs once per metric with the exact per-night result (P3).
/// Synthetic numbers.
final class ChargeBaselineGapTests: XCTestCase {

    private func daily(_ day: String, hrv: Double, rhr: Int) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 450, efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 260,
                    disturbances: 3, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: 40, exerciseCount: 0,
                    respRateBpm: 15)
    }

    private func charge(_ nights: [String: (hrv: Double, rhr: Int)], cfgDay day: String) -> Double? {
        let b = IntelligenceEngine.ChargeBaselines(
            hrv: nights.mapValues { Optional($0.hrv) }, rhr: nights.mapValues { Optional(Double($0.rhr)) },
            resp: nights.mapValues { _ in Optional(15.0) }, skin: [:],
            cfg: (Baselines.hrvCfg, Baselines.restingHRCfg, Baselines.respCfg, Baselines.metricCfg["skin_temp"]!),
            hrvEpoch: 0, recoveryEpoch: 0)
        guard let n = nights[day] else { return nil }
        return IntelligenceEngine.recomputeRecovery(daily(day, hrv: n.hrv, rhr: n.rhr), b.before(day))
    }

    /// Eight nights in March, then a night 60 days later. Going into that night the baseline is stale,
    /// so Charge is withheld instead of scored against two-month-old nights; the night after scores again.
    func testChargeIsWithheldOnTheFirstNightBackAfterALongGap() {
        var nights: [String: (hrv: Double, rhr: Int)] = [:]
        for (i, d) in (1...8).enumerated() { nights[String(format: "2026-03-%02d", d)] = (60 + Double(i % 3), 55) }
        nights["2026-04-30"] = (64, 54)
        nights["2026-05-01"] = (63, 54)
        XCTAssertNotNil(charge(nights, cfgDay: "2026-03-08"), "a continuous run scores")
        XCTAssertNil(charge(nights, cfgDay: "2026-04-30"), "first night back after 52 missing nights")
        XCTAssertNotNil(charge(nights, cfgDay: "2026-05-01"), "the night after scores again")
    }

    /// P3: the fold-once baselines give the exact Charge a fresh per-night fold gives, for every night.
    func testFoldOnceBaselinesScoreExactlyLikeAFreshFoldPerNight() {
        var hrv: [String: Double] = [:], rhr: [String: Double] = [:], resp: [String: Double] = [:]
        var d = Baselines.dayIndex("2026-01-01")!
        for i in 0..<90 {
            d += i % 11 == 0 ? 3 : 1
            let key = Baselines.dayKey(fromIndex: d)
            hrv[key] = 45 + Double((i * 13) % 25)
            rhr[key] = 52 + Double((i * 7) % 9)
            resp[key] = 14 + Double(i % 4) * 0.4
        }
        let b = IntelligenceEngine.ChargeBaselines(
            hrv: hrv.mapValues { Optional($0) }, rhr: rhr.mapValues { Optional($0) },
            resp: resp.mapValues { Optional($0) }, skin: [:],
            cfg: (Baselines.hrvCfg, Baselines.restingHRCfg, Baselines.respCfg, Baselines.metricCfg["skin_temp"]!),
            hrvEpoch: 0, recoveryEpoch: 0)
        for day in hrv.keys.sorted() {
            let fresh = AnalyticsEngine.ProfileBaselines(
                hrv: Baselines.foldCalendar(values: hrv, before: day, cfg: Baselines.hrvCfg, baselineEpoch: 0),
                restingHR: Baselines.foldCalendar(values: rhr, before: day, cfg: Baselines.restingHRCfg,
                                                  baselineEpoch: 0),
                resp: {
                    let r = Baselines.foldCalendar(values: resp, before: day, cfg: Baselines.respCfg, baselineEpoch: 0)
                    return r.usable ? r : nil
                }())
            let night = daily(day, hrv: hrv[day]!, rhr: Int(rhr[day]!))
            XCTAssertEqual(IntelligenceEngine.recomputeRecovery(night, b.before(day)),
                           IntelligenceEngine.recomputeRecovery(night, fresh), day)
        }
    }
}
