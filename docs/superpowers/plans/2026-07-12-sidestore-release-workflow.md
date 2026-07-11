# SideStore Release Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Commit the current NOOP work, build and install SideStore-managed iOS build 174 without losing the WHOOP database, push `dev`, and document the exact repeatable process.

**Architecture:** Treat `project.yml` as the build source of truth and SideStore as the final signer/installer. Keep health data in the iOS app container, keep the approved AWS plist ignored but bundle it into this personal IPA, and bracket the upgrade with read-only container snapshots and SQLite checks.

**Tech Stack:** Swift 6, Swift Package Manager, XcodeGen, Xcode 26, `xcodebuild`, `xcrun devicectl`, SideStore 0.6.3, LocalDevVPN, SQLite, Git, and GitHub CLI.

## Global Constraints

- Work on the existing `dev` branch and push directly to `origin/dev`.
- Keep `StrandiOS/Resources/CloudSyncSecrets.plist` ignored and never print or commit its values.
- Build number 174 must be shared by the iOS app and widget extension.
- The IPA's source bundle identifier is `com.jotsarup.noop`; SideStore's installed identifier is expected to remain `com.jotsarup.noop.B6925R5WYB`.
- Never commit copied device containers, SQLite files, provisioning profiles, pairing files, or private health data.
- Do not delete the installed NOOP before a verified pre-upgrade backup exists.
- A live UI value does not prove persistence; require SQLite integrity plus non-regressing counts and check for a fresh live-stream timestamp.

---

### Task 1: Verify and commit the current application changes

**Files:**
- Modify/commit: `.gitignore`
- Modify/commit: `Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift`
- Modify/commit: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/DaytimeStressTests.swift`
- Create/commit: `Strand/Cloud/CloudSyncProvisioning.swift`
- Modify/commit: `Strand/Liquid/LiquidCore.swift`
- Modify/commit: `Strand/Liquid/LiquidPrimitives.swift`
- Modify/commit: `Strand/Liquid/LiquidSky.swift`
- Modify/commit: `Strand/Liquid/LiquidTodayView.swift`
- Modify/commit: `Strand/Screens/SleepAnalyticsCard.swift`
- Modify/commit: `Strand/Screens/TodayView.swift`
- Modify/commit: `StrandiOS/App/RootTabView.swift`
- Modify/commit: `StrandiOS/App/StrandiOSApp.swift`
- Create/commit: `StrandiOS/Resources/CloudSyncSecrets.example.plist`
- Create/commit: `Tools/analyze_data.py`
- Modify/commit: `project.yml`

**Interfaces:**
- Consumes: the user's complete current worktree diff and the ignored personal cloud plist.
- Produces: one reviewed commit containing only the current app/analytics/tooling changes.

- [ ] **Step 1: Verify the real cloud plist is present and ignored without printing values**

Run:

```bash
test -f StrandiOS/Resources/CloudSyncSecrets.plist
git check-ignore -q StrandiOS/Resources/CloudSyncSecrets.plist
plutil -lint StrandiOS/Resources/CloudSyncSecrets.plist
```

Expected: all commands exit 0 and the file remains absent from `git status --short`.

- [ ] **Step 2: Run focused analytics and tooling checks**

Run:

```bash
swift test --package-path Packages/StrandAnalytics
python3 -m py_compile Tools/analyze_data.py
python3 Tools/analyze_data.py --help >/dev/null
git diff --check
```

Expected: Swift tests pass with zero failures; Python compilation/help and diff checks exit 0.

- [ ] **Step 3: Compile the complete iOS source graph before committing**

Run:

```bash
xcodegen generate
rm -rf build/precommit-ios-dd
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/precommit-ios-dd \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Stage only the intended application files**

Run `git add` with the 15 explicit paths listed under **Files**, then run:

```bash
git diff --cached --check
git diff --cached --stat
git status --short
```

Expected: the cache contains the current application diff only; the design and implementation-plan documents are not included in this commit.

- [ ] **Step 5: Commit the application work**

Run:

```bash
git commit -m "Improve stress, sleep, scrolling, and cloud sync"
```

