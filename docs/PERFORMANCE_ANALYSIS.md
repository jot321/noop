# Performance & Power Analysis — NOOP iOS

*Analysis date: 2026-07-10. Scope: UI lag on the phone app and whether the BLE
connectivity design costs more battery than it needs to. Every finding below was
verified against the code at the cited file:line; nothing is speculative.*

## TL;DR

- **UI lag** has one dominant cause: per-BLE-packet work multiplying through views
  that observe too much. The Live tab re-renders its entire ~1,200-line body on
  every heart-rate/R-R/frame publish, the strap-log card materializes up to 5,000
  `Text` rows non-lazily with unstable identity, and during a workout the whole
  accumulated sample array is JSON-encoded to `UserDefaults` on the main actor
  once per second.
- **Power**: the always-on `bluetooth-central` + 1 Hz recording baseline is a
  deliberate product decision and is mostly well-engineered (batched persistence,
  change-gated publishes, reconnect backoff). But **yes, the app consumes more
  power than necessary** in four specific places: an infinite 8-second scan
  rotation whenever the strap is away, the heavy R10/R11 raw stream surviving
  backgrounding via the keep-alive, that same keep-alive arming the heavy burst
  for the passive continuous-HRV toggle, and a Live Activity updated every 2 s
  around the clock (~43k lock-screen updates/day) during passive wear.

---

## Part 1 — UI performance (the reported lag)

### U1. HIGH — `LiveView` observes `LiveState` and `AppModel` at the top level

`Strand/Screens/LiveView.swift:22-23`

```swift
@EnvironmentObject private var model: AppModel
@EnvironmentObject private var live: LiveState
```

The file's own header comment (lines 16–20) says LiveState is "observed ONLY in
leaf views … so a fresh HR / R-R / frame notify re-renders just that leaf, never
the whole screen." That is not true as written: `@EnvironmentObject` subscribes
to the whole object's `objectWillChange`. Every `@Published` write on
`LiveState` — `heartRate` (~1 Hz), `rr` (per packet), `lastFrameType`/`lastEvent`
(per routed frame), `log` (per line), `syncChunksThisSession` (per chunk during
an offload) — invalidates the entire LiveView body: the double-layout
`ViewThatFits` passes, the `LazyVGrid` trust rail (~30 `String(localized:)`
lookups per pass), the log card. During a history backfill this becomes a
re-render storm. During a workout, `AppModel.activeWorkout` is reassigned once
per HR sample (see U3), so the parent also re-renders at ≥1 Hz from that side.

**Fix:** remove the top-level observation. Extract the coarse reads the parent
needs (`connected`, `bonded`, `backfilling`, `reconnectGuide`,
`activeWorkout != nil`) into a tiny bridge leaf that pushes only edge changes
into `@State` — the exact `BackfillFlagBridge` pattern TodayView already uses
(`Strand/Screens/TodayView.swift:4396-4406`). Alternatively split `LiveState`
into a high-frequency object (HR/RR/frames/log) and a low-frequency connection
object. **This is the single highest-impact fix for the Live-tab lag.**

### U2. HIGH — Strap-log card: 5,000 non-lazy rows with unstable identity

`Strand/Screens/LiveView.swift:1075-1089` (`LiveLogCard`)

```swift
ForEach(Array(live.log.enumerated()), id: \.offset) { idx, line in
    Text(line)...
```

- `live.log` caps at 5,000 lines; a plain `VStack` materializes every row even
  though ~15 fit the 200-pt viewport.
- `Array(live.log.enumerated())` allocates a fresh array per render.
- `id: \.offset`: once the ring buffer trims (`removeFirst`), every line shifts
  one offset, so all rows change identity → full re-diff per append.
- The card observes `LiveState`, so it re-renders on every HR/RR/frame publish,
  not just log appends; `scrollTo` fires per append too.

**Fix:** `LazyVStack`; render only a tail slice (e.g. last 200 lines — the full
log is already exportable); key rows by a stable monotonic line ID; throttle the
log's UI updates (`.throttle(for: .seconds(1))`) or decouple it from
`LiveState.objectWillChange`.

