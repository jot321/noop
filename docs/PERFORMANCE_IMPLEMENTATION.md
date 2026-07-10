# Performance Implementation and Verification

Branch: `agent/high-impact-performance`

Worktree: `/Users/jotsarup/Desktop/experiments/noop-performance-worktree`

Baseline tag: `performance-baseline-2026-07-10`

Baseline commit: `1e49b86`

Accepted implementation head before Task 5: `0444aa5`

This document records the implemented U1-U5/P1-P4 behavior from
[PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md), the verification evidence,
and rollback guidance for the integrated branch.

## Recorded Milestones and Authoritative Inventory

The milestones below record the implementation sequence through the initial
Task 5 verification documentation. This is intentionally not a complete,
self-referential inventory of `HEAD`:

- `33428f1` - Document high-impact performance design
- `ebe8d00` - Document high-impact performance implementation plan
- `aa05711` - Reduce Live screen render churn
- `38fbe5b` - Scroll Live log to newest row on open
- `c0e40cb` - Coalesce hot-path state persistence
- `88076c8` - Fix Task 2 persistence review findings
- `0ca6d25` - Derive realtime BLE demand from explicit owners
- `652a9e5` - Fix realtime sent-state reconciliation
- `ff70856` - Respect realtime BLE write readiness
- `700bcbb` - Throttle passive Live Activity updates
- `1fc2c47` - Fix Live Activity end race and preference updates
- `0444aa5` - Prevent Live Activity ended-handle re-adoption
- `cb70fce` - Document performance changes and verification

Later documentation-only corrections, including corrections to this section,
are intentionally discovered from Git rather than hard-coded into the document.
The authoritative inventory of every current branch commit after the baseline is:

```bash
git log performance-baseline-2026-07-10..HEAD
```

## Subsystem Behavior

### Live Screen and Log

`LiveView` now separates low-frequency root layout inputs from high-frequency
BLE data. `LiveScreenSnapshot` is equatable and contains connection/bond state,
guidance text, standard-HR mode, active-workout presence, last-workout summary,
active device name, HR max, and backfill state. It intentionally excludes HR,
R-R, frame, event, log, visible-log, and BPM values. Leaf views continue to
observe the objects they actually render. `LiveView` installs SwiftUI's
`.equatable()` boundary around `LiveScreenContent`, so the snapshot equality is
used by the production host rather than existing only as an unused conformance.

`LiveState` still retains the full diagnostic log for export, while
`visibleLog` projects the newest 200 rows with monotonic IDs. The UI renders
that projection lazily and scrolls by `newestVisibleLogID`. Copy and Save still
use `exportableLogText()` so exported logs are not limited to the 200 visible
rows.

### Workout Persistence

`ActiveWorkoutRuntime` accepts at most one HR sample per Unix second and keeps
sample count, BPM sum, rounded average, peak BPM, and strain cadence state in
memory. Restored samples seed the same accumulator values as a fresh run.

`ActiveWorkoutPersistenceCoordinator` synchronously dispatches the initial
encode/store to its serial utility queue, so `start` returns only after the
snapshot is durable. Normal updates coalesce to the production interval of 15
seconds. Flush writes the newest snapshot immediately, and `finishAndClear()`
invalidates pending delayed work before clearing the key so stale queued writes
cannot recreate an ended session.

Realtime ownership follows the workout rather than the workout sheet. A
successfully started or restored workout acquires `.workout`; ending or
discarding releases it once before final persistence. Dismissing the sheet only
releases the view-scoped screen-idle assertion.

### Log Tail Persistence

`LogTailPersistence` owns the persisted diagnostic tail. It caps persisted
state at 2,000 lines and writes at the production interval of five seconds.
`flush()` writes the newest dirty state immediately; clean flushes are no-ops.
`persistedTail()` flushes before returning so scheduled exports include the
latest lines.

### Stress Persistence

Stress evaluation consumes the supplied R-R packet once through
`StressRRPacketWindow`. HR-only publications no longer replay the last R-R
packet into the detector.

`StressStatePersistence` persists replay-safety edges immediately when
`wasBelow` or `lastFireAt` changes. Baseline-only changes coalesce to the
production interval of 60 seconds. The real master/auto-nudge preference edge
invalidates delayed baseline work synchronously; disabled and unchanged states
write nothing, and a later re-enable can schedule fresh state.

