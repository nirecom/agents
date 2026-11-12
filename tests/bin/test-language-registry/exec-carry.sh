# RUN_TL3 / RUN_TL4 carry of rtb_exec_one (#2997): the base test gets the values this checkout's
# run_all_carried_read reads (environment first, then the real settings), read before the base
# launcher's decoy switch. Sourced by the dispatcher.
# TL3 gap (not caught here): a stub get-config-var always succeeds, so a real session whose actual
# settings read fails (settings dir not found, bridge names unreadable) still carries nothing; only a
# real run-tests session shows it. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh, category skill-orchestration.
# shellcheck shell=bash

echo ""
echo "=== exec carry ==="

# The real settings are a stub get-config-var in a fixture copy of bin/lib; every probe unsets the
# inherited RUN_TL3 / RUN_TL4, so only a settings-only value detects the regression.

# carry_lib <dir> [tl4] — <dir>/bin/lib is a copy of this checkout's bin/lib and <dir>/bin/get-config-var
# a stub that answers on for RUN_TL3 and <tl4> (default cfg-RUN_TL4, may be empty) for RUN_TL4.
carry_lib() {
  local d="$1" tl4="${2-cfg-RUN_TL4}"
  mkdir -p "$d/bin"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$d/bin/" || return 1
  cat >"$d/bin/get-config-var" <<EOF
#!/usr/bin/env bash
if [ "\$1" = RUN_TL3 ]; then echo on; fi
if [ "\$1" = RUN_TL4 ]; then echo '$tl4'; fi
exit 0
EOF
}

# carry_decoy_aware_lib <dir> <real-root> — like carry_lib, but the stub answers (on / cfg-RUN_TL4)
# only while AGENTS_MAIN_ROOT is <real-root>, and nothing under any other root.
carry_decoy_aware_lib() {
  local d="$1" real="$2"
  mkdir -p "$d/bin"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$d/bin/" || return 1
  cat >"$d/bin/get-config-var" <<EOF
#!/usr/bin/env bash
[ "\${AGENTS_MAIN_ROOT:-}" = "$real" ] || exit 0
if [ "\$1" = RUN_TL3 ]; then echo on; fi
if [ "\$1" = RUN_TL4 ]; then echo cfg-RUN_TL4; fi
exit 0
EOF
}

# The probe: one rtb_exec_one of the lib given as $1, then "RET=<n> RC=<n> STATE=<s> LEAK=<n>" where
# LEAK counts the launcher functions left in the caller. Arguments: lib, rel path, logdir, worktree.
CARRY_PROBE="$TMPBASE/carry-probe.sh"
cat >"$CARRY_PROBE" <<'EOF'
. "$1" || exit 98
rtb_exec_one "$4" "$2" 10 "$3"
ret=$?
n=0
for f in run_all_pin_root_decoy run_all_pin_command_guard run_all_pin_worktree_change_detect; do
  if declare -F "$f" >/dev/null 2>&1; then n=$((n + 1)); fi
done
printf 'RET=%s RC=%s STATE=%s LEAK=%s\n' "$ret" "${RTB_EXEC_RC:-unset}" "${RTB_EXEC_STATE:-unset}" "$n"
EOF

# carry_probe <carry-dir> <wt> <rel-path> <logdir> [VAR=val...] — the probe from <wt>; only the given
# VAR=val are exported (RUN_TL3 / RUN_TL4 are unset first).
carry_probe() {
  local lib="$1/bin/lib/run-tests-baseline-exec.sh" wt="$2" rel="$3" logdir="$4" a
  shift 4
  mkdir -p "$logdir"
  (
    unset RUN_TL3 RUN_TL4
    for a in "$@"; do export "$a"; done
    cd "$wt" && run_with_timeout 60 bash "$CARRY_PROBE" "$lib" "$rel" "$logdir" "$wt" 2>/dev/null | grep '^RET=' | tail -1
  )
}

# carry_out <logdir> — the base test's output file as one line.
carry_out() { tr '\n' ' ' <"$1/1.out" 2>/dev/null; }

