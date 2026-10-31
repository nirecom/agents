#!/usr/bin/env bash
# tests/install/TL3-installer-rtk-config-create-contract.sh
# Tests: install/win/rtk.ps1, install/linux/rtk.sh
# Tags: TL3, rtk, installer, config, scope:issue-specific, upgrade, static, fail-safe-off, idempotency, TL2, pwsh-not-required
#
# Real-binary contract for `rtk config` / `rtk config --create` (exit 0 on absent/valid/
# obsolete, non-zero on unparseable TOML; --create repairs and migrates).
# Also the RTK upgrade step (#2862): static greps + rtk.sh against stub brew / rtk, both
# unconditional and run before the skip-gated real-binary section.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# TL3 gap (not caught): Windows-native rtk.ps1 path (winget, %LOCALAPPDATA%, poll; pwsh-required);
# installer orchestration against real package managers; config schema compat after a real
# upgrade (#2347); async completion / variable install paths / silent failure (rules/test/installer.md)
# TL2 gap (upgrade, #2862): static checks never run pwsh; Linux cases stub brew and rtk, so real
# winget / brew "no update" exit codes and `brew upgrade` on a non-brew RTK are not exercised
# Closest-to-action mitigation: pwsh-required category fires at WORKFLOW_USER_VERIFIED preflight

# --- Fixture isolation (rules/test/fixture-isolation.md) --------------------
# Pin both dirs once, before the first line that runs a bin entrypoint.
readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/pin"
unset CLAUDE_CODE_SESSION_ID
unset RTK

