#!/usr/bin/env bash
# tests/bin/feature-2431-baseline-evidence.sh
# Tests: bin/workflow/run-tests-baseline-evidence, bin/workflow/lib/run-tests-baseline-evidence.js
# Tags: run-tests, baseline, evidence, workflow, scope:issue-specific, pwsh-not-required, TL2
#
# TDD — tests are RED until bin/workflow/run-tests-baseline-evidence and
# bin/workflow/lib/run-tests-baseline-evidence.js are implemented (stage 6-5 / 7-2).
#
# TL3 gap: whether a real failing run actually seeds failing_tests annotation is
# covered by tests/hooks/feature-2431-run-tests-failing-list.sh.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

EVIDENCE_CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow/run-tests-baseline-evidence"

TMPROOT="$(make_tmp)"
trap 'rm -rf "$TMPROOT"' EXIT

harness_isolate "$TMPROOT/iso"
export RUN_ALL_CACHE_DIR="$TMPROOT/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

AGENTS_WIN="$(np "$SCRIPT_CHECKOUT_ROOT")"

# ---------------------------------------------------------------------------
# Helpers (JS in heredoc files so no multi-line inline script precedes a case)
# ---------------------------------------------------------------------------

SEED_JS="$TMPROOT/seed-events.js"
cat > "$SEED_JS" <<'JSCODE'
"use strict";
// argv: agents sid events-json — each event gets observed provenance.
const [agents, sid, raw] = process.argv.slice(2);
try {
  const { appendEvents } = require(agents + "/hooks/workflow-state/state-io/events");
  appendEvents(sid, JSON.parse(raw).map((e) =>
    Object.assign({ provenance: "observed", origin: "run-tests-hook" }, e)));
} catch (e) { process.stderr.write("seed-error: " + e.message + "\n"); process.exit(1); }
JSCODE

READ_JS="$TMPROOT/read-field.js"
cat > "$READ_JS" <<'JSCODE'
"use strict";
try {
  const s = require(process.argv[2] + "/hooks/workflow-state").readState(process.argv[3]);
  const e = s && s.steps && s.steps[process.argv[4]];
  const v = e ? e[process.argv[5]] : undefined;
  process.stdout.write(v === undefined || v === null ? "(absent)" : JSON.stringify(v));
} catch (err) { process.stdout.write("(absent)"); }
JSCODE

next_sid() { printf 'be-%s-%s' "${1:-ev}" "$$"; }

# seed_events <sid> <events-json-array>
seed_events() {
  run_with_timeout 30 node "$(np "$SEED_JS")" "$AGENTS_WIN" "$1" "$2" >/dev/null 2>&1 || true
}

# seed_pending_fail <sid> <test-path...> — pending + run_outcome=fail + failing_tests.
seed_pending_fail() {
  local sid="$1" list="" p; shift
  for p in "$@"; do list="$list${list:+,}\"$p\""; done
  local ann='{"kind":"step_annotation","step":"run_tests"'
  seed_events "$sid" "[{\"kind\":\"step_status\",\"step\":\"run_tests\",\"status\":\"pending\"},$ann,\"key\":\"run_outcome\",\"value\":\"fail\"},$ann,\"key\":\"failing_tests\",\"value\":[$list]}]"
}

# read_step_field <sid> <step> <field>
read_step_field() {
  run_with_timeout 20 node "$(np "$READ_JS")" "$AGENTS_WIN" "$1" "$2" "$3" 2>/dev/null || echo "(absent)"
}

# run_failing <sid> → sets EV_RC, EV_OUT
run_failing() {
  EV_RC=0
  EV_OUT="$(run_with_timeout 30 "$EVIDENCE_CLI" failing --session "$1" 2>/dev/null)" || EV_RC=$?
}

# get_seq <sid> — SEQ from `failing` (empty when it did not exit 0).
get_seq() {
  run_failing "$1"
  [ "$EV_RC" -eq 0 ] && printf '%s' "$EV_OUT" | grep '^SEQ=' | head -1 | sed 's/^SEQ=//'
}

