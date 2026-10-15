#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-paths/hook-recognition.sh
# Tests: bin/worker-dispatch-paths, hooks/workflow-run-tests/exec-model.js, hooks/workflow-run-tests/provenance-identity.js
# Tags: worker-dispatch, paths-resolver, slash-form, run-tests, provenance, hook, TL2, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-paths.sh AFTER group_slash_output has run (reuses its
# fixture and $_SO_BASE/out.txt); the cases run at source time.
# #2486: the WD-3 command built from the resolver's slash-form values must be one the
# run_tests hook recognises — a test command, emitted by this repo's worker-dispatch.
# Known limit, recorded only (#2519, out of scope): the backslash spelling of the same
# command may not be recognised.

declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

_HR_PROBE="$_SO_BASE/hook-probe.js"

_hr_setup() {
  mkdir -p "$_SO_DECOY/bin" || return 1
  # A real file at the decoy path: provenance must fail on identity, not on absence.
  printf '"use strict";\n' >"$_SO_DECOY/bin/worker-dispatch.js" || return 1
  cat >"$_HR_PROBE" <<'PROBE_JS'
"use strict";
const [checkout, mode, cmd, cwd] = process.argv.slice(2);
const m = require(checkout + "/hooks/workflow-run-tests/exec-model.js");
if (mode === "is-test") {
  process.stdout.write(String(m.isTestCommand(cmd)));
} else {
  const r = m.resolveTestProvenance(cmd, cwd);
  process.stdout.write(r === null ? "null" : `${r.emitter}:ambiguous=${r.ambiguous}`);
}
PROBE_JS
}

_hr_probe() { run_with_timeout 60 node "$_HR_PROBE" "$_SO_CHECKOUT_N" "$@" 2>&1; }

_HR_OUT="$_SO_BASE/out.txt"
_HR_SETUP_OK=0
_hr_setup && _HR_SETUP_OK=1
_HR_DISPATCH="$(_so_value "$_HR_OUT" DISPATCH)"
_HR_TMR="$(_so_value "$_HR_OUT" TARGET_MAIN_ROOT)"
_HR_PAYLOAD="$WORKFLOW_STATE_DIR/s2486.control/worker-test-runner-1.json"
_HR_CMD="node \"$_HR_DISPATCH\" test-runner \"$_HR_TMR\" \"$_HR_PAYLOAD\""
_HR_BAD="node \"$_SO_DECOY/bin/worker-dispatch.js\" test-runner \"$_HR_TMR\" \"$_HR_PAYLOAD\""
_HR_READY=0
[ "$_HR_SETUP_OK" = 1 ] && [ -n "$_HR_DISPATCH" ] && [ -n "$_HR_TMR" ] && _HR_READY=1

case_begin "resolver-values-build-the-wd3-command" "bin/worker-dispatch-paths"
if [ "$_HR_SETUP_OK" != 1 ]; then
  fail "hook-recognition setup: the probe could not be written"
elif [ "$_HR_READY" = 1 ]; then
  pass "hook-recognition: the resolver gives DISPATCH and TARGET_MAIN_ROOT for the WD-3 command"
else
  fail "hook-recognition: no resolver values to build the WD-3 command from" "$(_so_flat "$_HR_OUT")"
fi
case_end

case_begin "slash-form-wd3-is-a-test-command" "hooks/workflow-run-tests/exec-model.js"
if [ "$_HR_READY" = 1 ]; then
  got="$(_hr_probe is-test "$_HR_CMD")"
  if [ "$got" = "true" ]; then
    pass "hook-recognition: the slash-form WD-3 command is a test command"
  else
    fail "hook-recognition: slash-form WD-3 command not a test command" "got='$got' cmd='$_HR_CMD'"
  fi
else
  fail "hook-recognition: is-test case not runnable (no resolver values or probe)"
fi
case_end

case_begin "slash-form-wd3-provenance-is-worker-dispatch" "hooks/workflow-run-tests/provenance-identity.js"
if [ "$_HR_READY" = 1 ]; then
  got="$(_hr_probe provenance "$_HR_CMD" "$TARGET_CHECKOUT_ROOT")"
  if [ "$got" = "worker-dispatch:ambiguous=false" ]; then
    pass "hook-recognition: provenance is this repo's worker-dispatch, not ambiguous"
  else
    fail "hook-recognition: provenance of the slash-form WD-3 command" "got='$got' cmd='$_HR_CMD'"
  fi
else
  fail "hook-recognition: provenance case not runnable (no resolver values or probe)"
fi
case_end

case_begin "decoy-dispatcher-is-not-worker-dispatch" "hooks/workflow-run-tests/provenance-identity.js"
# A same-named dispatcher outside this checkout is a test command by shape (control) but is never
# this repo's emitter.
if [ "$_HR_READY" = 1 ]; then
  got="$(_hr_probe is-test "$_HR_BAD")"
  if [ "$got" = "true" ]; then
    pass "hook-recognition: control — the decoy command has the test-command shape"
  else
    fail "hook-recognition: control — the decoy command is not even shaped as a test command" "got='$got'"
  fi
  got="$(_hr_probe provenance "$_HR_BAD" "$TARGET_CHECKOUT_ROOT")"
  case "$got" in
    worker-dispatch:*) fail "hook-recognition: a decoy dispatcher was attributed to worker-dispatch" "got='$got'" ;;
    *) pass "hook-recognition: a decoy dispatcher outside the checkout is not worker-dispatch" ;;
  esac
else
  fail "hook-recognition: decoy case not runnable (no resolver values or probe)"
fi
case_end

# #2519, recorded only (not asserted): the backslash spelling of the same command.
_hr_back="$(backslash_form "$_HR_DISPATCH")"
case "$_hr_back" in
  *\\*)
    got="$(_hr_probe provenance "node \"$_hr_back\" test-runner \"$_HR_TMR\" \"$_HR_PAYLOAD\"" "$TARGET_CHECKOUT_ROOT")"
    echo "NOTE: hook-recognition: backslash-form provenance (#2519 known limit, not asserted): $got" ;;
  *) echo "NOTE: hook-recognition: this host has no backslash path form (#2519 note skipped)" ;;
esac
