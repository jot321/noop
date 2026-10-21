import XCTest
@testable import StrandDesign

/// Effort is plotted on its stored 0–100 scale; on WHOOP's 0–21 scale its Y axis must print 0–21
/// numbers, not the raw 25/50/75 (2026-10-21).
final class TrendChartAxisTests: XCTestCase {

    func testEffortTicksPrintRoundNumbersOnTheTwentyOneScale() {
        let ticks = TrendChart.axisTicks(domain: 10...90, scale: 0.21, desiredCount: 3)
        XCTAssertEqual(ticks.map { TrendChart.axisLabel($0, scale: 0.21) }, ["5", "10", "15"])
    }

    func testFullRangeTicks() {
        let ticks = TrendChart.axisTicks(domain: 0...106, scale: 0.21, desiredCount: 3)
        XCTAssertEqual(ticks.map { TrendChart.axisLabel($0, scale: 0.21) }, ["0", "10", "20"])
    }

    func testTicksStayInsideTheDomain() {
        let domain = 37.0...41.0
        let ticks = TrendChart.axisTicks(domain: domain, scale: 0.21, desiredCount: 3)
        XCTAssertGreaterThanOrEqual(ticks.count, 3)
        XCTAssertTrue(ticks.allSatisfy { domain.contains($0) })
    }

    func testEmptyDomainGivesNoTicks() {
        XCTAssertTrue(TrendChart.axisTicks(domain: 5...5, scale: 0.21, desiredCount: 3).isEmpty)
    }
}
