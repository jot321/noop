import Foundation

// Baselines.swift — personal rolling baselines per nightly metric.
//
// Ported from server/ingest/app/analysis/baselines.py.
//
// Two paths are provided:
//   1. Winsorized EWMA (the production model): robust, recency-weighted center
//      with an EWMA-of-absolute-deviation spread tracker, cold-start gating, hard
//      outlier rejection, and Winsor clamping. This is `update`/`foldHistory`.
//   2. Trailing-window mean/SD (the task's "trailing 30-day mean/SD"): a simple,
//      auditable rolling mean and sample SD over the trailing N valid nights.
//      This is `rollingMeanSD`. Useful for explainability and cross-checking.
//
// Both produce a `BaselineState` so RecoveryScorer can consume either uniformly.

/// Per-metric configuration for the baseline model.
public struct MetricCfg: Equatable, Sendable {
    public let minVal: Double       // physiological lower bound (hard reject below)
    public let maxVal: Double       // physiological upper bound (hard reject above)
    public let floorSpread: Double  // σ_floor: minimum dispersion
    public let halfLifeB: Double    // baseline-center half-life (nights)
    public let halfLifeS: Double    // spread half-life (nights, slower than center)

    public init(minVal: Double, maxVal: Double, floorSpread: Double,
                halfLifeB: Double, halfLifeS: Double) {
        self.minVal = minVal
        self.maxVal = maxVal
        self.floorSpread = floorSpread
        self.halfLifeB = halfLifeB
        self.halfLifeS = halfLifeS
    }
}

/// Baseline status flags (cold-start → trusted → stale).
public enum BaselineStatus: String, Equatable, Sendable {
    case calibrating  // fewer than MIN_NIGHTS_SEED valid nights; no score yet
    case provisional  // between seed and trust thresholds; usable, higher uncertainty
    case trusted      // at least MIN_NIGHTS_TRUST valid nights
    case stale        // usable but no update for > STALE_DAYS nights
}

/// Immutable snapshot of a personal baseline for one metric after N nights.
public struct BaselineState: Equatable, Sendable {
    /// Robust EWMA center (the personal "mean").
    public let baseline: Double
    /// EWMA of absolute deviations, floored at cfg.floorSpread. Multiply by 1.253
    /// to approximate Gaussian σ.
    public let spread: Double
    /// Count of valid nights contributing to the state.
    public let nValid: Int
    /// Consecutive nights with no valid value (staleness tracking).
    public let nightsSinceUpdate: Int
    /// Cold-start / staleness status.
    public let status: BaselineStatus

    public init(baseline: Double, spread: Double, nValid: Int,
                nightsSinceUpdate: Int, status: BaselineStatus) {
        self.baseline = baseline
        self.spread = spread
        self.nValid = nValid
        self.nightsSinceUpdate = nightsSinceUpdate
        self.status = status
    }

    /// True iff fully trusted (not calibrating or stale).
    public var trusted: Bool { status == .trusted }
    /// True iff at least provisionally usable (nValid ≥ MIN_NIGHTS_SEED).
    public var usable: Bool { status == .provisional || status == .trusted }
}

/// Three forms of deviation from a personal baseline.
public struct Deviation: Equatable, Sendable {
    /// Robust z-score: (value − baseline) / (1.253 × spread).
    public let z: Double
    /// Signed physical-units delta: value − baseline.
    public let delta: Double
    /// Fractional deviation: value / baseline − 1.
    public let ratio: Double
    /// True iff |z| ≤ 1.0.
    public let inNormalRange: Bool

    public init(z: Double, delta: Double, ratio: Double, inNormalRange: Bool) {
        self.z = z; self.delta = delta; self.ratio = ratio
        self.inNormalRange = inNormalRange
    }
}

public enum Baselines {

    // MARK: - Constants (baselines.py)

    /// Winsorization clamp: fold only within ±WINSOR_K × spread.
    public static let winsorK: Double = 3.0
    /// Hard-reject gate: drop the night if > HARD_OUTLIER_K × spread away.
    public static let hardOutlierK: Double = 5.0
    /// Minimum valid nights before "provisionally" trusted.
    public static let minNightsSeed: Int = 4
    /// Minimum valid nights before fully trusted.
    public static let minNightsTrust: Int = 14
    /// Missing-night count after which a baseline is marked stale.
    public static let staleDays: Int = 14

