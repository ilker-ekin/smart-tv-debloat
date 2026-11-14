#!/usr/bin/env bash
# Read-only privacy audit of an Android TV / Google TV over ADB (verified on TCL). Changes NOTHING on the TV.
# macOS (bash 3.2), Linux, Git Bash. Same sections and findings as privacy-audit.ps1.
#
#   ./scripts/privacy-audit.sh 192.168.1.50 [--port 5555] [--reports-dir reports]
#
# Writes reports/<timestamp>-privacy.txt (git-ignored: it describes your TV; don't publish it).
# Every adb call is a read. Output is filtered on the PC, not with grep on the TV.

set -u

EXPECTED_MIC="
com.google.android.katniss
com.google.android.tv.assistant
com.tcl.assistant
com.tcl.micmanager
com.google.android.youtube.tv
"

IP="" PORT=5555 REPORTS_DIR="reports" TARGET="" ADB_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift ;;
    --reports-dir) REPORTS_DIR="${2:-}"; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) IP="$1" ;;
  esac
  shift
done

fail() { printf 'ERROR: %s\n' "$1"; exit "${2:-1}"; }
# < /dev/null: adb can never swallow the terminal's input. CR stripped (old Windows adb).
adb_run() {
  if [ -n "$TARGET" ]; then ADB_OUT="$(adb -s "$TARGET" "$@" < /dev/null 2>&1)"
  else ADB_OUT="$(adb "$@" < /dev/null 2>&1)"; fi
  ADB_OUT="$(printf '%s' "$ADB_OUT" | tr -d '\r')"
}
tv() { adb_run shell "$@"; printf '%s\n' "$ADB_OUT"; }
setting() { tv settings get "$1" "$2" | head -n 1 | sed 's/[[:space:]]*$//'; }
unset_() { [ -z "$1" ] || [ "$1" = null ]; }

command -v adb > /dev/null 2>&1 || fail "'adb' was not found. See docs/WALKTHROUGH.md (Install ADB)."
[ -n "$IP" ] || fail "give the TV address, e.g. privacy-audit.sh 192.168.1.50" 2
case "$IP" in *:*) ADDR="$IP" ;; *) ADDR="$IP:$PORT" ;; esac
adb_run connect "$ADDR"
case "$ADB_OUT" in
  *10060*|*"timed out"*) fail "timeout reaching $ADDR (10060). Check the IP for typos and that PC and TV are on the same network." 3 ;;
  *10061*|*refused*) fail "$ADDR refused the connection (10061). Turn on Network debugging / USB debugging on the TV." 3 ;;
  *failed*|*cannot*|*unable*) fail "could not connect to $ADDR: $ADB_OUT" 3 ;;
esac
adb_run devices
STATE="$(printf '%s\n' "$ADB_OUT" | awk -v a="$ADDR" '$1 == a { print $2 }')"
TARGET="$ADDR"
[ "$STATE" = unauthorized ] && fail 'the TV has not accepted this PC yet. Pick "Always allow" on the TV prompt, then run again.' 3
[ "$STATE" = device ] || fail "TV not ready (state: ${STATE:-unknown})." 3

TS="$(date +%Y%m%d-%H%M%S)"

# ---- collect (all reads)
APPOPS="$(tv dumpsys appops --op RECORD_AUDIO)"
AUDIO="$(tv dumpsys audio)"
PKGS="$(tv pm list packages | sed 's/^package://')"
USERS="$(tv pm list users | grep 'UserInfo{')"
S_ASSIST="$(setting secure assistant)"
S_VI="$(setting secure voice_interaction_service)"
S_VR="$(setting secure voice_recognition_service)"
S_ACC="$(setting secure enabled_accessibility_services)"
S_NL="$(setting secure enabled_notification_listeners)"
S_LOC="$(setting secure location_mode)"
S_ADB="$(setting global adb_enabled)"
S_ADBW="$(setting global adb_wifi_enabled)"

# appops prints the time since last access as e.g. "-225d21h26m3s120ms":
# "225 days, 21 hours ago". It is the LAST access, not a recording.
ago() {
  printf '%s\n' "$1" | awk '{
    s = $0; out = ""; n = 0
    if (match(s, /[0-9]+d/)) { v = substr(s, RSTART, RLENGTH - 1) + 0; out = v " day" (v == 1 ? "" : "s"); n++ }
    if (match(s, /[0-9]+h/)) { v = substr(s, RSTART, RLENGTH - 1) + 0; out = out (n ? ", " : "") v " hour" (v == 1 ? "" : "s"); n++ }
    if (n < 2) { t = s; gsub(/[0-9]+ms/, "", t); if (match(t, /[0-9]+m/)) { v = substr(t, RSTART, RLENGTH - 1) + 0; out = out (n ? ", " : "") v " min"; n++ } }
    print (n ? out " ago" : "less than a minute ago") }'
}

# One line per package with a RECORD_AUDIO block: pkg<TAB>mode<TAB>last_rel<TAB>running(0/1)
MIC="$(printf '%s\n' "$APPOPS" | awk '
  function flush() { if (cur != "") printf "%s\t%s\t%s\t%d\n", cur, mode, last, run; cur = "" }
  /^[[:space:]]*Package [^ ]+:/ { flush(); pkg = $2; sub(/:$/, "", pkg); next }
  pkg != "" && /^[[:space:]]*RECORD_AUDIO \([a-z]+\):/ { flush(); cur = pkg; mode = $2; gsub(/[():]/, "", mode); last = ""; run = 0; next }
  cur != "" && /^[[:space:]]*Access:/ && last == "" { if (match($0, /\(-[0-9dhms]+\)/)) last = substr($0, RSTART + 1, RLENGTH - 2) }
  cur != "" && /^[[:space:]]*Running/ { run = 1 }
  END { flush() }')"

