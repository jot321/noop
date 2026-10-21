import XCTest
import WhoopStore
import StrandDesign
@testable import Strand

/// Windows labelled in days must be calendar days, not the last N rows. After a months-long gap in
/// wear the last 14 or 30 rows reached back to old nights: the sleep-debt ledger showed a large debt
/// from months ago, the "trailing 30 days" sleep trend plotted old nights, the Stress markers compared
/// today with a months-old baseline, and the Stress trend fell back to all history under the "M"
/// label. Synthetic dates and values only.
final class CalendarWindowTests: XCTestCase {

    private func daily(_ day: String, sleep: Double? = nil, rhr: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
    }

    /// Twenty days in early March, a long gap, then 9 and 10 June. "Today" is 10 June.
    private let today = "2030-06-10"
    private var earlyDays: [String] { (1...20).map { String(format: "2030-03-%02d", $0) } }

    // MARK: Sleep-debt ledger

    func testDebtLedgerOnlyCountsTheLast14CalendarDays() {
        let days = earlyDays.map { daily($0, sleep: 300) }
            + [daily("2030-06-09", sleep: 480), daily("2030-06-10", sleep: 480)]
        let ledger = SleepView.debtLedger(days: days, needHours: 8, today: today)
        XCTAssertEqual(ledger.nights.map(\.day), ["2030-06-09", "2030-06-10"])
        XCTAssertEqual(ledger.balanceMin, 0, accuracy: 0.001, "March's short nights are not this fortnight's debt")
    }

    func testDebtLedgerIsEmptyWhenNoNightInTheWindow() {
        let days = earlyDays.map { daily($0, sleep: 300) }
        XCTAssertEqual(SleepView.debtLedger(days: days, needHours: 8, today: today).nightCount, 0)
    }

    // MARK: Hours-asleep trend

    func testSleepTrendIsTheLast30CalendarDays() {
        let days = earlyDays.map { daily($0, sleep: 420) }
            + [daily("2030-06-09", sleep: 450), daily("2030-06-10", sleep: 400)]
        let trend = SleepView.durationTrend(days: days, today: today)
        XCTAssertTrue(trend.isLast30Days)
        XCTAssertEqual(trend.points.count, 2)
    }

    func testSleepTrendFallsBackToEveryNightAndSaysSo() {
        let days = earlyDays.map { daily($0, sleep: 420) } + [daily("2030-06-10", sleep: 400)]
        let trend = SleepView.durationTrend(days: days, today: today)
        XCTAssertFalse(trend.isLast30Days, "a fallback to old nights must not be labelled the last 30 days")
        XCTAssertEqual(trend.points.count, 21)
    }

    // MARK: Stress baseline

    func testStressBaselineIsTheLast30CalendarDays() throws {
        let days = earlyDays.map { daily($0, rhr: 50) }
            + [daily("2030-06-09", rhr: 56), daily("2030-06-10", rhr: 60)]
        let model = try XCTUnwrap(StressModel(days: days, stored: []))
        XCTAssertEqual(model.asOfDay, "2030-06-10")
        XCTAssertEqual(try XCTUnwrap(model.rhrDelta), 4, accuracy: 0.001,
                       "compared with 9 June only, not with March")
    }

    // MARK: Stress trend

    private func point(_ day: String, _ v: Double) -> TrendPoint {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return TrendPoint(date: f.date(from: day)!, value: v)
    }

    func testStressTrendFallbackIsLabelledAllTime() {
        let all = earlyDays.map { point($0, 1.2) } + [point("2030-06-10", 1.8)]
        let w = StressView.windowedTrend(all, range: .month, today: today)
        XCTAssertEqual(w.points.count, all.count)
        XCTAssertEqual(w.shown, .all, "showing every day under the M label misstates the span")
    }

    func testStressTrendWindowEndsToday() {
        // All history is from March: a "month" ending on the last point would chart March as this month.
        let all = earlyDays.map { point($0, 1.2) }
        let w = StressView.windowedTrend(all, range: .month, today: today)
        XCTAssertEqual(w.shown, .all)
    }

    func testStressTrendKeepsTheChosenRangeWhenItHasData() {
        let all = earlyDays.map { point($0, 1.2) } + [point("2030-06-09", 1.4), point("2030-06-10", 1.8)]
        let w = StressView.windowedTrend(all, range: .month, today: today)
        XCTAssertEqual(w.shown, .month)
        XCTAssertEqual(w.points.count, 2)
    }
}
