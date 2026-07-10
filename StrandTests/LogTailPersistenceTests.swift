import XCTest
@testable import Strand

final class LogTailPersistenceTests: XCTestCase {

    @MainActor
    private final class FlushOwner: PerformanceStateFlushing {
        private(set) var callCount = 0

        func flushPerformanceState() {
            callCount += 1
        }
    }

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

    func testDisconnectFinalizationFlushesExactlyOnceAfterDiagnostics() {
        for initiallyConnected in [true, false] {
            var events: [String] = []
            var connected = initiallyConnected

            DisconnectCallbackFinalization.run(
                diagnostics: {
                    events.append("final diagnostic")
                    events.append("reconnect scheduled")
                },
                disconnectEdge: {
                    let publishedNewEdge = connected
                    connected = false
                    if publishedNewEdge {
                        events.append("disconnect edge flush")
                    }
                    return publishedNewEdge
                },
                finalFlush: {
                    events.append("explicit final flush")
                }
            )

            XCTAssertEqual(
                events,
                initiallyConnected
                    ? ["final diagnostic", "reconnect scheduled", "disconnect edge flush"]
                    : ["final diagnostic", "reconnect scheduled", "explicit final flush"]
            )
        }
    }

    func testLoadingExistingPersistedTailSeedsSubsequentAppends() {
        let defaults = freshDefaults()
        defaults.set(["old-one", "old-two"], forKey: "tail")
        let (writer, _) = writer(defaults: defaults, key: "tail", limit: 3)

        writer.append("new")
        writer.flush()

        XCTAssertEqual(writer.persistedTail(), ["old-one", "old-two", "new"])
    }

    @MainActor
    func testScheduledExportFlushesInstalledOwnerSynchronouslyBeforeReadingTail() async {
        let owner = FlushOwner()
        PerformanceFlushRegistry.install(owner)
        var fallbackCalls = 0
        var flushCountWhenTailWasRead = 0

        let text = ScheduledDebugExport.preparedExportText(
            logFallback: { fallbackCalls += 1 },
            readTail: {
                flushCountWhenTailWasRead = owner.callCount
                return "persisted tail"
            })

        XCTAssertEqual(text, "persisted tail")
        XCTAssertEqual(owner.callCount, 1)
        XCTAssertEqual(flushCountWhenTailWasRead, 1)
        XCTAssertEqual(fallbackCalls, 0)
    }

    @MainActor
    func testPerformanceFlushRegistryDoesNotRetainOwnerAndFallsBackWhenItIsGone() async {
        var owner: FlushOwner? = FlushOwner()
        weak var weakOwner = owner
        PerformanceFlushRegistry.install(owner!)

        owner = nil

        XCTAssertNil(weakOwner)
        var fallbackCalls = 0
        PerformanceFlushRegistry.flush(logFallback: { fallbackCalls += 1 })
        XCTAssertEqual(fallbackCalls, 1)
    }

    @MainActor
    func testLifecycleFlushObserverRunsSynchronouslyOnMainActor() async {
        let center = NotificationCenter()
        let name = Notification.Name("test.performanceFlush.sync")
        let observers = PerformanceFlushObservers(center: center)
        var calls = 0
        observers.install(names: [name]) {
            XCTAssertTrue(Thread.isMainThread)
            calls += 1
        }

        center.post(name: name, object: nil)

        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testLifecycleFlushObserverRemovesTokensOnDeinit() async {
        let center = NotificationCenter()
        let name = Notification.Name("test.performanceFlush.cleanup")
        var observers: PerformanceFlushObservers? = PerformanceFlushObservers(center: center)
        var calls = 0
        observers?.install(names: [name]) { calls += 1 }

        observers = nil
        center.post(name: name, object: nil)

        XCTAssertEqual(calls, 0)
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