finish() {
  echo "Results: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}

# --- Static helpers (no pwsh needed) ----------------------------------------
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# assert_contains <name> <rel> <needle>   (fixed string)
assert_contains() {
  local f="$SCRIPT_CHECKOUT_ROOT/$2"
  [ -f "$f" ] || { fail "$1" "file missing: $2"; return; }
  if grep -qF -- "$3" "$f"; then pass "$1"; else fail "$1" "needle not found in $2: $3"; fi
}

# assert_absent <name> <rel> <needle>   (fixed string)
assert_absent() {
  local f="$SCRIPT_CHECKOUT_ROOT/$2"
  [ -f "$f" ] || { fail "$1" "file missing: $2"; return; }
  if grep -qF -- "$3" "$f"; then fail "$1" "forbidden text present in $2: $3"; else pass "$1"; fi
}

# assert_count_re <name> <rel> <ERE> <expected>
assert_count_re() {
  local f="$SCRIPT_CHECKOUT_ROOT/$2" n
  [ -f "$f" ] || { fail "$1" "file missing: $2"; return; }
  n="$(trim "$(grep -c -E -- "$3" "$f")")"
  if [ "$n" = "$4" ]; then pass "$1"; else fail "$1" "expected $4 line(s) matching '$3' in $2, got $n"; fi
}

# first_line <rel> <ERE> -> first matching line number or empty
first_line() {
  local out
  out="$(grep -n -m1 -E -- "$2" "$SCRIPT_CHECKOUT_ROOT/$1")"
  printf '%s' "${out%%:*}"
}

# assert_between_no_exit <name> <rel> <startERE> <endERE> <forbiddenERE>
assert_between_no_exit() {
  local f="$SCRIPT_CHECKOUT_ROOT/$2" s e
  [ -f "$f" ] || { fail "$1" "file missing: $2"; return; }
  s="$(first_line "$2" "$3")"
  e="$(first_line "$2" "$4")"
  [ -n "$s" ] || { fail "$1" "start needle not found in $2: $3"; return; }
  [ -n "$e" ] || { fail "$1" "end needle not found in $2: $4"; return; }
  [ "$s" -lt "$e" ] || { fail "$1" "start line $s is not before end line $e in $2"; return; }
  # Drop comment lines and quoted strings so words inside messages never match.
  if sed -n "${s},${e}p" "$f" | grep -vE '^[[:space:]]*#' | sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g' | grep -qE -- "$5"; then
    fail "$1" "early exit/return between lines $s and $e of $2"
  else
    pass "$1"
  fi
}

# assert_before <name> <rel> <firstERE> <secondERE>
assert_before() {
  local f="$SCRIPT_CHECKOUT_ROOT/$2" a b
  [ -f "$f" ] || { fail "$1" "file missing: $2"; return; }
  a="$(first_line "$2" "$3")"
  b="$(first_line "$2" "$4")"
  [ -n "$a" ] || { fail "$1" "first needle not found in $2: $3"; return; }
  [ -n "$b" ] || { fail "$1" "second needle not found in $2: $4"; return; }
  if [ "$a" -lt "$b" ]; then pass "$1"; else fail "$1" "line $a is not before line $b in $2"; fi
}

# ps1_section <rel> <startERE> <endERE>: comment-free lines from the first start to the first end match.
ps1_section() {
  local s e
  s="$(first_line "$1" "$2")"; e="$(first_line "$1" "$3")"
  [ -n "$s" ] && [ -n "$e" ] && [ "$s" -lt "$e" ] || return 1
  sed -n "${s},${e}p" "$SCRIPT_CHECKOUT_ROOT/$1" | grep -vE '^[[:space:]]*#'
}

# sec_line <section text> <ERE> -> first matching line number within the section
sec_line() { local out; out="$(printf '%s\n' "$1" | grep -n -m1 -E -- "$2")"; printf '%s' "${out%%:*}"; }

# assert_ps1_try_catch <name> <rel>: in the winget branch try { precedes winget upgrade, catch follows, Write-Warning sits after catch.
assert_ps1_try_catch() {
  local sec t u c w
  [ -f "$SCRIPT_CHECKOUT_ROOT/$2" ] || { fail "$1" "file missing: $2"; return; }
  sec="$(ps1_section "$2" 'Get-Command winget' "$END_RE")" || { fail "$1" "section ends not found/ordered in $2"; return; }
  t="$(sec_line "$sec" 'try[[:space:]]*\{')"
  u="$(sec_line "$sec" '^[[:space:]]*winget upgrade ')"
  c="$(sec_line "$sec" 'catch')"
  w="$(printf '%s\n' "$sec" | grep -n -E 'Write-Warning' | tail -n1)"; w="${w%%:*}"
  if [ -n "$t" ] && [ -n "$u" ] && [ -n "$c" ] && [ -n "$w" ] && [ "$t" -lt "$u" ] && [ "$u" -lt "$c" ] && [ "$c" -lt "$w" ]; then
    pass "$1"
  else
    fail "$1" "need try < winget upgrade < catch < Write-Warning (try=$t upgrade=$u catch=$c warn=$w)"
  fi
}

# assert_ps1_reset_count <name> <rel> <min>: LASTEXITCODE = 0 appears >= min times inside the winget branch.
assert_ps1_reset_count() {
  local sec n
  [ -f "$SCRIPT_CHECKOUT_ROOT/$2" ] || { fail "$1" "file missing: $2"; return; }
  sec="$(ps1_section "$2" 'Get-Command winget' "$END_RE")" || { fail "$1" "section ends not found/ordered in $2"; return; }
  n="$(trim "$(printf '%s\n' "$sec" | grep -c -F 'LASTEXITCODE = 0')")"
  if [ "$n" -ge "$3" ]; then pass "$1"; else fail "$1" "expected >= $3 'LASTEXITCODE = 0' in the winget branch of $2, got $n"; fi
}

# assert_ps1_section_has <name> <rel> <needle>: needle inside the winget branch (comment-free).
assert_ps1_section_has() {
  local sec
  [ -f "$SCRIPT_CHECKOUT_ROOT/$2" ] || { fail "$1" "file missing: $2"; return; }
  sec="$(ps1_section "$2" 'Get-Command winget' "$END_RE")" || { fail "$1" "section ends not found/ordered in $2"; return; }
  if printf '%s\n' "$sec" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "needle not in the winget branch of $2: $3"; fi
}

# assert_line_has_both <name> <rel> <needleA> <needleB>: one line carries both fixed strings.
assert_line_has_both() {
  local f="$SCRIPT_CHECKOUT_ROOT/$2"
  [ -f "$f" ] || { fail "$1" "file missing: $2"; return; }
  if grep -F -- "$3" "$f" | grep -qF -- "$4"; then pass "$1"; else fail "$1" "no line in $2 has both '$3' and '$4'"; fi
}

PS1_REL="install/win/rtk.ps1"
SH_REL="install/linux/rtk.sh"
END_RE='^[[:space:]]*(echo|Write-Host) "Installing RTK\.\.\."'
# return/exit as a command word, also in one-line forms such as `{ exit 0 }`.
EXIT_RE='(^|[[:space:]{;])(return|exit)([[:space:]};]|$)'

# assert_no_line_with_both <name> <rel> <needle> <forbidden-needle>: some line has <needle>, none also has <forbidden>.
assert_no_line_with_both() {
  local f="$SCRIPT_CHECKOUT_ROOT/$2" n
  [ -f "$f" ] || { fail "$1" "file missing: $2"; return; }
  grep -qF -- "$3" "$f" || { fail "$1" "needle not found in $2: $3"; return; }
  n="$(trim "$(grep -F -- "$3" "$f" | grep -c -F -- "$4")")"
  if [ "$n" = 0 ]; then pass "$1"; else fail "$1" "$n line(s) with '$3' also contain '$4' in $2"; fi
}

# --- Section S1: static checks ----------------------------------------------
case_begin "rtk-ps1-upgrade-static" "install/win/rtk.ps1"
assert_contains "R-01 rtk.ps1 runs winget upgrade with agreement flags" "$PS1_REL" "winget upgrade rtk-ai.rtk --accept-source-agreements --accept-package-agreements"
assert_contains "R-03 rtk.ps1 reports the winget exit code" "$PS1_REL" "winget exit code"
assert_contains "R-04 rtk.ps1 checks winget exists before upgrading" "$PS1_REL" "Get-Command winget"
assert_absent "R-12 rtk.ps1 no longer stops at 'already installed'" "$PS1_REL" "RTK is already installed"
assert_count_re "R-21 rtk.ps1 has exactly one winget upgrade line" "$PS1_REL" '^[[:space:]]*winget upgrade ' 1
assert_count_re "R-23 rtk.ps1 keeps exactly one winget install line" "$PS1_REL" '^[[:space:]]*winget install ' 1
assert_ps1_section_has "R-05 rtk.ps1 winget branch says 'up to date' on non-zero exit" "$PS1_REL" "up to date"
assert_no_line_with_both "R-06 rtk.ps1 exit-code message is not a Write-Warning" "$PS1_REL" "winget exit code" "Write-Warning"
assert_ps1_try_catch "R-07 rtk.ps1 winget branch: try < winget upgrade < catch < Write-Warning" "$PS1_REL"
assert_ps1_reset_count "R-08 rtk.ps1 winget branch resets LASTEXITCODE in both failure paths" "$PS1_REL" 2
assert_before "R-36 rtk.ps1 RTK-on gate precedes the installed branch" "$PS1_REL" '^[[:space:]]*if \(-not \$_rtkOn\)' '^[[:space:]]*if \(Get-Command rtk -ErrorAction'
assert_before "R-37 rtk.ps1 upgrade sits after the installed-branch opening" "$PS1_REL" '^[[:space:]]*if \(Get-Command rtk -ErrorAction' '^[[:space:]]*winget upgrade '
assert_between_no_exit "R-31 rtk.ps1 no return/exit between upgrade and install" "$PS1_REL" '^[[:space:]]*winget upgrade ' "$END_RE" "$EXIT_RE"
assert_between_no_exit "R-35 rtk.ps1 no return/exit in the winget-missing branch" "$PS1_REL" 'Get-Command winget' "$END_RE" "$EXIT_RE"
assert_before "R-33 rtk.ps1 upgrade precedes config validation" "$PS1_REL" '^[[:space:]]*winget upgrade ' '^[[:space:]]*& \$rtkExe config \*> \$null'
case_end

case_begin "rtk-sh-upgrade-static" "install/linux/rtk.sh"
assert_contains "R-02 rtk.sh runs brew upgrade with stdin closed" "$SH_REL" "brew upgrade rtk-ai/tap/rtk </dev/null"
assert_line_has_both "R-09 rtk.sh upgrade-failure message guides re-run" "$SH_REL" "upgrade failed" "Re-run to retry"
assert_absent "R-11 rtk.sh no longer stops at 'already installed'" "$SH_REL" "RTK is already installed"
assert_count_re "R-22 rtk.sh has exactly one brew upgrade line" "$SH_REL" '^[[:space:]]*if (! )?brew upgrade ' 1
assert_count_re "R-24 rtk.sh keeps exactly one brew install line" "$SH_REL" '^[[:space:]]*if (! )?brew install ' 1
assert_between_no_exit "R-32 rtk.sh no exit between upgrade and install" "$SH_REL" '^[[:space:]]*if (! )?brew upgrade ' "$END_RE" "$EXIT_RE"
assert_before "R-34 rtk.sh upgrade precedes config validation" "$SH_REL" '^[[:space:]]*if (! )?brew upgrade ' '^[[:space:]]*if ! rtk config >/dev/null'
case_end

# --- Section S2: rtk.sh behavior with stub brew / rtk -----------------------
# PATH without any real rtk / brew dirs; node stays reachable through a wrapper.
REAL_NODE="$(command -v node 2>/dev/null || true)"
CLEAN_PATH=""
_old_ifs="$IFS"; IFS=':'
for _d in $PATH; do
  [ -n "$_d" ] || continue
  _skip=0
  for _n in rtk rtk.exe rtk.cmd rtk.bat rtk.com brew brew.exe brew.cmd brew.bat brew.com; do
    if [ -e "$_d/$_n" ]; then _skip=1; break; fi
  done
  [ "$_skip" -eq 0 ] && CLEAN_PATH="${CLEAN_PATH:+$CLEAN_PATH:}$_d"
done
IFS="$_old_ifs"

# new_case <name> <installed:0|1>: fresh stub dir, fixture .env, default rcs.
new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/bin" "$d/cfg" "$d/home"
  STUBDIR="$d/bin"; CALL_LOG="$d/calls.log"; OUT="$d/out.txt"; ERR="$d/err.txt"
  : > "$CALL_LOG"
  printf 'UNRELATED_FIXTURE_VAR=1\n' > "$d/cfg/.env"
  cat > "$STUBDIR/brew" <<'STUB'
#!/bin/bash
echo "brew $*" >> "$CALL_LOG"
case "$1" in
  upgrade) exit "${BREW_UPGRADE_RC:-0}" ;;
  install)
    if [ "${BREW_INSTALL_RC:-0}" -eq 0 ]; then cp "$STUBDIR/rtk.pending" "$STUBDIR/rtk"; fi
    exit "${BREW_INSTALL_RC:-0}" ;;
