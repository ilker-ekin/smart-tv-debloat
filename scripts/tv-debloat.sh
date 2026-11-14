#!/usr/bin/env bash
# Debloat and speed up an Android TV / Google TV over ADB (verified on TCL). No root, fully reversible.
# macOS (stock bash 3.2), Linux, Git Bash on Windows. Feature parity with tv-debloat.ps1.
#
#   ./scripts/tv-debloat.sh 192.168.1.50 --dry-run
#   ./scripts/tv-debloat.sh 192.168.1.50 --tier 1 --yes
#   ./scripts/tv-debloat.sh 192.168.1.50 --measure after
#   ./scripts/tv-debloat.sh --restore reports/restore-20260101-120000.sh
#
# Removes packages for one Android user with `pm uninstall -k --user N` (the APK stays on
# /system; a factory reset or the restore file brings it back), falling back to
# `pm disable-user`. Every change appends its undo command to reports/restore-<ts>.sh.
#
# Reads ../packages.tsv, generated from packages.yaml: stock macOS has no YAML parser and
# we don't want users to install yq. CI fails if the TSV drifts from the YAML.
#
# Written for bash 3.2: no associative arrays, no mapfile, no ${x,,}. No `set -e`: the
# script checks adb results itself and must keep going after a single failed package.

set -u

# Enforced in code: refused even if someone adds them to packages.yaml.
# Kept in sync with packages.yaml by `python tools/packages.py check` (CI).
# BEGIN DENYLIST
DENYLIST="
com.google.android.apps.tv.launcherx
com.google.android.tungsten.setupwraith
com.google.android.gms
com.google.android.gsf
com.android.vending
com.google.android.webview
com.google.android.apps.mediashell
com.android.providers.tv
com.tcl.tv
com.tcl.tvinput
com.tcl.system.server
com.tcl.settings
com.tcl.dashboard
com.tcl.partnercustomizer
com.tcl.providers.config
com.tcl.keyhelp
com.tcl.autopair
com.tcl.micmanager
com.tcl.ui_mediaCenter
com.tcl.miracast
com.tcl.ttvs
com.tcl.suspension
com.tcl.factory.view
com.tcl.initsetup
com.tcl.useragreement
com.tvos
com.android.systemui
com.android.tv.settings
"
# END DENYLIST

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANIMATION_KEYS="window_animation_scale transition_animation_scale animator_duration_scale"
US=$'\037'   # field separator for parsed TSV rows (non-whitespace, so empty fields survive)

IP="" PORT=5555 LIST=0 DRY=0 TIER=3 YES=0 KEEP="" USER_ID="" MEASURE="" RESTORE="" PRIVACY=0
PACKAGES_FILE="$SCRIPT_DIR/../packages.tsv"
REPORTS_DIR="reports"
TARGET="" RESTORE_FILE="" ADB_OUT="" ADB_EXIT=0
N_REMOVED=0 N_DISABLED=0 N_SKIPPED=0 N_FAILED=0 FAILED="" REFUSED=""

