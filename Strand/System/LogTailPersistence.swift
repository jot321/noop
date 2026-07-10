import Foundation

final class LogTailPersistence {
    enum WriteEvent: Equatable {
        case store([String], isMainThread: Bool)
    }

    static let productionLimit = 2_000
    static let productionInterval: TimeInterval = 5

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let persistenceInterval: TimeInterval
    private let queue: DispatchQueue
    private let writeObserver: ((WriteEvent) -> Void)?
    private let specificKey = DispatchSpecificKey<Void>()

    private var tail: [String]
    private var dirty = false
    private var trailingID: UInt64 = 0
    private var scheduledTrailingID: UInt64?

    init(
        defaults: UserDefaults = .standard,
        key: String,
        limit: Int = productionLimit,
        persistenceInterval: TimeInterval = productionInterval,
        queue: DispatchQueue = DispatchQueue(label: "noop.logTail.persistence", qos: .utility),
        writeObserver: ((WriteEvent) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = max(1, limit)
        self.persistenceInterval = persistenceInterval
        self.queue = queue
        self.writeObserver = writeObserver
        let loaded = defaults.array(forKey: key) as? [String] ?? []
        self.tail = loaded.count > self.limit ? Array(loaded.suffix(self.limit)) : loaded
        queue.setSpecific(key: specificKey, value: ())
    }

    func append(_ line: String) {
        queue.async { [self] in
            tail.append(line)
            if tail.count > limit {
                tail.removeFirst(tail.count - limit)
            }
            dirty = true
            scheduleTrailingIfNeeded()
        }
    }

    func flush() {
        syncOnQueue {
            persistIfDirty()
        }
    }

    func persistedTail() -> [String] {
        syncOnQueue {
            persistIfDirty()
            return tail
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
        queue.asyncAfter(deadline: .now() + persistenceInterval) { [weak self] in
            self?.runTrailing(id: id)
        }
    }

    private func runTrailing(id: UInt64) {
        guard scheduledTrailingID == id else { return }
        scheduledTrailingID = nil
        persistIfDirty()
    }

    private func persistIfDirty() {
        guard dirty else {
            invalidateTrailing()
            return
        }
        dirty = false
        invalidateTrailing()
        defaults.set(tail, forKey: key)
        writeObserver?(.store(tail, isMainThread: Thread.isMainThread))
    }

    private func invalidateTrailing() {
        trailingID &+= 1
        scheduledTrailingID = nil
    }

    private func syncOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: specificKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }
}