# run_record <sid> <seq> <classfile> → sets REC_RC, REC_OUT, REC_ERR
run_record() {
  REC_RC=0
  REC_OUT="$(run_with_timeout 30 "$EVIDENCE_CLI" record --session "$1" --seq "$2" \
    --classification "$(np "$3")" 2>"$TMPROOT/rec-err")" || REC_RC=$?
  REC_ERR="$(cat "$TMPROOT/rec-err" 2>/dev/null || true)"
}

# assert_not_completed <label> <sid> — non-zero record exit, pending, no completion_basis.
assert_not_completed() {
  local st cb
  [ "$REC_RC" -ne 0 ] && pass "$1: non-zero exit" || fail "$1: exit 0 (cover not enforced)"
  st="$(read_step_field "$2" run_tests status)"
  [ "$st" = '"pending"' ] && pass "$1: run_tests stays pending" \
    || fail "$1: false complete, status=$st"
  cb="$(read_step_field "$2" run_tests completion_basis)"
  [ "$cb" = "(absent)" ] && pass "$1: no completion_basis written" \
    || fail "$1: completion_basis written: $cb"
}

CLI_EXISTS=0
if [ -f "$EVIDENCE_CLI" ]; then
  CLI_EXISTS=1
else
  fail "evidence-cli-missing: $EVIDENCE_CLI not yet implemented (TDD — expected FAIL)"
fi

# ---------------------------------------------------------------------------

case_begin "failing-exit3-not-pending" "bin/workflow/run-tests-baseline-evidence"
SID="$(next_sid np)"
seed_events "$SID" '[{"kind":"step_status","step":"run_tests","status":"complete"}]'
if [ "$CLI_EXISTS" = "1" ]; then
  run_failing "$SID"
  [ "$EV_RC" -eq 3 ] && pass "failing-exit3-not-pending: exits 3 when run_tests is not pending" \
    || fail "failing-exit3-not-pending: expected exit 3, got $EV_RC"
else
  fail "failing-exit3-not-pending: CLI missing"
fi
case_end

case_begin "failing-exit3-no-run-outcome-fail" "bin/workflow/run-tests-baseline-evidence"
SID="$(next_sid nrf)"
ANN='{"kind":"step_annotation","step":"run_tests"'
seed_events "$SID" "[{\"kind\":\"step_status\",\"step\":\"run_tests\",\"status\":\"pending\"},$ANN,\"key\":\"run_outcome\",\"value\":\"pass\"},$ANN,\"key\":\"failing_tests\",\"value\":[\"tests/bin/some-test.sh\"]}]"
if [ "$CLI_EXISTS" = "1" ]; then
  run_failing "$SID"
  [ "$EV_RC" -eq 3 ] && pass "failing-exit3-no-run-outcome-fail: exits 3 when run_outcome is not a fail value" \
    || fail "failing-exit3-no-run-outcome-fail: expected exit 3, got $EV_RC"
else
  fail "failing-exit3-no-run-outcome-fail: CLI missing"
fi
case_end

case_begin "failing-exit3-empty-failing-tests" "bin/workflow/run-tests-baseline-evidence"
SID="$(next_sid eft)"
seed_pending_fail "$SID"
if [ "$CLI_EXISTS" = "1" ]; then
  run_failing "$SID"
  [ "$EV_RC" -eq 3 ] && pass "failing-exit3-empty-failing-tests: exits 3 when failing_tests is empty" \
    || fail "failing-exit3-empty-failing-tests: expected exit 3, got $EV_RC"
else
  fail "failing-exit3-empty-failing-tests: CLI missing"
fi
case_end