if [ -t 1 ]; then C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_CYN=$'\033[36m' C_OFF=$'\033[0m'
else C_RED="" C_GRN="" C_YEL="" C_CYN="" C_OFF=""; fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YEL" "$*" "$C_OFF"; }
head_() { printf '\n%s%s%s\n' "$C_CYN" "$*" "$C_OFF"; }
red()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF"; }
fail() { red "ERROR: $1"; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Usage: tv-debloat.sh <TV_IP> [options]
  --list               show the package catalog (+ what's installed if TV_IP given); no changes
  --dry-run            show what would happen; no changes on the TV, no files written
  --tier N             offer tiers 1..N (default 3 = all)
  --yes                don't ask for tiers 1-2 and tweaks (tier 3 ALWAYS asks)
  --keep a,b           packages to leave alone
  --user N             Android user id (default: the TV's current user)
  --port N             ADB port (default 5555)
  --measure before|after   only take a RAM/package snapshot; 'after' prints a diff
  --restore FILE       replay an undo file from an earlier run (.sh or .ps1)
  --privacy            run the read-only privacy audit
  --help
PowerShell equivalents: -List -DryRun -Tier -Yes -Keep -User -Port -Measure -Restore -Privacy
EOF
}

# Run adb with an empty stdin (< /dev/null) so it can never swallow the script's input:
# the "pasted lines vanish" bug from the walkthrough, and our own y/N answers.
# Sets ADB_OUT (CR stripped; old adb on Windows emits CRLF) and ADB_EXIT.
adb_run() {
  if [ -n "$TARGET" ]; then ADB_OUT="$(adb -s "$TARGET" "$@" < /dev/null 2>&1)"
  else ADB_OUT="$(adb "$@" < /dev/null 2>&1)"; fi
  ADB_EXIT=$?
  ADB_OUT="$(printf '%s' "$ADB_OUT" | tr -d '\r')"
}
tv() { adb_run shell "$@"; }

ask() {   # ask "question" -> 0 for yes. No answer / EOF = no.
  local a=""
  printf '%s [y/N] ' "$1"
  IFS= read -r a || a=""
  a="$(printf '%s' "$a" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  [ -t 0 ] || printf '%s\n' "$a"
  [ "$a" = "y" ] || [ "$a" = "yes" ]
}

in_list() { printf '%s\n' "$2" | grep -qxF -- "$1"; }   # in_list needle "newline list"

thousands() {   # 1551191 -> 1,551,191 (locale-independent)
  local n="$1" sign="" out=""
  case "$n" in -*) sign="-"; n="${n#-}";; esac
  while [ "${#n}" -gt 3 ]; do out=",${n: -3}$out"; n="${n:0:${#n}-3}"; done
  printf '%s%s%s' "$sign" "$n" "$out"
}

# ------------------------------------------------------------------ args
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --dry-run) DRY=1 ;;
    --tier) TIER="${2:-}"; shift ;;
    --yes|-y) YES=1 ;;
    --keep) KEEP="${2:-}"; shift ;;
    --user) USER_ID="${2:-}"; shift ;;
    --port) PORT="${2:-}"; shift ;;
    --measure) MEASURE="${2:-}"; shift ;;
    --restore) RESTORE="${2:-}"; shift ;;
    --privacy) PRIVACY=1 ;;
    --packages-file) PACKAGES_FILE="${2:-}"; shift ;;   # advanced / tests
    --reports-dir) REPORTS_DIR="${2:-}"; shift ;;       # advanced / tests
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; fail "unknown option: $1" 2 ;;
    *) [ -z "$IP" ] || fail "unexpected argument: $1" 2; IP="$1" ;;
  esac
  shift
done
case "$TIER" in 1|2|3) ;; *) fail "--tier must be 1, 2 or 3" 2 ;; esac
case "$MEASURE" in ""|before|after) ;; *) fail "--measure must be 'before' or 'after'" 2 ;; esac
case "$USER_ID" in ""|*[!0-9]*) [ -z "$USER_ID" ] || fail "--user must be a number" 2 ;; esac
case "$PORT" in ""|*[!0-9]*) fail "--port must be a number" 2 ;; esac
KEEP_LIST="$(printf '%s' "$KEEP" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed '/^$/d')"

# ------------------------------------------------------------------ device
connect_tv() {
  command -v adb > /dev/null 2>&1 || fail "'adb' was not found. Install Android Platform Tools (macOS: brew install android-platform-tools; Debian/Ubuntu: sudo apt install adb) or put platform-tools on your PATH."
  [ -n "$IP" ] || fail "give the TV address, e.g. tv-debloat.sh 192.168.1.50" 2
  local addr="$IP"
  case "$IP" in *:*) ;; *) addr="$IP:$PORT" ;; esac
  TARGET=""
  adb_run connect "$addr"
  case "$ADB_OUT" in
    *10060*|*"timed out"*) fail "timeout reaching $addr (10060). Check the IP for typos (e.g. 192.16.x instead of 192.168.x) and that PC and TV are on the same network." 3 ;;
    *10061*|*refused*) fail "$addr refused the connection (10061). Turn on Network debugging / USB debugging on the TV, and check the port." 3 ;;
    *failed*|*cannot*|*unable*) fail "could not connect to $addr: $ADB_OUT" 3 ;;
  esac
  # `adb devices` prints the state on stdout; `get-state` only reports problems on stderr.
  adb_run devices
  local state
  state="$(printf '%s\n' "$ADB_OUT" | awk -v a="$addr" '$1 == a { print $2 }')"
  TARGET="$addr"
  case "$state" in
    device) ok "Connected to $addr" ;;
    unauthorized) fail 'the TV has not accepted this PC yet. Pick "Always allow" on the TV prompt, then run again.' 3 ;;
    *) fail "TV not ready (state: ${state:-unknown})." 3 ;;
  esac
}