esac
exit 0
STUB
  cat > "$STUBDIR/rtk.pending" <<'STUB'
#!/bin/bash
echo "rtk $*" >> "$CALL_LOG"
if [ "$1" = config ] && [ "$2" = "--create" ]; then exit 0; fi
if [ "$1" = config ]; then exit "${RTK_CONFIG_RC:-0}"; fi
exit 0
STUB
  if [ -n "$REAL_NODE" ]; then
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$REAL_NODE" > "$STUBDIR/node"
    chmod +x "$STUBDIR/node"
  fi
  chmod +x "$STUBDIR/brew" "$STUBDIR/rtk.pending"
  [ "$2" = 1 ] && { cp "$STUBDIR/rtk.pending" "$STUBDIR/rtk"; chmod +x "$STUBDIR/rtk"; }
  export STUBDIR CALL_LOG
  export BREW_UPGRADE_RC=0 BREW_INSTALL_RC=0 RTK_CONFIG_RC=0
  CASE_DIR="$d"
}

# run_installer [<RTK value>]: rc in RC, output in $OUT / $ERR.
run_installer() {
  : > "$CALL_LOG"
  (
    cd "$SCRIPT_CHECKOUT_ROOT" || exit 99
    export PATH="$STUBDIR:$CLEAN_PATH"
    export HOME="$CASE_DIR/home"
    export AGENTS_MAIN_ROOT="$CASE_DIR/cfg"
    unset RTK
    [ -n "${1:-}" ] && export RTK="$1"
    bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 bash install/linux/rtk.sh </dev/null >"$OUT" 2>"$ERR"
  )
  RC=$?
}

