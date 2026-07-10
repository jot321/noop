import XCTest
import WhoopStore
@testable import Strand

/// Pins the pure decision logic behind the automatic cloud-sync runs (CloudSyncScheduler) and the
/// hydration window→UTC-day expansion (CloudHydrator) — the pieces that decide WHEN a pass runs and
/// WHICH sealed objects a viewed window can restore. Everything here is clock- and network-free.
final class CloudSyncSchedulingTests: XCTestCase {

    // MARK: - Scheduler due check

    /// Never ran → always due (first enable syncs on the next tick, not tomorrow).
    func testNeverRanIsDue() {
        XCTAssertTrue(CloudSyncScheduler.isDue(last: nil, now: Date()))
    }

    /// The daily-ish spacing: due again only once ~20 h elapsed, so an hourly foreground tick can't
    /// re-run the pass all day, and a run that lands a little later each day can't drift forever.
    func testSpacingGatesReruns() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertFalse(CloudSyncScheduler.isDue(last: now.addingTimeInterval(-3600), now: now),
                       "an hour after a run is NOT due")
        XCTAssertFalse(CloudSyncScheduler.isDue(last: now.addingTimeInterval(-19 * 3600), now: now))
        XCTAssertTrue(CloudSyncScheduler.isDue(last: now.addingTimeInterval(-20 * 3600), now: now))
        XCTAssertTrue(CloudSyncScheduler.isDue(last: now.addingTimeInterval(-3 * 86_400), now: now))
    }

    /// A clock that moved BACKWARD (timezone hop, manual change) must not wedge the schedule forever:
    /// a last-run in the future simply isn't due yet, and becomes due once real time catches up.
    func testFutureLastRunIsNotDueButRecovers() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let future = now.addingTimeInterval(3600)
        XCTAssertFalse(CloudSyncScheduler.isDue(last: future, now: now))
        XCTAssertTrue(CloudSyncScheduler.isDue(last: future, now: now.addingTimeInterval(21 * 3600)))
    }

    // MARK: - Hydration window → UTC days

    /// A window inside one UTC day names exactly that day.
    func testSingleDayWindow() {
        let start = CloudStreams.dayStartTs("2026-05-01")!
        XCTAssertEqual(CloudHydrator.utcDays(from: start + 100, to: start + 200), ["2026-05-01"])
    }

    /// A window straddling a UTC midnight (the common LOCAL-day view) names both days — the reason
    /// hydration takes a window, not a single day string.
    func testMidnightStraddleNamesBothDays() {
        let d2 = CloudStreams.dayStartTs("2026-05-02")!
        XCTAssertEqual(CloudHydrator.utcDays(from: d2 - 3600, to: d2 + 3600), ["2026-05-01", "2026-05-02"])
    }

    /// `to` is EXCLUSIVE: a window ending exactly at midnight does not drag in the next day, and an
    /// empty/inverted window names nothing.
    func testExclusiveUpperBoundAndDegenerateWindows() {
        let d1 = CloudStreams.dayStartTs("2026-05-01")!
        let d2 = CloudStreams.dayStartTs("2026-05-02")!
        XCTAssertEqual(CloudHydrator.utcDays(from: d1, to: d2), ["2026-05-01"])
        XCTAssertTrue(CloudHydrator.utcDays(from: d1, to: d1).isEmpty)
        XCTAssertTrue(CloudHydrator.utcDays(from: d2, to: d1).isEmpty)
    }
}
