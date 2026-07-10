import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class PostureEngineTests: XCTestCase {

    func testClassifyAxes() {
        XCTAssertEqual(PostureEngine.classify(.init(ts: 0, x: 0, y: 0, z: 1)), .supine)
        XCTAssertEqual(PostureEngine.classify(.init(ts: 0, x: 0, y: 0, z: -1)), .prone)
        XCTAssertEqual(PostureEngine.classify(.init(ts: 0, x: 1, y: 0, z: 0)), .right)
        XCTAssertEqual(PostureEngine.classify(.init(ts: 0, x: -1, y: 0, z: 0)), .left)
        XCTAssertEqual(PostureEngine.classify(.init(ts: 0, x: 0, y: 1, z: 0)), .upright)
    }

    func testClassifyNearZeroVectorIsUpright() {
        XCTAssertEqual(PostureEngine.classify(.init(ts: 0, x: 0.05, y: 0.05, z: 0.05)), .upright)
    }

    func testAnalyzeDominantAndChanges() {
        // First half supine (z=1), then flip to right side (x=1) for the second half.
        var g: [GravitySample] = []
        var ts = 0
        for _ in 0..<120 { g.append(.init(ts: ts, x: 0, y: 0, z: 1)); ts += 1 }
        for _ in 0..<60 { g.append(.init(ts: ts, x: 1, y: 0, z: 0)); ts += 1 }
        let r = PostureEngine.analyze(gravity: g, sleepStart: 0, sleepEnd: ts)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.dominant, .supine)
        XCTAssertEqual(r!.positionChanges, 1)   // one debounced flip
        // Supine fraction ~ 2/3.
        XCTAssertGreaterThan(PostureEngine.supineFraction(r!), 0.6)
    }

    func testRestlessnessCountsMovingEpochs() {
        // Discrete jerks separated by still stretches -> each jerk is one debounced burst.
        var g: [GravitySample] = []
        var ts = 0
        for burst in 0..<6 {
            // 10 s still supine
            for _ in 0..<10 { g.append(.init(ts: ts, x: 0, y: 0, z: 1)); ts += 1 }
            // one jerk to the right and back (two moving samples), then settle
            g.append(.init(ts: ts, x: 0.7, y: 0, z: 0.7)); ts += 1
            _ = burst
        }
        for _ in 0..<10 { g.append(.init(ts: ts, x: 0, y: 0, z: 1)); ts += 1 }
        let r = PostureEngine.analyze(gravity: g, sleepStart: 0, sleepEnd: ts)
        XCTAssertNotNil(r)
        // 6 discrete jerks -> ~6 bursts (each isolated by a still stretch).
        XCTAssertGreaterThanOrEqual(r!.movementBursts, 5)
        XCTAssertLessThan(r!.restlessFraction, 0.5) // mostly still
    }

    func testRejectsTooFewSamples() {
        let g = (0..<10).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        XCTAssertNil(PostureEngine.analyze(gravity: g, sleepStart: 0, sleepEnd: 100))
    }
}