# carry_launcher_reports <wt> — a base launcher without the carry parts: run_all_exec writes
# TL3 / TL4 / PF (is the decoy pin defined) to <out>.
carry_launcher_reports() {
  mkdir -p "$1/bin/lib"
  cat >"$1/bin/lib/run-all-launch.sh" <<'EOF'
run_all_exec() {
  printf 'TL3=%s TL4=%s PF=no\n' "${RUN_TL3-<unset>}" "${RUN_TL4-<unset>}" >"$2"
  return 0
}
EOF
}

# carry_launcher_decoy_pin <wt> <decoy-root> — a base launcher whose decoy pin re-points
# AGENTS_MAIN_ROOT; run_all_exec writes TL3 / TL4 / ROOT to <out>.
carry_launcher_decoy_pin() {
  mkdir -p "$1/bin/lib"
  cat >"$1/bin/lib/run-all-launch.sh" <<EOF
run_all_pin_root_decoy() { export AGENTS_MAIN_ROOT="$2"; }
run_all_exec() {
  printf 'TL3=%s TL4=%s ROOT=%s\n' "\${RUN_TL3-<unset>}" "\${RUN_TL4-<unset>}" "\$AGENTS_MAIN_ROOT" >"\$2"
  return 0
}
EOF
}

# carry_launcher_marker <wt> <marker-file> — a base launcher whose decoy pin records TL3 / TL4 as seen then.
carry_launcher_marker() {
  mkdir -p "$1/bin/lib"
  cat >"$1/bin/lib/run-all-launch.sh" <<EOF
run_all_pin_root_decoy() { printf 'TL3=%s TL4=%s' "\${RUN_TL3-<unset>}" "\${RUN_TL4-<unset>}" >"$2"; }
run_all_exec() { return 0; }
EOF
}

# carry_launcher_calls <wt> <marker-file> [full] — a base launcher that appends "<function>:<RUN_TL3>" to
# <marker-file> as each pin runs; with "full" it also defines the run root and the two later pins
# (command guard, worktree change detection), as a current base does.
carry_launcher_calls() {
  mkdir -p "$1/bin/lib"
  cat >"$1/bin/lib/run-all-launch.sh" <<EOF
run_all_pin_root_decoy() { echo "decoy:\${RUN_TL3-<unset>}" >>"$2"; }
run_all_exec() { echo "exec:\${RUN_TL3-<unset>}" >>"$2"; return 0; }
EOF
  if [ "${3:-}" = full ]; then
    cat >>"$1/bin/lib/run-all-launch.sh" <<EOF
test_run_root_ensure() { echo "run-root:\${RUN_TL3-<unset>}" >>"$2"; }
run_all_pin_command_guard() { echo "guard:\${RUN_TL3-<unset>}" >>"$2"; }
run_all_pin_worktree_change_detect() { echo "wcd:\${RUN_TL3-<unset>}" >>"$2"; }
EOF
  fi
}

# carry_bad_launcher <dir> <mode> — a carry lib whose launcher cannot be read: source-fails or function-missing.
carry_bad_launcher() {
  carry_lib "$1" || return 1
  if [ "$2" = source-fails ]; then
    printf 'return 1\n' >"$1/bin/lib/run-all-launch.sh"
  else
    printf ':\n' >"$1/bin/lib/run-all-launch.sh"
  fi
}

CARRY_FX="$TMPBASE/carry-fx"
CARRY_WT="$TMPBASE/carry-wt"
CARRY_LOGS="$TMPBASE/carry-logs"
mkdir -p "$CARRY_LOGS"
fx_checkout "$CARRY_WT"
mkdir -p "$CARRY_WT/tests/bin"
printf '#!/usr/bin/env bash\nexit 77\n' >"$CARRY_WT/tests/bin/test-skip.sh"
carry_lib "$CARRY_FX" || fail "carry: fixture error - carry_lib failed"
carry_launcher_reports "$CARRY_WT"

case_begin "carry-settings-only-values-reach-an-old-base" "bin/lib/run-tests-baseline-exec.sh"
CARRY_R1="$(carry_probe "$CARRY_FX" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/old-base")"
CARRY_OUT="$(carry_out "$CARRY_LOGS/old-base")"
assert_eq "old base launcher: $CARRY_OUT" "old base launcher: TL3=on TL4=cfg-RUN_TL4 PF=no "
case_end

