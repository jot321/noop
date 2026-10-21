import XCTest
import WhoopStore
@testable import Strand

/// The Consistency tile scores the spread of bedtimes. `repo.sleeps` holds every block since #715, so
/// an afternoon nap or the second half of a split night counted as a "bedtime" and the tile read 0%
/// for a regular sleeper. Only each day's main-night onset is a bedtime. Synthetic times only.
final class SleepConsistencyTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Midnight UTC of a synthetic day.
    private func day(_ n: Int) -> Int { 1_798_761_600 + n * 86_400 }

    private func block(_ start: Int, minutes: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: start + minutes * 60, efficiency: nil,
                           restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// Seven nights in bed between 23:00 and 23:20, plus afternoon naps on three of the days and
    /// one night split by a 20-minute wake.
    private var regularSleeperWithNaps: [CachedSleepSession] {
        var out: [CachedSleepSession] = []
        for n in 0..<7 {
            let bed = day(n) + 23 * 3_600 + (n % 3) * 600
            if n == 4 {
                out.append(block(bed, minutes: 180))
                out.append(block(bed + 200 * 60, minutes: 240))
            } else {
                out.append(block(bed, minutes: 450))
            }
            if n % 2 == 1 { out.append(block(day(n + 1) + 15 * 3_600, minutes: 50)) }
        }
        return out.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    func testNapsAndSplitNightsDoNotCountAsBedtimes() {
        let scores = SleepView.bedtimeConsistency(regularSleeperWithNaps, habitualMidsleepSec: nil,
                                                  calendar: utc)
        XCTAssertEqual(scores.count, 5, "one bedtime per night: 7 nights, scored from the 3rd")
        XCTAssertGreaterThan(scores.last ?? 0, 85, "a 20-minute bedtime spread is a consistent sleeper")
    }

    func testIrregularBedtimesStillScoreLow() {
        let sessions = (0..<6).map { n in block(day(n) + (n % 2 == 0 ? 21 : 27) * 3_600, minutes: 420) }
        let scores = SleepView.bedtimeConsistency(sessions, habitualMidsleepSec: nil, calendar: utc)
        XCTAssertLessThan(scores.last ?? 100, 30, "bedtimes 6 h apart are inconsistent")
    }
}
