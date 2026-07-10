import Foundation
import WhoopProtocol

struct ActiveWorkoutRuntime {
    struct AcceptedSample: Equatable {
        let sample: HRSample
        let requestsStrain: Bool
    }

    private(set) var sampleCount: Int = 0
    private(set) var bpmSum: Int = 0
    private(set) var peakBpm: Int = 0
    private(set) var lastSampleSecond: Int?
    private(set) var lastStrainAt: Int?

    var roundedAverageBpm: Int {
        guard sampleCount > 0 else { return 0 }
        return Int((Double(bpmSum) / Double(sampleCount)).rounded())
    }

    init(restoredSamples: [HRSample] = []) {
        for sample in restoredSamples {
            seed(sample)
        }
    }

    mutating func accept(_ sample: HRSample) -> AcceptedSample? {
        guard sample.ts > 0, (1...300).contains(sample.bpm) else { return nil }
        if lastSampleSecond == sample.ts { return nil }
        sampleCount += 1
        bpmSum += sample.bpm
        peakBpm = max(peakBpm, sample.bpm)
        lastSampleSecond = sample.ts
        let shouldRequestStrain: Bool
        if let lastStrainAt {
            shouldRequestStrain = sample.ts - lastStrainAt >= 10
        } else {
            shouldRequestStrain = true
        }
        if shouldRequestStrain {
            lastStrainAt = sample.ts
        }
        return AcceptedSample(sample: sample, requestsStrain: shouldRequestStrain)
    }

    func requestsFinalStrain() -> Bool {
        sampleCount >= 2
    }

    private mutating func seed(_ sample: HRSample) {
        guard sample.ts > 0, (1...300).contains(sample.bpm) else { return }
        if lastSampleSecond == sample.ts { return }
        sampleCount += 1
        bpmSum += sample.bpm
        peakBpm = max(peakBpm, sample.bpm)
        lastSampleSecond = sample.ts
    }
}
