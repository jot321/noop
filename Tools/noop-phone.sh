#!/bin/bash
# noop-phone.sh: keep NOOP installed on Jot's iPhone with a free Apple ID, without SideStore.
#
# A free Personal Team profile expires 7 days after it is issued. This script backs up the app's data,
# rebuilds the app with a fresh profile, installs it over the existing app (same bundle ID, so the
# database is kept), and tries to relaunch it. A launchd job runs `auto` a few times a day; it does
# nothing until the profile is close to expiry.
#
# The backup goes through pymobiledevice3 (house_arrest), which works over USB or the same Wi-Fi with
# the phone locked. The install and relaunch use Xcode's devicectl, which installs over a running NOOP
# but needs the developer disk image: that mounts only while the phone is unlocked and then stays
# mounted until the next restart. The build targets generic iOS, so it needs no connected device.
#
# Everything the scheduled job touches lives in ~/.noop-phone, outside ~/Desktop, because macOS
# privacy controls block background jobs from reading Desktop folders.
#
# Commands:
#   install [--allow-dirty]  copy the checkout to ~/.noop-phone/src, then back up, build and install it
#   renew                    back up, rebuild ~/.noop-phone/src unchanged and install it (new profile only)
#   auto                     launchd entry point: renew only when fewer than RENEW_DAYS_LEFT days remain
#   backup                   copy the app's Library to ~/.noop-phone/backups and check the database
#   status                   show the phone, the installed build and the days left
#   setup                    copy this script to ~/.noop-phone/bin and load the launchd job
#
# Settings in ~/.noop-phone/config (shell syntax, kept out of Git): DEVICE_UDID=<the iPhone's UDID>,
# from `uvx pymobiledevice3 usbmux list --simple`.
set -euo pipefail

ROOT="$HOME/.noop-phone"
SRC="$ROOT/src"
DD="$ROOT/dd"
BACKUPS="$ROOT/backups"
LOGS="$ROOT/logs"
STATE="$ROOT/state"
CONFIG="$ROOT/config"
LOCK="$ROOT/.lock"
CHECKOUT="${NOOP_CHECKOUT:-$HOME/Desktop/experiments/noop}"
LABEL="com.jot.noop-phone"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

BUNDLE_ID="com.jotsarup.noop.B6925R5WYB"
SCHEME="NOOPiOS"
CONFIGURATION="Release"
PMD3_VERSION="11.40.1"
RENEW_DAYS_LEFT=3   # auto renews once fewer days than this remain
KEEP_BACKUPS=4      # dated backups kept; folders with a name suffix (e.g. -pre-xcode) are never pruned
DAY_START=9         # auto reinstalls only between these hours (installing stops NOOP, and the
DAY_END=21          # relaunch needs an unlocked phone), unless less than a day remains

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DEVICE_UDID="${DEVICE_UDID:-}"
[ -f "$CONFIG" ] && . "$CONFIG"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

notify() {
  /usr/bin/osascript -e "display notification \"${1//\"/\'}\" with title \"NOOP\"" >/dev/null 2>&1 || true
}

pmd3() { uvx --quiet "pymobiledevice3@$PMD3_VERSION" "$@"; }

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1 || true; }

