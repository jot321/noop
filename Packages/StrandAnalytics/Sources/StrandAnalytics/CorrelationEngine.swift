import Foundation

// CorrelationEngine.swift — relationships between two daily series.
//
// Pure, deterministic, DB-free. Computes the Pearson product-moment correlation r,
// a simple ordinary-least-squares regression line (slope/intercept of y on x), and
// an approximate two-sided p-value for r.
//
//   r = Σ(x−x̄)(y−ȳ) / sqrt( Σ(x−x̄)² · Σ(y−ȳ)² )         (Pearson)
//   slope     = Σ(x−x̄)(y−ȳ) / Σ(x−x̄)²                     (OLS, y on x)
//   intercept = ȳ − slope·x̄
//
// The p-value uses the standard t-statistic for a correlation,
//   t = r · sqrt( (n−2) / (1−r²) ),
// converted to a two-sided tail probability with the Student-t distribution on n−2
// degrees of freedom, P(|T| ≥ |t|) = I_{ν/(ν+t²)}(ν/2, ½) (regularized incomplete beta,
// continued fraction). The earlier normal tail understated p badly at small n (five
// pairs at r ≈ 0.77: 0.034 instead of 0.124), so Insights printed "p < 0.05" on a few
// days of data. Callers that make a significance claim also need
// `minPairsForSignificance` pairs; `Correlation.significant` checks both. (Audit I10.)
//
// `alignByDay` inner-joins two "yyyy-MM-dd"-keyed series on the day key, returning
// (x, y) pairs sorted by day. `lagged` shifts y forward by `lagDays` relative to x
// (x on day D paired with y on day D+lag) and correlates the result, which lets a
// caller probe directional / delayed effects (e.g. today's strain vs tomorrow's
// recovery).

/// The result of correlating two aligned series.
public struct Correlation: Equatable, Sendable {
    /// Pearson correlation coefficient in [-1, 1].
    public let r: Double
    /// Number of paired observations used.
    public let n: Int
    /// Two-sided p-value for H0: r = 0 (Student-t on n − 2 degrees of freedom).
    public let pApprox: Double
    /// OLS slope of y on x.
    public let slope: Double
    /// OLS intercept of y on x.
    public let intercept: Double

    public init(r: Double, n: Int, pApprox: Double, slope: Double, intercept: Double) {
        self.r = r
        self.n = n
        self.pApprox = pApprox
        self.slope = slope
        self.intercept = intercept
    }

    /// True only with enough pairs AND p < 0.05. A correlation over a handful of days can clear 0.05 by
    /// luck, so a "p < 0.05" label needs `CorrelationEngine.minPairsForSignificance` pairs too.
    public var significant: Bool {
        n >= CorrelationEngine.minPairsForSignificance && pApprox < 0.05
    }
}

public enum CorrelationEngine {

    /// Pairs below which a correlation is shown as a description only, never as significant. r can
    /// still be computed from 3 pairs; claiming significance on fewer than ~10 days is not honest.
    public static let minPairsForSignificance = 10

    // MARK: - Pearson + regression

    /// Pearson r plus an OLS regression line and approximate p-value for the pairs.
    /// Returns nil when fewer than 3 pairs, or when either variable has zero
    /// variance (r undefined).
    public static func pearson(_ xy: [(Double, Double)]) -> Correlation? {
        let n = xy.count
        guard n >= 3 else { return nil }
        let nD = Double(n)

        var sumX = 0.0, sumY = 0.0
        for p in xy { sumX += p.0; sumY += p.1 }
        let meanX = sumX / nD
        let meanY = sumY / nD

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in xy {
            let dx = p.0 - meanX
            let dy = p.1 - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }

        // Zero variance in either variable → correlation undefined.
        guard sxx > 0 && syy > 0 else { return nil }

        var r = sxy / (sxx.squareRoot() * syy.squareRoot())
        // Clamp tiny floating-point overshoot so |r| ≤ 1 exactly.
        if r > 1.0 { r = 1.0 }
        if r < -1.0 { r = -1.0 }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let p = pValue(r: r, n: n)

        return Correlation(r: r, n: n, pApprox: p, slope: slope, intercept: intercept)
    }

    // MARK: - Day alignment

    /// Inner-join two "yyyy-MM-dd"-keyed series on the day key, returning the (x, y)
    /// value pairs for days present in BOTH, sorted ascending by day. Later entries
    /// for a duplicated day in either series win (last-write).
    public static func alignByDay(_ a: [(day: String, value: Double)],
                                  _ b: [(day: String, value: Double)]) -> [(Double, Double)] {
        var mapA: [String: Double] = [:]
        for row in a { mapA[row.day] = row.value }
        var mapB: [String: Double] = [:]
        for row in b { mapB[row.day] = row.value }

        let commonDays = mapA.keys.filter { mapB[$0] != nil }.sorted()
        return commonDays.map { (mapA[$0]!, mapB[$0]!) }
    }

