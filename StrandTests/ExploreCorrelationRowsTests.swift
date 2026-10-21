import XCTest
@testable import Strand

/// "What correlates" moved off the main actor and out of the first paint (2026-10-21); the rows it
/// produces must not change: |r| >= 0.30 from 10+ shared days, strongest first, at most six.
final class ExploreCorrelationRowsTests: XCTestCase {

    private func metric(_ key: String) -> MetricDescriptor {
        MetricCatalog.all.first { $0.key == key }!
    }

    private func series(_ f: (Int) -> Double, days: ClosedRange<Int> = 1...12) -> [(day: String, value: Double)] {
        days.map { (day: String(format: "2026-10-%02d", $0), value: f($0)) }
    }

    func testRowsKeepStrongLinksStrongestFirst() {
        let mine = series { Double($0) }
        let others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = [
            (metric("rhr"), series { 80 - Double($0) + ($0 % 2 == 0 ? 1.5 : -1.5) }),   // strong negative
            (metric("strain"), series { Double($0) * 2 }),                                // perfect positive
            (metric("spo2"), series { $0 % 2 == 0 ? 97 : 96 }),                           // no link
            (metric("steps"), series({ Double($0) }, days: 1...5)),                        // too few days
        ]
        let rows = MetricDetailView.correlationRows(windowed: mine, others: others)
        XCTAssertEqual(rows.map(\.metric.key), ["strain", "rhr"])
        XCTAssertEqual(rows[0].r, 1, accuracy: 1e-9)
        XCTAssertLessThan(rows[1].r, -0.3)
        XCTAssertEqual(rows[0].n, 12)
    }

    func testEmptyWindowGivesNoRows() {
        let others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = [(metric("rhr"), series { Double($0) })]
        XCTAssertTrue(MetricDetailView.correlationRows(windowed: [], others: others).isEmpty)
    }
}