### U3. HIGH — Workout: full JSON snapshot to `UserDefaults` per HR sample, O(n) and growing

`Strand/App/AppModel.swift:699-708` → `Strand/App/ActiveWorkoutPersistence.swift:60-64`

```swift
w.avgHr = Int((Double(w.samples.map(\.bpm).reduce(0, +)) / ...)  // O(n) per tick
w.liveStrain = StrainScorer.strain(w.samples, ...)               // O(n) per tick (memo misses every time)
activeWorkout = w                                                // @Published struct copy → re-render
persistActiveWorkout()                                           // JSON-encode FULL samples array → UserDefaults
```

`captureWorkoutSample()` runs from `ingestHR()` at ~1 Hz. A 2-hour workout has
~7,200 samples: by the end, every second JSON-encodes the whole array (~100 KB+)
and rewrites the defaults plist — on the main actor (`AppModel` is
`@MainActor`) — plus three O(n) passes. O(n²) total over the session, a
per-second main-thread hitch on exactly the screen animating 60 fps liquid
canvases.

**Fix:** persist every 15–30 s (plus on start/end/background); keep a running
sum for `avgHr` (O(1)); compute `liveStrain` at a lower cadence (e.g. every
10 s); move the encode off the main actor.

### U4. MEDIUM — `LiveState.append(log:)` rewrites a 2,000-string defaults array per line

`Strand/BLE/LiveState.swift:466-473, 508-511`

Every log line: a `@Published` publish (re-renders all LiveState observers), a
PII-scrub pass, and a synchronous main-actor `UserDefaults.set` of up to 2,000
strings (~200 KB). Fine at a few lines/minute; hot during connects, backfills,
the away-strap scan rotation (one line per 8 s, see P1), and the
`IntelligenceEngine` rescore replay, which emits one line per scored day
(`Strand/Data/IntelligenceEngine.swift:626-632, 788-789`) — a one-shot upgrade
rescore over `maxDays: 4000` can push thousands of appends in a tight loop.

**Fix:** debounce `persistTail` (dirty flag, flush every 5–10 s and on
background/terminate); batch diagnostic replay loops into a single append.

### U5. MEDIUM — Stress detector writes `UserDefaults` at R-R rate all day

`Strand/App/AppModel.swift:753-765`, `Strand/Screens/BiofeedbackPrefs.swift:105-109`

With the stress check-in toggle on and the strap worn, `evaluateStress()` runs
per HR/R-R sample (~1–3 Hz) doing 6 defaults reads and 3 defaults writes per
tick, continuously — keeping the (large, see U4) defaults domain permanently
dirty. **Fix:** persist only on material state change (baseline moved > ε,
`wasBelow` flipped, `lastFireAt` changed) or on a 60 s timer + background.

### U6. MEDIUM — Always-on 60 fps liquid canvases never idle when settled

`Strand/Liquid/LiquidPrimitives.swift:242-255, 285, 320`, `Strand/Liquid/LiquidSky.swift:67`,
`Strand/Liquid/LiquidCore.swift:247-249`

Liquid Today runs 5 live `TimelineView` canvases concurrently (3 hero vessels +
HR thread + sky); Live runs a 210-pt vessel + R-R thread + effort tube. All are
CPU-side `GraphicsContext` path building per frame. `LiquidSim.settled` exists
precisely so a paused TimelineView can stand down, **but nothing consults it** —
redraw continues at full rate when the liquid is level and the target hasn't
moved. Constant frame-budget/battery drain competing with scroll.

**Fix:** switch to a paused/`.explicit` schedule (or the static pose) when
`sim.settled` and there's no recent tilt/energy.

### U7. MEDIUM — Classic TodayView: hint loop invalidates the 4,700-line body; unmemoized day scans

`Strand/Screens/TodayView.swift:1120-1130, 469-474, 499-506`