state_set() {
  touch "$STATE"
  grep -v "^$1=" "$STATE" > "$STATE.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

need_device() { [ -n "$DEVICE_UDID" ] || die "DEVICE_UDID is not set in $CONFIG (see: uvx pymobiledevice3 usbmux list --simple)"; }

# usbmuxd lists the phone when it is cabled, or on the same Wi-Fi with Wi-Fi sync on.
device_reachable() {
  need_device
  local seen; seen=$(pmd3 usbmux list --simple 2>/dev/null || true)
  [[ "$seen" == *"\"$DEVICE_UDID\""* ]]
}

days_left() {
  local exp; exp=$(state_get EXPIRES_AT)
  [ -n "$exp" ] || { echo 0; return; }
  awk -v e="$exp" -v n="$(date +%s)" 'BEGIN { printf "%.1f", (e - n) / 86400 }'
}

with_lock() {
  mkdir "$LOCK" 2>/dev/null || die "another noop-phone run is in progress (remove $LOCK if it is stale)"
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

# Copy the app's Library off the phone and refuse to continue unless the database passes quick_check.
backup() {
  need_device
  mkdir -p "$BACKUPS"
  local dest="$BACKUPS/$(date +%Y-%m-%d-%H%M%S)"
  mkdir -p "$dest"
  log "Backing up $BUNDLE_ID Library to $dest"
  # Copy only the data that matters. Caches, snapshots and saved state can carry complete file
  # protection, which makes AFC refuse the whole Library while the phone is locked (status 10).
  mkdir -p "$dest/Library/Application Support" "$dest/Library/Preferences"
  pmd3 apps pull --udid "$DEVICE_UDID" "$BUNDLE_ID" "/Library/Application Support/OpenWhoop" \
    "$dest/Library/Application Support/" >/dev/null 2>&1 || die "could not copy the database off the phone"
  pmd3 apps pull --udid "$DEVICE_UDID" "$BUNDLE_ID" "/Library/Preferences" "$dest/Library/" >/dev/null 2>&1 ||
    log "Preferences not copied (phone locked?); the database backup is complete"
  pmd3 apps pull --udid "$DEVICE_UDID" "$BUNDLE_ID" "/Library/Application Support/com.noopapp.noop" \
    "$dest/Library/Application Support/" >/dev/null 2>&1 || true   # rejected-frame archive, optional
  local db="$dest/Library/Application Support/OpenWhoop/whoop.sqlite"
  [ -f "$db" ] || die "backup has no whoop.sqlite at $db"
  local check; check=$(sqlite3 -readonly "$db" 'PRAGMA quick_check;' 2>&1 | head -1)
  [ "$check" = "ok" ] || die "backup database failed quick_check: $check"
  sqlite3 -readonly "$db" \
    "SELECT 'hrSample',COUNT(*),datetime(MAX(ts),'unixepoch','localtime') FROM hrSample
     UNION ALL SELECT 'rrInterval',COUNT(*),datetime(MAX(ts),'unixepoch','localtime') FROM rrInterval
     UNION ALL SELECT 'sleepSession',COUNT(*),datetime(MAX(endTs),'unixepoch','localtime') FROM sleepSession
     UNION ALL SELECT 'dailyMetric',COUNT(*),MAX(day) FROM dailyMetric;" > "$dest/counts.txt"
  log "Backup ok: $(tr '\n' ' ' < "$dest/counts.txt")"
  state_set LAST_BACKUP "$dest"
  # Keep the newest KEEP_BACKUPS dated snapshots; older ones go to the Trash, not straight to deletion.
  ls -1d "$BACKUPS"/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | sort |
    awk -v k="$KEEP_BACKUPS" '{ a[NR] = $0 } END { for (i = 1; i <= NR - k; i++) print a[i] }' |
    while read -r old; do /usr/bin/trash "$old" && log "Moved old backup to Trash: $old"; done
}

# Copy the checkout into ~/.noop-phone/src. Only committed work is installed unless --allow-dirty.
sync_source() {
  local allow_dirty="$1"
  [ -d "$CHECKOUT/.git" ] || die "no checkout at $CHECKOUT"
  if [ -n "$(git -C "$CHECKOUT" status --porcelain)" ] && [ "$allow_dirty" != yes ]; then
    die "$CHECKOUT has uncommitted changes; commit them or pass --allow-dirty"
  fi
  mkdir -p "$SRC"
  rsync -a --delete \
    --exclude '.git' --exclude '/build' --exclude '/android' --exclude '/marketing' \
    --exclude '.build' --exclude '.swiftpm' --exclude 'xcuserdata' --exclude '/Strand.xcodeproj' \
    "$CHECKOUT/" "$SRC/"
  local rev; rev=$(git -C "$CHECKOUT" rev-parse --short HEAD)
  [ -n "$(git -C "$CHECKOUT" status --porcelain)" ] && rev="$rev+dirty"
  echo "$rev" > "$SRC/.noop-source"
  log "Source synced from $CHECKOUT at $rev"
}

build() {
  need_device
  [ -d "$SRC" ] || die "no source at $SRC; run install first"
  log "Generating project and building $SCHEME ($CONFIGURATION) from $(cat "$SRC/.noop-source" 2>/dev/null)"
  (cd "$SRC" && xcodegen generate --quiet)
  # Generic iOS needs no connected device, so this works while the phone is locked. Xcode puts every
  # device registered on the team into the new profile; the check below catches a lapsed registration.
  xcodebuild \
    -project "$SRC/Strand.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    -allowProvisioningUpdates \
    -quiet \
    build
  APP="$DD/Build/Products/$CONFIGURATION-iphoneos/NOOP.app"
  [ -d "$APP" ] || die "build produced no app at $APP"
  local id; id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
  [ "$id" = "$BUNDLE_ID" ] || die "built bundle ID is $id, expected $BUNDLE_ID; installing it would create a new, empty app"
  local profile; profile=$(mktemp)
  security cms -D -i "$APP/embedded.mobileprovision" > "$profile" 2>/dev/null
  local devices; devices=$(plutil -extract ProvisionedDevices xml1 -o - "$profile" 2>/dev/null || true)
  if [[ "$devices" != *"<string>$DEVICE_UDID</string>"* ]]; then
    rm -f "$profile"
    die "the new profile does not include this iPhone; unlock it, open Xcode > Devices and Simulators so Xcode registers it again, then run renew"
  fi
  local exp_raw; exp_raw=$(plutil -extract ExpirationDate raw -o - "$profile")
  rm -f "$profile"
  APP_EXPIRES=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp_raw" +%s)
  APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
  log "Built NOOP build $APP_BUILD, profile expires $exp_raw"
}

# Run "$@" but give up after $1 seconds, killing the command and its children (uvx spawns python).
run_with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null ) & local watchdog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true   # reap quietly; bash would otherwise print "Terminated"
  return $rc
}