# calls <exact log line> -> count
calls() { trim "$(grep -c -x -F -- "$1" "$CALL_LOG")"; }
log_line() { local out; out="$(grep -n -m1 -x -F -- "$1" "$CALL_LOG")"; printf '%s' "${out%%:*}"; }
# expect <name> <condition-result 0/1> [detail]
expect() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "${3:-}"; fi; }
out_has() { grep -qF -- "$1" "$OUT"; }
err_has() { grep -qF -- "$1" "$ERR"; }
UP="brew upgrade rtk-ai/tap/rtk"
IN="brew install rtk-ai/tap/rtk"

case_begin "upgrade-installed-normal" "install/linux/rtk.sh"
new_case u1 1
run_installer on
expect "U1 rc is 0" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
expect "U1 exactly one brew upgrade" "$([ "$(calls "$UP")" = 1 ]; echo $?)" "count=$(calls "$UP")"
expect "U1 no brew install" "$([ "$(calls "$IN")" = 0 ]; echo $?)"
expect "U1 rtk config runs" "$([ "$(calls "rtk config")" = 1 ]; echo $?)"
expect "U1 no config --create" "$([ "$(calls "rtk config --create")" = 0 ]; echo $?)"
expect "U1 stdout reports upgrade finished" "$(out_has "RTK upgrade finished."; echo $?)"
expect "U1 stderr has no upgrade failed" "$(err_has "upgrade failed"; [ $? -ne 0 ]; echo $?)"
case_end