The "Swipe/Tap" hint writes `@State` on `TodayView` itself twice per ~11.5 s
with animation, re-running per-render O(days) computed properties
(`displayDay` via `repo.days.last(where:)`, `lastScoredRecoveryDay`,
`lastVitalsDay`). **Fix:** move the hint into a tiny leaf view with its own
state/loop (same pattern as the per-second clock at line 110); cache
`displayDay` in the existing `TodayDerived` memo like LiquidTodayView's
`cachedDisplayDay`.

### U8. MEDIUM — Liquid pull-to-refresh re-evaluates the full dashboard per frame while pulling

`Strand/Liquid/LiquidTodayView.swift:179-185, 209, 296-313`

`pullY` is `@State` on the root, written per scroll-offset change during a
pull-down — up to 120 full body passes/sec on a 120 Hz device, to grow a 30-pt
indicator. **Fix:** isolate the indicator into a child that alone reads the
preference, or hold `pullY` in a small `ObservableObject` observed only by the
indicator.

### U9. MEDIUM — Per-HR-packet anchor scan at the app root, ahead of the throttle

`StrandiOS/App/StrandiOSApp.swift:79-91`, `Strand/Data/Repository.swift:389-404`

`.onReceive(model.live.$heartRate)` computes `Repository.widgetAnchor(days:)`
(reverse scan of `repo.days` + two `DateFormatter.string` calls) on the main
thread per packet, before `LiveActivityController.update`'s 2 s throttle can
drop the tick — and even when Live Activities are disabled. **Fix:** throttle at
the subscription (`.throttle(for: .seconds(2), latest: true)`); cache the anchor
per `refreshSeq` (days only change on refresh).

### U10. LOW — assorted

- `RelativeDateTimeFormatter` allocated per render on the ~1 Hz Live re-render
  path (`Strand/Screens/LiveView.swift:1136-1144`) — make it `static let` (the
  codebase does this correctly elsewhere, e.g. `SleepView.swift:2298-2310`).
- Classic Today computes `StrainScorer.strain` over up to ~86k HR rows on the
  main actor per load (`Strand/Screens/TodayView.swift:3950-3959`) — wrap in
  `Task.detached` like the `StressModel` path (`LiquidTodayView.swift:851-855`).
- `Collector.flush()` parses up to 64 frames on the main actor
  (`Strand/Collect/Collector.swift:143-144`) — detach like `Backfiller` does
  (`Strand/Collect/Backfiller.swift:347-352`).
- `BreathingView` 20 Hz `Timer.publish` invalidations
  (`Strand/Screens/BreathingView.swift:154`) — a `TimelineView`/`Canvas` would
  bypass per-tick body diffing.
- `LiveHeartReadout` starts a 0.6 s `withAnimation` count-up per bpm change
  (`LiveView.swift:791-798`) — prefer compositor-side
  `contentTransition(.numericText())` as `LiquidLiveHR` already uses.

---

## Part 2 — BLE connectivity & power

**Baseline:** `UIBackgroundModes` = `bluetooth-central`, `location`, `fetch`
(`StrandiOS/Resources/Info.plist:61-66`). With an always-subscribed ~1 Hz HR
notify characteristic, the process effectively never suspends while a strap is
connected (~86k wakes/day). That is the product (24/7 recording) and it's
engineered around competently — but every finding below compounds on an
always-awake baseline.

### P1. HIGH — Strap-away infinite scan loop (single-WHOOP reconnect)

`Strand/BLE/BLEManager.swift:2311-2335` (`startScan`), `:2825-2830`, `:1008-1020`

For a single-WHOOP user, `preferredPeripheralUUID` is nil, so reconnect skips
the targeted `retrievePeripherals` branch and falls to `startScan(...)`, which
schedules a fallback work item that recursively stops+restarts the scan on the
other WHOOP service UUID **every 8 seconds, forever, with no overall timeout**
while the strap is away. Each rotation also logs a line → the U4 per-append
2,000-string defaults rewrite. Strap on the charger in another room = radio duty
cycle + CPU wake + defaults write every 8 s, all night, in background.

