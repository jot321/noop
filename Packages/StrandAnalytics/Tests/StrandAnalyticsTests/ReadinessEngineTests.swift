import XCTest
@testable import StrandAnalytics
import WhoopStore

final class ReadinessEngineTests: XCTestCase {

    private func d(_ i: Int, hrv: Double?, rhr: Int?, strain: Double?, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: String(format: "2024-03-%02d", i), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: strain, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    /// 28 baseline days with gentle variation (so SD > 0), then `today` as day 29.
    private func baseline(todayHrv: Double?, todayRhr: Int?, todayStrain: Double?,
                          todayResp: Double? = nil, baseStrain: Double = 10) -> [DailyMetric] {
        var days: [DailyMetric] = []
        for i in 1...28 {
            days.append(d(i, hrv: i % 2 == 0 ? 62 : 58, rhr: i % 2 == 0 ? 54 : 50,
                          strain: baseStrain, resp: i % 2 == 0 ? 14.5 : 13.5))
        }
        days.append(d(29, hrv: todayHrv, rhr: todayRhr, strain: todayStrain, resp: todayResp))
        return days
    }

    func testInsufficientWhenEmpty() {
        XCTAssertEqual(ReadinessEngine.evaluate(days: []).level, .insufficient)
    }

    func testPrimedWhenSignalsAligned() {
        // Today: HRV well above baseline, resting HR below, load steady.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10))
        XCTAssertEqual(r.level, .primed)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.evidence, "72 vs 60 ms")
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.evidence, "46 vs 52 bpm")
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.evidence, "7d 10.0 / 28d 10.0")
    }

    func testRundownWhenTwoRecoverySignalsDown() {
        // Today: HRV suppressed AND resting HR elevated → two "bad" recovery signals.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 60, todayStrain: 10))
        XCTAssertEqual(r.level, .rundown)
    }

    func testAcwrSpikeStrains() {
        // Recovery signals neutral, but acute load spikes above chronic.
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 5)) }
        for i in 22...28 { days.append(d(i, hrv: 60, rhr: 52, strain: 15)) }
        days.append(d(29, hrv: 60, rhr: 52, strain: 15))
        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .bad)
        XCTAssertEqual(r.level, .strained)
        XCTAssertNotNil(r.acwr)
        XCTAssertGreaterThan(r.acwr!, 1.5)
    }

    func testRespRateRiseFlags() {
        // Today resp rate well above baseline (~14) → illness-ish watch/bad signal present.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10, todayResp: 18))
        XCTAssertTrue(r.signals.contains { $0.key == "respRate" })
        XCTAssertEqual(r.signals.first { $0.key == "respRate" }?.evidence, "18.0 vs 14.0 rpm")
    }

    func testExplicitTodayWithoutMatchingRowIsInsufficient() {
        // Stale historical import: newest row is 2024-03-29, but the device's real calendar day is later.
        // An explicit `today` with no matching row must read INSUFFICIENT — NOT synthesize off the newest
        // stored (stale) row (issue #23/#24).
        let days = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10)
        XCTAssertEqual(ReadinessEngine.evaluate(days: days, today: "2026-06-08").level, .insufficient)
        // The day that IS present still computes (no regression for current data).
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days, today: "2024-03-29").level, .insufficient)
        // The legacy no-`today` path is unchanged — still falls back to the most recent row.
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days).level, .insufficient)
    }

    func testStatsHelpers() {
        XCTAssertEqual(ReadinessEngine.mean([2, 4, 6]), 4)
        XCTAssertEqual(ReadinessEngine.sampleSD([2, 4, 6])!, 2.0, accuracy: 0.0001)
        XCTAssertNil(ReadinessEngine.sampleSD([5]))
        XCTAssertNil(ReadinessEngine.mean([]))
    }

    // MARK: - Calendar windows (2026-10-21): a gap in the data is a gap, not more history

    private func day(_ key: String, hrv: Double?, rhr: Int?, strain: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: strain,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    func testBaselineIgnoresNightsOlderThanThirtyDays() {
        // 28 nights in March, nothing since, then a night in June: no HRV/RHR baseline exists for it.
        var days = (1...28).map { day(String(format: "2024-03-%02d", $0), hrv: $0 % 2 == 0 ? 62 : 58,
                                       rhr: $0 % 2 == 0 ? 54 : 50, strain: 10) }
        days.append(day("2024-06-20", hrv: 75, rhr: 45, strain: 10))
        let r = ReadinessEngine.evaluate(days: days, today: "2024-06-20")
        XCTAssertNil(r.signals.first { $0.key == "hrv" }, "March nights are not a 30-day baseline for June")
        XCTAssertNil(r.signals.first { $0.key == "acwr" }, "no strain in the last 28 days")
    }

    func testLaterDaysNeverShapeAnEarlierVerdict() {
        // Evaluating 14 March must not read 15–28 March (they hadn't happened yet).
        let base = baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10)
        var withFuture = base
        withFuture.append(contentsOf: (1...10).map { day(String(format: "2024-04-%02d", $0), hrv: 90, rhr: 40, strain: 30) })
        let a = ReadinessEngine.evaluate(days: base, today: "2024-03-14")
        let b = ReadinessEngine.evaluate(days: withFuture, today: "2024-03-14")
        XCTAssertEqual(a.level, b.level)
        XCTAssertEqual(a.acwr, b.acwr)
        XCTAssertEqual(a.signals.map(\.evidence), b.signals.map(\.evidence))
    }
}
