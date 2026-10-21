import XCTest
@testable import Strand

/// "Last night" may only name a night that ended today or yesterday. The nav header had this gate,
/// but the Sleep performance and Stages vs typical headers kept the literal for a weeks-old newest
/// night; they now share `isRecentNight`. Synthetic dates only.
final class SleepRecentNightLabelTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func ts(_ day: Int, _ hour: Int) -> Int {
        Int(utc.date(from: DateComponents(year: 2031, month: 5, day: day, hour: hour))!.timeIntervalSince1970)
    }

    private var now: Date { utc.date(from: DateComponents(year: 2031, month: 5, day: 20, hour: 21))! }

    func testThisMorningAndYesterdayAreRecent() {
        XCTAssertTrue(SleepView.isRecentNight(endTs: ts(20, 7), now: now, calendar: utc))
        XCTAssertTrue(SleepView.isRecentNight(endTs: ts(19, 7), now: now, calendar: utc))
    }

    func testOlderNightsAreNot() {
        XCTAssertFalse(SleepView.isRecentNight(endTs: ts(18, 7), now: now, calendar: utc))
        XCTAssertFalse(SleepView.isRecentNight(endTs: ts(2, 7), now: now, calendar: utc))
    }
}
