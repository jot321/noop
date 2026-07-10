import XCTest
@testable import Strand

final class LogTailPersistenceTests: XCTestCase {

    private final class LockedEvents {
        private let lock = NSLock()
        private var events: [LogTailPersistence.WriteEvent] = []

        func append(_ event: LogTailPersistence.WriteEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            events.removeAll()
            lock.unlock()
        }

        var snapshot: [LogTailPersistence.WriteEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "test.logTail.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func writer(
        defaults: UserDefaults,
        key: String = "tail",
        limit: Int = 2_000,
        interval: TimeInterval = 0.05,
        events: LockedEvents = LockedEvents()
    ) -> (LogTailPersistence, LockedEvents) {
        let writer = LogTailPersistence(
            defaults: defaults,
            key: key,
            limit: limit,
            persistenceInterval: interval,
            queue: DispatchQueue(label: "test.logTail.\(UUID().uuidString)", qos: .userInteractive),
            writeObserver: { events.append($0) })
        return (writer, events)
    }

    func testProductionDefaultsUseTwoThousandLineCapAndFiveSecondCadence() {
        XCTAssertEqual(LogTailPersistence.productionLimit, 2_000)
        XCTAssertEqual(LogTailPersistence.productionInterval, 5)
    }

    func testAppendPreservesOrderingAndCapsTail() {
        let defaults = freshDefaults()
        let (writer, _) = writer(defaults: defaults, limit: 3)

        writer.append("one")
        writer.append("two")
        writer.append("three")
        writer.append("four")
        writer.flush()

        XCTAssertEqual(writer.persistedTail(), ["two", "three", "four"])
    }

    func testContinuousAppendsAreBoundedToTrailingCadence() {
        let defaults = freshDefaults()
        let (writer, events) = writer(defaults: defaults, interval: 0.05)

        writer.append("one")
        writer.append("two")
        writer.append("three")
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertTrue(events.snapshot.isEmpty)

        XCTAssertTrue(waitUntil(timeout: 1) { events.snapshot.count == 1 })
        XCTAssertEqual(writer.persistedTail(), ["one", "two", "three"])

        events.removeAll()
        writer.append("four")
        writer.append("five")
        XCTAssertTrue(waitUntil(timeout: 1) { events.snapshot.count == 1 })
        XCTAssertEqual(writer.persistedTail(), ["one", "two", "three", "four", "five"])
    }

    func testTrailingStateIsEventuallyWrittenWhileLoggingContinues() {
        let defaults = freshDefaults()
        let (writer, events) = writer(defaults: defaults, interval: 0.03)

        for i in 0..<8 {
            writer.append("line-\(i)")
            Thread.sleep(forTimeInterval: 0.012)
        }

        XCTAssertTrue(waitUntil(timeout: 1) {
            events.snapshot.contains { event in
                if case let .store(lines, _) = event {
                    return lines.last == "line-7"
                }
                return false
            }
        })
    }

    func testFlushWritesLatestLineImmediatelyAndCleanFlushDoesNothing() {
        let defaults = freshDefaults()
        let (writer, events) = writer(defaults: defaults, interval: 0.2)

        writer.append("one")
        writer.append("two")
        writer.flush()
        XCTAssertTrue(writer.waitForIdle(timeout: 1))
        XCTAssertEqual(writer.persistedTail(), ["one", "two"])
        XCTAssertEqual(events.snapshot.count, 1)

        writer.flush()
        XCTAssertTrue(writer.waitForIdle(timeout: 1))
        XCTAssertEqual(events.snapshot.count, 1)
    }

    func testLoadingExistingPersistedTailSeedsSubsequentAppends() {
        let defaults = freshDefaults()
        defaults.set(["old-one", "old-two"], forKey: "tail")
        let (writer, _) = writer(defaults: defaults, key: "tail", limit: 3)

        writer.append("new")
        writer.flush()

        XCTAssertEqual(writer.persistedTail(), ["old-one", "old-two", "new"])
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