case_begin "failing-success-output" "bin/workflow/run-tests-baseline-evidence"
SID="$(next_sid fs)"
seed_pending_fail "$SID" "tests/bin/alpha.sh" "tests/bin/beta.sh"
if [ "$CLI_EXISTS" = "1" ]; then
  run_failing "$SID"
  if [ "$EV_RC" -eq 0 ]; then
    pass "failing-success-output: exits 0"
    printf '%s' "$EV_OUT" | grep -qE '^SEQ=[0-9]+' && pass "failing-success-output: stdout contains SEQ=<n> line" \
      || fail "failing-success-output: no SEQ= line in output: $EV_OUT"
    printf '%s\n' "$EV_OUT" | grep -qx 'tests/bin/alpha.sh' && pass "failing-success-output: stdout contains alpha.sh path" \
      || fail "failing-success-output: alpha.sh path missing in output"
    printf '%s\n' "$EV_OUT" | grep -qx 'tests/bin/beta.sh' && pass "failing-success-output: stdout contains beta.sh path" \
      || fail "failing-success-output: beta.sh path missing in output"
  else
    fail "failing-success-output: expected exit 0, got $EV_RC"
  fi
else
  fail "failing-success-output: CLI missing"
fi
case_end

case_begin "record-unmet-conditions-pending" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(next_sid ruc)"
seed_pending_fail "$SID" "tests/bin/gamma.sh"
if [ "$CLI_EXISTS" = "1" ]; then
  SEQ_VAL="$(get_seq "$SID")"
  CLASSFILE="$TMPROOT/cls-unmet.txt"
  printf 'tests/bin/gamma.sh\tbroken\t\n' > "$CLASSFILE"
  run_record "$SID" "${SEQ_VAL:-1}" "$CLASSFILE"
  [ "$REC_RC" -eq 1 ] && pass "record-unmet-conditions-pending: exits 1 when classification condition (4) not met" \
    || fail "record-unmet-conditions-pending: expected exit 1, got $REC_RC"
  STATUS="$(read_step_field "$SID" run_tests status)"
  [ "$STATUS" = '"pending"' ] && pass "record-unmet-conditions-pending: run_tests stays pending" \
    || fail "record-unmet-conditions-pending: run_tests not pending, got: $STATUS"
  BC="$(read_step_field "$SID" run_tests baseline_classification)"
  [ "$BC" != "(absent)" ] && pass "record-unmet-conditions-pending: baseline_classification annotation written" \
    || fail "record-unmet-conditions-pending: baseline_classification annotation absent"
else
  fail "record-unmet-conditions-pending: CLI missing"
fi
case_end

# Condition (3) is a SET cover: a duplicated line must not stand in for an omitted path.
case_begin "record-duplicate-row-no-cover" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(next_sid dup)"
seed_pending_fail "$SID" "tests/bin/zeta.sh" "tests/bin/eta.sh"
if [ "$CLI_EXISTS" = "1" ]; then
  SEQ_VAL="$(get_seq "$SID")"
  CLASSFILE="$TMPROOT/cls-dup.txt"
  printf 'tests/bin/zeta.sh\tpreexisting\tbase-fail\ntests/bin/zeta.sh\tpreexisting\tbase-fail\n' > "$CLASSFILE"
  run_record "$SID" "${SEQ_VAL:-1}" "$CLASSFILE"
  assert_not_completed "record-duplicate-row-no-cover" "$SID"
else
  fail "record-duplicate-row-no-cover: CLI missing"
fi
case_end

# Same row count, but one failing path is swapped for a foreign one: the cover is by
# path identity, so the substituted row must not authorize completion.
case_begin "record-substituted-path-no-cover" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(next_sid sub)"
seed_pending_fail "$SID" "tests/bin/theta.sh" "tests/bin/iota.sh"
if [ "$CLI_EXISTS" = "1" ]; then
  SEQ_VAL="$(get_seq "$SID")"
  CLASSFILE="$TMPROOT/cls-sub.txt"
  printf 'tests/bin/theta.sh\tpreexisting\tbase-fail\ntests/bin/kappa.sh\tpreexisting\tbase-fail\n' > "$CLASSFILE"
  run_record "$SID" "${SEQ_VAL:-1}" "$CLASSFILE"
  assert_not_completed "record-substituted-path-no-cover" "$SID"
else
  fail "record-substituted-path-no-cover: CLI missing"
fi
case_end

