# SideStore Release and Upgrade Guide

This guide builds a personal NOOP `.ipa`, upgrades the existing SideStore-managed installation, and verifies that its on-device database survived. Run commands from the repository root.

## Safety model

- Upgrade the existing SideStore app; do not delete it first. Its SideStore-suffixed bundle identifier owns the data container.
- Copy and validate `Library` before every upgrade.
- Keep device snapshots, IPAs, pairing files, and health databases outside Git.
- A live number on screen is not proof that data is being persisted. Verify SQLite integrity, row counts, and newest timestamps after launch.
- Stop if the installed bundle identifier changes unexpectedly. Installing under a different identifier creates a different container.

The examples use these variables:

```bash
DEVICE_ID='<DEVICE_ID>'
NOOP_BUNDLE_ID='<NOOP_SIDESTORE_BUNDLE_ID>'
SIDESTORE_BUNDLE_ID='<SIDESTORE_BUNDLE_ID>'
BUILD='<NEW_BUILD_NUMBER>'
DIAGNOSTICS='/Users/jotsarup/Desktop/experiments/noop_diagnostics'
```

Discover current values instead of copying old ones:

```bash
xcrun devicectl list devices
xcrun devicectl device info apps --device "$DEVICE_ID"
```

## One-time prerequisites

- Xcode command-line tools and XcodeGen are installed.
- SideStore is installed and signed on the iPhone.
- The SideStore pairing file is configured.
- LocalDevVPN is connected when SideStore signs, refreshes, or installs an app.
- The Mac and iPhone are on the same local network for the temporary HTTP transfer used below.
- Developer Mode is enabled on the iPhone.

Confirm the local build tools:

```bash
xcodebuild -version
xcodegen --version
swift --version
```

## Secret handling

The personal build may use `StrandiOS/Resources/CloudSyncSecrets.plist`. This file must remain ignored and must never be staged, committed, logged, or pasted into documentation.

```bash
test -f StrandiOS/Resources/CloudSyncSecrets.plist
git check-ignore -q StrandiOS/Resources/CloudSyncSecrets.plist
plutil -lint StrandiOS/Resources/CloudSyncSecrets.plist
! git ls-files --error-unmatch StrandiOS/Resources/CloudSyncSecrets.plist 2>/dev/null
```

The values are intentionally bundled into this approved personal IPA. Anyone who obtains the IPA can extract them, so keep the IPA private and rotate the credentials if it leaks.

## Prepare a new build

Start from a clean, current `dev` branch. Commit application changes before building.

```bash
git switch dev
git status --short
git pull --ff-only
```

Increment `CURRENT_PROJECT_VERSION` in `project.yml`. The shared setting updates both the app and widget. Keep `MARKETING_VERSION` unchanged unless this is a user-facing version change.

```bash
git diff --check
git add project.yml
git commit -m "Bump iOS build to $BUILD"
```

Never reuse an installed build number.

## Test and build the Release app

```bash
python3 -m py_compile Tools/analyze_data.py
python3 Tools/analyze_data.py --help >/dev/null
swift test --package-path Packages/StrandAnalytics
xcodegen generate

DERIVED_DATA="build/sidestore-$BUILD-dd"
rm -rf "$DERIVED_DATA"
xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Validate the generated product without printing secret values:

```bash
APP="$DERIVED_DATA/Build/Products/Release-iphoneos/NOOP.app"
WIDGET=$(find "$APP/PlugIns" -maxdepth 2 -name '*.appex' -print -quit)

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")" = 'com.jotsarup.noop'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")" = "$BUILD"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WIDGET/Info.plist")" = "$BUILD"
test -f "$APP/CloudSyncSecrets.plist"

SOURCE_SECRET_HASH=$(plutil -convert json -o - StrandiOS/Resources/CloudSyncSecrets.plist | jq -S -c . | shasum -a 256 | awk '{print $1}')
BUILT_SECRET_HASH=$(plutil -convert json -o - "$APP/CloudSyncSecrets.plist" | jq -S -c . | shasum -a 256 | awk '{print $1}')
test "$SOURCE_SECRET_HASH" = "$BUILT_SECRET_HASH"
```

Xcode may rewrite a plist's representation while copying it, so compare normalized content rather than raw file bytes.

## Package and verify the IPA

```bash
STAGE="build/sidestore-$BUILD-stage"
IPA="$DIAGNOSTICS/sidestore/NOOP-$BUILD.ipa"

rm -rf "$STAGE" "$IPA"
mkdir -p "$STAGE/Payload" "$(dirname "$IPA")"
ditto "$APP" "$STAGE/Payload/NOOP.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE/Payload" "$IPA"
unzip -tq "$IPA"
shasum -a 256 "$IPA"
```

The archive must contain `Payload/NOOP.app`, the widget extension, and `CloudSyncSecrets.plist`.

## Back up the current phone container

Confirm exactly one SideStore-managed NOOP is installed and record its bundle identifier and build number:

```bash
xcrun devicectl device info apps --device "$DEVICE_ID"
```

Copy its `Library` directory before installing:

```bash
BACKUP="$DIAGNOSTICS/$(date +%F-%H%M%S)-pre-build-$BUILD"
mkdir -p "$BACKUP"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$NOOP_BUNDLE_ID" \
  --source Library \
  --destination "$BACKUP/Library" \
  --timeout 120
