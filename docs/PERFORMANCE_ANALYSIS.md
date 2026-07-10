# Performance and Power Analysis - NOOP iOS

Analysis date: 2026-07-10. Updated after implementation verification on
2026-07-10 for branch `agent/high-impact-performance`.

The original audit identified the right high-impact areas, but several claims
were intentionally narrowed during implementation review. The verified behavior
and operational evidence are documented in
[PERFORMANCE_IMPLEMENTATION.md](PERFORMANCE_IMPLEMENTATION.md).

## Verified Corrections

- Root `LiveState` / `AppModel` observation proved a root invalidation risk for
  high-frequency BLE values. It did not prove a complete layout and render for
  every packet, because SwiftUI can coalesce and diff invalidations.
- Repeated `UserDefaults.set` calls proved repeated defaults-domain mutation and
  serialization work. They did not prove a physical plist disk write for every
  call.
- P1 was not missing UUID persistence. The real bug was a startup-order race:
  the persisted peripheral UUID could arrive after an ordinary reconnect scan
  had already started, and applying the late pin did not redirect that scan.
- WHOOP5/MG does not use the WHOOP4 R10/R11 realtime command path. It rejects
  that command family and relies on the puffin realtime toggle, so realtime
  policy has to distinguish WHOOP4 heavy stream demand from the shared toggle.
- Live Activity updates are event-driven from app state and HR samples. There
  was a two-second floor, not a two-second timer. The previous 43,000 updates
  per day number was only a theoretical maximum for sustained two-second update
  attempts and is not presented as observed behavior.

## Implemented High-Impact Items

### U1 - Live Root Observation

Status: implemented.

The Live screen now builds an equatable `LiveScreenSnapshot` from low-frequency
root inputs and keeps HR, R-R, frame, log, and workout sample changes in leaf
views. `LiveScreenSnapshotTests` verify that high-frequency fields are excluded
and that root-visible state changes are still represented.

Commits: `aa05711` and `38fbe5b`.

### U2 - Strap Log Rendering

Status: implemented.

`LiveState` keeps the full retained in-memory/exportable log while projecting a
200-row visible tail with monotonic IDs. The UI renders that tail with a lazy
stack and scrolls to the newest stable row ID. `LiveLogProjectionTests` verify
the visible cap, stable IDs after trimming, newest-ID changes, and full export
retention.

Commits: `aa05711` and `38fbe5b`.

### U3 - Active Workout Persistence

Status: implemented.

Workout capture now deduplicates to one accepted sample per Unix second, keeps
running count/sum/peak in `ActiveWorkoutRuntime`, gates live strain work to a
10-second cadence, and writes active-workout snapshots through a generation
checked coordinator. The coordinator writes start immediately, coalesces normal
snapshots to a 15-second production interval, flushes on lifecycle boundaries,
and clears after invalidating delayed work so an ended workout cannot be
resurrected.

Tests: `ActiveWorkoutRuntimeTests` and `ActiveWorkoutPersistenceTests`.

Commits: `c0e40cb` and `88076c8`.

### U4 - Strap Log Tail Persistence

Status: implemented.

Durable log-tail persistence moved behind `LogTailPersistence`, which owns the
2,000-line persisted cap and writes at a five-second production cadence, with
explicit flushes before lifecycle exits and scheduled debug export reads.
`LiveState.exportableLogText()` continues to include the retained diagnostic
log rather than only the visible 200 rows.

Tests: `LogTailPersistenceTests`.

Commits: `c0e40cb` and `88076c8`.

### U5 - Stress State Persistence

Status: implemented.

HR and R-R ingestion are split so stress evaluation consumes only the supplied
R-R packet once. Replay-safety transitions (`wasBelow`, `lastFireAt`) persist
immediately, baseline-only EMA updates coalesce to a 60-second production
interval, and disabled/unchanged state writes nothing.

Tests: `StressStatePersistenceTests`.

