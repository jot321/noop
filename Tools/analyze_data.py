#!/usr/bin/env python3
"""
analyze_data.py — offline analysis harness over a pulled NOOP whoop.sqlite.

Purpose: prototype and verify analytics logic in Python against the REAL on-device data
before porting changes into the Swift engines (StrandAnalytics). The ports here mirror
the Swift implementations closely enough to reproduce the app's numbers:

  * StrainScorer (Effort, 0-100 log TRIMP scale) — including the 41bd109 time-weighted
    per-sample durations (mixed-cadence fix).
  * HRVAnalyzer.cleanRR — range filter [300, 2000] ms + Malik 20% local-median ectopic
    rejection (window radius 2), and RMSSD.
  * DaytimeStress — the hourly 0-3 intraday timeline, in BOTH the current calm-quartile
    anchoring and the recalibrated variant, so the two can be compared side by side.

Pull the DB from the iPhone first (see docs/LOCAL_IPHONE_SETUP.md):

  xcrun devicectl device copy from --device <ID> \
    --domain-type appDataContainer --domain-identifier com.jotsarup.noop \
    --source "Library/Application Support/OpenWhoop/whoop.sqlite" --destination <dir>/

Usage:
  python3 Tools/analyze_data.py <path/to/whoop.sqlite> [--day YYYY-MM-DD] [--age 30] [--sex m]

Stdlib only — no dependencies.
"""

import argparse
import datetime as dt
import math
import sqlite3
import statistics
import sys
from zoneinfo import ZoneInfo

# ── Constants mirrored from StrandAnalytics ─────────────────────────────────────────────

RR_MIN_MS, RR_MAX_MS = 300.0, 2000.0        # HRVAnalyzer range filter
ECTOPIC_THRESHOLD = 0.20                    # Malik 20%
ECTOPIC_WINDOW_RADIUS = 2
HRV_MIN_BEATS = 20

STRAIN_DENOMINATOR = 7201.0                 # StrainScorer
MAX_STRAIN = 100.0
MIN_READINGS = 600
MIN_SPARSE_READINGS = 20
MIN_SPAN_SECONDS = 600
MAX_SAMPLE_GAP_S = 120.0                    # 41bd109 time-weighted TRIMP clamp
HRMAX_MIN_SAMPLES = 600
HRMAX_PERCENTILE = 99.5
EDWARDS_ZONES = [(90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1)]
DEFAULT_AGE = 30
DEFAULT_RESTING_HR = 60.0

STRESS_MIN_HOUR_HR = 300                    # DaytimeStress
STRESS_HIGH_FLOOR = 2.0
WAKING_START_H, WAKING_END_H = 6, 22

STREAMS = ["hrSample", "rrInterval", "ppgHrSample", "spo2Sample", "skinTempSample",
           "gravitySample", "stepSample", "sleepStateSample", "respSample"]


# ── HRV cleaning (HRVAnalyzer port) ─────────────────────────────────────────────────────

def range_filter(rr):
    return [v for v in rr if RR_MIN_MS <= v <= RR_MAX_MS]


def reject_ectopic(nn):
    if len(nn) <= ECTOPIC_WINDOW_RADIUS:
        return list(nn)
    kept = []
    for i, v in enumerate(nn):
        lo = max(0, i - ECTOPIC_WINDOW_RADIUS)
        hi = min(len(nn) - 1, i + ECTOPIC_WINDOW_RADIUS)
        neighbours = [nn[j] for j in range(lo, hi + 1) if j != i]
        if len(neighbours) < 2:
            kept.append(v)
            continue
        med = statistics.median(neighbours)
        if med <= 0 or abs(v - med) / med <= ECTOPIC_THRESHOLD:
            kept.append(v)
    return kept


def clean_rr(rr):
    return reject_ectopic(range_filter(rr))


def rmssd(rr):
    nn = clean_rr(rr)
    if len(nn) < HRV_MIN_BEATS:
        return None
    diffs = [(nn[i + 1] - nn[i]) ** 2 for i in range(len(nn) - 1)]
    return math.sqrt(sum(diffs) / len(diffs))


# ── Effort / strain (StrainScorer port, post-41bd109) ───────────────────────────────────

