import XCTest
@testable import Strand

/// Pins the 5/MG live-HR persistence source switch: REALTIME_DATA is stored only while 0x2A37 is
/// silent, so a strap that never notifies 0x2A37 still records live HR, and one that does is not
/// stored twice.
final class Whoop5LiveHRPersistenceTests: XCTestCase {

    private func puffinFrame(type: UInt8) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 24)
        frame[Whoop5LiveHRPersistence.typeIndex] = type
        return frame
    }

    func testOnlyRealtimeDataFramesQualify() {
        XCTAssertTrue(Whoop5LiveHRPersistence.isRealtimeDataFrame(puffinFrame(type: 40)))
        for type: UInt8 in [43, 47, 48, 49, 50, 56] {   // raw flood and offload types
            XCTAssertFalse(Whoop5LiveHRPersistence.isRealtimeDataFrame(puffinFrame(type: type)))
        }
        XCTAssertFalse(Whoop5LiveHRPersistence.isRealtimeDataFrame([0xAA, 0x01, 0x02]))
    }

    func testStrapThatNeverNotifiesStandardHRPersistsRealtime() {
        XCTAssertTrue(Whoop5LiveHRPersistence.persistRealtimeFrames(lastStandardHRAt: nil, now: Date()))
    }

    func testFlowingStandardHRSuppressesRealtimePersistence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(Whoop5LiveHRPersistence.persistRealtimeFrames(
            lastStandardHRAt: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(Whoop5LiveHRPersistence.persistRealtimeFrames(
            lastStandardHRAt: now.addingTimeInterval(-Whoop5LiveHRPersistence.standardHRSilenceSeconds),
            now: now))
    }

    func testStandardHRGoingSilentHandsPersistenceToRealtime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(Whoop5LiveHRPersistence.persistRealtimeFrames(
            lastStandardHRAt: now.addingTimeInterval(-Whoop5LiveHRPersistence.standardHRSilenceSeconds - 1),
            now: now))
    }
}
