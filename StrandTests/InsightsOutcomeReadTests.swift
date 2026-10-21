import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Reads behind Insights and the Today Steps page for a strap-only user, whose scores live under the
/// computed ("-noop") source. Synthetic numbers.
@MainActor
final class InsightsOutcomeReadTests: XCTestCase {

    /// Rest (`sleep_performance`) is written only to the computed series for a strap-only user, so an
    /// Insights read of the imported ids alone left the Rest outcome empty. (Audit I6, 2026-10-21.)
    func testRestOutcomeFallsBackToTheComputedSeries() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let tz = TimeZone.current.secondsFromGMT()
        let todayMidnight = IntelligenceEngine.midnightLocal(Int(Date().timeIntervalSince1970), offsetSec: tz)
        let days = (1...3).map { AnalyticsEngine.dayString(todayMidnight - $0 * 86_400, offsetSec: tz) }
        try await store.upsertMetricSeries(days.enumerated().map {
            MetricPoint(day: $0.element, key: "sleep_performance", value: 70 + Double($0.offset))
        }, deviceId: "my-whoop-noop")
        await repo.refresh()

        let rest = await repo.insightsOutcome(key: "sleep_performance")
        XCTAssertEqual(rest.count, 3)
        XCTAssertEqual(rest[days[0]], 70)
    }

    /// The Today Steps card opens "Steps (estimated)", whose `steps_est` series exists only for a WHOOP
    /// 4.0 with a calibration. On a 5/MG the strap's own counter is on the daily row, so the page falls
    /// back to it instead of saying "no data". (Audit T7, 2026-10-21.)
    func testStepsEstimateFallsBackToTheDailyStepCount() {
        let d = DailyMetric(day: "2026-03-14", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                            strain: nil, exerciseCount: nil, steps: 8_400)
        XCTAssertEqual(Repository.dailyColumn(key: "steps_est", day: d), 8_400)
        XCTAssertEqual(Repository.dailyColumn(key: "steps", day: d), 8_400)
    }
}