Commits: `c0e40cb` and `88076c8`.

### P1 - Late Persisted UUID Reconnect Race

Status: implemented.

The persisted `CBPeripheral.identifier` was already stored. The fix narrows the
late-pin path: when a valid saved UUID arrives while an ordinary automatic scan
is active, the scanner cancels the fallback rotation, retrieves the preferred
peripheral, and redirects to the targeted connect path. Presentation scans,
restoration, connected links, bond-loop pauses, stale pins, and no-pin first
pairing are left alone.

Tests: `PreferredPeripheralRedirectTests`.

Commits: `0ca6d25`, with follow-up realtime fixes in `652a9e5` and `ff70856`.

### P2 - WHOOP4 Heavy Stream In Background

Status: implemented.

Realtime demand is now derived from explicit owners. Backgrounding suppresses
only the foreground Live-screen owner; active workout, live session, and manual
control owners continue to hold their intended demand. This prevents a Live
screen-only WHOOP4 R10/R11 burst from surviving backgrounding while preserving
workout/session capture.

Tests: `RealtimeDemandPolicyTests`.

Commits: `0ca6d25`, `652a9e5`, and `ff70856`.

### P3 - Passive Continuous HRV Heavy Stream

Status: implemented.

Passive continuous capture can request the lightweight toggle, but it does not
imply WHOOP4 R10/R11 heavy stream demand. WHOOP5/MG remains on the puffin toggle
path and never requests the WHOOP4 heavy command family.

Tests: `RealtimeDemandPolicyTests`.

Commits: `0ca6d25`, `652a9e5`, and `ff70856`.

### P4 - Live Activity Cadence

Status: implemented.

Live Activity updates now pass through `LiveActivityUpdatePolicy`: start on a
valid connected HR sample, update at a two-second minimum only during an active
Live/workout/session experience, update at a 30-second minimum during passive
wear, and end immediately on disconnect or Live Activity opt-out. Follow-up
fixes prevent end race re-adoption and preserve newer push state when old
ActivityKit handles finish ending.

Tests: `LiveActivityUpdatePolicyTests` and the focused iOS 17 ActivityKit
typecheck recorded in the implementation document.

Commits: `700bcbb`, `1fc2c47`, and `0444aa5`.

## Deferred Findings

The branch intentionally implements U1-U5 and P1-P4 only. U6-U10 and P5-P8
remain deferred and were not changed as dedicated audit work. The source line
numbers below are the original baseline references at
`performance-baseline-2026-07-10`; paths and named symbols remain the durable
references if later edits move the lines.

### U6 - Always-On Liquid Canvases Do Not Idle When Settled

Status: deferred / not changed.

Baseline sources: `Strand/Liquid/LiquidPrimitives.swift:242-255,285,320`,
`Strand/Liquid/LiquidSky.swift:67`, and
`Strand/Liquid/LiquidCore.swift:247-249`.

Symptom: Liquid Today can run five `TimelineView` canvases concurrently, while
Live adds its vessel, R-R thread, and effort tube. These CPU-side
`GraphicsContext` paths continue receiving frame callbacks even after
`LiquidSim.settled` becomes true because the schedules do not consult that
state.

Impact: settled visuals continue consuming frame budget and power and can
compete with scrolling and other main-screen work.

Recommended remediation: switch to a paused or explicit schedule, or a static
pose, while the simulation is settled and there is no recent tilt or energy.

### U7 - Classic Today Hint Loop and Repeated Day Scans

Status: deferred / not changed.

Baseline source: `Strand/Screens/TodayView.swift:1120-1130,469-474,499-506`.

Symptom: the Swipe/Tap hint updates state on the `TodayView` root twice per
roughly 11.5 seconds with animation. Each root evaluation also repeats linear
day searches for `displayDay`, `lastScoredRecoveryDay`, and `lastVitalsDay`.

Impact: a small hint animation causes broad view invalidation and repeated work
that is unrelated to the hint itself.

