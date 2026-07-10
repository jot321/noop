import XCTest
import StrandAnalytics
@testable import Strand

final class StressStatePersistenceTests: XCTestCase {

    private final class LockedEvents {
        private let lock = NSLock()
        private var events: [StressStatePersistence.WriteEvent] = []

        func append(_ event: StressStatePersistence.WriteEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            events.removeAll()
            lock.unlock()
        }

        var snapshot: [StressStatePersistence.WriteEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "test.stressState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func coordinator(
        defaults: UserDefaults,
        interval: TimeInterval = 0.05,
        events: LockedEvents = LockedEvents()
    ) -> (StressStatePersistence, LockedEvents) {
        let coordinator = StressStatePersistence(
            defaults: defaults,
            baselineInterval: interval,
            queue: DispatchQueue(label: "test.stressState.\(UUID().uuidString)", qos: .userInteractive),
            writeObserver: { events.append($0) })
        return (coordinator, events)
    }

    func testProductionBaselineIntervalIsSixtySeconds() {
        XCTAssertEqual(StressStatePersistence.productionBaselineInterval, 60)
    }

    func testPreferenceEnablementRequiresMasterAndAutoNudge() {
        XCTAssertFalse(StressStatePersistence.isEnabled(checkIn: false, autoNudge: false))
        XCTAssertFalse(StressStatePersistence.isEnabled(checkIn: false, autoNudge: true))
        XCTAssertFalse(StressStatePersistence.isEnabled(checkIn: true, autoNudge: false))
        XCTAssertTrue(StressStatePersistence.isEnabled(checkIn: true, autoNudge: true))
    }

    func testWasBelowTransitionPersistsImmediately() {
        let defaults = freshDefaults()
        let (coordinator, events) = coordinator(defaults: defaults)
        let previous = StressOnsetDetector.State(baselineRMSSD: 80, wasBelow: false, lastFireAt: 0)
        let next = StressOnsetDetector.State(baselineRMSSD: 81, wasBelow: true, lastFireAt: 0)

        coordinator.persist(previous: previous, next: next, enabled: true)

        XCTAssertEqual(BiofeedbackPrefs.loadStressState(from: defaults), next)
        XCTAssertEqual(events.snapshot, [.store(next, isMainThread: false)])
    }

    func testLastFireAtTransitionPersistsImmediatelyBeforeNudgeSideEffect() {
        let defaults = freshDefaults()
        var sequence: [String] = []
        let lock = NSLock()
        let events = LockedEvents()
        let previous = StressOnsetDetector.State(baselineRMSSD: 80, wasBelow: true, lastFireAt: 0)
        let next = StressOnsetDetector.State(baselineRMSSD: 79, wasBelow: true, lastFireAt: 1_800_000_000)

        let ordered = StressStatePersistence(
            defaults: defaults,
            baselineInterval: 0.05,
            queue: DispatchQueue(label: "test.stressState.ordered", qos: .userInteractive),
            writeObserver: { event in
                events.append(event)
                lock.lock()
                sequence.append("persist")
                lock.unlock()
            })
        ordered.persist(previous: previous, next: next, enabled: true)
        lock.lock()
        sequence.append("nudge")
        lock.unlock()

        XCTAssertTrue(ordered.waitForIdle(timeout: 1))
        XCTAssertEqual(BiofeedbackPrefs.loadStressState(from: defaults), next)
        XCTAssertEqual(sequence, ["persist", "nudge"])
        XCTAssertEqual(events.snapshot, [.store(next, isMainThread: false)])
    }

    func testBaselineOnlyChangesCoalesceToTrailingDeadline() {
        let defaults = freshDefaults()
        let (coordinator, events) = coordinator(defaults: defaults, interval: 0.05)
        let previous = StressOnsetDetector.State(baselineRMSSD: 80, wasBelow: false, lastFireAt: 0)
        let intermediate = StressOnsetDetector.State(baselineRMSSD: 81, wasBelow: false, lastFireAt: 0)
        let newest = StressOnsetDetector.State(baselineRMSSD: 82, wasBelow: false, lastFireAt: 0)

        coordinator.persist(previous: previous, next: intermediate, enabled: true)
        coordinator.persist(previous: intermediate, next: newest, enabled: true)
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertTrue(events.snapshot.isEmpty)

        XCTAssertTrue(waitUntil(timeout: 1) { events.snapshot.count == 1 })
        XCTAssertEqual(BiofeedbackPrefs.loadStressState(from: defaults), newest)
    }

