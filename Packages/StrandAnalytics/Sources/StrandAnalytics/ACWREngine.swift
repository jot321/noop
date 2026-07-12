import Foundation

/// Acute-to-Chronic Workload Ratio (ACWR) over the daily Effort (strain) series — the ratio of a short
/// "acute" load window to a longer "chronic" one, the standard training-load-monitoring signal for how
/// fast load is ramping. Turns Effort *history* into forward-looking guidance: a ratio well above the
/// chronic base means load is spiking faster than the body has adapted to (injury/overreach risk rises
/// ~2–4× the following week when ACWR exceeds ~1.5 in the literature), while a low ratio reads as
/// detraining. A ratio near 1 is business-as-usual.
///
/// Method (the widely-cited "rolling-average" ACWR): acute = mean daily Effort over the trailing
/// `acuteDays` (7), chronic = mean daily Effort over the trailing `chronicDays` (28), ACWR =
/// acute / chronic. Rest days count as 0 Effort (they legitimately lower the mean), so the caller
/// passes a dense day-indexed series with missing days already zero-filled — see `ratio(fromDaily:)`.
///
/// APPROXIMATE / non-clinical, like every derived metric in this package. Pure/deterministic.
public enum ACWREngine {

    /// Trailing days in the acute (short) window.
    public static let acuteDays = 7
    /// Trailing days in the chronic (long) window.
    public static let chronicDays = 28
    /// Minimum chronic-window days with data before a ratio is trustworthy — below this the chronic base
    /// is too thin to divide by, so the ratio would swing wildly. ~2 weeks of history.
    public static let minChronicDays = 14

    /// Guidance band for a ratio. Cut points follow the common "acute:chronic workload ratio" sweet-spot
    /// convention (~0.8–1.3 balanced; a ratio > ~1.5 is the high-risk ramp). Screening language only.
    public enum Band: String, Equatable, Sendable {
        case detraining   // < 0.8 — load has dropped well below the chronic base
        case balanced     // 0.8 … 1.3 — the "sweet spot"
        case building     // 1.3 … 1.5 — ramping, still productive but watch the trend
        case ramping      // > 1.5 — spiking faster than adaptation; elevated risk

        public static func classify(_ ratio: Double) -> Band {
            switch ratio {
            case ..<0.8:      return .detraining
            case 0.8..<1.3:   return .balanced
            case 1.3..<1.5:   return .building
            default:          return .ramping
            }
        }
    }

    public struct Result: Equatable, Sendable {
        /// Mean daily Effort over the trailing acute window.
        public let acute: Double
        /// Mean daily Effort over the trailing chronic window.
        public let chronic: Double
        /// acute / chronic. The headline.
        public let ratio: Double
        /// The band the ratio falls in.
        public let band: Band
        /// Chronic-window days that actually carried a value (the confidence denominator).
        public let chronicCount: Int
        public init(acute: Double, chronic: Double, ratio: Double, band: Band, chronicCount: Int) {
            self.acute = acute; self.chronic = chronic; self.ratio = ratio
            self.band = band; self.chronicCount = chronicCount
        }
    }

    /// Compute ACWR from an ordered, DENSE daily-Effort series (oldest → newest, one entry per calendar
    /// day; a rest day is 0, NOT omitted — the caller zero-fills gaps so the means are over calendar time,
    /// not over active days only). Uses the trailing `acuteDays` / `chronicDays` ending at the last entry.
    ///
    /// Returns nil when there isn't enough chronic history (< `minChronicDays` non-nil days) or the
    /// chronic mean is ~0 (no load to divide by — a ratio would be meaningless).
    public static func ratio(fromDaily daily: [Double?]) -> Result? {
        guard !daily.isEmpty else { return nil }

        let acuteSlice = daily.suffix(acuteDays)
        let chronicSlice = daily.suffix(chronicDays)

        let acuteVals = acuteSlice.compactMap { $0 }
        let chronicVals = chronicSlice.compactMap { $0 }
        guard chronicVals.count >= minChronicDays else { return nil }

        // Means are over the WINDOW LENGTH (calendar days), so absent days read as 0 load and correctly
        // pull the mean down — using count-of-present-days would erase rest days from the chronic base.
        let acuteMean = acuteVals.reduce(0, +) / Double(acuteSlice.count)
        let chronicMean = chronicVals.reduce(0, +) / Double(chronicSlice.count)
        guard chronicMean > 0.01 else { return nil }

        let r = acuteMean / chronicMean
        return Result(acute: acuteMean, chronic: chronicMean, ratio: r,
                      band: Band.classify(r), chronicCount: chronicVals.count)
    }

    /// Convenience: build the dense daily series from (day-string, Effort) pairs spanning the window and
    /// compute the ratio ending at `endDay`. Days in [endDay − chronicDays + 1, endDay] with no pair are
    /// zero-filled (rest days). `dayOffset` maps a "yyyy-MM-dd" to an integer day index for alignment.
    public static func ratio(points: [(day: String, value: Double)], endDay: String,
                             dayIndex: (String) -> Int?) -> Result? {
        guard let end = dayIndex(endDay) else { return nil }
        let start = end - chronicDays + 1
        var byIndex: [Int: Double] = [:]
        for p in points {
            guard let i = dayIndex(p.day), i >= start, i <= end else { continue }
            // If several rows share a day (shouldn't for a daily series), keep the max — the day's load.
            byIndex[i] = Swift.max(byIndex[i] ?? 0, p.value)
        }
        // Dense oldest→newest series over the chronic window; absent days are rest (0), present days
        // carry their value. Everything in-window is non-nil here, so `minChronicDays` gates on how many
        // days actually had a logged Effort value (not zero-fill) — track that separately.
        var dense: [Double?] = []
        var present = 0
        for i in start...end {
            if let v = byIndex[i] { dense.append(v); present += 1 }
            else { dense.append(0) }
        }
        guard present >= minChronicDays else { return nil }
        return ratio(fromDaily: dense)
    }
}
