import Foundation
import StrandAnalytics

struct StressRRPacketWindow {
    private(set) var values: [Int] = []
    private let limit: Int

    init(limit: Int = 120) {
        self.limit = limit
    }

    @discardableResult
    mutating func consume(_ packet: [Int]) -> Bool {
        let fresh = packet.filter { $0 > 300 && $0 < 2_000 }
        guard !fresh.isEmpty else { return false }
        values.append(contentsOf: fresh)
        if values.count > limit {
            values.removeFirst(values.count - limit)
        }
        return true
    }
}

final class StressStatePersistence {
    enum WriteEvent: Equatable {
        case store(StressOnsetDetector.State, isMainThread: Bool)
    }

    static let productionBaselineInterval: TimeInterval = 60

    private let defaults: UserDefaults
    private let baselineInterval: TimeInterval
    private let queue: DispatchQueue
    private let writeObserver: ((WriteEvent) -> Void)?
    private let specificKey = DispatchSpecificKey<Void>()

    private var latest: StressOnsetDetector.State?
    private var dirty = false
    private var trailingID: UInt64 = 0
    private var scheduledTrailingID: UInt64?

    init(
        defaults: UserDefaults = .standard,
        baselineInterval: TimeInterval = productionBaselineInterval,
        queue: DispatchQueue = DispatchQueue(label: "noop.stressState.persistence", qos: .utility),
        writeObserver: ((WriteEvent) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.baselineInterval = baselineInterval
        self.queue = queue
        self.writeObserver = writeObserver
        queue.setSpecific(key: specificKey, value: ())
    }

    func persist(previous: StressOnsetDetector.State, next: StressOnsetDetector.State, enabled: Bool) {
        guard enabled else {
            queue.async { [self] in
                latest = nil
                dirty = false
                invalidateTrailing()
            }
            return
        }
        guard previous != next else { return }

        let safetyEdge = previous.wasBelow != next.wasBelow || previous.lastFireAt != next.lastFireAt
        if safetyEdge {
            syncOnQueue {
                self.latest = next
                self.dirty = false
                self.invalidateTrailing()
                self.store(next)
            }
        } else {
            queue.async { [self] in
                latest = next
                dirty = true
                scheduleTrailingIfNeeded()
            }
        }
    }

    func flush() {
        syncOnQueue {
            self.persistIfDirty()
        }
    }

    @discardableResult
    func waitForIdle(timeout: TimeInterval = 1) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    private func scheduleTrailingIfNeeded() {
        guard scheduledTrailingID == nil else { return }
        trailingID &+= 1
        let id = trailingID
        scheduledTrailingID = id
        queue.asyncAfter(deadline: .now() + baselineInterval) { [weak self] in
            self?.runTrailing(id: id)
        }
    }

    private func runTrailing(id: UInt64) {
        guard scheduledTrailingID == id else { return }
        scheduledTrailingID = nil
        persistIfDirty()
    }

    private func persistIfDirty() {
        guard dirty, let latest else {
            invalidateTrailing()
            return
        }
        dirty = false
        invalidateTrailing()
        store(latest)
    }

    private func store(_ state: StressOnsetDetector.State) {
        BiofeedbackPrefs.saveStressState(state, into: defaults)
        writeObserver?(.store(state, isMainThread: Thread.isMainThread))
    }

    private func invalidateTrailing() {
        trailingID &+= 1
        scheduledTrailingID = nil
    }

    private func syncOnQueue<T>(_ work: @escaping () -> T) -> T {
        if DispatchQueue.getSpecific(key: specificKey) != nil {
            return work()
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        queue.async {
            result = work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }
}
