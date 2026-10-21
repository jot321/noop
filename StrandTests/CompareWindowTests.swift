import XCTest
@testable import Strand

/// Compare anchors every series on today and needs 10 shared days before it reports r (2026-10-21).
final class CompareWindowTests: XCTestCase {

    private func rows(_ month: Int, _ days: ClosedRange<Int>, _ value: (Int) -> Double = { _ in 50 })
        -> [(day: String, value: Double)] {
        days.map { (day: String(format: "2026-%02d-%02d", month, $0), value: value($0)) }
    }

    // MARK: R5: r needs 10 shared days

    func testFourSharedDaysAreTooFewForR() {
        // Four points on a line give r = 1.00, "very strong", from almost nothing.
        let a = rows(10, 18...21) { Double($0) }
        let b = rows(10, 18...21) { Double($0) * 2 }
        XCTAssertNil(CompareView.correlation(a, b))
    }

    func testTenSharedDaysGiveR() throws {
        let a = rows(10, 12...21) { Double($0) }
        let b = rows(10, 12...21) { Double($0) * 2 + 1 }
        let c = try XCTUnwrap(CompareView.correlation(a, b))
        XCTAssertEqual(c.n, 10)
        XCTAssertEqual(c.r, 1, accuracy: 1e-9)
    }
}