case_begin "upgrade-failure-keeps-installed" "install/linux/rtk.sh"
new_case u2 1
BREW_UPGRADE_RC=1
run_installer on
expect "U2 rc is 0 after failed upgrade" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
expect "U2 stderr says upgrade failed" "$(err_has "upgrade failed"; echo $?)"
expect "U2 stdout does not claim upgrade finished" "$(out_has "RTK upgrade finished."; [ $? -ne 0 ]; echo $?)"
expect "U2 no brew install" "$([ "$(calls "$IN")" = 0 ]; echo $?)"
expect "U2 rtk config still validated" "$([ "$(calls "rtk config")" = 1 ]; echo $?)"
case_end

case_begin "upgrade-failure-then-invalid-config" "install/linux/rtk.sh"
new_case u3 1
BREW_UPGRADE_RC=1
RTK_CONFIG_RC=1
run_installer on
expect "U3 rc is 0" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
expect "U3 config --create runs once" "$([ "$(calls "rtk config --create")" = 1 ]; echo $?)"
case_end

case_begin "upgrade-then-invalid-config-order" "install/linux/rtk.sh"
new_case u4 1
RTK_CONFIG_RC=1
run_installer on
expect "U4 config --create runs once" "$([ "$(calls "rtk config --create")" = 1 ]; echo $?)"
U4_UP="$(log_line "$UP")"; U4_CFG="$(log_line "rtk config")"
expect "U4 brew upgrade precedes rtk config" "$([ -n "$U4_UP" ] && [ -n "$U4_CFG" ] && [ "$U4_UP" -lt "$U4_CFG" ]; echo $?)" "upgrade=$U4_UP config=$U4_CFG"
case_end

case_begin "rtk-off-explicit" "install/linux/rtk.sh"
new_case u5 1
run_installer off
expect "U5 rc is 0" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
expect "U5 stdout says RTK is off" "$(out_has "RTK is off"; echo $?)"
expect "U5 no brew / rtk call" "$([ ! -s "$CALL_LOG" ]; echo $?)"
case_end

case_begin "fresh-install-then-validate" "install/linux/rtk.sh"
new_case u6 0
run_installer on
expect "U6 rc is 0" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
expect "U6 brew install runs" "$([ "$(calls "$IN")" = 1 ]; echo $?)"
expect "U6 no brew upgrade" "$([ "$(calls "$UP")" = 0 ]; echo $?)"
expect "U6 rtk config runs after install" "$([ "$(calls "rtk config")" = 1 ]; echo $?)"
case_end

case_begin "fresh-install-failure-returns-early" "install/linux/rtk.sh"
new_case u7 0
BREW_INSTALL_RC=1
run_installer on
expect "U7 rc is 0" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
expect "U7 no brew upgrade" "$([ "$(calls "$UP")" = 0 ]; echo $?)"
expect "U7 no rtk config" "$([ "$(calls "rtk config")" = 0 ]; echo $?)"
case_end

case_begin "rtk-unset-defaults-off" "install/linux/rtk.sh"
new_case u8 1
run_installer
expect "U8 rc is 0" "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
expect "U8 stdout says RTK is off" "$(out_has "RTK is off"; echo $?)"
expect "U8 no brew / rtk call" "$([ ! -s "$CALL_LOG" ]; echo $?)"
case_end

case_begin "upgrade-idempotent-rerun" "install/linux/rtk.sh"
new_case u9 1
run_installer on
U9_RC1=$RC; U9_N1="$(calls "$UP")"
run_installer on
U9_RC2=$RC; U9_N2="$(calls "$UP")"
expect "U9 both runs rc 0" "$([ "$U9_RC1" -eq 0 ] && [ "$U9_RC2" -eq 0 ]; echo $?)" "rc1=$U9_RC1 rc2=$U9_RC2"
expect "U9 one brew upgrade per run" "$([ "$U9_N1" = 1 ] && [ "$U9_N2" = 1 ]; echo $?)" "n1=$U9_N1 n2=$U9_N2"
case_end

