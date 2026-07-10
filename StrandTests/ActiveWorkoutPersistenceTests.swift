import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// Pins the durable manual-workout codec (#529): the persist -> rehydrate round-trip that lets a
/// manually-started session survive iOS killing the app mid-session so it can still be ended and saved.
/// Pure + `UserDefaults`-backed, mirroring the Android `ActiveWorkoutPersistenceTest` case for case.
final class ActiveWorkoutPersistenceTests: XCTestCase {

    private final class LockedEvents {
        private let lock = NSLock()
        private var events: [ActiveWorkoutPersistenceCoordinator.WriteEvent] = []

        func append(_ event: ActiveWorkoutPersistenceCoordinator.WriteEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            events.removeAll()
            lock.unlock()
        }

        var snapshot: [ActiveWorkoutPersistenceCoordinator.WriteEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private func sample(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    private func snapshot(
        startSec: Int = 1_700_000_000,
        sport: String = "Tennis",
        samples: [HRSample] = [HRSample(ts: 1_700_000_001, bpm: 120), HRSample(ts: 1_700_000_061, bpm: 145)],
        avgHr: Int = 133,
        peakHr: Int = 145,
        liveStrain: Double = 8.4
    ) -> ActiveWorkoutPersistence.Snapshot {
        ActiveWorkoutPersistence.Snapshot(startSec: startSec, sport: sport, samples: samples,
                                          avgHr: avgHr, peakHr: peakHr, liveStrain: liveStrain)
    }

    /// A throwaway, isolated defaults suite so the test never touches the real store.
    private func freshDefaults() -> UserDefaults {
        let name = "test.activeWorkout.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - pure codec round-trip

    func testEncodeDecodeRoundTripsEveryField() {
        let original = snapshot()
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripWithNoSamples() {
        // A session that started but hasn't captured a sample yet (strap not streaming) must still
        // persist + rehydrate — otherwise a kill right after Start loses the start time.
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(samples: [], avgHr: 0, peakHr: 0, liveStrain: 0)))
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.samples.isEmpty)
        XCTAssertEqual(decoded!.startSec, 1_700_000_000)
        XCTAssertEqual(decoded!.sport, "Tennis")
    }

    func testRoundTripSportNameWithSpacesPreserved() {
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sport: "Traditional Strength Training")))
        XCTAssertEqual(decoded!.sport, "Traditional Strength Training")
    }

    // MARK: - UserDefaults store / load / clear

    func testStoreLoadClearRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))   // nothing yet
        let snap = snapshot()
        ActiveWorkoutPersistence.store(snap, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snap)
        // Ending the session clears it — a relaunch then rehydrates nothing.
        ActiveWorkoutPersistence.clear(from: defaults)
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
    }

    func testStoreOverwritesPreviousSnapshot() {
        // Each captured sample re-stores; the latest write wins (mirrors the per-sample persist).
        let defaults = freshDefaults()
        ActiveWorkoutPersistence.store(snapshot(samples: [sample(1_700_000_001, 120)], avgHr: 120, peakHr: 120),
                                       into: defaults)
        let later = snapshot(samples: [sample(1_700_000_001, 120), sample(1_700_000_061, 150)],
                             avgHr: 135, peakHr: 150, liveStrain: 9.1)
        ActiveWorkoutPersistence.store(later, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), later)
    }

    // MARK: - honest failure (no revived bogus card)

    func testDecodeNilOrEmptyIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(nil))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data()))
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("not json".utf8)))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("{\"unexpected\":1}".utf8)))
    }

    func testDecodeRejectsNonPositiveStart() {
        let bad = snapshot(startSec: 0)
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(bad)))
    }

    // MARK: - bound-checked untrusted samples

    func testDecodeDropsOutOfRangeSamples() {
        // A corrupt blob with a bpm=0, bpm=400, and ts<=0 sample — only the in-range one survives.
        let dirty = snapshot(samples: [
            sample(1_700_000_001, 150),   // good
            sample(1_700_000_002, 0),     // bpm 0 — rejected
            sample(1_700_000_003, 400),   // bpm out of range — rejected
            sample(0, 120),               // ts <= 0 — rejected
        ])
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertEqual(decoded?.samples, [sample(1_700_000_001, 150)])
    }

    func testDecodeClampsNegativeDerivedStats() {
        let dirty = snapshot(samples: [], avgHr: -5, peakHr: -9, liveStrain: -3)
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.avgHr, 0)
        XCTAssertEqual(decoded!.peakHr, 0)
        XCTAssertEqual(decoded!.liveStrain, 0, accuracy: 1e-9)
    }

    // MARK: - coalesced coordinator

    private func testQueue(_ name: String = UUID().uuidString) -> DispatchQueue {
        DispatchQueue(label: "test.activeWorkoutPersistence.\(name)", qos: .userInteractive)
    }

    func testCoordinatorStartPersistsImmediatelyOffMainThread() {
        let defaults = freshDefaults()
        let events = LockedEvents()
        let coordinator = ActiveWorkoutPersistenceCoordinator(
            defaults: defaults,
            snapshotInterval: 0.05,
            queue: testQueue(),
            writeObserver: { events.append($0) })

        coordinator.start(snapshot())
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))

        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snapshot())
        XCTAssertEqual(events.snapshot.count, 1)
        if case let .store(_, isMainThread) = events.snapshot[0] {
            XCTAssertFalse(isMainThread)
        } else {
            XCTFail("Expected an immediate store event")
        }
    }

    func testCoordinatorStartReturnsOnlyAfterInitialSnapshotIsDurable() {
        let defaults = freshDefaults()
        let events = LockedEvents()
        let queue = testQueue()
        let unblockQueue = DispatchSemaphore(value: 0)
        queue.async { unblockQueue.wait() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
            unblockQueue.signal()
        }
        let coordinator = ActiveWorkoutPersistenceCoordinator(
            defaults: defaults,
            snapshotInterval: 0.05,
            queue: queue,
            writeObserver: { events.append($0) })
        let initial = snapshot()

        coordinator.start(initial)

        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), initial)
        XCTAssertEqual(events.snapshot, [.store(initial, isMainThread: false)])
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))
    }

    func testCoordinatorCoalescesRepeatedUpdatesToOneTrailingWrite() {
        let defaults = freshDefaults()
        let events = LockedEvents()
        let coordinator = ActiveWorkoutPersistenceCoordinator(
            defaults: defaults,
            snapshotInterval: 0.05,
            queue: testQueue(),
            writeObserver: { events.append($0) })
        coordinator.start(snapshot())
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))
        events.removeAll()

        let firstUpdate = snapshot(samples: [sample(1_700_000_001, 120)], avgHr: 120, peakHr: 120)
        let newestUpdate = snapshot(
            samples: [sample(1_700_000_001, 120), sample(1_700_000_002, 140)],
            avgHr: 130,
            peakHr: 140,
            liveStrain: 3.2)
        coordinator.update(firstUpdate)
        coordinator.update(newestUpdate)

        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertTrue(events.snapshot.isEmpty)
        XCTAssertTrue(waitUntil(timeout: 1) { events.snapshot.count == 1 })
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), newestUpdate)
        if case let .store(stored, _) = events.snapshot[0] {
            XCTAssertEqual(stored, newestUpdate)
        } else {
            XCTFail("Expected the trailing event to store the newest snapshot")
        }
    }

    func testCoordinatorFlushPersistsNewestSnapshotNowAndInvalidatesTrailingWrite() {
        let defaults = freshDefaults()
        let events = LockedEvents()
        let coordinator = ActiveWorkoutPersistenceCoordinator(
            defaults: defaults,
            snapshotInterval: 0.2,
            queue: testQueue(),
            writeObserver: { events.append($0) })
        coordinator.start(snapshot())
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))
        events.removeAll()

        let latest = snapshot(samples: [sample(1_700_000_001, 121)], avgHr: 121, peakHr: 121)
        coordinator.update(latest)
        coordinator.flush()
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))

        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), latest)
        XCTAssertEqual(events.snapshot.count, 1)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))
        XCTAssertEqual(events.snapshot.count, 1)
    }

    func testCoordinatorFinishClearsAfterQueuedWritesAndDelayedWorkCannotResurrect() {
        let defaults = freshDefaults()
        let events = LockedEvents()
        let coordinator = ActiveWorkoutPersistenceCoordinator(
            defaults: defaults,
            snapshotInterval: 0.05,
            queue: testQueue(),
            writeObserver: { events.append($0) })
        coordinator.start(snapshot())
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))

        let late = snapshot(samples: [sample(1_700_000_001, 122)], avgHr: 122, peakHr: 122)
        coordinator.update(late)
        coordinator.finishAndClear()
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(coordinator.waitForIdle(timeout: 1))

        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
        XCTAssertEqual(events.snapshot.last, .clear(isMainThread: false))
        let clearIndex = events.snapshot.lastIndex(of: .clear(isMainThread: false))
        let laterStores = events.snapshot.enumerated().filter { index, event in
            guard let clearIndex, index > clearIndex else { return false }
            if case .store = event { return true }
            return false
        }
        XCTAssertTrue(laterStores.isEmpty)
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
