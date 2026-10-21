import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The "What shaped your Charge" sheets fold the same calendar baseline the engine scores with
/// (2026-10-21): nights before the shown one only, and a long gap makes the baseline stale.
final class ChargeBaselinesTests: XCTestCase {

    private func night(_ day: String, hrv: Double?, rhr: Int?, recovery: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14)
    }

    private func week(from start: Int) -> [DailyMetric] {
        (0..<8).map { night(String(format: "2026-03-%02d", start + $0), hrv: 50 + Double($0 % 3), rhr: 55) }
    }

    func testAfterALongGapChargeIsRelearningAndHasNoDrivers() {
        let back = night("2026-06-20", hrv: 52, rhr: 54)                 // three months later
        let days = week(from: 1) + [back]
        XCTAssertTrue(ChargeBaselines.isRelearning(back, days: days))
        XCTAssertTrue(ChargeBaselines.drivers(for: back, days: days, restScore: 80).isEmpty)
    }

    func testRecentNightsGiveDriversAndNoRelearning() {
        let next = night("2026-03-09", hrv: 58, rhr: 52, recovery: 70)
        let days = week(from: 1) + [next]
        XCTAssertFalse(ChargeBaselines.isRelearning(next, days: days))
        XCTAssertFalse(ChargeBaselines.drivers(for: next, days: days, restScore: 80).isEmpty)
    }

    func testTheShownNightIsNotPartOfItsOwnBaseline() {
        let next = night("2026-03-09", hrv: 58, rhr: 52)
        let without = ChargeBaselines.before("2026-03-09", days: week(from: 1))
        let with = ChargeBaselines.before("2026-03-09", days: week(from: 1) + [next])
        XCTAssertEqual(without.hrv, with.hrv)
    }
}