**Fix:** after first connect, persist `CBPeripheral.identifier` and reconnect
via `central.connect(retrievePeripherals(withIdentifiers:)[0])` — the
zero-power pending connect that the pinned multi-WHOOP path already uses
(`:1010-1016`). Bound the family rotation to 2–3 cycles, then park on the
pending connect. **Highest-value power fix.**

### P2. HIGH — Heavy R10/R11 raw stream survives backgrounding

`Strand/BLE/BLEManager.swift:2196-2204` (keep-alive re-arm), `Strand/App/AppModel.swift:917-930`,
`StrandiOS/App/StrandiOSApp.swift:150-171`

`stopRealtime()` is driven only by SwiftUI `onDisappear`
(`LiveView.swift:109`, `LiveWorkoutView.swift:85`) via the `realtimeWanters`
ref-count. `onDisappear` does not fire on backgrounding, and no `scenePhase`
handler calls `stopRealtimeHR()`. Background the phone with the Live tab
frontmost and the 30 s keep-alive re-arms the R10/R11 raw burst (the "~2/s
type-43 raw flood" the code itself calls "the battery-hungry part",
`:1585`, `:1928`) **forever in background** — draining strap and phone.

**Fix:** observe `scenePhase`/`didEnterBackgroundNotification` and call
`ble.stopRealtime()` (restore on `.active` if the Live surface is still up),
except while a workout session holds the ref-count.

### P3. HIGH (opt-in users) — Keep-alive arms the heavy burst for passive continuous-HRV

`Strand/BLE/BLEManager.swift:2200-2204` vs `:1928-1931`, `:1972-1978`

