import XCTest
@testable import Strand

/// PR#554 (MumiZed, reimplemented as NoopApp) — per-day wake overrides for the wind-down nudge.
///
/// The nudge derives its fire time from the user's wake time minus sleep need minus lead. Per-day overrides
/// let a single weekday use a DIFFERENT wake time (a weekend lie-in, say) while every un-overridden day
/// falls back to the default. These pin: the override round-trips through the store, an absent override
/// reverts a day to the default, the per-weekday nudge math follows the override, and clamping is honest.
///
/// `WindDownNudge` is @MainActor and backed by UserDefaults.standard, so each test clears its keys first.
@MainActor
final class WindDownPerDayOverrideTests: XCTestCase {

    private let perDayKey = "windDown.perDayWakeMinutes"
    private let wakeKey = "windDown.wakeMinutes"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: perDayKey)
        UserDefaults.standard.removeObject(forKey: wakeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: perDayKey)
        UserDefaults.standard.removeObject(forKey: wakeKey)
        super.tearDown()
    }

    func testNoOverrides_everyDayUsesDefaultWake() {
        WindDownNudge.setWakeMinutes(7 * 60)   // 07:00 default
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
        for weekday in 1...7 {
            XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: weekday), 7 * 60)
        }
    }

    func testSetOverride_appliesToThatDayOnly() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)   // Saturday lie-in to 09:00
        XCTAssertTrue(WindDownNudge.hasPerDayOverrides)
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 7), 9 * 60)
        // Every other day still uses the default.
        for weekday in 1...6 {
            XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: weekday), 7 * 60)
        }
    }

    func testClearOverride_revertsDayToDefault() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: 8 * 60)   // Sunday 08:00
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 1), 8 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: nil)      // clear it
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 1), 7 * 60)
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }

    func testPerDayNudgeMinute_followsTheOverride() {
        // Defaults: 8h need + 30m lead. Wake 07:00 default → nudge 22:00. Override Saturday wake 09:00 →
        // nudge 00:00 the previous day's evening? No — 09:00 − 8:30 = 00:30. Just assert it tracks the math.
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)
        let need = WindDownNudge.sleepNeedMinutes, lead = WindDownNudge.leadMinutes
        let expectedSat = (((9 * 60 - need - lead) % 1440) + 1440) % 1440
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWeekday: 7), expectedSat)
        // A non-overridden day uses the default wake.
        let expectedDefault = (((7 * 60 - need - lead) % 1440) + 1440) % 1440
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWeekday: 3), expectedDefault)
    }

    func testOverrideMinutesAreClamped() {
        WindDownNudge.setWakeOverride(weekday: 4, minutes: 5_000)   // way past a day
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 4), 24 * 60 - 1)
        WindDownNudge.setWakeOverride(weekday: 4, minutes: -100)
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 4), 0)
    }

    func testInvalidWeekday_isIgnored() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 9, minutes: 8 * 60)   // no weekday 9
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }
    // MARK: - Which evening a per-day override fires on

    func testOverrideBeforeMidnightFiresThePreviousEvening() {
        // Monday wake 07:00, 8 h need + 30 min lead → 22:30 on SUNDAY, not Monday night.
        let slot = WindDownNudge.nudgeSlot(wakeWeekday: 2, wakeMinutes: 7 * 60, sleepNeed: 8 * 60, lead: 30)
        XCTAssertEqual(slot.weekday, 1)
        XCTAssertEqual(slot.minute, 22 * 60 + 30)
    }

    func testSundayWakeWrapsToSaturday() {
        let slot = WindDownNudge.nudgeSlot(wakeWeekday: 1, wakeMinutes: 6 * 60, sleepNeed: 8 * 60, lead: 30)
        XCTAssertEqual(slot.weekday, 7)
        XCTAssertEqual(slot.minute, 21 * 60 + 30)
    }

    func testNudgeAfterMidnightStaysOnTheWakeDay() {
        // Saturday wake 09:00 → 00:30 early Saturday, the same night.
        let slot = WindDownNudge.nudgeSlot(wakeWeekday: 7, wakeMinutes: 9 * 60, sleepNeed: 8 * 60, lead: 30)
        XCTAssertEqual(slot.weekday, 7)
        XCTAssertEqual(slot.minute, 30)
    }

    // MARK: - The "Tonight" hero

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// A synthetic Sunday at the given UTC hour (4 Jan 2032 is a Sunday).
    private func sunday(_ hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2032, month: 1, day: 4, hour: hour))!
    }

    func testTonightUsesTomorrowsOverride() {
        // Sunday evening, Monday has an early 05:30 override → wake 05:30, nudge 21:00.
        let t = WindDownNudge.tonight(now: sunday(18), calendar: utc, defaultWake: 8 * 60,
                                      overrides: [2: 5 * 60 + 30], sleepNeed: 8 * 60, lead: 30)
        XCTAssertEqual(t.wake, 5 * 60 + 30)
        XCTAssertEqual(t.nudgeMinute, 21 * 60)
    }

    func testTonightBeforeTodaysWakeIsThisMorning() {
        // 02:00 on Sunday, before Sunday's 09:00 override: the coming wake is this morning's.
        let t = WindDownNudge.tonight(now: sunday(2), calendar: utc, defaultWake: 7 * 60,
                                      overrides: [1: 9 * 60], sleepNeed: 8 * 60, lead: 30)
        XCTAssertEqual(t.wake, 9 * 60)
    }

    func testTonightWithoutOverridesUsesTheDefault() {
        let t = WindDownNudge.tonight(now: sunday(18), calendar: utc, defaultWake: 7 * 60,
                                      overrides: [:], sleepNeed: 8 * 60, lead: 30)
        XCTAssertEqual(t.wake, 7 * 60)
        XCTAssertEqual(t.nudgeMinute, 22 * 60 + 30)
    }
}