    // MARK: - Early-life anti-anchoring (Reddit HRV report)
    //
    // The original model seeds the center on the first valid night with spread pinned at the
    // floor, then becomes "usable" at minNightsSeed. If those first few nights read artificially
    // HIGH (a common cold-start artefact), three things compounded to lock the baseline high for
    // ~2-3 weeks: (a) the seed fixed the mean high while spread sat at the floor; (b) the hard
    // outlier gate then REJECTED the user's genuine LOWER nights (a true 54ms vs an anchored ~85ms
    // baseline is >5× the floor spread → "seen but not folded"); (c) the still-tight spread made
    // the z-score hypersensitive, crushing Charge to 1-2.
    //
    // The fix is conservative and principled: during the baseline's EARLY life let reality pull
    // the center down quickly, THEN settle to the normal long-term smoothing.
    //   - Skip the hard-outlier rejection while the baseline is young (nValid below the threshold)
    //     OR while spread is still at the floor — so legitimate lower nights are never discarded
    //     before the spread has had a chance to widen to reflect them.
    //   - Use a faster effective center half-life for the first few nights so it tracks reality in
    //     days, not weeks, before relaxing back to halfLifeB.
    //   - Widen the effective spread used for Winsor clamping during early life so an honest lower
    //     night isn't clamped flat against a floor-tight band.
    // Long-term behaviour (after earlyAdaptNights, once spread has lifted) is byte-identical to
    // before, so the baseline stays smooth and non-jittery once it has settled.

    /// Valid-night count below which the baseline is treated as "young": fast center adaptation
    /// and a suspended hard-outlier gate. Chosen so convergence happens in days, not weeks.
    public static let earlyAdaptNights: Int = 8
    /// Center half-life (nights) used while the baseline is young — much faster than halfLifeB so a
    /// high seed is pulled toward reality within days.
    public static let earlyHalfLifeB: Double = 3.0
    /// Multiplier on spread for the Winsor clamp while young, so an honest lower night isn't clamped
    /// flat against a floor-tight band before the spread has had a chance to widen.
    public static let earlySpreadInflate: Double = 2.5

    /// UserDefaults key for the manual HRV-baseline recalibration epoch (epoch SECONDS).
    /// 0 / absent = no recalibration. Written by the Settings "Recalibrate HRV baseline" button.
    public static let hrvBaselineEpochKey: String = "noop.hrvBaselineEpoch"

    /// UserDefaults key for the manual RECOVERY-baseline recalibration epoch (epoch SECONDS).
    /// 0 / absent = no recalibration. This is the Charge-wide sibling of `hrvBaselineEpochKey`: HRV is
    /// the dominant Charge driver and re-anchors on its own epoch today, while the resting-HR /
    /// respiration / skin-temp baselines that also feed Charge re-anchor on THIS epoch. The Settings
    /// "Recalibrate Charge baseline" button writes BOTH keys to now (see `recalibrateRecoveryBaselines`)
    /// so the whole Charge build-up restarts cleanly. Same string on iOS UserDefaults + Android prefs.
    public static let recoveryBaselineEpochKey: String = "noop.recoveryBaselineEpoch"

    /// Default per-metric configurations (HRV, resting HR, respiration, skin temp).
    public static let metricCfg: [String: MetricCfg] = [
        "hrv": MetricCfg(minVal: 5.0, maxVal: 250.0, floorSpread: 5.0,
                         halfLifeB: 14.0, halfLifeS: 21.0),
        "resting_hr": MetricCfg(minVal: 30.0, maxVal: 120.0, floorSpread: 2.0,
                                halfLifeB: 14.0, halfLifeS: 21.0),
        "resp": MetricCfg(minVal: 4.0, maxVal: 40.0, floorSpread: 0.5,
                          halfLifeB: 14.0, halfLifeS: 21.0),
        "skin_temp": MetricCfg(minVal: 20.0, maxVal: 42.0, floorSpread: 0.3,
                               halfLifeB: 14.0, halfLifeS: 21.0),
    ]

    /// Convenience accessors for the standard configs.
    public static var hrvCfg: MetricCfg { metricCfg["hrv"]! }
    public static var restingHRCfg: MetricCfg { metricCfg["resting_hr"]! }
    public static var respCfg: MetricCfg { metricCfg["resp"]! }

