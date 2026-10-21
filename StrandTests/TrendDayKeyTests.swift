import XCTest
@testable import Strand

/// Day keys name a LOCAL calendar day, and the charts label dates in the local zone, so a key must
/// parse to that zone's midnight (2026-10-21). Parsed as UTC midnight, "2026-07-14" read as 13 Jul
/// west of UTC and sat in Monday's heat-strip row. The zone is pinned here, never the machine's.
final class TrendDayKeyTests: XCTestCase {

    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    private func label(_ date: Date, _ format: String, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f.string(from: date)
    }

    func testWestOfUTCKeyLabelsAsTheSameDay() throws {
        let d = try XCTUnwrap(TrendDayKey.date("2026-07-14", in: losAngeles))
        XCTAssertEqual(label(d, "EEE d MMM", in: losAngeles), "Tue 14 Jul")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = losAngeles
        XCTAssertEqual(cal.component(.weekday, from: d), 3, "14 Jul 2026 is a Tuesday")
    }

    func testEastOfUTCKeyLabelsAsTheSameDay() throws {
        let d = try XCTUnwrap(TrendDayKey.date("2026-10-21", in: kolkata))
        XCTAssertEqual(label(d, "d MMM", in: kolkata), "21 Oct")
    }

    func testAsOfLabelUsesTheSameZone() {
        XCTAssertEqual(TrendDayKey.longLabel("2026-07-14", in: losAngeles), "14 Jul 2026")
    }

    func testBadKeyIsNil() {
        XCTAssertNil(TrendDayKey.date("2026-02-30", in: losAngeles))
        XCTAssertNil(TrendDayKey.date("not a day", in: losAngeles))
    }
}
