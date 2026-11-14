#!/usr/bin/env bash
# Tests for scripts/tv-debloat.sh. Plain bash (no bats needed), bash 3.2 compatible.
# Never touches a real TV: tests/mock-adb is put first on PATH and every call is logged.
#   bash tests/test_debloat.sh            # all tests
#   bash tests/test_debloat.sh restore    # only tests whose name contains "restore"
#
# Assertions are strings evaluated later by check(), so single quotes are intended
# (SC2016) and variables read only inside them look unused to shellcheck (SC2034).
# shellcheck disable=SC2016,SC2034

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/scripts/tv-debloat.sh"

MOCK_DIR="$REPO/tests/mock-adb"
MUTATING='(pm uninstall|pm disable-user|pm enable|install-existing|settings put|settings delete|reboot)'
FILTER="${1:-}"
PASS=0 FAILN=0 FAILED_NAMES=""
TMP_ROOT="$(mktemp -d 2> /dev/null || mktemp -d -t tcltest)"
trap 'rm -rf "$TMP_ROOT"' EXIT

chmod +x "$MOCK_DIR/adb" 2> /dev/null

# run_debloat "<stdin answers>" [ENV=val ...] -- <script args>
# Sets OUT, CODE, LOG (adb call log), WORK (cwd used for the run)
run_debloat() {
  local stdin="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  WORK="$(mktemp -d "$TMP_ROOT/run.XXXXXX")"
  : > "$WORK/adb.log"
  OUT="$(cd "$WORK" && printf '%b' "$stdin" | env PATH="$MOCK_DIR:$PATH" MOCK_ADB_LOG="$WORK/adb.log" ${envs[@]+"${envs[@]}"} "$BASH" "${RUN_SCRIPT:-$SCRIPT}" "$@" 2>&1)"
  CODE=$?
  LOG="$(cat "$WORK/adb.log")"
}

T_OK=1
check() { if ! eval "$1"; then T_OK=0; printf '      assertion failed: %s\n' "$1"; fi; }
log_has()   { printf '%s\n' "$LOG" | grep -Eq -- "$1"; }
log_count() { printf '%s\n' "$LOG" | grep -Ec -- "$1"; }
out_has()   { printf '%s\n' "$OUT" | grep -Eq -- "$1"; }

t() {   # t "name" function
  case "$1" in *"$FILTER"*) ;; *) return ;; esac
  T_OK=1
  "$2"
  if [ "$T_OK" = 1 ]; then PASS=$((PASS + 1)); printf '  [+] %s\n' "$1"
  else FAILN=$((FAILN + 1)); FAILED_NAMES="$FAILED_NAMES
    $1"; printf '  [-] %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/      | /' | tail -n 15; fi
}

# ------------------------------------------------------------------ tests
dry_run_zero_mutations() {
  run_debloat 'y\ny\ny\n' -- 192.168.1.50 --dry-run --yes
  check '[ "$CODE" = 0 ]'
  check '! log_has "$MUTATING"'
  check '[ -n "$LOG" ]'
  check '[ ! -e "$WORK/reports" ]'
  check 'out_has "would remove com.tcl.guard"'
}

denylist_enforced_in_code() {
  local tsv="$TMP_ROOT/evil.tsv"
  {   # no deny rows, so only the hardcoded list can catch these
    printf 'kind\tpackage\ttier\trisk\tname\tbreaks\tverified_on\tdescription\n'
    printf 'pkg\tcom.tcl.tv\t1\tsafe\tLive TV\t\t\t\n'
    printf 'pkg\tcom.google.android.apps.tv.launcherx\t1\tsafe\tHome\t\t\t\n'
    printf 'pkg\tcom.tcl.guard\t1\tsafe\tTCL Guard\t\t\t\n'
  } > "$tsv"
  run_debloat '' -- 192.168.1.50 --yes --packages-file "$tsv"
  check 'out_has "REFUSED com\.tcl\.tv "'
  check 'out_has "REFUSED com\.google\.android\.apps\.tv\.launcherx"'
  check '! log_has "uninstall.*(com\.tcl\.tv$|launcherx)"'
  check '[ "$(log_count "uninstall.*com\.tcl\.guard")" = 1 ]'
}

tsv_empty_fields_do_not_shift_columns() {
  # 'breaks' is empty for com.tcl.guard; a whitespace IFS would collapse the tabs
  run_debloat '' -- 192.168.1.50 --tier 1 --yes --dry-run
  check 'out_has "com\.tcl\.guard  \(TCL Guard\)$"'
}