### Reconnect and Realtime Ownership

The active strap UUID remains persisted by the existing registry path. The P1
fix handles the late startup race: if a valid preferred UUID is applied while an
ordinary automatic scan is already active, `BLEManager` cancels scan fallback,
retrieves the preferred peripheral, and redirects to targeted reconnect.
That late redirect discovers both WHOOP primary service families, infers the
actual family from the returned services, and configures the model, framing,
router, collector, and rated-hours state before characteristic discovery.
Presentation scans, state restoration, connected links, bond-loop pause, stale
family recovery, and first-time no-pin pairing are preserved.

Realtime ownership is explicit:

| Owner | Toggle demand | WHOOP4 R10/R11 heavy demand | Background behavior |
| --- | --- | --- | --- |
| Live screen | Yes in foreground | Yes in foreground unless marginal-radio fallback suppresses heavy | Suppressed when app backgrounds |
| Workout | Yes | Yes unless marginal-radio fallback suppresses heavy | Preserved in background |
| Live session | Yes | Yes unless marginal-radio fallback suppresses heavy | Preserved in background |
| Manual control | Yes | Yes unless marginal-radio fallback suppresses heavy | Preserved in background |
| Passive continuous HRV | Yes inside its policy window | No | Preserved only as lightweight toggle demand |

WHOOP5/MG never requests WHOOP4 R10/R11. It uses the puffin realtime toggle for
live/workout/session/background capture.

`RealtimeCommandSentState` records command state only when writes are actually
queued. Backpressure from `canSendWriteWithoutResponse == false` blocks the
write plan without advancing sent-state, so later readiness can retry the same
wanted start or stop. WHOOP4 heavy sent-state starts unknown after connection,
disconnect, and family transition; therefore passive desired state still emits
a stop until a successful write records `false`. WHOOP5/MG clears and ignores
that WHOOP4-only state.

### Live Activity

`LiveActivityUpdatePolicy` is pure and tested without ActivityKit:

- start immediately when enabled, connected, and a valid HR is available;
- active Live/workout/session experience minimum interval: two seconds;
- passive connected wear minimum interval: 30 seconds;
- disconnect: end immediately, bypassing cadence throttles; the disconnect path
  separately tears down the BLE connection and live biometric streams;
- Live Activity opt-out: end only the Live Activity immediately. BLE connection,
  standard HR/R-R, and realtime owner policy remain unchanged.

Active cadence uses scene-effective owners: a backgrounded Live-screen-only
owner is excluded, while workout, live-session, and manual owners remain
active.

`LiveActivityController` gates expensive score lookup behind policy decisions,
caches `ActivityAuthorizationInfo`, avoids concurrent duplicate starts, and
tracks pending/active/completed end targets so ActivityKit list lag cannot
re-adopt a handle that has already begun or completed ending. Terminal handling
unions the cached handle with ActivityKit enumeration before clearing it and
uses bounded, duplicate-suppressed hydration retries when neither source has a
target; a later valid state cancels an unstarted retry.

Standard-HR publication applies a valid packet HR before its R-R intervals, so
the R-R subscriber sees the matching HR; invalid packet HR leaves the prior
value intact. On disconnect, the connected-state edge is emitted after final
synchronous diagnostics and reconnect scheduling, making the existing
performance-state observer flush the final log tail once without duplicating
workout or stress flush work.

## Persistence Intervals and Flush Boundaries

| State | Production interval | Immediate writes | Flush boundaries |
| --- | ---: | --- | --- |
| Active workout snapshot | 15 seconds | Workout start; final clear on end | `AppModel.flushPerformanceState()`, background/inactive lifecycle, BLE disconnect, best-effort termination |
| Strap log tail | 5 seconds | Explicit flush when dirty | `AppModel.flushPerformanceState()`, `LiveState.persistedLogTail()`, scheduled debug export, lifecycle/termination observers |
| Stress detector state | 60 seconds for baseline-only changes | `wasBelow` or `lastFireAt` transitions | `AppModel.flushPerformanceState()`, lifecycle/termination observers |
| Live Activity active update | 2-second minimum | Start and immediate end | Driven by valid HR/connectivity events |
| Live Activity passive update | 30-second minimum | Start and immediate end | Driven by valid HR/connectivity events |