    // MARK: - Lagged correlation

    /// Correlate x[day] against y[day + lagDays]. A positive lag asks "does x today
    /// predict y `lagDays` later?"; a negative lag looks backward. Days are matched
    /// on the calendar by offsetting x's day key by `lagDays` and joining to y.
    ///
    /// Returns nil when fewer than 3 lag-matched pairs survive or when `pearson`
    /// rejects them (zero variance).
    public static func lagged(x: [(day: String, value: Double)],
                              y: [(day: String, value: Double)],
                              lagDays: Int) -> Correlation? {
        var mapY: [String: Double] = [:]
        for row in y { mapY[row.day] = row.value }

        var pairs: [(Double, Double)] = []
        // Sort x by day for deterministic ordering of the pair list.
        let sortedX = x.sorted { $0.day < $1.day }
        for row in sortedX {
            guard let shifted = shiftDay(row.day, by: lagDays) else { continue }
            if let yv = mapY[shifted] {
                pairs.append((row.value, yv))
            }
        }
        return pearson(pairs)
    }

    // MARK: - p-value

    /// Two-sided p-value for H0: r = 0 via t = r·sqrt((n−2)/(1−r²)) and the Student-t tail on
    /// n − 2 degrees of freedom. n ≤ 2 → 1.0 (no evidence); |r| = 1 → 0.0.
    static func pValue(r: Double, n: Int) -> Double {
        guard n > 2 else { return 1.0 }
        let oneMinusR2 = 1.0 - r * r
        if oneMinusR2 <= 0 { return 0.0 }  // |r| == 1
        let t = r * (Double(n - 2) / oneMinusR2).squareRoot()
        return studentTTwoSided(t: t, df: Double(n - 2))
    }

    /// P(|T| ≥ |t|) for Student's t with `df` degrees of freedom: I_{df/(df+t²)}(df/2, 1/2).
    static func studentTTwoSided(t: Double, df: Double) -> Double {
        guard df > 0 else { return 1.0 }
        guard t.isFinite else { return 0.0 }
        let x = df / (df + t * t)
        return min(1.0, max(0.0, regularizedIncompleteBeta(x: x, a: df / 2, b: 0.5)))
    }

    /// The regularized incomplete beta I_x(a, b), by the Numerical Recipes continued fraction (modified
    /// Lentz), using I_x(a,b) = 1 − I_{1−x}(b,a) on the side where the fraction converges slowly.
    static func regularizedIncompleteBeta(x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x))
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(x: x, a: a, b: b) / a
        }
        return 1 - front * betaContinuedFraction(x: 1 - x, a: b, b: a) / b
    }

    private static func betaContinuedFraction(x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300, eps = 1e-15
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1...500 {
            let md = Double(m), m2 = 2 * md
            var aa = md * (b - md) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + md) * (qab + md) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < eps { break }
        }
        return h
    }

    /// Standard-normal CDF Φ(z) using the A&S 7.1.26 erf approximation.
    static func normalCDF(_ z: Double) -> Double {
        0.5 * (1.0 + erfApprox(z / 2.0.squareRoot()))
    }

    /// erf(x) — Abramowitz & Stegun 7.1.26, |error| ≤ 1.5e-7.
    static func erfApprox(_ x: Double) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let ax = abs(x)
        let t = 1.0 / (1.0 + 0.3275911 * ax)
        let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
                        - 0.284496736) * t + 0.254829592) * t * exp(-ax * ax)
        return sign * y
    }

    // MARK: - Day arithmetic

    /// Shift a "yyyy-MM-dd" day string by `delta` days (can be negative), returning
    /// a normalised "yyyy-MM-dd" string. Uses a fixed UTC calendar so it is
    /// deterministic and timezone-free. Returns nil if the input can't be parsed.
    static func shiftDay(_ day: String, by delta: Int) -> String? {
        if delta == 0 { return day }
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1 else { return nil }

        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: comps),
              let shifted = cal.date(byAdding: .day, value: delta, to: base) else { return nil }
        let out = cal.dateComponents([.year, .month, .day], from: shifted)
        guard let oy = out.year, let om = out.month, let od = out.day else { return nil }
        return String(format: "%04d-%02d-%02d", oy, om, od)
    }
}
