import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SpO2EngineTests: XCTestCase {

    // MARK: - Seed curve

    func testSeedCurveKnownAnchors() {
        // SpO2 = 110 - 25*R. R = 0.4 -> 100 (clamped from 100), R = 1.0 -> 85, R = 1.2 -> 80.
        XCTAssertEqual(SpO2Engine.spo2(fromR: 0.4), 100.0, accuracy: 1e-9)
        XCTAssertEqual(SpO2Engine.spo2(fromR: 1.0), 85.0, accuracy: 1e-9)
        XCTAssertEqual(SpO2Engine.spo2(fromR: 1.2), 80.0, accuracy: 1e-9)
    }

    func testSeedCurveClampsToPhysiology() {
        // R below 0.4 would exceed 100; clamps at 100. Very high R clamps at floor 70.
        XCTAssertEqual(SpO2Engine.spo2(fromR: 0.0), 100.0, accuracy: 1e-9)
        XCTAssertEqual(SpO2Engine.spo2(fromR: 2.0), 70.0, accuracy: 1e-9)
    }

    // MARK: - Window estimate

    /// Build a synthetic window: DC + a pulsatile square wave of a chosen peak-to-peak AC on each channel.
    private func window( tsStart: Int, count: Int, dcRed: Double, acRed: Double,
                        dcIr: Double, acIr: Double) -> [SpO2Sample] {
        (0..<count).map { i in
            let phase = i % 2 == 0 ? 0.5 : -0.5
            return SpO2Sample(ts: tsStart + i,
                              red: Int((dcRed + phase * acRed).rounded()),
                              ir: Int((dcIr + phase * acIr).rounded()))
        }
    }

    func testEstimateWindowComputesRatioOfRatios() {
        // AC_red/DC_red = 60/1000 = 0.06; AC_ir/DC_ir = 200/2000 = 0.10; R = 0.6 -> SpO2 110-15 = 95.
        let w = window(tsStart: 1000, count: 12, dcRed: 1000, acRed: 60, dcIr: 2000, acIr: 200)
        let p = SpO2Engine.estimateWindow(w[...])
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.r, 0.6, accuracy: 1e-6)
        XCTAssertEqual(p!.spo2, 95.0, accuracy: 1e-6)
        XCTAssertEqual(p!.perfusionIndex, 0.10, accuracy: 1e-6)
    }

    func testEstimateWindowRejectsLowPerfusion() {
        // Flat IR pulse (AC_ir tiny) -> PI below the gate -> nil.
        let w = window(tsStart: 0, count: 12, dcRed: 1000, acRed: 40, dcIr: 2000, acIr: 1)
        XCTAssertNil(SpO2Engine.estimateWindow(w[...]))
    }

    func testEstimateWindowRejectsTooFewSamples() {
        let w = window(tsStart: 0, count: 3, dcRed: 1000, acRed: 40, dcIr: 2000, acIr: 200)
        XCTAssertNil(SpO2Engine.estimateWindow(w[...]))
    }

    // MARK: - Night summary

    func testNightSummaryT90AndMin() {
        // 30 points: 25 at ~97%, 5 at 88% -> min 88, t90 = 5/30, mean between.
        var pts: [SpO2Engine.SpO2Point] = []
        for i in 0..<25 { pts.append(.init(ts: i * 10, spo2: 97, r: 0.52, perfusionIndex: 0.1)) }
        for i in 25..<30 { pts.append(.init(ts: i * 10, spo2: 88, r: 0.88, perfusionIndex: 0.1)) }
        let s = SpO2Engine.nightSummary(points: pts)
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.minPct, 88.0, accuracy: 1e-9)
        XCTAssertEqual(s!.t90Fraction, SpO2Engine.round3(5.0 / 30.0), accuracy: 1e-9)
        XCTAssertEqual(s!.sampleCount, 30)
    }

    func testNightSummaryNeedsCoverage() {
        let pts = (0..<10).map { SpO2Engine.SpO2Point(ts: $0, spo2: 97, r: 0.5, perfusionIndex: 0.1) }
        XCTAssertNil(SpO2Engine.nightSummary(points: pts))
    }

    func testDesaturationCountDetectsDrops() {
        // Baseline 97 with two isolated dips to 92 (>=3% drop) -> 2 events.
        var pts: [SpO2Engine.SpO2Point] = []
        var ts = 0
        for _ in 0..<10 { pts.append(.init(ts: ts, spo2: 97, r: 0.5, perfusionIndex: 0.1)); ts += 5 }
        pts.append(.init(ts: ts, spo2: 92, r: 0.7, perfusionIndex: 0.1)); ts += 5
        for _ in 0..<10 { pts.append(.init(ts: ts, spo2: 97, r: 0.5, perfusionIndex: 0.1)); ts += 5 }
        pts.append(.init(ts: ts, spo2: 92, r: 0.7, perfusionIndex: 0.1)); ts += 5
        for _ in 0..<10 { pts.append(.init(ts: ts, spo2: 97, r: 0.5, perfusionIndex: 0.1)); ts += 5 }
        let n = SpO2Engine.desaturationCount(pts, dropThreshold: 3.0)
        XCTAssertEqual(n, 2)
    }
}