# pymobiledevice3's installer hangs over a NOOP that has been running: installd waits for the app to
# quit, iOS relaunches it within seconds via Bluetooth state restoration, and the stalled attempt leaves
# a coordinated install that blocks every retry ("scoped to a different process") until NOOP has quit
# and a few seconds pass (seen 2026-10-20). Xcode's devicectl installs over the running app in ~2 s, so
# it is the primary path. It needs the developer disk image, which mounts only while the phone is
# unlocked and then stays mounted until the next restart.
noop_pids() {
  local j; j=$(mktemp)
  if xcrun devicectl device info processes --device "$DEVICE_UDID" --timeout 60 --json-output "$j" >/dev/null 2>&1; then
    /usr/bin/python3 -c '
import json, sys
for p in json.load(open(sys.argv[1]))["result"]["runningProcesses"]:
    if str(p.get("executable", "")).endswith("/NOOP.app/NOOP"):
        print(p["processIdentifier"])
' "$j" 2>/dev/null || true
  fi
  rm -f "$j"
}

# Last resort: stop NOOP, wait for iOS to drop any stalled install, then use pymobiledevice3.
install_with_pmd3() {
  local pid
  for pid in $(noop_pids); do
    xcrun devicectl device process terminate --device "$DEVICE_UDID" --pid "$pid" --timeout 60 >/dev/null 2>&1 &&
      log "Stopped NOOP (pid $pid) before installing"
  done
  sleep 5
  run_with_timeout 300 uvx --quiet "pymobiledevice3@$PMD3_VERSION" apps install --udid "$DEVICE_UDID" "$APP" >/dev/null 2>&1
}

install_app() {
  log "Installing over $BUNDLE_ID"
  local out; out=$(mktemp)
  if run_with_timeout 180 xcrun devicectl device install app --device "$DEVICE_UDID" --timeout 150 "$APP" > "$out" 2>&1 &&
     grep -q "App installed" "$out"; then
    rm -f "$out"
  else
    log "devicectl install failed: $(grep -m1 -E 'NSLocalizedFailureReason|ERROR' "$out" | sed 's/^ *//' | cut -c1-200)"
    rm -f "$out"
    if awk -v l="$(days_left)" 'BEGIN { exit !(l < 1) }'; then
      log "Less than a day left; trying pymobiledevice3 as a last resort"
      install_with_pmd3 || die "install failed; unlock the iPhone and run renew"
    else
      notify "NOOP needs renewing. Unlock your iPhone near the Mac; the next check retries."
      die "install needs the iPhone unlocked once since its last restart (developer disk image); the next check retries"
    fi
  fi
  state_set EXPIRES_AT "$APP_EXPIRES"
  state_set INSTALLED_AT "$(date +%s)"
  state_set BUILD "$APP_BUILD"
  state_set SOURCE "$(cat "$SRC/.noop-source" 2>/dev/null)"
  # Relaunching needs Xcode's developer disk image, which mounts only while the phone is unlocked.
  if xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing --timeout 60 "$BUNDLE_ID" >/dev/null 2>&1; then
    log "Installed and relaunched NOOP"
  else
    log "Installed; the relaunch failed (phone locked?)"
    notify "NOOP was renewed until $(date -r "$APP_EXPIRES" '+%a %d %b'). Open it on the iPhone so it keeps collecting."
  fi
}