    /// Convert a half-life in nights to an EWMA smoothing factor.
    static func lambda(halfLife: Double) -> Double {
        1.0 - pow(0.5, 1.0 / halfLife)
    }

    static func computeStatus(nValid: Int, nightsSinceUpdate: Int) -> BaselineStatus {
        if nightsSinceUpdate > staleDays && nValid >= minNightsSeed { return .stale }
        if nValid < minNightsSeed { return .calibrating }
        if nValid < minNightsTrust { return .provisional }
        return .trusted
    }

    // MARK: - Winsorized EWMA update (production model)

    /// Incorporate one new nightly value into the baseline state.
    ///
    /// - `state == nil`: seed the first night.
    /// - `value == nil` or out-of-range: skip-and-hold (carry forward).
    /// - hard outlier (> HARD_OUTLIER_K × spread): seen but not folded.
    /// - otherwise: Winsorized EWMA center + EWMA-abs-dev spread update.
    public static func update(_ state: BaselineState?, value: Double?, cfg: MetricCfg) -> BaselineState {
        let lb = lambda(halfLife: cfg.halfLifeB)
        let ls = lambda(halfLife: cfg.halfLifeS)

        // First night ever.
        guard let state = state else {
            if let v = value, cfg.minVal <= v && v <= cfg.maxVal {
                return BaselineState(baseline: v, spread: cfg.floorSpread, nValid: 1,
                                     nightsSinceUpdate: 0, status: .calibrating)
            }
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                 nightsSinceUpdate: 1, status: .calibrating)
        }