    func testFlushCommitsLatestBaseline() {
        let defaults = freshDefaults()
        let (coordinator, events) = coordinator(defaults: defaults, interval: 0.2)
        let previous = StressOnsetDetector.State(baselineRMSSD: 80, wasBelow: false, lastFireAt: 0)
        let next = StressOnsetDetector.State(baselineRMSSD: 83, wasBelow: false, lastFireAt: 0)

        coordinator.persist(previous: previous, next: next, enabled: true)
        coordinator.flush()

        XCTAssertEqual(BiofeedbackPrefs.loadStressState(from: defaults), next)
        XCTAssertEqual(events.snapshot, [.store(next, isMainThread: false)])
    }

    func testDisableBeforeDeadlineInvalidatesScheduledBaselineWrite() {
        let defaults = freshDefaults()
        let (coordinator, events) = coordinator(defaults: defaults, interval: 0.05)
        let previous = StressOnsetDetector.State(baselineRMSSD: 80, wasBelow: false, lastFireAt: 0)
        let next = StressOnsetDetector.State(baselineRMSSD: 83, wasBelow: false, lastFireAt: 0)

        coordinator.persist(previous: previous, next: next, enabled: true)
        coordinator.setEnabled(false)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))

        XCTAssertTrue(events.snapshot.isEmpty)
        XCTAssertEqual(BiofeedbackPrefs.loadStressState(from: defaults), .initial)
    }

    func testReenableAllowsNewBaselineStateToSchedule() {
        let defaults = freshDefaults()
        let (coordinator, events) = coordinator(defaults: defaults, interval: 0.05)
        let previous = StressOnsetDetector.State(baselineRMSSD: 80, wasBelow: false, lastFireAt: 0)
        let canceled = StressOnsetDetector.State(baselineRMSSD: 81, wasBelow: false, lastFireAt: 0)
        let reenabled = StressOnsetDetector.State(baselineRMSSD: 84, wasBelow: false, lastFireAt: 0)

        coordinator.persist(previous: previous, next: canceled, enabled: true)
        coordinator.setEnabled(false)
        coordinator.setEnabled(true)
        coordinator.persist(previous: canceled, next: reenabled, enabled: true)

        XCTAssertTrue(waitUntil(timeout: 1) { events.snapshot.count == 1 })
        XCTAssertEqual(BiofeedbackPrefs.loadStressState(from: defaults), reenabled)
    }

    func testUnchangedAndDisabledStateWriteNothing() {
        let defaults = freshDefaults()
        let (coordinator, events) = coordinator(defaults: defaults)
        let state = StressOnsetDetector.State(baselineRMSSD: 80, wasBelow: false, lastFireAt: 0)
        let changed = StressOnsetDetector.State(baselineRMSSD: 90, wasBelow: true, lastFireAt: 123)

        coordinator.persist(previous: state, next: state, enabled: true)
        coordinator.persist(previous: state, next: changed, enabled: false)
        coordinator.flush()

        XCTAssertTrue(events.snapshot.isEmpty)
        XCTAssertEqual(BiofeedbackPrefs.loadStressState(from: defaults), .initial)
    }

    func testRRPacketWindowConsumesOnlyPlausibleValuesFromSuppliedPacketOnce() {
        var window = StressRRPacketWindow()

        XCTAssertTrue(window.consume([800, 810, 250, 2_000]))

        XCTAssertEqual(window.values, [800, 810])
    }

    func testRRPacketWindowDoesNotReplayPreviousPacketWhenNoNewRRValuesArrive() {
        var window = StressRRPacketWindow()
        XCTAssertTrue(window.consume([800, 810]))

        XCTAssertFalse(window.consume([]))

        XCTAssertEqual(window.values, [800, 810])
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
