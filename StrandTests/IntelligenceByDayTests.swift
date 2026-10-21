import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The Intelligence By-Day list covers every stored scored day, not only the last pass's window, so the
/// 3M / 6M / 1Y / ALL ranges differ. (Audit I7, 2026-10-21.) Synthetic numbers.
final class IntelligenceByDayTests: XCTestCase {

    private func row(_ day: String, recovery: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90, lightMin: 250,
                    disturbances: 2, restingHr: 54, avgHrv: 61, recovery: recovery, strain: 35, exerciseCount: 0)
    }

    func testStoredDaysJoinTheLastPassNewestFirst() {
        let pass = IntelligenceEngine.Computed(day: "2026-05-20", recovery: 71, strain: 30, sleepMin: 430,
                                               hrv: 62, rhr: 53, confidence: .building)
        let stored: [SourcedDailyMetric] = [
            SourcedDailyMetric(metric: row("2026-05-20", recovery: 70), source: .noopComputed),
            SourcedDailyMetric(metric: row("2026-02-01", recovery: 64), source: .noopComputed),
            SourcedDailyMetric(metric: row("2025-11-15", recovery: nil), source: .noopComputed),
            SourcedDailyMetric(metric: row("2025-11-15", recovery: 58), source: .whoopImport),
            SourcedDailyMetric(metric: row("2025-08-03", recovery: 66), source: .appleHealth),   // watch-only
            SourcedDailyMetric(metric: row("2025-08-04", recovery: nil), source: .appleHealth),  // no Charge
            SourcedDailyMetric(metric: row("2025-07-01", recovery: 61), source: .whoopImport),   // import only
        ]
        let days = IntelligenceEngine.byDayRows(results: [pass], stored: stored)
        XCTAssertEqual(days.map(\.day), ["2026-05-20", "2026-02-01", "2025-11-15", "2025-08-03"])
        XCTAssertEqual(days[0].recovery, 71, "this pass's row wins its day")
        XCTAssertFalse(days[0].fromHistory)
        XCTAssertTrue(days[1].fromHistory)
        XCTAssertEqual(days[2].source, .whoopImport)
        XCTAssertEqual(days[3].source, .appleHealth)
    }
}
