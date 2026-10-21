import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the October 2026 audit fixes that live in the app's scoring orchestration (IntelligenceEngine):
/// naps stay on their own day (A2), days need their own data (A13), and a post-sync rescore widens to
/// reach backfilled days older than the usual window (A15).
final class AuditFixesTests: XCTestCase {

    private let ist = 5 * 3_600 + 30 * 60

    private func ts(_ day: String, _ hour: Int, _ minute: Int = 0) -> Int {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: ist)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return Int(f.date(from: String(format: "%@ %02d:%02d", day, hour, minute))!.timeIntervalSince1970)
    }

    private func edit(_ start: Int, _ end: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.86, restingHr: nil, avgHrv: nil,
                           stagesJSON: "[]", userEdited: true)
    }

    // MARK: - A2: a hand-logged nap belongs to the day it ends on

    func testLoggedNapIsNotAddedToOtherDays() {
        let napStart = ts("2026-07-12", 16, 0)
        let edits = [napStart: edit(napStart, ts("2026-07-12", 16, 45))]
        XCTAssertEqual(IntelligenceEngine.twinlessEdits(endingOn: "2026-07-12", editsByStart: edits,
                                                        detectedStarts: [], offsetSec: ist).count, 1)
        for day in ["2026-07-17", "2026-07-18", "2026-07-22"] {
            XCTAssertTrue(IntelligenceEngine.twinlessEdits(endingOn: day, editsByStart: edits,
                                                           detectedStarts: [], offsetSec: ist).isEmpty,
                          "the 12 Jul nap must not appear on \(day)")
        }
    }

    func testEditWithADetectedTwinIsNotTwinless() {
        let start = ts("2026-07-12", 1, 30)
        let edits = [start: edit(start, ts("2026-07-12", 7, 0))]
        XCTAssertTrue(IntelligenceEngine.twinlessEdits(endingOn: "2026-07-12", editsByStart: edits,
                                                       detectedStarts: [start], offsetSec: ist).isEmpty)
    }

    func testOvernightEditBelongsToItsWakeDay() {
        let start = ts("2026-07-12", 23, 30)
        let edits = [start: edit(start, ts("2026-07-13", 7, 0))]
        XCTAssertTrue(IntelligenceEngine.twinlessEdits(endingOn: "2026-07-12", editsByStart: edits,
                                                       detectedStarts: [], offsetSec: ist).isEmpty)
        XCTAssertEqual(IntelligenceEngine.twinlessEdits(endingOn: "2026-07-13", editsByStart: edits,
                                                        detectedStarts: [], offsetSec: ist).count, 1)
    }

    // MARK: - A13: a day needs its own HR, not just the previous evening's

    func testDayWithDataOnlyInTheReadWindowIsSkipped() {
        let dayStart = ts("2026-07-18", 0)
        // 300 samples the evening before: inside the 54 h read window, outside the day.
        let eveningBefore = (0..<300).map { HRSample(ts: dayStart - 4 * 3_600 + $0, bpm: 70) }
        XCTAssertFalse(IntelligenceEngine.hasOwnData(eveningBefore, dayStart: dayStart, dayEnd: dayStart + 86_400))
        let own = (0..<300).map { HRSample(ts: dayStart + 9 * 3_600 + $0, bpm: 70) }
        XCTAssertTrue(IntelligenceEngine.hasOwnData(eveningBefore + own, dayStart: dayStart,
                                                    dayEnd: dayStart + 86_400))
    }

    // MARK: - A15: backfilled days older than the window get a wide enough rescore

    func testRescoreWidensToTheOldestUnscoredBackfilledDay() {
        let todayIdx = 20_000
        let oldIdx = todayIdx - 85                       // 85 days ago, well outside 21 days
        let days = IntelligenceEngine.rescoreDays(hrDayCounts: [oldIdx: 27_000, oldIdx + 1: 50],
                                                  scoredDays: [], todayIdx: todayIdx, tzOffset: ist,
                                                  defaultDays: 21, historyDays: 4000)
        XCTAssertEqual(days, 86, "must reach back to the backfilled day itself")
    }

    func testRescoreStaysDefaultWhenOldDaysAreScoredOrThin() {
        let todayIdx = 20_000
        let oldIdx = todayIdx - 85
        let oldDay = AnalyticsEngine.dayString(oldIdx * 86_400 - ist, offsetSec: ist)
        XCTAssertEqual(IntelligenceEngine.rescoreDays(hrDayCounts: [oldIdx: 27_000], scoredDays: [oldDay],
                                                      todayIdx: todayIdx, tzOffset: ist,
                                                      defaultDays: 21, historyDays: 4000), 21)
        XCTAssertEqual(IntelligenceEngine.rescoreDays(hrDayCounts: [oldIdx: 120], scoredDays: [],
                                                      todayIdx: todayIdx, tzOffset: ist,
                                                      defaultDays: 21, historyDays: 4000), 21,
                       "fewer than 200 samples is not a scoreable day")
    }
}