```

Locate and validate the copied database:

```bash
DB=$(find "$BACKUP/Library" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) -print -quit)
test -n "$DB"
sqlite3 -readonly "$DB" 'PRAGMA quick_check;'
```

Record the important counts and newest timestamps using the current schema. For the existing NOOP schema:

```bash
sqlite3 -readonly "$DB" \
  "SELECT 'hrSample',COUNT(*),MAX(ts) FROM hrSample
   UNION ALL SELECT 'rrInterval',COUNT(*),MAX(ts) FROM rrInterval
   UNION ALL SELECT 'sleepSession',COUNT(*),MAX(endTs) FROM sleepSession
   UNION ALL SELECT 'dailyMetric',COUNT(*),MAX(day) FROM dailyMetric;"
```

Do not proceed if `PRAGMA quick_check` is not `ok`.

## Install through SideStore

Find the Mac's LAN address and serve only the IPA directory temporarily:

```bash
MAC_LAN_IP=$(ipconfig getifaddr en0)
cd "$DIAGNOSTICS/sidestore"
python3 -m http.server 8765 --bind 0.0.0.0
```

In a second terminal, percent-encode the local IPA URL and launch SideStore:

```bash
ENCODED_URL=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' \
  "http://$MAC_LAN_IP:8765/NOOP-$BUILD.ipa")
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  --payload-url "sidestore://install?url=$ENCODED_URL" \
  "$SIDESTORE_BUNDLE_ID"
```

Keep LocalDevVPN connected. Wait for SideStore to finish signing and installing, and confirm the HTTP server received the phone's request. Then stop the server with Control-C.

When SideStore detects the NOOP widget, it may pause at **App Contains Extensions**. Choose **Keep App Extensions (Register App ID for Each Extension)** to retain the widget with its own registered identifier. This confirmation is required even when the incoming and installed extensions match.

Do not delete NOOP before this step. SideStore must upgrade the existing suffixed bundle identifier to preserve its container.

## Verify the upgrade and live persistence

Confirm the installed build and launch that exact managed bundle:

```bash
xcrun devicectl device info apps --device "$DEVICE_ID"
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  "$NOOP_BUNDLE_ID"
```

Copy another snapshot to a new directory and repeat `PRAGMA quick_check` and the four count queries from the backup section. Every pre-upgrade table count must be preserved or increased.

Leave NOOP open with Bluetooth enabled for 30-60 seconds, take a second post-launch snapshot, and compare `COUNT(*)` plus `MAX(ts)` for `hrSample` and `rrInterval`. At least one should advance before claiming live persistence works. A changing live UI alone is insufficient.

Also verify:

- only one NOOP app is installed;
- its build is `$BUILD`;
- the installed bundle identifier is unchanged;
- SideStore shows the app as active and refreshable;
- cloud provisioning reports success without exposing credentials.

## Rollback

If installation fails, leave the current installation and backup untouched. If the new build launches but data is missing, stop NOOP before restoring:

```bash
xcrun devicectl device process terminate \
  --device "$DEVICE_ID" \
  "$NOOP_BUNDLE_ID"

xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$NOOP_BUNDLE_ID" \
  --source "$BACKUP/Library" \
  --destination Library \
  --remove-existing-content true \
  --timeout 120
```

Copy the restored `Library` back to the Mac, run `PRAGMA quick_check`, and compare its counts with the original backup before relaunching NOOP. If app code must also be rolled back, install the previous private IPA through SideStore without deleting the app.

## Future-release checklist

- [ ] Commit all intended source changes; confirm the real secret plist is ignored and untracked.
- [ ] Increment `CURRENT_PROJECT_VERSION` in `project.yml` for both app and widget.
- [ ] Run Python checks, all StrandAnalytics tests, XcodeGen, and the unsigned Release build.
- [ ] Verify app ID, app/widget build numbers, and normalized embedded secret content.
- [ ] Package the IPA, test the ZIP, and record its SHA-256.
- [ ] Confirm the current SideStore bundle identifiers and installed build.
- [ ] Back up `Library`; require SQLite `quick_check = ok`; record counts/timestamps.
- [ ] Keep LocalDevVPN connected and install the IPA through SideStore.
- [ ] Confirm one upgraded app with the same managed bundle identifier.
- [ ] Re-copy and validate the database; ensure counts do not regress.
- [ ] Verify a live timestamp advances after launch, or explicitly record that persistence is not yet proven.
- [ ] Commit this release's documentation updates and push `dev`.