# Two failing tests, the classification simply omits one (no duplicate, no foreign row):
# a partial cover must not authorize completion even though every listed row is preexisting.
case_begin "record-omitted-path-no-cover" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(next_sid omit)"
seed_pending_fail "$SID" "tests/bin/lambda.sh" "tests/bin/mu.sh"
if [ "$CLI_EXISTS" = "1" ]; then
  SEQ_VAL="$(get_seq "$SID")"
  CLASSFILE="$TMPROOT/cls-omit.txt"
  printf 'tests/bin/lambda.sh\tpreexisting\tbase-fail\n' > "$CLASSFILE"
  run_record "$SID" "${SEQ_VAL:-1}" "$CLASSFILE"
  [ "$REC_RC" -eq 1 ] && pass "record-omitted-path-no-cover: exits 1 (cover condition (3) unmet)" \
    || fail "record-omitted-path-no-cover: expected exit 1, got $REC_RC"
  assert_not_completed "record-omitted-path-no-cover" "$SID"
else
  fail "record-omitted-path-no-cover: CLI missing"
fi
case_end

case_begin "record-success-complete" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(next_sid rsc)"
seed_pending_fail "$SID" "tests/bin/delta.sh"
if [ "$CLI_EXISTS" = "1" ]; then
  SEQ_VAL="$(get_seq "$SID")"
  CLASSFILE="$TMPROOT/cls-success.txt"
  printf 'tests/bin/delta.sh\tpreexisting\tbase-fail\n' > "$CLASSFILE"
  run_record "$SID" "${SEQ_VAL:-1}" "$CLASSFILE"
  [ "$REC_RC" -eq 0 ] && pass "record-success-complete: exits 0 when all preexisting" \
    || fail "record-success-complete: expected exit 0, got $REC_RC"
  STATUS="$(read_step_field "$SID" run_tests status)"
  [ "$STATUS" = '"complete"' ] && pass "record-success-complete: run_tests becomes complete" \
    || fail "record-success-complete: run_tests not complete, got: $STATUS"
  RO="$(read_step_field "$SID" run_tests run_outcome)"
  [ "$RO" = '"pass"' ] && pass "record-success-complete: run_outcome is pass" \
    || fail "record-success-complete: run_outcome not pass, got: $RO"
  CB="$(read_step_field "$SID" run_tests completion_basis)"
  printf '%s' "$CB" | grep -qF 'baseline-preexisting' && pass "record-success-complete: completion_basis is baseline-preexisting" \
    || fail "record-success-complete: completion_basis missing or wrong: $CB"
else
  fail "record-success-complete: CLI missing"
fi
case_end

case_begin "record-race-new-write" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(next_sid race)"
seed_pending_fail "$SID" "tests/bin/epsilon.sh"
if [ "$CLI_EXISTS" = "1" ]; then
  SEQ_VAL="$(get_seq "$SID")"
  seed_events "$SID" '[{"kind":"step_status","step":"run_tests","status":"pending","origin":"race-interloper"}]'
  CLASSFILE="$TMPROOT/cls-race.txt"
  printf 'tests/bin/epsilon.sh\tpreexisting\tbase-fail\n' > "$CLASSFILE"
  run_record "$SID" "${SEQ_VAL:-1}" "$CLASSFILE"
  [ "$REC_RC" -eq 3 ] && pass "record-race-new-write: exits 3 when seq no longer matches (race)" \
    || fail "record-race-new-write: expected exit 3, got $REC_RC"
else
  fail "record-race-new-write: CLI missing"
fi
case_end

case_begin "record-missing-seq-arg" "bin/workflow/run-tests-baseline-evidence"
if [ "$CLI_EXISTS" = "1" ]; then
  SID="$(next_sid msa)"
  CLASSFILE="$TMPROOT/cls-empty.txt"
  : > "$CLASSFILE"
  NOARG_RC=0
  run_with_timeout 15 "$EVIDENCE_CLI" record --session "$SID" \
    --classification "$(np "$CLASSFILE")" >/dev/null 2>&1 || NOARG_RC=$?
  [ "$NOARG_RC" -ne 0 ] && pass "record-missing-seq-arg: exits non-zero when --seq is absent" \
    || fail "record-missing-seq-arg: should fail without --seq, got exit 0"
else
  fail "record-missing-seq-arg: CLI missing"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