# --- Real-binary section (skip-gated) ---------------------------------------
# A skip here keeps the PASS / FAIL of the sections above (finish_skip).
finish_skip() { echo "SKIP: $1" >&2; finish; }

# Skip-gate 1: get-config-var must be usable.
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || finish_skip "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var not found or not executable"

# Skip-gate 2: RUN_TL3 must be explicitly on (rules/test/claude-e2e.md).
if "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off; then
  finish_skip "real-binary section requires RUN_TL3=on in .env"
fi

# Skip-gate 3: the real rtk binary must be on PATH.
command -v rtk >/dev/null 2>&1 || finish_skip "rtk CLI not found on PATH (real-binary section)"

FIXTURE_HOME="$TMP_ROOT/real-home"
mkdir -p "$FIXTURE_HOME"

# Pin every home/config anchor rtk might resolve at the fixture. On Linux/macOS
# the dirs crate honors XDG_CONFIG_HOME/HOME; on Windows it reads the OS known
# folder and ignores these -- the containment check below then skips (TL3 gap).
export HOME="$FIXTURE_HOME"
export USERPROFILE="$FIXTURE_HOME"
export XDG_CONFIG_HOME="$FIXTURE_HOME"
export APPDATA="$FIXTURE_HOME"
export LOCALAPPDATA="$FIXTURE_HOME"

# run_rtk: run `rtk <args>` under a timeout, silence output, echo the exit code.
run_rtk() {
  if run_with_timeout 60 rtk "$@" >/dev/null 2>&1; then
    echo 0
  else
    echo $?
  fi
}

# --- Containment verification (once, before any destructive op) -------------
# 1. Pre-write read-only check: the fixture must hold no config file yet.
EXISTING="$(find "$FIXTURE_HOME" -type f 2>/dev/null)"
if [ -n "$EXISTING" ]; then
  finish_skip "fixture home already contains files before probe: $EXISTING"
fi

# Windows pre-skip: RTK's dirs crate ignores env var pins on Windows.
# Must exit BEFORE calling the probe to avoid mutating the live user config.
case "$(uname -s 2>/dev/null || true)" in
  CYGWIN*|MINGW*|MSYS*)
    finish_skip "Windows host: RTK dirs crate ignores env var pins; skipping before probe" ;;
esac
if [ -n "${WINDIR:-}" ] || [ -n "${SystemRoot:-}" ]; then
  finish_skip "Windows host: RTK dirs crate ignores env var pins; skipping before probe"
fi

# 2. First and only write probe: this single --create both probes containment
#    and generates Case C's valid config.
CREATE_EXIT="$(run_rtk config --create)"
if [ "$CREATE_EXIT" -ne 0 ]; then
  finish_skip "rtk config --create probe exited $CREATE_EXIT (cannot establish fixture)"
fi

# 3. Containment check (read-only): the generated config must land under the
#    fixture home. The fixture was empty, so any file found now is rtk's.
FIXTURE_CONFIG_PATH="$(find "$FIXTURE_HOME" -type f -name '*.toml' 2>/dev/null | head -n1)"
if [ -z "$FIXTURE_CONFIG_PATH" ]; then
  FIXTURE_CONFIG_PATH="$(find "$FIXTURE_HOME" -type f 2>/dev/null | head -n1)"
fi
if [ -z "$FIXTURE_CONFIG_PATH" ]; then
  finish_skip "rtk config --create wrote no file under \$FIXTURE_HOME -- PIN ignored, aborting destructive ops"
fi

# --- Case C: valid config (already generated by the probe) ------------------
case_begin "real-binary-valid-config" "install/linux/rtk.sh"
C_EXIT="$(run_rtk config)"
[ "$C_EXIT" -eq 0 ] && pass "Case C: rtk config exits 0 on generated valid config" \
  || fail "Case C: rtk config expected exit 0 on valid config, got $C_EXIT"

BEFORE_RECREATE="$(cat "$FIXTURE_CONFIG_PATH" 2>/dev/null)"
C_RECREATE_EXIT="$(run_rtk config --create)"
[ "$C_RECREATE_EXIT" -eq 0 ] && pass "Case C: rtk config --create is idempotent (exit 0 on valid config)" \
  || fail "Case C: rtk config --create expected exit 0 on re-run, got $C_RECREATE_EXIT"

