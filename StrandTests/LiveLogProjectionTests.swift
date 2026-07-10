import XCTest
@testable import Strand

@MainActor
final class LiveLogProjectionTests: XCTestCase {
    func testVisibleLogCapsAtTwoHundredLines() {
        let live = LiveState()

        append(201, to: live)

        XCTAssertEqual(live.visibleLog.count, 200)
        XCTAssertEqual(live.visibleLog.first?.text, "line 2")
        XCTAssertEqual(live.visibleLog.last?.text, "line 201")
    }

    func testVisibleLogIDsIncreaseMonotonically() {
        let live = LiveState()

        append(3, to: live)

        XCTAssertEqual(live.visibleLog.map(\.id), [1, 2, 3])
    }

    func testSourceTrimDoesNotReuseVisibleIDs() {
        let live = LiveState()

        append(LiveState.maxLogLines + 1, to: live)
        let beforeAppend = live.visibleLog
        live.append(log: "line \(LiveState.maxLogLines + 2)")

        XCTAssertEqual(live.log.count, LiveState.maxLogLines)
        XCTAssertEqual(beforeAppend.last?.id, UInt64(LiveState.maxLogLines + 1))
        XCTAssertEqual(live.visibleLog.last?.id, UInt64(LiveState.maxLogLines + 2))
        XCTAssertGreaterThan(live.visibleLog.first!.id, beforeAppend.first!.id)
    }

    func testNewestVisibleLogIDChangesForEveryAppendAfterCaps() {
        let live = LiveState()

        append(LiveState.maxLogLines + 1, to: live)
        let first = live.newestVisibleLogID
        live.append(log: "next after source cap")
        let second = live.newestVisibleLogID
        live.append(log: "another after source cap")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, live.newestVisibleLogID)
    }

    func testExportRetainsLinesOutsideVisibleTail() {
        let live = LiveState()

        append(201, to: live)

        XCTAssertFalse(live.visibleLog.contains(where: { $0.text == "line 1" }))
        XCTAssertTrue(live.exportableLogText().contains("line 1"))
    }

    func testInitialMountScrollTargetUsesCurrentNewestVisibleID() {
        XCTAssertEqual(
            LiveLogScrollTarget.resolve(for: .initialMount, newestVisibleLogID: 42),
            42
        )
    }

    func testVisibleLogChangeScrollTargetUsesChangedNewestVisibleID() {
        XCTAssertEqual(
            LiveLogScrollTarget.resolve(for: .visibleLogChanged, newestVisibleLogID: 43),
            43
        )
    }

    func testScrollTargetIsNilWhenVisibleLogIsEmpty() {
        XCTAssertNil(
            LiveLogScrollTarget.resolve(for: .initialMount, newestVisibleLogID: nil)
        )
    }

    private func append(_ count: Int, to live: LiveState) {
        for number in 1...count {
            live.append(log: "line \(number)")
        }
    }
}