renew() {
  device_reachable || die "iPhone $DEVICE_UDID is not reachable (needs a cable, or the same Wi-Fi as the Mac)"
  backup
  build
  install_app
}

auto() {
  mkdir -p "$LOGS"
  exec >> "$LOGS/noop-phone.log" 2>&1
  local left hour today
  left=$(days_left)
  if awk -v l="$left" -v t="$RENEW_DAYS_LEFT" 'BEGIN { exit !(l >= t) }'; then
    exit 0
  fi
  hour=$((10#$(date +%H)))
  if [ "$hour" -lt "$DAY_START" ] || [ "$hour" -ge "$DAY_END" ]; then
    awk -v l="$left" 'BEGIN { exit !(l >= 1) }' && exit 0
  fi
  log "Renewal due: $left days left"
  if ! device_reachable; then
    today=$(date +%F)
    if [ "$(state_get LAST_NOTIFY)" != "$today" ]; then
      notify "NOOP expires in $left days. Put the iPhone on the Mac's Wi-Fi or plug it in."
      state_set LAST_NOTIFY "$today"
    fi
    log "iPhone not reachable; will retry at the next check"
    exit 0
  fi
  # set -e is ignored inside an `if` condition, so renew runs as its own process, where it still applies.
  if "$ROOT/bin/noop-phone.sh" _renew; then
    log "Renewal done"
  else
    notify "NOOP renewal failed. See ~/.noop-phone/logs/noop-phone.log"
    exit 1
  fi
}

status() {
  echo "Device:      ${DEVICE_UDID:-<not set>}"
  if [ -n "$DEVICE_UDID" ] && device_reachable; then echo "Reachable:   yes"; else echo "Reachable:   no"; fi
  echo "Source:      $(cat "$SRC/.noop-source" 2>/dev/null || echo '<none>')"
  echo "Build:       $(state_get BUILD)"
  local exp; exp=$(state_get EXPIRES_AT)
  if [ -n "$exp" ]; then
    echo "Expires:     $(date -r "$exp" '+%a %d %b %Y %H:%M') ($(days_left) days left)"
  else
    echo "Expires:     unknown (not installed by this script yet)"
  fi
  echo "Last backup: $(state_get LAST_BACKUP)"
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then echo "Schedule:    loaded ($LABEL)"; else echo "Schedule:    not loaded"; fi
}

setup() {
  mkdir -p "$ROOT/bin" "$LOGS" "$BACKUPS"
  cp "$0" "$ROOT/bin/noop-phone.sh"
  chmod +x "$ROOT/bin/noop-phone.sh"
  [ -f "$CONFIG" ] || printf 'DEVICE_UDID=%s\n' "$DEVICE_UDID" > "$CONFIG"
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/bin/noop-phone.sh</string>
    <string>auto</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>20</integer></dict>
    <dict><key>Hour</key><integer>13</integer><key>Minute</key><integer>20</integer></dict>
    <dict><key>Hour</key><integer>16</integer><key>Minute</key><integer>20</integer></dict>
    <dict><key>Hour</key><integer>19</integer><key>Minute</key><integer>20</integer></dict>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$LOGS/launchd.out</string>
  <key>StandardErrorPath</key>
  <string>$LOGS/launchd.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  log "Installed $ROOT/bin/noop-phone.sh and loaded $LABEL (checks at 10:20, 13:20, 16:20, 19:20)"
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  install)
    allow_dirty=no; [ "${1:-}" = "--allow-dirty" ] && allow_dirty=yes
    with_lock
    device_reachable || die "iPhone ${DEVICE_UDID:-?} is not reachable"
    backup
    sync_source "$allow_dirty"
    mkdir -p "$ROOT/bin" && cp "$0" "$ROOT/bin/noop-phone.sh" && chmod +x "$ROOT/bin/noop-phone.sh"
    build
    install_app
    ;;
  renew)  with_lock; renew ;;
  _renew) renew ;;   # auto's child process; auto already holds the lock
  auto)   with_lock; auto ;;
  backup) backup ;;
  status) status ;;
  setup)  setup ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