Recommended remediation: move the hint state and loop into a leaf view and
cache `displayDay` in `TodayDerived`, matching Liquid Today's cached-day pattern.

### U8 - Liquid Pull-to-Refresh Root Invalidations

Status: deferred / not changed.

Baseline source: `Strand/Liquid/LiquidTodayView.swift:179-185,209,296-313`.

Symptom: root `pullY` state changes with scroll-offset updates throughout a
pull gesture so the full dashboard is invalidated to animate a small progress
indicator.

Impact: on high-refresh-rate devices, a pull can schedule many broad body
evaluations per second and compete with the gesture's own rendering work.

Recommended remediation: isolate the indicator in a child that alone reads the
preference, or store `pullY` in a small observable object consumed only by that
indicator.

### U9 - Live Activity Anchor Work at the App Root

Status: deferred; no dedicated U9 remediation was implemented. P4 incidentally
narrowed the original symptom.

Baseline sources: `StrandiOS/App/StrandiOSApp.swift:79-91` and
`Strand/Data/Repository.swift:389-404`.

Original symptom: the root HR subscription computed
`Repository.widgetAnchor(days:)`, including a reverse day scan and date
formatting, before the old Live Activity cadence check and even when Live
Activities were disabled.

Current impact: P4 now supplies the anchor through a lazy closure after
`LiveActivityUpdatePolicy` decides to start or update, so dropped or disabled
events no longer pay the anchor lookup. The root subscription still evaluates
policy for every HR publication, and accepted pushes can repeat the same anchor
scan because it is not cached by repository generation.

Recommended remediation: throttle or deduplicate the upstream subscription at
the active/passive policy cadence and cache the anchor per `refreshSeq`.

### U10 - Miscellaneous UI and Main-Actor Work

Status: deferred / not changed.

- `Strand/Screens/LiveView.swift:1136-1144`: a
  `RelativeDateTimeFormatter` was allocated on the Live render path. This adds
  avoidable allocation work; use a shared `static let`, as in
  `SleepView.swift:2298-2310`.
- `Strand/Screens/TodayView.swift:3950-3959`: Classic Today computed
  `StrainScorer.strain` over as many as roughly 86,000 HR rows on the main
  actor. This can stall view loading; move it to detached work like the
  `StressModel` path in `LiquidTodayView.swift:851-855`.
- `Strand/Collect/Collector.swift:143-144`: `Collector.flush()` parsed batches
  of up to 64 frames on the main actor. This can contend with UI work during
  ingest; detach parsing like `Backfiller.swift:347-352`.
- `Strand/Screens/BreathingView.swift:154`: a 20 Hz `Timer.publish` invalidated
  SwiftUI state. This causes repeated body diffing for visual time; use a
  `TimelineView` or `Canvas`-driven presentation.
- `Strand/Screens/LiveView.swift:791-798`: `LiveHeartReadout` started a
  0.6-second `withAnimation` count-up for each BPM change. Overlapping updates
  add animation work; prefer compositor-side
  `contentTransition(.numericText())`, matching `LiquidLiveHR`.

### P5 - Oura Live-HR Re-Engage Policy

Status: deferred / not changed.

Baseline source: `Strand/BLE/OuraLiveSource.swift:307-310,481,698-715`.

Symptom: after the ring's roughly 20-second live-HR auto-revert, NOOP re-sends
enable and subscribe every 15 seconds from stream start until disconnect,
without a visible-live-surface gate.

Impact: an adopted ring can be held in live-HR mode for the full connected
period, defeating the ring's power-saving fallback and waking the phone on the
re-engage cadence.

Recommended remediation: gate re-engagement on a visible live-HR owner; when
there is no such owner, stop the loop and use history-fetch-only behavior.

### P6 - HealthKit Foreground Catch-Up

Status: deferred / not changed.

Baseline sources: `StrandiOS/Health/HealthKitBridge.swift:211-213,425-488` and
`StrandiOS/App/StrandiOSApp.swift:158`.

