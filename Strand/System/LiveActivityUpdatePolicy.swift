import Foundation

/// Shared cadence policy for the iOS Live Activity. Kept pure so the macOS test target can verify
/// active/passive decisions with explicit timestamps and no ActivityKit dependency.
enum LiveActivityUpdatePolicy {
    static let activeMinimumInterval: TimeInterval = 2
    static let passiveMinimumInterval: TimeInterval = 30

    enum Decision: Equatable {
        case none
        case start
        case update
        case end
    }

    static func evaluate(
        hasExistingActivity: Bool,
        enabled: Bool,
        connected: Bool,
        bpm: Int?,
        activeRealtimeExperience: Bool,
        lastPush: Date?,
        now: Date
    ) -> Decision {
        guard enabled, connected else { return .end }
        guard bpm != nil else { return .none }
        guard hasExistingActivity else { return .start }

        let minimumInterval = activeRealtimeExperience ? activeMinimumInterval : passiveMinimumInterval
        guard let lastPush else { return .update }
        return now.timeIntervalSince(lastPush) >= minimumInterval ? .update : .none
    }
}

/// Builds the terminal target snapshot before the controller drops its cached handle. The cached
/// object wins duplicate IDs because it is the exact instance the controller most recently used.
enum LiveActivityEndCandidateSet {
    static func deduplicated<Element>(
        cached: Element?,
        listed: [Element],
        id: KeyPath<Element, String>
    ) -> [Element] {
        var seenIDs: Set<String> = []
        return ([cached].compactMap { $0 } + listed).filter {
            seenIDs.insert($0[keyPath: id]).inserted
        }
    }
}

/// Tracks Live Activity end targets without depending on ActivityKit. Pending work can be canceled,
/// while begun and completed target IDs remain unavailable for re-adoption.
struct LiveActivityReconciliationState {
    struct EndPlan: Equatable {
        fileprivate let generation: UInt64
        let targetIDs: [String]
    }

    struct TerminalHydrationRetryPlan: Equatable {
        fileprivate let generation: UInt64
        let attempt: Int
    }

    private var generation: UInt64 = 0
    private var pendingEnds: [UInt64: EndPlan] = [:]
    private var activeEndTargetIDs: [UInt64: Set<String>] = [:]
    private var retiredTargetIDs: Set<String> = []
    private let maxTerminalHydrationRetries: Int
    private var terminalHydrationGeneration: UInt64 = 0
    private var terminalHydrationAttempts = 0
    private var pendingTerminalHydrationRetry: TerminalHydrationRetryPlan?
    private var terminalTargetsFound = false
    private(set) var lastPush: Date?

    init(maxTerminalHydrationRetries: Int = 2) {
        self.maxTerminalHydrationRetries = max(0, maxTerminalHydrationRetries)
    }

    mutating func planEnd(targetIDs: [String]) -> EndPlan? {
        var unavailableIDs = pendingEnds.values.reduce(into: retiredTargetIDs) {
            $0.formUnion($1.targetIDs)
        }
        unavailableIDs = activeEndTargetIDs.values.reduce(into: unavailableIDs) {
            $0.formUnion($1)
        }
        var seenIDs: Set<String> = []
        let plannedIDs = targetIDs.filter {
            seenIDs.insert($0).inserted && !unavailableIDs.contains($0)
        }
        lastPush = nil
        guard !plannedIDs.isEmpty else { return nil }

        generation &+= 1
        let plan = EndPlan(generation: generation, targetIDs: plannedIDs)
        pendingEnds[plan.generation] = plan
        return plan
    }

    mutating func cancelPendingEndForValidUpdate() {
        pendingEnds.removeAll()
        terminalHydrationGeneration &+= 1
        pendingTerminalHydrationRetry = nil
        terminalHydrationAttempts = 0
        terminalTargetsFound = false
    }

    mutating func planTerminalHydrationRetry() -> TerminalHydrationRetryPlan? {
        guard !terminalTargetsFound else { return nil }
        guard pendingTerminalHydrationRetry == nil else { return nil }
        guard terminalHydrationAttempts < maxTerminalHydrationRetries else { return nil }

        terminalHydrationAttempts += 1
        terminalHydrationGeneration &+= 1
        let plan = TerminalHydrationRetryPlan(
            generation: terminalHydrationGeneration,
            attempt: terminalHydrationAttempts
        )
        pendingTerminalHydrationRetry = plan
        return plan
    }

    @discardableResult
    mutating func beginTerminalHydrationRetry(_ plan: TerminalHydrationRetryPlan) -> Bool {
        guard pendingTerminalHydrationRetry == plan else { return false }
        pendingTerminalHydrationRetry = nil
        return true
    }

    mutating func markTerminalTargetsFound() {
        terminalHydrationGeneration &+= 1
        pendingTerminalHydrationRetry = nil
        terminalTargetsFound = true
    }

    func isAdoptable(activityID: String) -> Bool {
        guard !retiredTargetIDs.contains(activityID) else { return false }
        guard !pendingEnds.values.contains(where: { $0.targetIDs.contains(activityID) }) else {
            return false
        }
        return !activeEndTargetIDs.values.contains { $0.contains(activityID) }
    }

    @discardableResult
    mutating func beginEnd(_ plan: EndPlan) -> Bool {
        guard pendingEnds[plan.generation] == plan else { return false }
        pendingEnds.removeValue(forKey: plan.generation)
        activeEndTargetIDs[plan.generation] = Set(plan.targetIDs)
        return true
    }

    mutating func recordPush(at date: Date) {
        lastPush = date
    }

    @discardableResult
    mutating func completeEnd(_ plan: EndPlan) -> Bool {
        guard let completedIDs = activeEndTargetIDs.removeValue(forKey: plan.generation) else {
            return false
        }
        retiredTargetIDs.formUnion(completedIDs)
        return true
    }
}
