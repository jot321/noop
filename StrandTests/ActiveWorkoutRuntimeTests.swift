import XCTest
import WhoopProtocol
@testable import Strand

final class ActiveWorkoutRuntimeTests: XCTestCase {

    private func sample(_ ts: Int, _ bpm: Int) -> HRSample {
        HRSample(ts: ts, bpm: bpm)
    }

    func testAcceptsAtMostOneSamplePerUnixSecondAndMaintainsO1Stats() {
        var runtime = ActiveWorkoutRuntime()

        let first = runtime.accept(sample(1_800_000_000, 120))
        let duplicateSecond = runtime.accept(sample(1_800_000_000, 150))
        let nextSecond = runtime.accept(sample(1_800_000_001, 150))

        XCTAssertNotNil(first)
        XCTAssertNil(duplicateSecond)
        XCTAssertNotNil(nextSecond)
        XCTAssertEqual(runtime.sampleCount, 2)
        XCTAssertEqual(runtime.bpmSum, 270)
        XCTAssertEqual(runtime.roundedAverageBpm, 135)
        XCTAssertEqual(runtime.peakBpm, 150)
    }

    func testRestoredSamplesSeedSameValuesAsFreshRun() {
        let restoredSamples = [
            sample(1_800_000_000, 118),
            sample(1_800_000_001, 142),
            sample(1_800_000_002, 136),
        ]
        var fresh = ActiveWorkoutRuntime()
        for s in restoredSamples { _ = fresh.accept(s) }

        let restored = ActiveWorkoutRuntime(restoredSamples: restoredSamples)

        XCTAssertEqual(restored.sampleCount, fresh.sampleCount)
        XCTAssertEqual(restored.bpmSum, fresh.bpmSum)
        XCTAssertEqual(restored.roundedAverageBpm, fresh.roundedAverageBpm)
        XCTAssertEqual(restored.peakBpm, fresh.peakBpm)
    }

    func testRequestsStrainImmediatelyAndAtMostEveryTenSeconds() {
        var runtime = ActiveWorkoutRuntime()

        XCTAssertEqual(runtime.accept(sample(1_800_000_000, 120))?.requestsStrain, true)
        XCTAssertEqual(runtime.accept(sample(1_800_000_005, 122))?.requestsStrain, false)
        XCTAssertEqual(runtime.accept(sample(1_800_000_009, 123))?.requestsStrain, false)
        XCTAssertEqual(runtime.accept(sample(1_800_000_010, 124))?.requestsStrain, true)
        XCTAssertEqual(runtime.accept(sample(1_800_000_019, 125))?.requestsStrain, false)
        XCTAssertEqual(runtime.accept(sample(1_800_000_020, 126))?.requestsStrain, true)
    }

    func testForcesFinalStrainAtWorkoutEnd() {
        var runtime = ActiveWorkoutRuntime()
        _ = runtime.accept(sample(1_800_000_000, 120))
        _ = runtime.accept(sample(1_800_000_001, 122))
        _ = runtime.accept(sample(1_800_000_002, 124))

        XCTAssertTrue(runtime.requestsFinalStrain())
    }
}
