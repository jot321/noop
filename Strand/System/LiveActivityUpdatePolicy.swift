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

/// Tracks pending Live Activity ends without depending on ActivityKit. End plans retain the exact
/// target IDs captured by the controller, while a later successful push invalidates an unstarted plan.
struct LiveActivityReconciliationState {
    struct EndPlan: Equatable {
        fileprivate let generation: UInt64
        let targetIDs: [String]
    }

    private var generation: UInt64 = 0
    private var pendingEndGeneration: UInt64?
    private(set) var lastPush: Date?

    init() {}

    mutating func planEnd(targetIDs: [String]) -> EndPlan {
        generation &+= 1
        pendingEndGeneration = generation
        lastPush = nil
        return EndPlan(generation: generation, targetIDs: targetIDs)
    }

    mutating func recordPush(at date: Date) {
        generation &+= 1
        pendingEndGeneration = nil
        lastPush = date
    }

    func shouldBeginEnd(_ plan: EndPlan) -> Bool {
        generation == plan.generation && pendingEndGeneration == plan.generation
    }

    @discardableResult
    mutating func completeEnd(_ plan: EndPlan) -> Bool {
        guard shouldBeginEnd(plan) else { return false }
        pendingEndGeneration = nil
        return true
    }
}