        // Missing night: skip-and-hold.
        guard let value = value else {
            let m = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: m,
                                 status: computeStatus(nValid: state.nValid, nightsSinceUpdate: m))
        }

        // Step 0: sanity gate — physiologically implausible → skip-and-hold.
        if !(cfg.minVal <= value && value <= cfg.maxVal) {
            let m = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: m,
                                 status: computeStatus(nValid: state.nValid, nightsSinceUpdate: m))
        }

        // Is the baseline still "young"? While young we adapt faster and suspend the hard-outlier
        // gate so genuine lower nights are never discarded before the spread reflects them. Tied to
        // the valid-night count (NOT spread): a long flat history is settled even though its spread
        // never lifted off the floor, and must still reject a wild one-off outlier.
        let isYoung = state.nValid < earlyAdaptNights

        // Hard outlier rejection (only once seeded AND no longer young): seen, but not folded.
        // Suspending this during early life is the core anti-anchoring fix — a high seed with a
        // floor-tight spread would otherwise reject the user's real, lower readings as "outliers"
        // (a true 54ms vs an anchored ~90ms baseline is >5× the floor spread).
        if state.nValid >= minNightsSeed && !isYoung {
            let dev = abs(value - state.baseline)
            if dev > hardOutlierK * state.spread {
                return BaselineState(baseline: state.baseline, spread: state.spread,
                                     nValid: state.nValid, nightsSinceUpdate: 0,
                                     status: computeStatus(nValid: state.nValid, nightsSinceUpdate: 0))
            }
        }

        // First real value after a None-placeholder seed: treat as clean first night.
        if state.nValid == 0 {
            return BaselineState(baseline: value, spread: cfg.floorSpread, nValid: 1,
                                 nightsSinceUpdate: 0, status: .calibrating)
        }

        // Step 1: Winsorized EWMA update.
        // While young, widen the clamp band (inflate the effective spread) so an honest lower night
        // isn't clamped flat against a floor-tight band, and use the faster early center half-life so
        // the center tracks reality in days. Both relax to the normal values once settled.
        let effSpread = isYoung ? state.spread * earlySpreadInflate : state.spread
        let effLb = isYoung ? lambda(halfLife: earlyHalfLifeB) : lb
        let lo = state.baseline - winsorK * effSpread
        let hi = state.baseline + winsorK * effSpread
        let clamped = max(lo, min(hi, value))
        let newBaseline = effLb * clamped + (1.0 - effLb) * state.baseline

        // Spread uses the UNCLAMPED value so true deviations are tracked.
        let absDev = abs(value - newBaseline)
        let newSpread = max(cfg.floorSpread, ls * absDev + (1.0 - ls) * state.spread)
        let newN = state.nValid + 1

        return BaselineState(baseline: newBaseline, spread: newSpread, nValid: newN,
                             nightsSinceUpdate: 0,
                             status: computeStatus(nValid: newN, nightsSinceUpdate: 0))
    }

    /// Replay an ordered sequence of nightly values (oldest first) to build state.
    /// `nil` entries are treated as missing nights (skip-and-hold).
    public static func foldHistory(_ values: [Double?], cfg: MetricCfg) -> BaselineState {
        var state: BaselineState? = nil
        for v in values { state = update(state, value: v, cfg: cfg) }
        if let s = state { return s }
        let seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                             nightsSinceUpdate: 0, status: .calibrating)
    }

    /// Read the persisted manual-recalibration epoch (epoch SECONDS) for the HRV baseline.
    /// 0 = no recalibration. The Settings "Recalibrate HRV baseline" button writes now-seconds here.
    public static func hrvBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: hrvBaselineEpochKey)
    }

    /// Read the persisted manual-recalibration epoch (epoch SECONDS) for the wider RECOVERY baseline
    /// (resting HR / respiration / skin temp). 0 = no recalibration. Written alongside the HRV epoch by
    /// `recalibrateRecoveryBaselines`. A fold that wants to honour this passes it through the day-keyed
    /// `foldHistory(_:dayKeys:cfg:baselineEpoch:)` overload exactly like the HRV path.
    public static func recoveryBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: recoveryBaselineEpochKey)
    }

    /// Recalibrate every baseline that feeds Charge: drop the anchor so the ~4-night build-up restarts
    /// from `now`. This is the single source of truth behind the Settings "Recalibrate Charge baseline"
    /// button on all platforms — it writes `now` (epoch SECONDS) to BOTH the HRV epoch and the recovery
    /// epoch, so HRV (the dominant driver, already wired) and the resting-HR / respiration / skin-temp
    /// baselines re-anchor together. It does NOT delete any stored day: only the day from which the
    /// baselines re-learn moves. After this the next baseline computation re-seeds from the first
    /// on-or-after-`now` night, so Today honestly shows the calibrating/building state again.
    /// - Parameters:
    ///   - now: the anchor instant (epoch SECONDS). Defaults to the current time.
    ///   - defaults: the store to write to (overridable for tests).
    public static func recalibrateRecoveryBaselines(now: Double = Date().timeIntervalSince1970,
                                                    defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: hrvBaselineEpochKey)
        defaults.set(now, forKey: recoveryBaselineEpochKey)
    }

    /// Replay an ordered sequence of nightly values (oldest first) to build state, honouring a
    /// manual recalibration `baselineEpoch` (epoch SECONDS; 0 = no recalibration).
    ///
    /// `dayKeys` runs parallel to `values` ("yyyy-MM-dd", same order/length). Any night whose day
    /// STARTS before `baselineEpoch` is ignored entirely (NOT a skip-and-hold — it is dropped, so the
    /// baseline re-seeds from the first on-or-after-epoch night). This lets the user reset a baseline
    /// that anchored too high: tap Recalibrate, and the Charge baseline re-learns from tonight onward.
    ///
    /// When `baselineEpoch <= 0` (the default / no recalibration) this is byte-identical to the plain
    /// `foldHistory(_:cfg:)`. When `baselineEpoch` is nil it is read from UserDefaults via
    /// `hrvBaselineEpoch()` so callers that already use the HRV config get recalibration for free.
    public static func foldHistory(_ values: [Double?], dayKeys: [String], cfg: MetricCfg,
                                   baselineEpoch: Double? = nil) -> BaselineState {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        guard epoch > 0 else { return foldHistory(values, cfg: cfg) }

        // Pre-build the day-start epoch (UTC) for each "yyyy-MM-dd" key once.
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"

        var state: BaselineState? = nil
        for (i, v) in values.enumerated() {
            // Drop (not skip-and-hold) any night dated before the recalibration epoch.
            if i < dayKeys.count, let d = fmt.date(from: dayKeys[i]),
               d.timeIntervalSince1970 < epoch {
                continue
            }
            state = update(state, value: v, cfg: cfg)
        }
        if let s = state { return s }
        let seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                             nightsSinceUpdate: 0, status: .calibrating)
    }

    /// The baseline going into `day` ("yyyy-MM-dd") from the nights strictly BEFORE it. A night is
    /// scored against what was known going into it, never against its own value or later nights, so a
    /// past score doesn't shift as new nights arrive and the first nights stay calibrating. (Audit A1.)
    ///
    /// `dayKeys` (parallel to `values`) may skip days: the fold runs over the CALENDAR, so a day with no
    /// key counts as a missing night exactly like a nil value. Folding only the keyed days hid gaps:
    /// after three months off the wrist the state stayed "provisional" instead of `.stale`. (Audit I4.)
    public static func foldHistory(_ values: [Double?], dayKeys: [String], before day: String,
                                   cfg: MetricCfg, baselineEpoch: Double? = nil) -> BaselineState {
        var byDay: [String: Double] = [:]
        for (i, v) in values.enumerated() where i < dayKeys.count {
            if let v { byDay[dayKeys[i]] = v } else { byDay[dayKeys[i]] = nil }
        }
        return foldCalendar(values: byDay, before: day, cfg: cfg, baselineEpoch: baselineEpoch)
    }

    // MARK: - Calendar fold (audit I4 / P3, 2026-10-21)

    /// The baseline going into `day` ("yyyy-MM-dd") from per-day nightly values, folded over a dense
    /// calendar: every day between the first value and the day before `day` is a night, and a day with
    /// no value is a missing night (skip-and-hold, counted toward `.stale`). Honours the recalibration
    /// epoch like `foldHistory(_:dayKeys:cfg:baselineEpoch:)` (nil reads the HRV epoch from defaults).
    /// The engine scores Charge with this, and the Today breakdown calls it so its drivers match.
    public static func foldCalendar(values: [String: Double], before day: String, cfg: MetricCfg,
                                    baselineEpoch: Double? = nil) -> BaselineState {
        CalendarFold(values: values, cfg: cfg, baselineEpoch: baselineEpoch).state(before: day)
    }

    /// One pass over a metric's whole history that then answers "the baseline going into day D" for
    /// any D. Re-folding the history for every scored night was O(nights × history) on the main actor;
    /// this folds once and replays only the missing nights after the last value before D. The answer is
    /// `foldCalendar`'s exactly (it IS `foldCalendar`'s implementation). (Audit P3.)
    public struct CalendarFold: Sendable {
        private let cfg: MetricCfg
        /// Day indices that carry a value (after the epoch cut), ascending.
        private let indices: [Int]
        /// The state after folding through `indices[i]`, missing days before it included.
        private let after: [BaselineState]

        public init(values: [String: Double], cfg: MetricCfg, baselineEpoch: Double? = nil) {
            let epoch = baselineEpoch ?? Baselines.hrvBaselineEpoch()
            var byIndex: [Int: Double] = [:]
            for (key, v) in values {
                guard let i = Baselines.dayIndex(key) else { continue }
                // Same cut as the day-keyed fold: drop (not hold) nights whose UTC day starts before it.
                if epoch > 0 && Double(i) * 86_400 < epoch { continue }
                byIndex[i] = v
            }
            let sorted = byIndex.keys.sorted()
            var states: [BaselineState] = []
            states.reserveCapacity(sorted.count)
            var state: BaselineState? = nil
            var prev: Int? = nil
            for i in sorted {
                if let p = prev, i - p > 1 {
                    for _ in (p + 1)..<i { state = Baselines.update(state, value: nil, cfg: cfg) }
                }
                state = Baselines.update(state, value: byIndex[i], cfg: cfg)
                states.append(state!)
                prev = i
            }
            self.cfg = cfg
            self.indices = sorted
            self.after = states
        }

        /// The baseline going into `day`, from the nights strictly before it.
        public func state(before day: String) -> BaselineState {
            guard let d = Baselines.dayIndex(day) else { return Baselines.emptyState(cfg) }
            var lo = 0, hi = indices.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if indices[mid] < d { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return Baselines.emptyState(cfg) }
            var s = after[lo - 1]
            let missing = d - 1 - indices[lo - 1]
            if missing > 0 {
                for _ in 0..<missing { s = Baselines.update(s, value: nil, cfg: cfg) }
            }
            return s
        }
    }

    /// The no-history state every fold returns when nothing was folded.
    static func emptyState(_ cfg: MetricCfg) -> BaselineState {
        BaselineState(baseline: (cfg.minVal + cfg.maxVal) / 2.0, spread: cfg.floorSpread, nValid: 0,
                      nightsSinceUpdate: 0, status: .calibrating)
    }

    /// Days since 1970-01-01 for a "yyyy-MM-dd" key, or nil when it isn't a real date. Integer civil
    /// calendar arithmetic (no DateFormatter, no time zone), so it is fast and agrees with UTC day keys.
    public static func dayIndex(_ key: String) -> Int? {
        let b = Array(key.utf8)
        guard b.count == 10, b[4] == 45, b[7] == 45 else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r { let c = Int(b[i]) - 48; guard (0...9).contains(c) else { return nil }; n = n * 10 + c }
            return n
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10),
              (1...12).contains(m), d >= 1 else { return nil }
        // Reject days past the month's end (2026-02-30).
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let monthDays = m == 2 ? (leap ? 29 : 28) : ([4, 6, 9, 11].contains(m) ? 30 : 31)
        guard d <= monthDays else { return nil }
        return daysFromCivil(y, m, d)
    }

    /// The "yyyy-MM-dd" key for a day index (inverse of `dayIndex`).
    public static func dayKey(fromIndex z: Int) -> String {
        let zz = z + 719_468
        let era = (zz >= 0 ? zz : zz - 146_096) / 146_097
        let doe = zz - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Howard Hinnant's days-from-civil (proleptic Gregorian), day 0 = 1970-01-01.
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    // MARK: - Deviation

    /// Compute z / delta / ratio / in-normal-range for a value vs a baseline.
    /// z uses (value − baseline) / (1.253 × spread); 1.253 converts EWMA-abs-dev
    /// to an approximate Gaussian σ (E[|X−μ|] = σ·√(2/π) ≈ σ/1.253).
    public static func deviation(_ value: Double, state: BaselineState) -> Deviation {
        let sigma = max(1.253 * state.spread, 1e-9)
        let z = (value - state.baseline) / sigma
        let delta = value - state.baseline
        let ratio = state.baseline != 0 ? (value / state.baseline - 1.0) : 0.0
        return Deviation(z: z, delta: delta, ratio: ratio, inNormalRange: abs(z) <= 1.0)
    }

    // MARK: - Trailing-window mean/SD (simple, auditable)

    /// Rolling personal baseline from the trailing `window` valid nights, as a
    /// plain mean and sample SD (ddof=1). This is the task's "trailing 30-day
    /// mean/SD" path: no recency weighting, maximally explainable.
    ///
    /// Physiologically implausible values (outside cfg bounds) and nils are
    /// dropped. The spread returned is stored in the SAME internal units the
    /// Winsor EWMA uses (abs-dev space), i.e. SD / 1.253, so that
    /// `deviation()` recovers the intended Gaussian σ unchanged.
    ///
    /// - Parameters:
    ///   - values: ordered nightly values (oldest → newest); nils allowed.
    ///   - cfg: metric config (bounds + floor spread).
    ///   - window: number of trailing valid nights to use (default 30).
    public static func rollingMeanSD(_ values: [Double?], cfg: MetricCfg, window: Int = 30) -> BaselineState {
        let valid = values.compactMap { v -> Double? in
            guard let v = v, cfg.minVal <= v && v <= cfg.maxVal else { return nil }
            return v
        }
        guard !valid.isEmpty else {
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                 nightsSinceUpdate: 0, status: .calibrating)
        }
        let trailing = valid.suffix(window)
        let n = trailing.count
        let mean = trailing.reduce(0, +) / Double(n)

        let sd: Double
        if n >= 2 {
            var ss = 0.0
            for v in trailing { let d = v - mean; ss += d * d }
            sd = (ss / Double(n - 1)).squareRoot()
        } else {
            // Single sample: no dispersion estimate; fall back to the σ floor.
            sd = cfg.floorSpread * 1.253
        }

        // Apply the σ floor in σ-space, then convert to internal abs-dev space.
        let sigmaFloored = max(cfg.floorSpread, sd)
        let spreadInternal = sigmaFloored / 1.253

        return BaselineState(baseline: mean, spread: spreadInternal, nValid: n,
                             nightsSinceUpdate: 0,
                             status: computeStatus(nValid: n, nightsSinceUpdate: 0))
    }
}
