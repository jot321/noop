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

struct RealtimeCommandSentState {
    private(set) var toggleArmed = false
    private(set) var heavyWhoop4Armed = false
    private(set) var heavyWhoop4ArmedAt: Date?

    func shouldSendToggle(wanted: Bool, forceWanted: Bool = false) -> Bool {
        wanted != toggleArmed || (forceWanted && wanted)
    }

    func shouldSendHeavy(wanted: Bool, forceWanted: Bool = false) -> Bool {
        wanted != heavyWhoop4Armed || (forceWanted && wanted)
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
        heavyWhoop4Armed = false
        heavyWhoop4ArmedAt = nil
    }

    mutating func resetForDisconnect() {
        toggleArmed = false
        heavyWhoop4Armed = false
        heavyWhoop4ArmedAt = nil
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
    static func evaluate(deviceFamily: DeviceFamily,
                         owners: Set<RealtimeDemandOwner>,
                         appForeground: Bool,
                         passiveCaptureWanted: Bool,
                         marginalRadioFallback: Bool)
        -> RealtimeDemandOutput {
        var activeOwners = owners
        if !appForeground {
            activeOwners.remove(.liveScreen)
        }

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