Expected: commit succeeds and the ignored real cloud plist is absent from the commit.

---

### Task 2: Create and commit build 174

**Files:**
- Modify: `project.yml`

**Interfaces:**
- Consumes: committed build 173 source.
- Produces: shared app/widget build number 174.

- [ ] **Step 1: Change only the shared build number**

Change:

```yaml
CURRENT_PROJECT_VERSION: "173"
```

to:

```yaml
CURRENT_PROJECT_VERSION: "174"
```

- [ ] **Step 2: Verify and commit the bump**

Run:

```bash
git diff --check -- project.yml
git diff -- project.yml
git add project.yml
git commit -m "Bump iOS build to 174"
```

Expected: the commit changes only the build-number line.

---

### Task 3: Build and validate the personal SideStore IPA

**Files:**
- Generated: `Strand.xcodeproj/*` (ignored)
- Generated: `build/sidestore-174-dd/Build/Products/Release-iphoneos/NOOP.app`
- Generated: `/Users/jotsarup/Desktop/experiments/noop_diagnostics/sidestore/NOOP-174.ipa`

**Interfaces:**
- Consumes: committed build 174 source and the ignored personal cloud plist.
- Produces: a structurally valid Release IPA ready for SideStore.

- [ ] **Step 1: Regenerate and run fresh release verification**

Run:

```bash
xcodegen generate
swift test --package-path Packages/StrandAnalytics
rm -rf build/sidestore-174-dd build/sidestore-174-stage
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/sidestore-174-dd \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: tests pass and the Release build prints `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Verify app, widget, and approved cloud resource**

Run checks against `build/sidestore-174-dd/Build/Products/Release-iphoneos/NOOP.app`:

```bash
APP=build/sidestore-174-dd/Build/Products/Release-iphoneos/NOOP.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")" = 174
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")" = com.jotsarup.noop
WIDGET=$(find "$APP/PlugIns" -name '*.appex' -maxdepth 2 -print -quit)
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WIDGET/Info.plist")" = 174
test -f "$APP/CloudSyncSecrets.plist"
cmp -s StrandiOS/Resources/CloudSyncSecrets.plist "$APP/CloudSyncSecrets.plist"
```

Expected: every command exits 0; no secret value is printed.

- [ ] **Step 3: Package and validate the IPA**

Run:

```bash
APP=build/sidestore-174-dd/Build/Products/Release-iphoneos/NOOP.app
STAGE=build/sidestore-174-stage
IPA=/Users/jotsarup/Desktop/experiments/noop_diagnostics/sidestore/NOOP-174.ipa
rm -rf "$STAGE" "$IPA"
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/NOOP.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE/Payload" "$IPA"
unzip -t "$IPA"
shasum -a 256 "$IPA"
```

Expected: no archive errors and a recorded SHA-256 digest.

---

### Task 4: Back up and upgrade the SideStore-managed app

**Files:**
- Generated outside Git: `/Users/jotsarup/Desktop/experiments/noop_diagnostics/2026-07-12-pre-build-174/Library`
- Generated outside Git: `/Users/jotsarup/Desktop/experiments/noop_diagnostics/2026-07-12-post-build-174/Library`

**Interfaces:**
- Consumes: connected iPhone, LocalDevVPN, SideStore, and `NOOP-174.ipa`.
- Produces: one SideStore-managed build 174 with preserved app data.

- [ ] **Step 1: Discover current device and bundle state**

Run:

```bash
xcrun devicectl list devices
xcrun devicectl device info apps --device <DEVICE_ID>
```

Expected: the paired iPhone is available and exactly one SideStore-managed NOOP build 173 is installed.

- [ ] **Step 2: Create and verify the pre-upgrade container snapshot**

Copy `Library` from `com.jotsarup.noop.B6925R5WYB`, then run on the copied database:

```bash
sqlite3 -readonly "$DB" 'PRAGMA quick_check;'
sqlite3 -readonly "$DB" "SELECT 'hrSample',COUNT(*),MAX(ts) FROM hrSample UNION ALL SELECT 'rrInterval',COUNT(*),MAX(ts) FROM rrInterval UNION ALL SELECT 'sleepSession',COUNT(*),MAX(endTs) FROM sleepSession UNION ALL SELECT 'dailyMetric',COUNT(*),MAX(day) FROM dailyMetric;"
```