case_begin "carry-environment-beats-settings-for-the-first-key" "bin/lib/run-tests-baseline-exec.sh"
# Pins the priority rule; the TL3 half is not regression detection (an exported value reaches the test anyway).
carry_probe "$CARRY_FX" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/env-first" RUN_TL3=off >/dev/null
assert_eq "RUN_TL3=off exported: $(carry_out "$CARRY_LOGS/env-first")" "RUN_TL3=off exported: TL3=off TL4=cfg-RUN_TL4 PF=no "
case_end

case_begin "carry-reading-launcher-does-not-leak-into-the-caller" "bin/lib/run-tests-baseline-exec.sh"
assert_eq "probe of the settings-only run: $CARRY_R1" "probe of the settings-only run: RET=0 RC=0 STATE=unset LEAK=0"
case_end

case_begin "carry-environment-beats-settings-for-the-second-key" "bin/lib/run-tests-baseline-exec.sh"
carry_probe "$CARRY_FX" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/env-second" RUN_TL4=off >/dev/null
assert_eq "RUN_TL4=off exported: $(carry_out "$CARRY_LOGS/env-second")" "RUN_TL4=off exported: TL3=on TL4=off PF=no "
case_end

case_begin "carry-empty-last-setting-is-omitted-and-rtb-exec-one-returns-zero" "bin/lib/run-tests-baseline-exec.sh"
CARRY_FX_EMPTY="$TMPBASE/carry-fx-tl4empty"
carry_lib "$CARRY_FX_EMPTY" "" || fail "carry: fixture error - carry_lib failed"
CARRY_R="$(carry_probe "$CARRY_FX_EMPTY" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/tl4-empty")"
assert_eq "RUN_TL4 empty: $(carry_out "$CARRY_LOGS/tl4-empty") ${CARRY_R%% *}" "RUN_TL4 empty: TL3=on TL4=<unset> PF=no  RET=0"
case_end

case_begin "carry-unreadable-launcher-carries-nothing-and-the-base-runs" "bin/lib/run-tests-baseline-exec.sh"
# Not regression detection: a launcher that cannot be read leaves the carry empty, the base still runs.
for CARRY_MODE in source-fails function-missing; do
  carry_bad_launcher "$TMPBASE/carry-fx-bad-$CARRY_MODE" "$CARRY_MODE" || fail "carry: fixture error - carry_bad_launcher failed"
  CARRY_R="$(carry_probe "$TMPBASE/carry-fx-bad-$CARRY_MODE" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/bad-$CARRY_MODE")"
  assert_eq "$CARRY_MODE: $(carry_out "$CARRY_LOGS/bad-$CARRY_MODE") ${CARRY_R%% *}" "$CARRY_MODE: TL3=<unset> TL4=<unset> PF=no  RET=0"
done
case_end

case_begin "carry-reads-the-settings-before-the-decoy-pin" "bin/lib/run-tests-baseline-exec.sh"
CARRY_REAL_ROOT="$TMPBASE/carry-real-root"
CARRY_DECOY_ROOT="$TMPBASE/carry-decoy-root"
carry_decoy_aware_lib "$TMPBASE/carry-fx-decoy" "$CARRY_REAL_ROOT" || fail "carry: fixture error - carry_decoy_aware_lib failed"
carry_launcher_decoy_pin "$CARRY_WT" "$CARRY_DECOY_ROOT"
carry_probe "$TMPBASE/carry-fx-decoy" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/before-decoy" "AGENTS_MAIN_ROOT=$CARRY_REAL_ROOT" >/dev/null
assert_eq "real-root settings after the decoy pin: $(carry_out "$CARRY_LOGS/before-decoy")" "real-root settings after the decoy pin: TL3=on TL4=cfg-RUN_TL4 ROOT=$CARRY_DECOY_ROOT "
case_end

case_begin "carry-exports-before-the-base-decoy-pin" "bin/lib/run-tests-baseline-exec.sh"
rm -f "$CARRY_LOGS/pin.marker"
carry_launcher_marker "$CARRY_WT" "$CARRY_LOGS/pin.marker"
carry_probe "$CARRY_FX" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/export-order" >/dev/null
CARRY_MARKER="$(cat "$CARRY_LOGS/pin.marker" 2>/dev/null || printf '<no marker>')"
assert_eq "values seen by the decoy pin: $CARRY_MARKER" "values seen by the decoy pin: TL3=on TL4=cfg-RUN_TL4"
case_end