`AppModel.flushPerformanceState()` flushes active workout, persisted log tail,
and stress state. It is called from iOS/macOS lifecycle handlers, disconnect
paths, termination observers, and scheduled debug export preparation.

## Owner Matrix

| Scenario | BLE connection | Standard HR/R-R | WHOOP4 R10/R11 | WHOOP5/MG puffin toggle | Live Activity cadence |
| --- | --- | --- | --- | --- | --- |
| Live screen foreground | Kept | Kept | Armed | Armed | Active, 2-second floor |
| Live screen backgrounded with no other owner | Kept | Kept | Dropped | Dropped unless another owner/passive capture wants toggle | Passive or ended based on connectivity/preference |
| Active workout | Kept | Kept | Armed | Armed | Active, 2-second floor |
| Live session runner | Kept | Kept | Armed | Armed | Active, 2-second floor |
| Passive continuous HRV only | Kept | Kept | Not armed | Toggle only | Passive, 30-second floor |
| BLE disconnect | Dropped | Dropped | Dropped | Dropped | Immediate end |
| Live Activity opt-out | Unchanged | Unchanged | Unchanged; follows realtime owners | Unchanged; follows realtime owners/passive policy | Immediate end only |

## Verification Evidence

Regeneration:

```bash
xcodegen generate
git status --short
```

Final fix result: XcodeGen completed. `Strand.xcodeproj/project.pbxproj` is
ignored by `.gitignore`; regeneration introduced no new tracked file, and no
generated reference diff was staged.

Final fix focused GREEN evidence: workout ownership lifecycle 3/3; Live
snapshot/equality and scene-effective demand 5/5; preferred redirect 11/11;
realtime demand/sent-state 25/25; Live Activity policy/reconciliation 18/18;
workout persistence 15/15; stress persistence 11/11; standard-HR publication
8/8; log-tail/disconnect ordering 11/11; and the supporting workout,
continuous-HRV, marginal-radio, and bond-loop group 45/45.

Full macOS suite:

```bash
xcodebuild -quiet -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' \
  -resultBundlePath .superpowers/sdd/verification/final-fix-macos-full.xcresult \
  test CODE_SIGNING_ALLOWED=NO
```

Result bundle:
`/Users/jotsarup/Desktop/experiments/noop-performance-worktree/.superpowers/sdd/verification/final-fix-macos-full.xcresult`

Final fix result: 904 total tests, 901 passed, 1 skipped, 2 failed. The skip was
`XiaomiImporterIntegrationTests.testRealExportRoundTripsIntoStore`, which still
requires `XIAOMI_REAL_DB`. The two failures match the accepted baseline
exceptions:

- `TodayExplainabilityTests/testScoreState_carryWithinCap_isFreshLastNight()`
- `TodayExplainabilityTests/testScoreState_staleCarry_relabelsLatestSleep()`

Both are `LocalizedStringKey` formatting-representation assertions under this
Xcode toolchain and were already present at the baseline tag. The branch added
new passing tests and introduced no failures beyond those two.

macOS build:

```bash
xcodebuild -quiet -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Result: passed with `** BUILD SUCCEEDED **`.

Generic iOS scheme build:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Result: blocked before build by the known watch runtime requirement:
`This scheme builds an embedded Apple Watch app. watchOS 26.2 must be installed
in order to run the scheme`.

The final fix wave did not rerun this known-blocked command.

Direct iOS app-target fallback:

```bash
xcodebuild -project Strand.xcodeproj -target NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Result: blocked in the existing package dependency path:
`DefaultImageProvider.swift:1:8: error: Unable to find module dependency:
'NetworkImage'`, followed by `SwiftDriver MarkdownUI normal arm64 ... (in
target 'MarkdownUI' from project 'swift-markdown-ui')`.

The final fix wave did not rerun this known-blocked fallback.

Focused ActivityKit iOS 17 typecheck:

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios17.0 \
  -module-name LiveActivityCheck \
  Strand/System/LiveActivityUpdatePolicy.swift \
  StrandiOSShared/LiveActivityAttributes.swift \
  StrandiOS/Widgets/LiveActivityController.swift