Symptom: foregrounding calls the default 30-day `sync()` rather than the
existing seven-day `foregroundCatchUp()`. The sync runs 14 statistics queries
plus sleep/workout work and can delete and save up to roughly 56 write-back
samples even when values are unchanged.

Impact: foreground and observer-driven syncs perform broader HealthKit query
and write work than the catch-up path requires.

Recommended remediation: call `foregroundCatchUp()` from the scene-phase path,
diff against the last written values, and rewrite only changed rows.

### P7 - Full-History Dashboard Refresh

Status: deferred / not changed.

Baseline source: `Strand/Data/Repository.swift:667-741`.

Symptom: `refresh(days: 4000)` reads roughly 11 years at launch, after
`analyzeRecent`, and after sleep, nap, or workout edits. The merge is
single-flighted, off-main, and diff-guarded, but it still reads and republishes
large history arrays.

Impact: repeated full-history I/O and large-array comparisons add avoidable
work to common refresh paths.

Recommended remediation: keep the dashboard cache to a recent window of about
400 days, lazy-load deep history where required, and use smaller post-edit
windows such as the existing `refresh(days: 120)` backfill path.

### P8 - Miscellaneous BLE and Snapshot Work

Status: deferred / not changed.

- `Strand/BLE/BLEManager.swift:2169-2174`: the 120-second liveness fuse could
  recycle a healthy but quiet WHOOP4 link through disconnect, scan, re-bond, and
  backfill. That costs radio and catch-up work; distinguish a quiet healthy
  standard-HR link before forcing a reconnect.
- `StrandiOS/Widgets/WidgetPublish.swift:43-46` and
  `Strand/Data/WatchSessionBridge.swift:75-88,150`: widget/watch snapshot builds
  read a 4,000-day `exploreSeries` before their spacing gates. This pays deep
  history I/O for updates that may be discarded; check the gate first and read
  only the anchor day's row.
- `Strand/BLE/BLEManager.swift:502-503`: `uploadTimer` was declared but never
  started. Dead timer state increases maintenance ambiguity; remove it or wire
  it only if a current upload policy requires it.
- `Strand/BLE/BLEManager.swift:3352-3358`: WHOOP4 subscribed to the 0x2A19
  battery characteristic even though that path returned a known constant-100
  stub. The subscription cannot provide useful battery data; skip it for
  `.whoop4` until a real value is supported.

## Integrated Verification Summary

Verification was run after `xcodegen generate`.

- Full macOS tests:
  `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -resultBundlePath .superpowers/sdd/verification/macos-full.xcresult test`
  executed 877 tests: 874 passed, 1 skipped, 2 failed. The only failures were
  the accepted baseline `TodayExplainabilityTests` localization-key failures:
  `testScoreState_carryWithinCap_isFreshLastNight` and
  `testScoreState_staleCarry_relabelsLatestSleep`.
- macOS build:
  `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' build`
  succeeded.
- Generic iOS scheme build:
  `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  stopped at the known watchOS runtime blocker: the scheme embeds a Watch app
  and requires watchOS 26.2.
- Direct iOS target fallback:
  `xcodebuild -project Strand.xcodeproj -target NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  stopped in the existing `swift-markdown-ui` dependency because `MarkdownUI`
  could not resolve module `NetworkImage`.
- Focused ActivityKit iOS 17 typecheck:
  `xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios17.0 -module-name LiveActivityCheck Strand/System/LiveActivityUpdatePolicy.swift StrandiOSShared/LiveActivityAttributes.swift StrandiOS/Widgets/LiveActivityController.swift`
  passed.
- Device visibility:
  `xcrun xctrace list devices` showed `Jot's iPhone (26.5)`
  (`00008140-001064C83ED3001C`), but no real-device behavioral checklist item
  is claimed as passed because the scheme build still stops at the watchOS 26.2
  requirement.