crlf_output() {
  run_debloat '' MOCK_ADB_CRLF=1 -- 192.168.1.50 --tier 1 --yes
  check '[ "$CODE" = 0 ]'
  check '[ "$(log_count "uninstall.*com\.tcl\.guard$")" = 1 ]'
  local before; before="$(cat "$WORK"/reports/*-before.txt)"
  check 'printf "%s\n" "$before" | grep -qx "metric Free RAM: 656576K"'
  check 'printf "%s\n" "$before" | grep -qx "metric Truly free: 161364K"'
  check 'printf "%s\n" "$before" | grep -qx "com.tcl.guard"'
  check '! grep -q $(printf "\r") "$WORK"/reports/*-before.txt'
}

multi_user_warning() {
  run_debloat '' -- 192.168.1.50 --dry-run --tier 1 --yes
  check 'out_has "WARNING: this TV has 2 Android users \(0, 10\)"'
}
single_user_no_warning() {
  run_debloat '' MOCK_ADB_USERS=users-single.txt -- 192.168.1.50 --dry-run --tier 1 --yes
  check '! out_has "WARNING: this TV has"'
}
user_default_and_flag() {
  run_debloat '' MOCK_ADB_CURRENT_USER=10 -- 192.168.1.50 --tier 1 --yes
  check '[ "$(log_count "pm uninstall -k --user 10 com\.tcl\.guard")" = 1 ]'
  run_debloat '' MOCK_ADB_CURRENT_USER=10 -- 192.168.1.50 --tier 1 --yes --user 0
  check '[ "$(log_count "pm uninstall -k --user 0 com\.tcl\.guard")" = 1 ]'
}
unknown_user_rejected() {
  run_debloat '' -- 192.168.1.50 --tier 1 --yes --user 7
  check '[ "$CODE" = 2 ]'
  check '! log_has "$MUTATING"'
}

restore_file_contents() {
  run_debloat '' MOCK_ADB_FAIL_UNINSTALL=com.tcl.esticker,com.tcl.browser MOCK_ADB_FAIL_DISABLE=com.tcl.browser -- 192.168.1.50 --tier 1 --yes
  local files rf
  files="$(ls "$WORK"/reports/restore-*.sh 2> /dev/null)"
  check '[ "$(printf "%s\n" "$files" | sed "/^$/d" | wc -l | tr -d " ")" = 1 ]'
  rf="$(printf '%s\n' "$files" | head -n 1)"
  check 'grep -qxF "adb -s 192.168.1.50:5555 shell cmd package install-existing --user 0 com.tcl.guard" "$rf"'
  check '[ "$(log_count "disable-user --user 0 com\.tcl\.esticker")" = 1 ]'
  check 'grep -qxF "adb -s 192.168.1.50:5555 shell pm enable --user 0 com.tcl.esticker" "$rf"'
  check '! grep -q "com\.tcl\.browser" "$rf"'
  check 'out_has "failed: com\.tcl\.browser"'
  check '[ "$CODE" = 1 ]'
  check 'grep -qxF "adb -s 192.168.1.50:5555 shell settings delete global window_animation_scale" "$rf"'
  check '! log_has "uninstall.*com\.tcl\.smartalexa"'
}

restore_replays_only_known_lines() {
  local f="$TMP_ROOT/restore-test.sh"
  {
    echo '# comment'
    echo 'adb -s 192.168.1.50:5555 shell cmd package install-existing --user 0 com.tcl.guard'
    printf 'adb -s 192.168.1.50:5555 shell pm enable --user 0 com.tcl.esticker\r\n'   # CRLF line from a .ps1 undo file
    echo 'adb -s 192.168.1.50:5555 shell rm -rf /sdcard'
    echo 'touch /tmp/pwned; adb -s 192.168.1.50:5555 shell pm enable --user 0 x.y'
  } > "$f"
  run_debloat '' -- --restore "$f"
  check '[ "$CODE" = 0 ]'
  check '[ "$(log_count "install-existing --user 0 com\.tcl\.guard")" = 1 ]'
  check '[ "$(log_count "pm enable --user 0 com\.tcl\.esticker")" = 1 ]'
  check '! log_has "rm -rf"'
  check '! log_has "x\.y"'
}