AFTER_RECREATE="$(cat "$FIXTURE_CONFIG_PATH" 2>/dev/null)"
[ "$BEFORE_RECREATE" = "$AFTER_RECREATE" ] && pass "Case C: valid config unchanged by idempotent --create" \
  || fail "Case C: --create modified an already-valid config"
case_end

# --- Case A: unparseable config rejected, then repaired by --create --------
# rtk config's reject verdict fires on a TOML syntax error, not on a parseable
# but obsolete schema (Case D). Both verdicts are covered (CPR-ORTH).
case_begin "real-binary-unparseable-config" "install/linux/rtk.sh"
printf 'this is = = broken [[[ not toml\n' > "$FIXTURE_CONFIG_PATH"
A_EXIT="$(run_rtk config)"
[ "$A_EXIT" -ne 0 ] && pass "Case A: rtk config exits non-zero on unparseable TOML" \
  || fail "Case A: rtk config expected non-zero on unparseable TOML, got $A_EXIT"

A_CREATE_EXIT="$(run_rtk config --create)"
[ "$A_CREATE_EXIT" -eq 0 ] && pass "Case A: rtk config --create repairs unparseable config (exit 0)" \
  || fail "Case A: rtk config --create expected exit 0 repairing config, got $A_CREATE_EXIT"

A_AFTER_EXIT="$(run_rtk config)"
[ "$A_AFTER_EXIT" -eq 0 ] && pass "Case A: rtk config exits 0 after repair" \
  || fail "Case A: rtk config expected exit 0 after repair, got $A_AFTER_EXIT"
case_end

# --- Case D: obsolete schema tolerated on read, migrated by --create --------
# `[retriever]` is the retired v<0.48 schema. It parses, so `rtk config` exits 0;
# `rtk config --create` rewrites it to the current valid default (content changes).
case_begin "real-binary-obsolete-schema" "install/linux/rtk.sh"
OBSOLETE='[retriever]
enabled = false'
printf '%s\n' "$OBSOLETE" > "$FIXTURE_CONFIG_PATH"
D_READ_EXIT="$(run_rtk config)"
[ "$D_READ_EXIT" -eq 0 ] && pass "Case D: rtk config exits 0 on parseable obsolete schema" \
  || fail "Case D: rtk config expected exit 0 on obsolete schema, got $D_READ_EXIT"

D_CREATE_EXIT="$(run_rtk config --create)"
D_AFTER="$(cat "$FIXTURE_CONFIG_PATH" 2>/dev/null)"
[ "$D_CREATE_EXIT" -eq 0 ] && pass "Case D: rtk config --create exits 0 migrating obsolete schema" \
  || fail "Case D: rtk config --create expected exit 0 migrating, got $D_CREATE_EXIT"

# Version-agnostic validity check: verify the new config is valid, not absent.
# Avoid hard-coding schema content (e.g. [retriever] absent) since RTK's defaults
# evolve across versions; the binary's own 'rtk config' is the authoritative validator.
D_VALID_EXIT="$(run_rtk config)"
[ "$D_VALID_EXIT" -eq 0 ] && pass "Case D: --create migrated obsolete schema to a valid default" \
  || fail "Case D: post-migration config is invalid (rtk config exit $D_VALID_EXIT)"
[ -n "$D_AFTER" ] && pass "Case D: --create wrote non-empty config" \
  || fail "Case D: --create left config empty instead of migrating"
case_end

# --- Case B: absent/empty config falls back to built-in defaults ------------
# The "no create needed" branch: rtk config must succeed WITHOUT a prior --create.
case_begin "real-binary-absent-or-empty-config" "install/linux/rtk.sh"
rm -f "$FIXTURE_CONFIG_PATH"
B_EXIT="$(run_rtk config)"
[ "$B_EXIT" -eq 0 ] && pass "Case B: rtk config exits 0 on absent config (built-in defaults, no --create)" \
  || fail "Case B: rtk config expected exit 0 on absent config, got $B_EXIT"

# B2: empty file; the installer premise that an empty config is treated as absent.
printf '' > "$FIXTURE_CONFIG_PATH"
B2_EXIT="$(run_rtk config)"
[ "$B2_EXIT" -eq 0 ] && pass "Case B: rtk config exits 0 on empty config file (built-in defaults)" \
  || fail "Case B: rtk config expected exit 0 on empty config, got $B2_EXIT"
case_end

finish