case_begin "carry-values-are-exported-before-every-base-pin-and-the-test" "bin/lib/run-tests-baseline-exec.sh"
# A base with the run root, command guard and worktree change detection: all of them run, in order,
# after the carried values are exported and before the test.
rm -f "$CARRY_LOGS/calls-full.marker"
carry_launcher_calls "$CARRY_WT" "$CARRY_LOGS/calls-full.marker" full
carry_probe "$CARRY_FX" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/calls-full" >/dev/null
assert_eq "pin order with RUN_TL3: $(tr '\n' ' ' <"$CARRY_LOGS/calls-full.marker" 2>/dev/null)" "pin order with RUN_TL3: decoy:on run-root:on guard:on wcd:on exec:on "
case_end

case_begin "carry-base-without-guard-or-change-detection-still-runs-the-test" "bin/lib/run-tests-baseline-exec.sh"
# An old base has neither pin: they are skipped, the decoy pin and the test still run with the carried values.
rm -f "$CARRY_LOGS/calls-old.marker"
carry_launcher_calls "$CARRY_WT" "$CARRY_LOGS/calls-old.marker"
CARRY_R="$(carry_probe "$CARRY_FX" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/calls-old")"
assert_eq "old base calls: $(tr '\n' ' ' <"$CARRY_LOGS/calls-old.marker" 2>/dev/null) ${CARRY_R%% *}" "old base calls: decoy:on exec:on  RET=0"
case_end

case_begin "carry-value-with-a-line-break-cannot-forge-another-key" "bin/lib/run-tests-baseline-exec.sh"
# Regression detection (security): a RUN_TL4 holding a line break plus a forged RUN_TL3=off line is dropped,
# so RUN_TL3 keeps the settings value (on) and the run still completes. The exported RUN_TL4 itself stays
# in the inherited environment (it is the caller's own); only the carried line is dropped, so the check is on RUN_TL3.
carry_launcher_reports "$CARRY_WT"
for CARRY_BRK in lf cr; do
  if [ "$CARRY_BRK" = lf ]; then CARRY_SEP=$'\n'; else CARRY_SEP=$'\r'; fi
  CARRY_R="$(carry_probe "$CARRY_FX" "$CARRY_WT" tests/bin/test-skip.sh "$CARRY_LOGS/forge-$CARRY_BRK" "RUN_TL4=on${CARRY_SEP}RUN_TL3=off")"
  CARRY_O="$(carry_out "$CARRY_LOGS/forge-$CARRY_BRK")"
  assert_eq "$CARRY_BRK-injected RUN_TL4: RUN_TL3 stays ${CARRY_O%% TL4=*} ${CARRY_R%% *}" "$CARRY_BRK-injected RUN_TL4: RUN_TL3 stays TL3=on RET=0"
done
case_end

case_begin "carry-tl3-gated-test-is-not-skipped-at-base" "bin/lib/run-tests-baseline-exec.sh"
# Regression (#2997): a RUN_TL3-gated test is not skip-at-base when only the settings say on.
CARRY_WT_REAL="$TMPBASE/carry-wt-real"
fx_checkout "$CARRY_WT_REAL"
mkdir -p "$CARRY_WT_REAL/tests/bin"
printf '#!/usr/bin/env bash\n[ "${RUN_TL3:-}" = on ] || exit 77\nexit 0\n' >"$CARRY_WT_REAL/tests/bin/test-tl3-gated.sh"
chmod +x "$CARRY_WT_REAL/tests/bin/test-tl3-gated.sh"
CARRY_R="$(carry_probe "$CARRY_FX" "$CARRY_WT_REAL" tests/bin/test-tl3-gated.sh "$CARRY_LOGS/tl3-gated")"
assert_eq "RUN_TL3-gated test at base (skip-at-base gives RC=77 STATE=SKIP): $CARRY_R" "RUN_TL3-gated test at base (skip-at-base gives RC=77 STATE=SKIP): RET=0 RC=0 STATE=PASS LEAK=0"
case_end
