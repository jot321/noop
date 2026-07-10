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
wear, and end immediately on disconnect or opt-out. Follow-up fixes prevent end
race re-adoption and preserve newer push state when old ActivityKit handles
finish ending.

Tests: `LiveActivityUpdatePolicyTests` and the focused iOS 17 ActivityKit
typecheck recorded in the implementation document.

Commits: `700bcbb`, `1fc2c47`, and `0444aa5`.

## Deferred Findings

The branch intentionally implements U1-U5 and P1-P4 only. These audit items
remain out of scope for this branch: liquid animation idling, classic Today
hint/root work, pull-to-refresh isolation, BreathingView timer behavior, Oura
live-HR re-engage policy, HealthKit foreground catch-up, repository history
window reduction, widget/watch deep-history reads, and miscellaneous lower-risk
cleanups from the original report.

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