Expected: `ok`, with counts/timestamps recorded before installation.

- [ ] **Step 3: Deliver build 174 through SideStore**

Start a temporary local HTTP server in the IPA directory, then launch SideStore with:

```text
sidestore://install?url=http%3A%2F%2F<MAC_LAN_IP>%3A8765%2FNOOP-174.ipa
```

Expected: the phone downloads the IPA and SideStore reports installation success. Stop the temporary server afterward.

- [ ] **Step 4: Verify installed state and preserved data**

Run:

```bash
xcrun devicectl device info apps --device <DEVICE_ID>
xcrun devicectl device process launch --device <DEVICE_ID> \
  --terminate-existing com.jotsarup.noop.B6925R5WYB
```

Then copy the post-install `Library` and repeat the SQLite queries from Step 2.

Expected: one NOOP build 174, database `quick_check` is `ok`, and no table count regresses.

- [ ] **Step 5: Verify live persistence or record the remaining gap**

Leave NOOP running with Bluetooth allowed, take a second post-launch snapshot, and compare `MAX(ts)`/counts for `hrSample` and `rrInterval`.

Expected: at least one live stream advances. If neither advances while the UI is live, preserve the working build and report that persistence remains unverified rather than claiming success.

---

### Task 5: Write the durable release guide and publish `dev`

**Files:**
- Create: `docs/SIDESTORE_RELEASE.md`
- Commit: `docs/superpowers/specs/2026-07-12-sidestore-release-workflow-design.md`
- Commit: `docs/superpowers/plans/2026-07-12-sidestore-release-workflow.md`

**Interfaces:**
- Consumes: commands and evidence from Tasks 1-4.
- Produces: a secret-free operator guide and a pushed `origin/dev` branch.

- [ ] **Step 1: Write the guide from the verified workflow**

Create `docs/SIDESTORE_RELEASE.md` with these exact top-level sections:

```markdown
# SideStore Release and Upgrade Guide

## Safety model
## One-time prerequisites
## Secret handling
## Prepare a new build
## Test and build the Release app
## Package and verify the IPA
## Back up the current phone container
## Install through SideStore
## Verify the upgrade and live persistence
## Rollback
## Future-release checklist
```

Under each section, use the verified commands from Tasks 1-4. Use placeholders such as `<DEVICE_ID>` and `<MAC_LAN_IP>` only for values that change per machine/session; do not include private plist values or health data. The rollback section must restore `Library` only after stopping NOOP, then re-run `PRAGMA quick_check` before launch.

- [ ] **Step 2: Verify documentation and repository safety**

Run:

```bash
! rg -n 'AKIA[0-9A-Z]|PASTE_YOUR_SCOPED_IAM_SECRET_HERE' docs/SIDESTORE_RELEASE.md docs/superpowers/specs/2026-07-12-sidestore-release-workflow-design.md docs/superpowers/plans/2026-07-12-sidestore-release-workflow.md
git diff --check
git status --short
```

Expected: no secrets or whitespace errors; only the intended documentation remains uncommitted.

- [ ] **Step 3: Commit the guide and plan**

Run:

```bash
git add docs/SIDESTORE_RELEASE.md \
  docs/superpowers/plans/2026-07-12-sidestore-release-workflow.md
git commit -m "Document SideStore release workflow"
```

The already-committed design document remains a separate earlier commit.

- [ ] **Step 4: Run final verification from the committed tree**

Run:

```bash
swift test --package-path Packages/StrandAnalytics
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/final-174-dd \
  CODE_SIGNING_ALLOWED=NO build
git status -sb
git log -5 --oneline --decorate
```

Expected: tests and build pass; the tree is clean except for ignored/generated outputs; commits are in the intended order.

- [ ] **Step 5: Push the canonical branch**

Run:

```bash
git push -u origin dev
git status -sb
git ls-remote --heads origin dev
```

Expected: `origin/dev` points to the final local commit and the branch is no longer ahead.
