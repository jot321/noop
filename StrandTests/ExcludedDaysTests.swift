import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Days the user excluded ("not me"): the stored list, the `--exclude-days` launch argument, and which
/// detected sleep sessions the engine removes for them.
final class ExcludedDaysTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "ExcludedDaysTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDayKeysMustBeRealDates() {
        XCTAssertTrue(ExcludedDays.isDayKey("2026-08-02"))
        XCTAssertFalse(ExcludedDays.isDayKey("2026-8-2"))
        XCTAssertFalse(ExcludedDays.isDayKey("2026-02-30"))
        XCTAssertFalse(ExcludedDays.isDayKey("yesterday"))
    }

    func testLaunchArgumentAddsDaysOnceAndIgnoresJunk() {
        let args = ["NOOP", "--exclude-days", "2026-08-02, 2026-08-03,bogus"]
        XCTAssertEqual(ExcludedDays.launchDays(args), ["2026-08-02", "2026-08-03"])
        XCTAssertTrue(ExcludedDays.applyLaunchArguments(args, defaults))
        XCTAssertEqual(ExcludedDays.current(defaults), ["2026-08-02", "2026-08-03"])
        XCTAssertFalse(ExcludedDays.applyLaunchArguments(args, defaults), "a repeat launch changes nothing")
        XCTAssertFalse(ExcludedDays.applyLaunchArguments(["NOOP"], defaults))
    }

    func testRemoveBringsADayBack() {
        ExcludedDays.add(["2026-08-02", "2026-08-03"], defaults)
        XCTAssertTrue(ExcludedDays.remove("2026-08-02", defaults))
        XCTAssertFalse(ExcludedDays.remove("2026-08-02", defaults))
        XCTAssertEqual(ExcludedDays.current(defaults), ["2026-08-03"])
    }

    /// The rescore after a list change reaches the oldest touched day; the launch path uses the same
    /// span, so a launch exclusion months back is not rescored at the default 21 days. (Audit I2.)
    func testRescoreSpanReachesTheOldestTouchedDay() {
        let today = Baselines.dayIndex("2026-06-30")!
        XCTAssertEqual(ExcludedDays.rescoreSpan(touched: ["2026-06-28"], todayIdx: today), 21)
        XCTAssertEqual(ExcludedDays.rescoreSpan(touched: ["2026-01-01", "2026-06-01"], todayIdx: today), 182)
        XCTAssertEqual(ExcludedDays.rescoreSpan(touched: ["2010-01-01"], todayIdx: today), 4000)
        XCTAssertEqual(ExcludedDays.rescoreSpan(touched: [], todayIdx: today), 21)
    }

    func testDetectedSessionsEndingOnAnExcludedDayAreRemovedEditedOnesStay() {
        let ist = 5 * 3_600 + 30 * 60
        func ts(_ s: String) -> Int {
            let f = DateFormatter()
            f.timeZone = TimeZone(secondsFromGMT: ist)
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return Int(f.date(from: s)!.timeIntervalSince1970)
        }
        func session(_ a: String, _ b: String, edited: Bool = false) -> CachedSleepSession {
            CachedSleepSession(startTs: ts(a), endTs: ts(b), efficiency: 0.9, restingHr: nil, avgHrv: nil,
                               stagesJSON: "[]", userEdited: edited)
        }
        let sessions = [
            session("2026-08-02 13:00", "2026-08-02 15:00"),               // excluded nap
            session("2026-08-02 23:30", "2026-08-03 07:00"),               // wakes on an excluded day
            session("2026-08-03 14:00", "2026-08-03 16:00", edited: true), // hand-edited: kept
            session("2026-08-03 23:00", "2026-08-04 07:00"),               // wakes on 4 Aug: kept
        ]
        let starts = IntelligenceEngine.excludedSessionStarts(sessions, excluded: ["2026-08-02", "2026-08-03"],
                                                              offsetSec: ist)
        XCTAssertEqual(starts, [ts("2026-08-02 13:00"), ts("2026-08-02 23:30")])
    }
}
