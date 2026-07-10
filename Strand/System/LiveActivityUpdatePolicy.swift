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

/// Tracks Live Activity end targets without depending on ActivityKit. Pending work can be canceled,
/// while begun and completed target IDs remain unavailable for re-adoption.
struct LiveActivityReconciliationState {
    struct EndPlan: Equatable {
        fileprivate let generation: UInt64
        let targetIDs: [String]
    }

    private var generation: UInt64 = 0
    private var pendingEnds: [UInt64: EndPlan] = [:]
    private var activeEndTargetIDs: [UInt64: Set<String>] = [:]
    private var retiredTargetIDs: Set<String> = []
    private(set) var lastPush: Date?

    init() {}

    mutating func planEnd(targetIDs: [String]) -> EndPlan {
        generation &+= 1
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
        let plan = EndPlan(generation: generation, targetIDs: plannedIDs)
        pendingEnds[plan.generation] = plan
        lastPush = nil
        return plan
    }

    mutating func cancelPendingEndForValidUpdate() {
        pendingEnds.removeAll()
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
