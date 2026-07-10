import Foundation
import WhoopProtocol

enum RealtimeDemandOwner: CaseIterable, Hashable {
    case liveScreen
    case workout
    case liveSession
    case manualControl
}

struct RealtimeOwnerChange: Equatable {
    let owners: Set<RealtimeDemandOwner>
    let changed: Bool
    let becameActive: Bool
}

struct RealtimeOwnerCoordinator {
    private(set) var owners = Set<RealtimeDemandOwner>()

    var ownersForRearm: Set<RealtimeDemandOwner>? {
        owners.isEmpty ? nil : owners
    }

    @discardableResult
    mutating func acquire(_ owner: RealtimeDemandOwner) -> RealtimeOwnerChange {
        replace(with: owners.union([owner]))
    }

    @discardableResult
    mutating func release(_ owner: RealtimeDemandOwner) -> RealtimeOwnerChange {
        replace(with: owners.subtracting([owner]))
    }

    @discardableResult
    mutating func replace(with nextOwners: Set<RealtimeDemandOwner>) -> RealtimeOwnerChange {
        let previousOwners = owners
        owners = nextOwners
        return RealtimeOwnerChange(
            owners: nextOwners,
            changed: previousOwners != nextOwners,
            becameActive: previousOwners.isEmpty && !nextOwners.isEmpty
        )
    }
}

enum RealtimeOwnerMutation: Equatable {
    case acquire(RealtimeDemandOwner)
    case release(RealtimeDemandOwner)
}

/// Couples the workout realtime owner to the workout's lifetime rather than to any one presentation.
/// AppModel applies the returned mutation through its existing idempotent owner coordinator.
struct ActiveWorkoutRealtimeOwnership {
    private(set) var ownsRealtime = false

    mutating func workoutDidBegin() -> RealtimeOwnerMutation? {
        guard !ownsRealtime else { return nil }
        ownsRealtime = true
        return .acquire(.workout)
    }

    mutating func workoutWillEnd() -> RealtimeOwnerMutation? {
        guard ownsRealtime else { return nil }
        ownsRealtime = false
        return .release(.workout)
    }
}

struct RealtimeCommandSentState {
    private(set) var toggleArmed = false
    private(set) var heavyWhoop4Armed: Bool?
    private(set) var heavyWhoop4ArmedAt: Date?

    func shouldSendToggle(wanted: Bool, forceWanted: Bool = false) -> Bool {
        wanted != toggleArmed || (forceWanted && wanted)
    }

    func shouldSendHeavy(wanted: Bool, forceWanted: Bool = false) -> Bool {
        guard let heavyWhoop4Armed else { return true }
        return wanted != heavyWhoop4Armed || (forceWanted && wanted)
    }

    mutating func recordToggle(wanted: Bool, queued: Bool) {
        guard queued else { return }
        toggleArmed = wanted
    }

    mutating func recordHeavy(wanted: Bool, queued: Bool, at: Date) {
        guard queued else { return }
        heavyWhoop4Armed = wanted
        heavyWhoop4ArmedAt = wanted ? at : nil
    }

    mutating func clearHeavyForOtherFamily() {
        resetHeavyForFamilyTransition()
    }

    mutating func resetHeavyForFamilyTransition() {
        heavyWhoop4Armed = nil
        heavyWhoop4ArmedAt = nil
    }

    mutating func resetForDisconnect() {
        toggleArmed = false
        resetHeavyForFamilyTransition()
    }
}

struct RealtimeCommandWritePlan: Equatable {
    let heavyWhoop4Wanted: Bool?
    let toggleWanted: Bool?

    static let none = RealtimeCommandWritePlan(
        heavyWhoop4Wanted: nil,
        toggleWanted: nil
    )
}

struct RealtimeCommandWritePlanner {
    static func plan(deviceFamily: DeviceFamily,
                     demand: RealtimeDemandOutput,
                     sentState: RealtimeCommandSentState,
                     connected: Bool,
                     bonded: Bool,
                     canSendWriteWithoutResponse: Bool,
                     forceWantedCommands: Bool = false)
        -> RealtimeCommandWritePlan {
        guard connected, canSendWriteWithoutResponse else { return .none }

        let heavyWhoop4Wanted: Bool? = deviceFamily == .whoop4
            && sentState.shouldSendHeavy(
                wanted: demand.heavyWhoop4Wanted,
                forceWanted: forceWantedCommands
            )
            ? demand.heavyWhoop4Wanted
            : nil

        let canSendToggle = deviceFamily == .whoop4 || bonded
        let toggleWanted: Bool? = canSendToggle
            && sentState.shouldSendToggle(
                wanted: demand.toggleWanted,
                forceWanted: forceWantedCommands
            )
            ? demand.toggleWanted
            : nil

        return RealtimeCommandWritePlan(
            heavyWhoop4Wanted: heavyWhoop4Wanted,
            toggleWanted: toggleWanted
        )
    }
}

struct RealtimeDemandOutput: Equatable {
    var toggleWanted: Bool
    var heavyWhoop4Wanted: Bool
}

struct RealtimeDemandPolicy {
    static func effectiveExplicitOwners(
        _ owners: Set<RealtimeDemandOwner>,
        appForeground: Bool
    ) -> Set<RealtimeDemandOwner> {
        guard !appForeground else { return owners }
        return owners.subtracting([.liveScreen])
    }

    static func evaluate(deviceFamily: DeviceFamily,
                         owners: Set<RealtimeDemandOwner>,
                         appForeground: Bool,
                         passiveCaptureWanted: Bool,
                         marginalRadioFallback: Bool)
        -> RealtimeDemandOutput {
        let activeOwners = effectiveExplicitOwners(owners, appForeground: appForeground)

        let explicitDemand = !activeOwners.isEmpty
        let toggleWanted = explicitDemand || passiveCaptureWanted
        let heavyWhoop4Wanted = deviceFamily == .whoop4
            && explicitDemand
            && !marginalRadioFallback

        return RealtimeDemandOutput(
            toggleWanted: toggleWanted,
            heavyWhoop4Wanted: heavyWhoop4Wanted
        )
    }
}