def percentile(sorted_vals, pct):
    if not sorted_vals:
        return None
    pos = pct / 100.0 * (len(sorted_vals) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (pos - lo) * (sorted_vals[hi] - sorted_vals[lo])


def sample_durations_min(ts_list):
    """Each sample carries its OWN gap to the next, clamped to MAX_SAMPLE_GAP_S (minutes)."""
    n = len(ts_list)
    fallback = 1.0 / 60.0
    if n < 2:
        return [fallback] * n
    out = [fallback] * n
    for i in range(n - 1):
        delta = ts_list[i + 1] - ts_list[i]
        out[i] = min(max(delta, 0), MAX_SAMPLE_GAP_S) / 60.0
    out[n - 1] = out[n - 2]
    return out


def zone_weight(bpm, resting_hr, hr_reserve):
    pct = (bpm - resting_hr) / hr_reserve * 100.0
    for threshold, weight in EDWARDS_ZONES:
        if pct >= threshold:
            return weight
    return 0


def effort(hr_samples, resting_hr, age=DEFAULT_AGE):
    """hr_samples: sorted [(ts, bpm)]. Returns (strain 0-100, diagnostics dict) or (None, why)."""
    n = len(hr_samples)
    span = hr_samples[-1][0] - hr_samples[0][0] if n >= 2 else 0
    if not (n >= MIN_READINGS or (n >= MIN_SPARSE_READINGS and span >= MIN_SPAN_SECONDS)):
        return None, {"why": f"gate: n={n} span={span}s"}

    bpms = sorted(s[1] for s in hr_samples)
    tanaka = 208.0 - 0.7 * age
    observed = percentile(bpms, HRMAX_PERCENTILE) if n >= HRMAX_MIN_SAMPLES else None
    eff_max = max(observed, tanaka) if observed is not None else tanaka
    if eff_max <= resting_hr:
        return None, {"why": "hrmax <= rhr"}

    hr_reserve = eff_max - resting_hr
    durs = sample_durations_min([s[0] for s in hr_samples])
    trimp = 0.0
    zone_minutes = {w: 0.0 for w in range(1, 6)}
    for (ts, bpm), d in zip(hr_samples, durs):
        w = zone_weight(bpm, resting_hr, hr_reserve)
        if w > 0:
            trimp += w * d
            zone_minutes[w] += d
    strain = min(MAX_STRAIN * math.log(trimp + 1) / math.log(STRAIN_DENOMINATOR), MAX_STRAIN)
    return strain, {"trimp": trimp, "hrmax": eff_max, "hrr": hr_reserve,
                    "rhr": resting_hr, "zone_minutes": zone_minutes, "n": n, "span_s": span}


# ── DaytimeStress port (current + recalibrated) ─────────────────────────────────────────

def quantile(sorted_vals, q):
    n = len(sorted_vals)
    if n == 0:
        return None
    if n == 1:
        return sorted_vals[0]
    pos = q * (n - 1)
    lo = int(pos)
    hi = min(lo + 1, n - 1)
    return sorted_vals[lo] + (pos - lo) * (sorted_vals[hi] - sorted_vals[lo])


def squash(raw):
    return min(max(3.0 / (1.0 + math.exp(-raw)), 0.0), 3.0)


def daytime_stress(hr_samples, rr_samples, tz_offset_s, anchor="quartile"):
    """Hourly 0-3 stress. anchor='quartile' = current app behaviour (calm-quartile reference);
    anchor='median' = recalibrated variant (typical hour ~= 1.5 baseline)."""
    hr_by_bucket, rr_by_bucket = {}, {}
    for ts, bpm in hr_samples:
        b = ((ts + tz_offset_s) // 3600) * 3600
        hr_by_bucket.setdefault(b, []).append(float(bpm))
    for ts, ms in rr_samples:
        b = ((ts + tz_offset_s) // 3600) * 3600
        rr_by_bucket.setdefault(b, []).append(float(ms))

    def is_waking(bucket):
        return WAKING_START_H <= (bucket // 3600) % 24 < WAKING_END_H

    aggs = []
    for b in sorted(hr_by_bucket):
        hrs = hr_by_bucket[b]
        mean_hr = statistics.fmean(hrs) if len(hrs) >= STRESS_MIN_HOUR_HR else None
        aggs.append((b, mean_hr, rmssd(rr_by_bucket.get(b, []))))

    ref_aggs = [a for a in aggs if is_waking(a[0])]
    hr_means = sorted(m for _, m, _ in ref_aggs if m is not None)
    rm_vals = sorted(r for _, _, r in ref_aggs if r is not None)
    q_hr, q_rm = (0.25, 0.75) if anchor == "quartile" else (0.5, 0.5)
    ref_hr = quantile(hr_means, q_hr) if len(hr_means) >= 4 else (statistics.fmean(hr_means) if hr_means else None)
    ref_rm = quantile(rm_vals, q_rm) if len(rm_vals) >= 4 else (statistics.fmean(rm_vals) if rm_vals else None)
    sd_hr = statistics.pstdev(hr_means) if len(hr_means) > 1 else 0.0
    sd_rm = statistics.pstdev(rm_vals) if len(rm_vals) > 1 else 0.0

    points = []
    for b, mean_hr, rm in aggs:
        if not is_waking(b):
            continue
        level = None
        if mean_hr is not None:
            raw = 0.0
            if ref_hr is not None and sd_hr > 1e-4:
                raw += (mean_hr - ref_hr) / sd_hr
            if rm is not None and ref_rm is not None and sd_rm > 1e-4:
                raw += (ref_rm - rm) / sd_rm
            level = squash(raw)
        points.append({"hour": (b // 3600) % 24, "level": level, "meanHR": mean_hr, "rmssd": rm})
    return points


def band(level):
    return "LOW" if level < 1.0 else ("MEDIUM" if level < 2.0 else "HIGH")


# ── Report ──────────────────────────────────────────────────────────────────────────────

def hr_rows(con, dev, frm, to):
    return con.execute(
        "SELECT ts, bpm FROM hrSample WHERE deviceId=? AND ts>=? AND ts<? ORDER BY ts",
        (dev, frm, to)).fetchall()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("db", help="path to whoop.sqlite (pulled from the iPhone)")
    ap.add_argument("--day", help="local day YYYY-MM-DD (default: today)")
    ap.add_argument("--tz", default="Asia/Kolkata", help="IANA timezone of the wearer")
    ap.add_argument("--age", type=int, default=DEFAULT_AGE)
    args = ap.parse_args()

    tz = ZoneInfo(args.tz)
    day = dt.date.fromisoformat(args.day) if args.day else dt.datetime.now(tz).date()
    day_start = int(dt.datetime.combine(day, dt.time.min, tz).timestamp())
    day_end = day_start + 86_400
    tz_offset = int(tz.utcoffset(dt.datetime.now(tz)).total_seconds())

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)

    print(f"═══ NOOP data report · {day} ({args.tz}) ═══\n")

    # 1 · Stream inventory per local day
    print("── Stream coverage by local day ──")
    for t in STREAMS:
        rows = con.execute(
            f"SELECT date((ts + ?)/86400*86400 - ?, 'unixepoch'), COUNT(*) FROM {t} "
            f"GROUP BY 1 ORDER BY 1", (tz_offset, -0)).fetchall()
        # bucket on the LOCAL day: shift, floor to day, then format
        rows = con.execute(
            f"SELECT date(ts + ?, 'unixepoch'), COUNT(*), MIN(ts), MAX(ts) FROM {t} "
            f"GROUP BY 1 ORDER BY 1", (tz_offset,)).fetchall()
        if not rows:
            continue
        days = "  ".join(f"{d}:{n:,}" for d, n, *_ in rows)
        print(f"  {t:<17} {days}")

    # 2 · Daily metrics + all metricSeries keys
    print("\n── dailyMetric ──")
    for r in con.execute("SELECT deviceId, day, recovery, strain, restingHr, avgHrv, "
                         "totalSleepMin, respRateBpm, spo2Pct FROM dailyMetric ORDER BY day, deviceId"):
        dev, d, rec, strain, rhr, hrv, sleep, resp, spo2 = r
        fm = lambda v, f="{:.1f}": "—" if v is None else f.format(v)
        print(f"  {d} [{dev}] recovery={fm(rec)} effort={fm(strain)} rhr={fm(rhr, '{:.0f}')} "
              f"hrv={fm(hrv)} sleep={fm(sleep, '{:.0f}')}m resp={fm(resp)} spo2={fm(spo2)}")

    print("\n── metricSeries (all keys, latest 3 days each) ──")
    for key, dev in con.execute("SELECT DISTINCT key, deviceId FROM metricSeries ORDER BY key"):
        vals = con.execute("SELECT day, value FROM metricSeries WHERE key=? AND deviceId=? "
                           "ORDER BY day DESC LIMIT 3", (key, dev)).fetchall()
        vs = "  ".join(f"{d}={v:.3g}" for d, v in vals)
        print(f"  {key:<24} [{dev}] {vs}")

    # 3 · Sleep sessions
    print("\n── sleepSession ──")
    for dev, s, e in con.execute("SELECT deviceId, startTs, endTs FROM sleepSession ORDER BY startTs"):
        st = dt.datetime.fromtimestamp(s, tz)
        en = dt.datetime.fromtimestamp(e, tz)
        print(f"  [{dev}] {st:%Y-%m-%d %H:%M} → {en:%H:%M}  ({(e - s) // 60} min)")

    # 4 · Effort recompute for the chosen day
    dev = con.execute("SELECT deviceId FROM hrSample GROUP BY deviceId ORDER BY COUNT(*) DESC "
                      "LIMIT 1").fetchone()
    if dev:
        dev = dev[0]
        hr = hr_rows(con, dev, day_start, day_end)
        rhr_row = con.execute("SELECT restingHr FROM dailyMetric WHERE day=? AND restingHr IS NOT NULL",
                              (day.isoformat(),)).fetchone()
        rhr = float(rhr_row[0]) if rhr_row else DEFAULT_RESTING_HR
        print(f"\n── Effort recompute · {day} · {len(hr):,} HR samples · RHR {rhr:.0f} ──")
        strain, diag = effort(hr, rhr, age=args.age)
        if strain is None:
            print(f"  not scorable ({diag['why']})")
        else:
            zm = {w: round(m, 1) for w, m in diag["zone_minutes"].items() if m > 0.05}
            print(f"  Effort = {strain:.2f} / 100   (TRIMP {diag['trimp']:.1f}, "
                  f"HRmax {diag['hrmax']:.0f}, reserve {diag['hrr']:.0f})")
            print(f"  minutes ≥50% HRR by Edwards zone: {zm or 'none'}")

        # 5 · Daytime stress, current vs recalibrated
        rr = con.execute("SELECT ts, rrMs FROM rrInterval WHERE deviceId=? AND ts>=? AND ts<? "
                         "ORDER BY ts", (dev, day_start, day_end)).fetchall()
        print(f"\n── Daytime stress · {day} · current (calm-quartile) vs recalibrated (median) ──")
        cur = daytime_stress(hr, rr, tz_offset, anchor="quartile")
        rec = daytime_stress(hr, rr, tz_offset, anchor="median")
        print(f"  {'hour':>4}  {'meanHR':>6}  {'rmssd':>6}  {'current':>8}  {'recal':>8}")
        for c, m in zip(cur, rec):
            lv = lambda p: "—" if p["level"] is None else f"{p['level']:.2f} {band(p['level'])[0]}"
            mh = "—" if c["meanHR"] is None else f"{c['meanHR']:.0f}"
            rm = "—" if c["rmssd"] is None else f"{c['rmssd']:.0f}"
            print(f"  {c['hour']:>3}h  {mh:>6}  {rm:>6}  {lv(c):>8}  {lv(m):>8}")
        for name, pts in (("current", cur), ("recalibrated", rec)):
            scored = [p["level"] for p in pts if p["level"] is not None]
            if scored:
                bands = {b: sum(1 for l in scored if band(l) == b) for b in ("LOW", "MEDIUM", "HIGH")}
                print(f"  {name:<13} mean {statistics.fmean(scored):.2f} · "
                      f"low {bands['LOW']}h · med {bands['MEDIUM']}h · high {bands['HIGH']}h")

    con.close()


if __name__ == "__main__":
    sys.exit(main())