FINDINGS=""
finding() { FINDINGS="$FINDINGS$(printf '%-6s %-14s %s' "$1" "$2" "$3")
"; }

if [ -z "$MIC" ]; then finding OK microphone "no app has a RECORD_AUDIO history"; fi
while IFS="$(printf '\t')" read -r pkg mode last run; do
  [ -n "$pkg" ] || continue
  if [ -n "$last" ]; then when="last used $(ago "$last")"; else when="no recorded use"; fi
  if [ "$run" = 1 ]; then finding REVIEW microphone "$pkg: appops reports the mic op as RUNNING now ($when)"
  elif printf '%s\n' "$EXPECTED_MIC" | grep -qxF -- "$pkg"; then finding OK microphone "$pkg (voice search, $mode): $when"
  else finding REVIEW microphone "$pkg is not a known voice app but has mic access ($mode): $when"; fi
done <<EOF
$MIC
EOF
finding INFO "recording now" "check section 3 by hand: with nobody holding the mic button it should list no active recording"
finding INFO "remote mic" "the remote's mic is Bluetooth push-to-talk; ADB can't see its hardware, only audio Android receives"
if unset_ "$S_ACC"; then finding OK accessibility "no accessibility services enabled"
else finding REVIEW accessibility "enabled: $S_ACC (expected only if you set up e.g. Projectivy's launcher override)"; fi
if unset_ "$S_NL"; then finding OK notifications "no notification listeners"
else finding REVIEW notifications "listeners: $S_NL"; fi
if [ "$S_LOC" = 0 ]; then finding OK location "location is off"
elif unset_ "$S_LOC"; then finding INFO location "location_mode not reported by this firmware"
else finding REVIEW location "location is on (mode $S_LOC); a TV doesn't need it"; fi
NUSERS="$(printf '%s\n' "$USERS" | sed '/^$/d' | wc -l | tr -d ' ')"
[ "$NUSERS" -gt 1 ] && finding INFO users "$NUSERS Android users on this TV; apps removed for one user stay for the others"
[ "$S_ADB" = 1 ] && finding WARN debugging "ADB is on (needed for this audit). Turn it OFF when you are done: anyone on your Wi-Fi gets full control"

# ---- report
section() {   # section "title" "content"
  printf '\n===== %s =====\n' "$1"
  local c; c="$(printf '%s\n' "$2" | sed '/^[[:space:]]*$/d')"
  if [ -n "$c" ]; then printf '%s\n' "$c"; else echo '(nothing)'; fi
}
REC="$(printf '%s\n' "$AUDIO" | grep -A8 'RecordActivityMonitor')"
[ -n "$REC" ] || REC="RecordActivityMonitor not found in dumpsys audio on this firmware"

mkdir -p "$REPORTS_DIR" || fail "cannot create $REPORTS_DIR"
FILE="$REPORTS_DIR/$TS-privacy.txt"
{
  echo "Android TV privacy audit  $TS  (read-only: nothing on the TV was changed)"
  echo "Device: $(tv getprop ro.product.name)"
  echo "Build:  $(tv getprop ro.build.fingerprint)"
  printf '\n===== FINDINGS =====\n%s' "$FINDINGS"
  echo 'How to read times: "(-225d21h26m...)" = the LAST time the app used the mic, 225 days 21 hours ago.'
  echo 'It is a timestamp of when the app last opened the mic, not a recording.'
  section "1. Apps ALLOWED to use the microphone (RECORD_AUDIO app-op)" "$(tv cmd appops query-op RECORD_AUDIO allow)
--- foreground-only ---
$(tv cmd appops query-op RECORD_AUDIO foreground)"
  section "2. Recent microphone ACCESS history (who actually used it, and when)" "$(printf '%s\n' "$APPOPS" | grep -E 'Package|Access|Reject|Running')"
  section "3. Is anything recording RIGHT NOW?" "$REC"
  section "4. Voice assistant / hotword services" "assistant: $S_ASSIST
voice_interaction_service: $S_VI
voice_recognition_service: $S_VR
hotword / always-on packages installed:
$(printf '%s\n' "$PKGS" | grep -iE 'hotword|alexa|katniss|assistant|micmanager|voice')"
  section "5. Accessibility services (can read the screen)" "$S_ACC"
  section "6. Notification listeners" "$S_NL"
  section "7. Device admins / device owner" "$(tv dumpsys device_policy | grep -iE 'admin|owner')"
  section "8. Third-party apps and who installed them" "$(tv pm list packages -3 -i)"
  section "9. Apps allowed to install other apps (unknown sources)" "$(tv cmd appops query-op REQUEST_INSTALL_PACKAGES allow)"
  section "10. Location" "location_mode: $S_LOC
$(tv cmd appops query-op COARSE_LOCATION allow)"
  section "11. Debugging left on? (turn OFF when done)" "adb_enabled: $S_ADB
adb_wifi_enabled: $S_ADBW"
  section "Android users" "$USERS"
} > "$FILE"

cat "$FILE"
printf "\nSaved to %s. Nothing on the TV was changed. Don't publish this file.\n" "$FILE"
exit 0
