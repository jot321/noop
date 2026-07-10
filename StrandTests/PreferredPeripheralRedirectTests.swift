import XCTest
@testable import Strand

/// Pins the P1 late-pin reconnect race: a persisted preferred peripheral may arrive after an
/// ordinary reconnect scan already started. The planner is pure so the startup-order edge can be
/// tested without a CoreBluetooth seam.
final class PreferredPeripheralRedirectTests: XCTestCase {
    private let oldPin = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let newPin = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testNewValidUUIDRedirectsOrdinaryAutomaticScanWhenTargetIsRetrievable() {
        let plan = BLEManager.preferredPeripheralRedirectPlan(
                previousPin: oldPin,
                incomingPin: newPin.uuidString,
                isPresentingScan: false,
                hasRestoredPeripheral: false,
                isConnected: false,
                isScanning: true,
                autoReconnectPausedForBondLoop: false,
                retrievedTargetAvailable: true)

        XCTAssertEqual(plan, .redirectToRetrievedPeripheral(newPin))
        XCTAssertTrue(plan.requiresFamilyDetection)
    }

    func testSameNilAndInvalidUUIDDoNotRedirect() {
        for incoming in [oldPin.uuidString, nil, "not-a-uuid"] {
            XCTAssertEqual(
                BLEManager.preferredPeripheralRedirectPlan(
                    previousPin: oldPin,
                    incomingPin: incoming,
                    isPresentingScan: false,
                    hasRestoredPeripheral: false,
                    isConnected: false,
                    isScanning: true,
                    autoReconnectPausedForBondLoop: false,
                    retrievedTargetAvailable: true),
                .noRedirect
            )
        }
    }

    func testPresentationScansDoNotRedirect() {
        XCTAssertEqual(
            BLEManager.preferredPeripheralRedirectPlan(
                previousPin: oldPin,
                incomingPin: newPin.uuidString,
                isPresentingScan: true,
                hasRestoredPeripheral: false,
                isConnected: false,
                isScanning: true,
                autoReconnectPausedForBondLoop: false,
                retrievedTargetAvailable: true),
            .noRedirect
        )
    }

    func testRestorationTakesPrecedenceOverLatePinRedirect() {
        XCTAssertEqual(
            BLEManager.preferredPeripheralRedirectPlan(
                previousPin: oldPin,
                incomingPin: newPin.uuidString,
                isPresentingScan: false,
                hasRestoredPeripheral: true,
                isConnected: false,
                isScanning: true,
                autoReconnectPausedForBondLoop: false,
                retrievedTargetAvailable: true),
            .noRedirect
        )
    }

    func testConnectedAndNonScanningStatesDoNotRedirect() {
        XCTAssertEqual(
            BLEManager.preferredPeripheralRedirectPlan(
                previousPin: oldPin,
                incomingPin: newPin.uuidString,
                isPresentingScan: false,
                hasRestoredPeripheral: false,
                isConnected: true,
                isScanning: true,
                autoReconnectPausedForBondLoop: false,
                retrievedTargetAvailable: true),
            .noRedirect
        )
        XCTAssertEqual(
            BLEManager.preferredPeripheralRedirectPlan(
                previousPin: oldPin,
                incomingPin: newPin.uuidString,
                isPresentingScan: false,
                hasRestoredPeripheral: false,
                isConnected: false,
                isScanning: false,
                autoReconnectPausedForBondLoop: false,
                retrievedTargetAvailable: true),
            .noRedirect
        )
    }

    func testBondLoopPauseDoesNotRedirect() {
        XCTAssertEqual(
            BLEManager.preferredPeripheralRedirectPlan(
                previousPin: oldPin,
                incomingPin: newPin.uuidString,
                isPresentingScan: false,
                hasRestoredPeripheral: false,
                isConnected: false,
                isScanning: true,
                autoReconnectPausedForBondLoop: true,
                retrievedTargetAvailable: true),
            .noRedirect
        )
    }

    func testMissingRetrievedTargetKeepsFilteredScanAndFallbackActive() {
        XCTAssertEqual(
            BLEManager.preferredPeripheralRedirectPlan(
                previousPin: oldPin,
                incomingPin: newPin.uuidString,
                isPresentingScan: false,
                hasRestoredPeripheral: false,
                isConnected: false,
                isScanning: true,
                autoReconnectPausedForBondLoop: false,
                retrievedTargetAvailable: false),
            .keepScanningForPreferred(newPin)
        )
    }

    func testLateRedirectDiscoversBothPrimaryFamiliesBeforeAndAfterFallbackRotation() {
        for selectedModel in [WhoopModel.whoop4, .whoop5mg] {
            XCTAssertEqual(
                WhoopPrimaryServiceDiscoveryPlan.make(
                    selectedModel: selectedModel,
                    detectsFamily: true
                ).primaryModels,
                [.whoop4, .whoop5mg]
            )
        }
    }

    func testNormalConnectionDiscoversOnlySelectedPrimaryFamily() {
        XCTAssertEqual(
            WhoopPrimaryServiceDiscoveryPlan.make(
                selectedModel: .whoop4,
                detectsFamily: false
            ).primaryModels,
            [.whoop4]
        )
        XCTAssertEqual(
            WhoopPrimaryServiceDiscoveryPlan.make(
                selectedModel: .whoop5mg,
                detectsFamily: false
            ).primaryModels,
            [.whoop5mg]
        )
    }

    func testDetectedFamilyComesFromActualPrimaryService() {
        XCTAssertEqual(
            WhoopPrimaryServiceDiscoveryPlan.detectedModel(
                from: [WhoopModel.whoop4.scanService]
            ),
            .whoop4
        )
        XCTAssertEqual(
            WhoopPrimaryServiceDiscoveryPlan.detectedModel(
                from: [WhoopModel.whoop5mg.scanService]
            ),
            .whoop5mg
        )
    }

    func testNoPrimaryServiceDoesNotGuessFamily() {
        XCTAssertNil(
            WhoopPrimaryServiceDiscoveryPlan.detectedModel(
                from: [BLEManager.heartRateService, BLEManager.batteryService]
            )
        )
    }
}