resolve_user() {   # sets U
  tv pm list users
  local users current others count
  users="$(printf '%s\n' "$ADB_OUT" | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')"
  tv am get-current-user
  current="$(printf '%s\n' "$ADB_OUT" | head -n 1 | tr -d ' ')"
  if [ -n "$USER_ID" ]; then U="$USER_ID"
  else case "$current" in ""|*[!0-9]*) U=0 ;; *) U="$current" ;; esac; fi
  count="$(printf '%s\n' "$users" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" -gt 1 ]; then
    others="$(printf '%s\n' "$users" | grep -vxF "$U" | paste -sd, - | sed 's/,/, /g')"
    warn "WARNING: this TV has $count Android users ($(printf '%s\n' "$users" | paste -sd, - | sed 's/,/, /g')). Changes apply to user $U only."
    warn "         Apps stay installed for user(s) $others. Re-run with --user <id> to debloat those too."
  fi
  if [ "$count" -gt 0 ] && ! in_list "$U" "$users"; then
    fail "user $U does not exist on this TV (users: $(printf '%s\n' "$users" | paste -sd, - | sed 's/,/, /g'))." 2
  fi
}

installed_pkgs() { tv pm list packages --user "$U"; printf '%s\n' "$ADB_OUT" | sed -n 's/^package://p' | sed 's/ *$//'; }

metric_lines() {   # "metric <name>: <n>K" lines from dumpsys meminfo
  tv dumpsys meminfo
  printf '%s\n' "$ADB_OUT" | awk '
    /^ *Free RAM:/ { v=$3; gsub(/[,K]/, "", v); print "metric Free RAM: " v "K"
                     if (match($0, /\+ *[0-9,]+K free\)/)) { f=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", f); tf=f } }
    /^ *Used RAM:/ { v=$3; gsub(/[,K]/, "", v); used=v }
    END { if (tf != "") print "metric Truly free: " tf "K"; if (used != "") print "metric Used RAM: " used "K" }'
}

save_snapshot() {   # save_snapshot before|after -> sets SNAP_FILE
  mkdir -p "$REPORTS_DIR" || fail "cannot create $REPORTS_DIR"
  local ts model
  ts="$(date +%Y%m%d-%H%M%S)"
  SNAP_FILE="$REPORTS_DIR/$ts-$1.txt"
  tv getprop ro.product.name; model="$ADB_OUT"
  {
    say "# tv-debloat $1 snapshot $ts"
    say "model: $model"
    say "user: $U"
    metric_lines
    say "# packages"
    installed_pkgs | LC_ALL=C sort
  } > "$SNAP_FILE"
  say "Saved $1 snapshot: $SNAP_FILE"
}

show_diff() {   # show_diff before_file after_file
  say "Before: $1"; say "After:  $2"
  printf '\n%-11s %12s %12s %12s\n' Metric Before After Change
  printf '%-11s %12s %12s %12s\n' ------ ------ ----- ------
  local name b a d sign
  for name in "Free RAM" "Truly free" "Used RAM"; do
    b="$(sed -n "s/^metric $name: \([0-9]*\)K$/\1/p" "$1")"
    a="$(sed -n "s/^metric $name: \([0-9]*\)K$/\1/p" "$2")"
    [ -n "$b" ] && [ -n "$a" ] || continue
    d=$((a - b)); sign=""; [ "$d" -gt 0 ] && sign="+"
    printf '%-11s %12s %12s %12s\n' "$name" "$(thousands "$b")K" "$(thousands "$a")K" "$sign$(thousands "$d")K"
  done
  say ""
}

undo() { say "$1" >> "$RESTORE_FILE"; }

remove_pkg() {   # remove_pkg <pkg>
  local pkg="$1"
  if [ "$DRY" = 1 ]; then say "  [dry-run] would remove $pkg"; N_REMOVED=$((N_REMOVED + 1)); return; fi
  tv pm uninstall -k --user "$U" "$pkg"
  case "$ADB_OUT" in *Success*)
    undo "adb -s $TARGET shell cmd package install-existing --user $U $pkg"
    N_REMOVED=$((N_REMOVED + 1)); ok "  removed $pkg"; return ;;
  esac
  warn "  uninstall refused ($ADB_OUT), trying disable-user"
  tv pm disable-user --user "$U" "$pkg"
  case "$ADB_OUT" in *"new state: disabled"*)
    undo "adb -s $TARGET shell pm enable --user $U $pkg"
    N_DISABLED=$((N_DISABLED + 1)); ok "  disabled $pkg"; return ;;
  esac
  N_FAILED=$((N_FAILED + 1)); FAILED="$FAILED $pkg"; red "  FAILED $pkg ($ADB_OUT)"
}

