import XCTest
@testable import StrandDesign

/// The heat strip lays days out by calendar date (2026-10-21). It started a new column only when a
/// Monday row appeared and never filled missing days, so after a gap a later Tuesday landed in an
/// old column and overwrote the earlier Tuesday's cell.
final class YearHeatStripLayoutTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 2
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testGapStartsNewColumnsInsteadOfOverwriting() {
        // Mon 13 – Wed 15 Jul, then nothing until Tue 28 Jul.
        let days = [
            RecoveryDay(date: day(2026, 7, 13), score: 60),
            RecoveryDay(date: day(2026, 7, 14), score: 61),
            RecoveryDay(date: day(2026, 7, 15), score: 62),
            RecoveryDay(date: day(2026, 7, 28), score: 30),
        ]
        let weeks = YearHeatStrip.buildWeeks(from: days, through: nil, calendar: calendar)
        XCTAssertEqual(weeks[0].cells[1]?.score, 61, "Tue 14 Jul keeps its cell")
        guard weeks.count == 3 else { return XCTFail("Expected weeks of 13, 20 and 27 Jul, got \(weeks.count)") }
        XCTAssertEqual(weeks[2].cells[1]?.score, 30, "Tue 28 Jul sits in the third column")
        // Missing days are present as "no data" cells, not left out.
        XCTAssertNotNil(weeks[1].cells[3])
        XCTAssertNil(weeks[1].cells[3]?.score)
    }

    func testFirstWeekIsPaddedAndStripRunsThroughEndDate() {
        // Starts on a Thursday; runs to the following Tuesday with no data after the first day.
        let days = [RecoveryDay(date: day(2026, 10, 15), score: 70)]
        let weeks = YearHeatStrip.buildWeeks(from: days, through: day(2026, 10, 20), calendar: calendar)
        guard weeks.count == 2 else { return XCTFail("Expected two columns, got \(weeks.count)") }
        XCTAssertNil(weeks[0].cells[0], "Before the first day the column is blank padding")
        XCTAssertEqual(weeks[0].cells[3]?.score, 70, "Thursday row")
        XCTAssertNotNil(weeks[1].cells[1], "Tue 20 Oct is drawn as an empty day")
        XCTAssertNil(weeks[1].cells[2], "Nothing after the end date")
    }

    func testWeekdayRowFollowsTheCalendarZone() {
        // Local midnight of Tue 14 Jul in Los Angeles is still Tuesday there.
        let weeks = YearHeatStrip.buildWeeks(from: [RecoveryDay(date: day(2026, 7, 14), score: 50)],
                                             through: nil, calendar: calendar)
        XCTAssertEqual(weeks.first?.cells[1]?.score, 50)
    }
}