`stopRealtime()` deliberately keeps only the lightweight TOGGLE/0x2A37 for
continuous capture when the live screen closes — but `keepAliveFire` re-arms
**both** `.sendR10R11Realtime` and `.toggleRealtimeHR` whenever `wantsRealtime`
is true, and `wantsRealtime` includes `keepRealtimeForData` (the "Continuous
HRV capture" toggle). So with that toggle on, the raw flood is silently
re-armed 30 s after Live closes and held all night. **Fix:** re-arm
`.sendR10R11Realtime` only when `screenWantsRealtime`; re-arm only
`.toggleRealtimeHR` for the continuous-capture want.

### P4. MEDIUM-HIGH — Live Activity updated every 2 s during passive all-day wear

`StrandiOS/Widgets/LiveActivityController.swift:24-28, 61-63`, `StrandiOSApp.swift:79-91`

The Live Activity starts whenever the strap is connected with HR present — not
just during workouts — and pushes an ActivityKit update per 2 s: **~43,000
lock-screen/Dynamic-Island re-renders per day** for a resting HR display.
**Fix:** adaptive throttle — 2 s only while a workout/Live session is active,
30–60 s otherwise, or update only when bpm moves ≥3.

### P5. MEDIUM-HIGH — Oura ring's own power-saver defeated 24/7

`Strand/BLE/OuraLiveSource.swift:307-310, 481, 698-715`

The ring auto-reverts live HR after ~20 s (a ring power feature); NOOP re-sends
enable+subscribe every 15 s from stream start until disconnect, not gated on any
live surface — holding an adopted ring in live-HR mode the whole time it's
connected, plus a 15 s timer wake on the phone. **Fix:** gate the re-engage loop
on a visible live-HR surface (mirror `screenWantsRealtime`); otherwise fall back
to history-fetch-only.

### P6. MEDIUM — HealthKit full 30-day re-sync per foreground; `foregroundCatchUp()` unwired

`StrandiOS/Health/HealthKitBridge.swift:211-213, 425-488`, `StrandiOSApp.swift:158`

Every foreground runs `sync()` with the default 30 days → 14
`HKStatisticsCollectionQuery`s + sleep + workouts + 4 upserts, even when nothing
changed; the purpose-built 7-day `foregroundCatchUp()` is never called.
`writeBack` re-emits up to ~56 samples per sync via delete+save cycles even when
values are identical, repeated hourly per observer wake. **Fix:** wire
`foregroundCatchUp()` into the scenePhase handler; diff against last-written
values and only rewrite changed rows.

### P7. MEDIUM — Dashboard refresh reads full history (default 4,000 days)

`Strand/Data/Repository.swift:667-741`

`refresh(days: 4000)` (~11 years) runs at launch, after every `analyzeRecent`,
and after every sleep edit/nap/workout save. The merge is correctly off-main and
diff-guarded, but the I/O is a full-history read each time, and the published
arrays hold thousands of elements that every downstream `Equatable` diff
re-compares. **Fix:** keep the dashboard cache to a recent window (~400 days)
and lazy-load deep history for the few screens that need it; post-edit
refreshes can use the small window the backfill path already uses
(`refresh(days: 120)`, `AppModel.swift:472`).

### P8. LOW/MEDIUM — assorted

- 120 s liveness fuse recycles a healthy-but-quiet WHOOP4 link with a full
  disconnect→scan→re-bond→backfill cycle (`BLEManager.swift:2169-2174`).
- Widget/watch snapshot builds pay a 4,000-day `exploreSeries` read *before*
  their own spacing gates (`StrandiOS/Widgets/WidgetPublish.swift:43-46`,
  `Strand/Data/WatchSessionBridge.swift:75-88, 150`) — check the gate first,
  and read only the anchor day's row.
- `uploadTimer` is declared but never started — dead code
  (`BLEManager.swift:502-503`).
- WHOOP 4 battery characteristic is a known stub (constant 100) yet still
  subscribed (`BLEManager.swift:3352-3358`) — skip 0x2A19 for `.whoop4`.

### What's already good (don't regress)

- Persistence is SQLite (GRDB, WAL) with batched prepared-statement inserts
  (`Packages/WhoopStore/Sources/.../StreamStore.swift:37-171`); live BLE ingest
  batches through `Collector` (flush at 64 frames/30 s) — no per-packet disk
  writes.
- Scans are service-filtered, no-duplicates, stopped on discovery/connect;
  failed-connect backoff is capped 3→60 s; bond-loop detector pauses reconnects.
- Frame publishes are change-gated (`FrameRouter.swift:58-59`); HR log throttled
  to 30 s; backfill floors via `BackfillPolicy`; no RSSI polling.
- `Repository.refresh` is single-flighted, diff-guarded, generation-ordered;
  heavy merges/decodes are detached off-main in Repository, IntelligenceEngine
  (fingerprint-gated), and Backfiller.
- TodayView/LiquidTodayView deliberately do NOT observe `LiveState`/`AppModel`
  at the root — live values isolated into leaves. LiveView should be brought up
  to this standard (U1), not the other way around.
- Liquid tiering (static vessels for small gauges, `LiquidSkyStatic`, gated hero
  animation), `TodayDerived` memoization, 2 s debounced backfill→refresh,
  publish-suppressed `ingestHR` bpm.
- HealthKit sync only on `.active`, never per sample; widget publishes gated on
  `scenePhase == .active` + diff-guarded `refreshSeq`.

---

## Recommended order of attack

1. **U1** — de-observe `LiveState`/`AppModel` in the LiveView parent (biggest
   lag win, small diff).
2. **U2** — lazy/truncated strap-log card with stable IDs.
3. **U3 + U4 + U5** — debounce the three hot `UserDefaults` write paths
   (workout snapshot, log tail, stress state).
4. **P1** — pending-connect reconnect for single-WHOOP (biggest battery win).
5. **P2 + P3** — scenePhase teardown of the R10/R11 burst; keep-alive re-arms
   the heavy burst only for a visible live screen.
6. **P4** — adaptive Live Activity throttle.
7. **U6** — honor `LiquidSim.settled` in the TimelineView schedules.
8. Then P5–P8, U7–U10 as cleanups.