apply_tweaks() {
  if [ "$YES" != 1 ] && ! ask "Apply animation scale 0.5 (snappier menus)?"; then return; fi
  local k old
  for k in $ANIMATION_KEYS; do
    if [ "$DRY" = 1 ]; then say "  [dry-run] would set $k 0.5"; continue; fi
    tv settings get global "$k"; old="$(printf '%s' "$ADB_OUT" | tr -d ' ')"
    case "$old" in
      ""|*[!0-9.]*) undo "adb -s $TARGET shell settings delete global $k" ;;
      *) undo "adb -s $TARGET shell settings put global $k $old" ;;
    esac
    tv settings put global "$k" 0.5
  done
  [ "$DRY" = 1 ] || ok "  animation scale 0.5 set (reboot recommended)"
}

# Only replay lines we know we wrote; never execute arbitrary content from the file.
# Same line format as the .ps1 undo files, so either script can replay either file.
# The target is limited to address characters, and only the command part (group 2) is ever sent to the TV:
# the line itself is never re-split, so tabs or shell characters in a crafted file can't add arguments.
RESTORE_RE='^adb -s ([A-Za-z0-9.:_-]+) shell ((cmd package install-existing|pm enable) --user [0-9]+ [A-Za-z0-9_.]+|settings (put global [A-Za-z0-9_]+ [0-9.]+|delete global [A-Za-z0-9_]+))$'

do_restore() {
  [ -f "$1" ] || fail "restore file not found: $1" 2
  local cmds first line okc=0 bad=0 args
  cmds="$(tr -d '\r' < "$1" | grep -E "$RESTORE_RE")"
  [ -n "$cmds" ] || fail "no restore commands found in $1"
  first="$(printf '%s\n' "$cmds" | head -n 1 | awk '{ print $3 }')"
  [ -n "$IP" ] || IP="$first"
  connect_tv
  while IFS= read -r line; do
    [[ $line =~ $RESTORE_RE ]] || continue
    # Split only the whitelisted command (group 2) on single spaces, with globbing off.
    set -f
    IFS=' ' read -r -a args <<< "${BASH_REMATCH[2]}"
    set +f
    set -- "${args[@]}"
    if [ "$DRY" = 1 ]; then say "  [dry-run] $*"; continue; fi
    tv "$@"
    case "$ADB_EXIT:$ADB_OUT" in
      0:*Error*|0:*Failure*|[1-9]*) bad=$((bad + 1)); red "  failed: $* ($ADB_OUT)" ;;
      *) okc=$((okc + 1)); ok "  ok: $*" ;;
    esac
  done <<EOF
$cmds
EOF
  say "Restore done: $okc ok, $bad failed. Reboot the TV: adb -s $TARGET reboot"
  [ "$bad" = 0 ]
}

# ------------------------------------------------------------------ main
if [ -n "$RESTORE" ]; then do_restore "$RESTORE"; exit $?; fi

if [ "$PRIVACY" = 1 ]; then
  [ -f "$SCRIPT_DIR/privacy-audit.sh" ] || fail "privacy-audit.sh not found next to this script."
  if [ -n "$IP" ]; then exec "${BASH:-bash}" "$SCRIPT_DIR/privacy-audit.sh" "$IP" --port "$PORT"; fi
  exec "${BASH:-bash}" "$SCRIPT_DIR/privacy-audit.sh" --port "$PORT"
fi

[ -f "$PACKAGES_FILE" ] || fail "package list not found: $PACKAGES_FILE"
# kind package tier risk name breaks verified_on description -> US-separated, CR stripped
CATALOG="$(tr -d '\r' < "$PACKAGES_FILE" | awk -F'\t' -v OFS="$US" '!/^#/ && $1 != "kind" && NF { $1 = $1; print }')"
DENY="$(printf '%s\n%s\n' "$DENYLIST" "$(printf '%s\n' "$CATALOG" | awk -F"$US" '$1 == "deny" { print $2 }')" | sed '/^$/d' | LC_ALL=C sort -u)"