tier3_always_asks() {
  run_debloat 'n\nn\nn\nn\n' -- 192.168.1.50 --yes
  check '! log_has "uninstall.*com\.google\.android\.katniss"'
  check '[ "$(log_count "uninstall.*com\.tcl\.guard")" = 1 ]'
}
closed_stdin_means_no() {
  run_debloat '' -- 192.168.1.50 --tier 1
  check '! log_has "pm uninstall"'
}
answers_not_swallowed_by_adb() {
  # The mock adb eats stdin on every `shell` call. Both tier-3 answers must survive
  # the adb calls in between, which only works because the script uses < /dev/null.
  run_debloat 'y\ny\ny\ny\n' -- 192.168.1.50 --yes
  check '[ "$(log_count "uninstall.*(katniss|disneyplus)")" = 2 ]'
}
keep_list() {
  run_debloat '' -- 192.168.1.50 --tier 1 --yes --keep com.tcl.guard,com.tcl.browser
  check '! log_has "uninstall.*(com\.tcl\.guard|com\.tcl\.browser)"'
  check '[ "$(log_count "uninstall.*com\.tcl\.esticker")" = 1 ]'
}

err_10060() {
  run_debloat '' MOCK_ADB_CONNECT=10060 -- 192.16.1.50
  check '[ "$CODE" = 3 ]'; check 'out_has typos'
}
err_10061() {
  run_debloat '' MOCK_ADB_CONNECT=10061 -- 192.168.1.50
  check '[ "$CODE" = 3 ]'; check 'out_has "Network debugging"'
}
err_unauthorized() {
  run_debloat '' MOCK_ADB_STATE=unauthorized -- 192.168.1.50
  check '[ "$CODE" = 3 ]'; check 'out_has "Always allow"'
}

measure_before_after() {
  local rd="$TMP_ROOT/measure"
  run_debloat '' -- 192.168.1.50 --measure before --reports-dir "$rd"
  check '[ "$CODE" = 0 ]'
  check '! log_has "$MUTATING"'
  sleep 1
  run_debloat '' MOCK_ADB_MEMINFO=meminfo-synthetic-after.txt -- 192.168.1.50 --measure after --reports-dir "$rd"
  check 'out_has "Free RAM +656,576K +900,000K +\+243,424K"'
  check 'out_has "Truly free +161,364K +250,000K +\+88,636K"'
  check 'out_has "Used RAM +1,551,191K +1,300,000K +-251,191K"'
}

list_without_tv() {
  run_debloat '' -- --list
  check '[ "$CODE" = 0 ]'
  check 'out_has com\.tcl\.guard'
  check '[ -z "$LOG" ]'
}

bad_flag() {
  run_debloat '' -- 192.168.1.50 --tier 9
  check '[ "$CODE" = 2 ]'
  check '[ -z "$LOG" ]'
}

echo "tv-debloat.sh tests (bash $BASH_VERSION)"
t "dry run makes zero mutating adb calls and writes no files" dry_run_zero_mutations
t "denylist is enforced in code" denylist_enforced_in_code
t "empty TSV fields don't shift columns" tsv_empty_fields_do_not_shift_columns
t "CRLF adb output is handled" crlf_output
t "multi-user: warns with 2 users" multi_user_warning
t "multi-user: no warning with 1 user" single_user_no_warning
t "multi-user: defaults to current user, honours --user" user_default_and_flag
t "multi-user: unknown --user is rejected" unknown_user_rejected
t "restore file: contents, disable fallback, failures" restore_file_contents
t "restore: replays only known lines (also CRLF .ps1 lines)" restore_replays_only_known_lines
t "prompts: tier 3 always asks, even with --yes" tier3_always_asks
t "prompts: closed stdin means no" closed_stdin_means_no
t "prompts: adb never swallows the answers" answers_not_swallowed_by_adb
t "prompts: --keep" keep_list
t "errors: 10060 explained" err_10060
t "errors: 10061 explained" err_10061
t "errors: unauthorized explained" err_unauthorized
t "measure: before/after diff table" measure_before_after
t "list works without a TV" list_without_tv
t "bad flag value exits 2 before touching adb" bad_flag

printf '\nPassed %s, Failed %s\n' "$PASS" "$FAILN"
[ "$FAILN" = 0 ] || { printf 'Failed:%s\n' "$FAILED_NAMES"; exit 1; }