```

Result: passed with no diagnostics.

Device listing:

```bash
xcrun xctrace list devices
```

Result: the connected phone was visible:
`Jot's iPhone (26.5) (00008140-001064C83ED3001C)`.

Device build attempt:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'id=00008140-001064C83ED3001C' CODE_SIGNING_ALLOWED=NO build
```

Result: blocked by the same scheme-level watchOS 26.2 requirement before any
device install or manual behavior verification.

The final fix wave did not rerun device listing or this known-blocked build, and
does not claim a physical-device check.

Diff hygiene:

```bash
git diff --check performance-baseline-2026-07-10..HEAD
```

Task 5 records the final command result in
`.superpowers/sdd/task-5-report.md`.

## Remaining Hardware and iOS Gaps

No real-device behavioral checklist item is claimed as passed in Task 5. The
connected iPhone is visible, but the `NOOPiOS` scheme cannot build in this
environment until the watchOS 26.2 runtime blocker is resolved or a no-watch
build route is provided without modifying `agent/local-iphone-setup` or exposing
signing secrets.

Pending real-device checks:

- Live HR appears and leaving/re-entering Live arms/disarms correctly.
- Start/end workout records one sample per second and survives
  background/foreground.
- A Live-screen-only WHOOP4 stream drops heavy demand on background while
  workout/session owners continue.
- Continuous HRV does not arm WHOOP4 R10/R11 by itself.
- Disconnect/reconnect and late registry load reconnect to the selected strap.
- Live Activity updates rapidly in active use, slowly in passive wear, and ends
  immediately on disconnect.
- Copy/Save includes the full retained strap log while the card shows only 200
  rows.

## Rollback Guidance

Do not discard local work to inspect or roll back this branch. First inspect the
baseline in a separate worktree, using an unused destination path:

```bash
git status --short
git worktree add --detach ../noop-performance-baseline-inspection performance-baseline-2026-07-10
```

The added worktree is a non-destructive baseline checkout; it does not move or
rewrite the performance branch. Before any revert, require a clean status and
create a backup ref. Commit, stash, or otherwise back up any local work before
continuing; none of the commands below should be used to discard it.

```bash
test -z "$(git status --porcelain)" || {
  echo "Stop: back up local work and restore a clean worktree before rollback."
  exit 1
}
backup_branch="backup/performance-before-rollback-$(date +%Y%m%d-%H%M%S)"
git branch "$backup_branch"
```

For a full branch rollback, create a separate rollback branch and revert every
commit currently after the baseline. `git rev-list` supplies the complete
newest-first sequence at execution time, so it includes `cb70fce` and all later
documentation corrections without requiring this document to name its own
commit:

```bash
rollback_branch="rollback/performance-to-baseline-$(date +%Y%m%d-%H%M%S)"
git switch -c "$rollback_branch"
git revert --no-edit $(git rev-list performance-baseline-2026-07-10..HEAD)
```

If a revert conflicts, stop and inspect it. Use `git revert --continue` only
after a deliberate resolution, or `git revert --abort` to abandon the active
sequence. The backup ref and separate rollback branch preserve the accepted
branch state without commands that erase working-tree changes.

Only the full dynamic rollback above is verified and supported automatically.
The implementation commits cross subsystem boundaries and later fixes depend
on earlier types and behavior; reverting a listed group in isolation can leave
the branch uncompilable or behaviorally inconsistent.

For subsystem investigation only, inspect the path-scoped history:

```bash
git log --oneline performance-baseline-2026-07-10..HEAD -- \
  Strand StrandTests StrandiOS \
  docs/PERFORMANCE_ANALYSIS.md \
  docs/PERFORMANCE_IMPLEMENTATION.md \
  docs/superpowers/specs/2026-07-10-high-impact-performance-design.md \
  docs/superpowers/plans/2026-07-10-high-impact-performance.md
```

This command is inspection-only, not a supported revert recipe. Any partial
rollback requires manual dependency integration and its own build/test review.
The full-branch command above remains the authoritative dynamic sequence when
the intent is to remove every change after the baseline.

After any partial revert, rerun `xcodegen generate`, the relevant focused tests,
the full macOS suite, and the macOS/iOS build checks described above.