if [ "$LIST" = 1 ] && [ -z "$IP" ]; then
  printf '%-45s %-4s %-15s %s\n' PACKAGE TIER RISK NAME
  printf '%s\n' "$CATALOG" | awk -F"$US" '$1 == "pkg" { printf "%-45s %-4s %-15s %s\n", $2, $3, $4, $5 }'
  exit 0
fi

connect_tv
U=0
resolve_user

if [ -n "$MEASURE" ]; then
  save_snapshot "$MEASURE"
  if [ "$MEASURE" = after ]; then
    before=""
    for f in "$REPORTS_DIR"/*-before.txt; do [ -f "$f" ] && before="$f"; done   # glob is sorted: last = newest
    if [ -n "$before" ]; then show_diff "$before" "$SNAP_FILE"; else warn "No *-before.txt in $REPORTS_DIR to compare against."; fi
  fi
  exit 0
fi

INSTALLED="$(installed_pkgs)"

if [ "$LIST" = 1 ]; then
  printf '%-9s %-45s %-4s %-15s %s\n' INSTALLED PACKAGE TIER RISK NAME
  printf '%s\n' "$CATALOG" | while IFS="$US" read -r kind pkg tier risk name _; do
    [ "$kind" = pkg ] || continue
    inst="-"; in_list "$pkg" "$INSTALLED" && inst="yes"
    printf '%-9s %-45s %-4s %-15s %s\n' "$inst" "$pkg" "$tier" "$risk" "$name"
  done
  exit 0
fi

if [ "$DRY" = 1 ]; then
  printf '%sDRY RUN: nothing will be changed on the TV and no files are written.%s\n' "$C_CYN" "$C_OFF"
else
  save_snapshot before
  RESTORE_FILE="$REPORTS_DIR/restore-$(date +%Y%m%d-%H%M%S).sh"
  {
    say "#!/usr/bin/env bash"
    say "# Undo file written by tv-debloat.sh. Replay with:"
    say "#   ./scripts/tv-debloat.sh --restore $RESTORE_FILE"
    say "# (or run this file directly; it only contains adb commands)"
    say "# Target user: $U"
  } > "$RESTORE_FILE"
  chmod +x "$RESTORE_FILE" 2> /dev/null
fi

# Read the catalog on fd 3 so prompts inside the loop still read the user's stdin.
t=1
while [ "$t" -le "$TIER" ]; do
  printed=0
  while IFS="$US" read -r kind pkg tier risk name breaks _ <&3; do
    [ "$kind" = pkg ] && [ "$tier" = "$t" ] || continue
    [ "$printed" = 1 ] || { head_ "=== Tier $t ==="; printed=1; }
    if in_list "$pkg" "$DENY"; then REFUSED="$REFUSED $pkg"; red "  REFUSED $pkg (on the denylist)"; continue; fi
    if in_list "$pkg" "$KEEP_LIST"; then N_SKIPPED=$((N_SKIPPED + 1)); say "  keep    $pkg"; continue; fi
    if ! in_list "$pkg" "$INSTALLED"; then N_SKIPPED=$((N_SKIPPED + 1)); continue; fi
    label="$pkg  ($name${breaks:+; breaks: $breaks})"
    if [ "$YES" != 1 ] || [ "$t" = 3 ]; then
      ask "Remove $label?" || { N_SKIPPED=$((N_SKIPPED + 1)); continue; }
    else
      say "  $label"
    fi
    remove_pkg "$pkg"
  done 3<<EOF
$CATALOG
EOF
  t=$((t + 1))
done

head_ "=== Tweaks ==="
apply_tweaks

head_ "=== Summary ==="
if [ "$DRY" = 1 ]; then printf '  %-9s %s\n' "would rm" "$N_REMOVED"; else printf '  %-9s %s\n' removed "$N_REMOVED"; fi
printf '  %-9s %s\n' disabled "$N_DISABLED" skipped "$N_SKIPPED" failed "$N_FAILED"
[ -z "$REFUSED" ] || red "  refused  $(printf '%s' "$REFUSED" | wc -w | tr -d ' ') (${REFUSED# })"
[ -z "$FAILED" ] || red "  failed: ${FAILED# }"
if [ "$DRY" != 1 ]; then
  say "  undo:     ./scripts/tv-debloat.sh --restore $RESTORE_FILE"
  say "  next:     adb -s $TARGET reboot   then   --measure after"
fi
[ "$N_FAILED" = 0 ]
