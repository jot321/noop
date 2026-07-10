import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class ApneaScreenerTests: XCTestCase {

    func testMicroarousalCountDetectsSurges() {
        // Steady 1000 ms R-R for 90 s (baseline), then a single abrupt drop to 800 ms (20% shorter).
        var rr: [RRInterval] = []
        var ts = 0
        for _ in 0..<90 { rr.append(.init(ts: ts, rrMs: 1000)); ts += 1 }
        rr.append(.init(ts: ts, rrMs: 800))
        let n = ApneaScreener.microarousalCount(rr: rr)
        XCTAssertEqual(n, 1)
    }

    func testMicroarousalRefractoryCollapsesCluster() {
        // Three drops within the refractory window collapse to one event.
        var rr: [RRInterval] = []
        var ts = 0
        for _ in 0..<90 { rr.append(.init(ts: ts, rrMs: 1000)); ts += 1 }
        rr.append(.init(ts: ts, rrMs: 800)); ts += 3
        rr.append(.init(ts: ts, rrMs: 800)); ts += 3
        rr.append(.init(ts: ts, rrMs: 800))
        XCTAssertEqual(ApneaScreener.microarousalCount(rr: rr), 1)
    }

    func testMovementBurstCount() {
        // Still gravity, then one large jerk.
        var g: [GravitySample] = []
        var ts = 0
        for _ in 0..<60 { g.append(.init(ts: ts, x: 0, y: 0, z: 1)); ts += 1 }
        g.append(.init(ts: ts, x: 0.5, y: 0, z: 0.86)) // |Δ| ~0.52 >> threshold
        XCTAssertEqual(ApneaScreener.movementBurstCount(gravity: g), 1)
    }

    func testScreenBandsFromODI() {
        // A high-ODI night lands in a higher band and suggests screening.
        let night = SpO2Engine.NightSummary(meanPct: 92, medianPct: 93, minPct: 82,
                                            t90Fraction: 0.2, odi: 25, sampleCount: 100)
        let r = ApneaScreener.screen(nightSpO2: night, rr: [], gravity: [], sleepSpanSec: 8 * 3600)
        // estimatedAHI = 0.7*25 = 17.5 -> moderate, and >= screenAtAHI(15).
        XCTAssertEqual(r.estimatedAHI, 17.5, accuracy: 1e-9)
        XCTAssertEqual(r.band, .moderate)
        XCTAssertTrue(r.suggestScreening)
    }

    func testScreenNormalNight() {
        let night = SpO2Engine.NightSummary(meanPct: 97, medianPct: 97, minPct: 95,
                                            t90Fraction: 0.0, odi: 2, sampleCount: 100)
        let r = ApneaScreener.screen(nightSpO2: night, rr: [], gravity: [], sleepSpanSec: 8 * 3600)
        XCTAssertEqual(r.band, .normal)
        XCTAssertFalse(r.suggestScreening)
    }
}
