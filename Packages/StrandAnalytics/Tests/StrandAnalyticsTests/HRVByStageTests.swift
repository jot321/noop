import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HRVByStageTests: XCTestCase {

    func testStageResolvedGrouping() {
        // Two stage windows: deep [0,300) with steady ~1000ms RR (high RMSSD variation added),
        // light [300,600) with faster, less variable RR.
        var rr: [RRInterval] = []
        var ts = 0
        // deep: alternate 1000/1040 ms (clear successive differences) for 300 s
        while ts < 300 {
            rr.append(.init(ts: ts, rrMs: ts % 2 == 0 ? 1000 : 1040)); ts += 1
        }
        // light: alternate 800/810 ms for 300 s
        while ts < 600 {
            rr.append(.init(ts: ts, rrMs: ts % 2 == 0 ? 800 : 810)); ts += 1
        }
        let stages: [(start: Int, end: Int, stage: String)] = [
            (0, 300, "deep"), (300, 600, "light"),
        ]
        let out = HRVByStage.analyze(rr: rr, stages: stages)
        let deep = out.byStage.first { $0.stage == "deep" }
        let light = out.byStage.first { $0.stage == "light" }
        XCTAssertNotNil(deep)
        XCTAssertNotNil(light)
        // Deep has larger successive differences (40ms vs 10ms) -> larger RMSSD.
        XCTAssertGreaterThan(deep!.rmssd ?? 0, light!.rmssd ?? 0)
        // Mean HR: light (~800ms) faster than deep (~1020ms).
        XCTAssertGreaterThan(light!.meanHR ?? 0, deep!.meanHR ?? 0)
        // Whole-night RMSSD present, rolling curve non-empty.
        XCTAssertNotNil(out.nightRMSSD)
        XCTAssertFalse(out.rollingRMSSD.isEmpty)
    }

    func testEmptyStagesProducesNoStageRows() {
        let rr = (0..<100).map { RRInterval(ts: $0, rrMs: 1000) }
        let out = HRVByStage.analyze(rr: rr, stages: [])
        XCTAssertTrue(out.byStage.isEmpty)
        // Night-level still computed.
        XCTAssertNotNil(out.nightRMSSD)
    }
}
