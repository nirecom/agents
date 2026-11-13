#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-compare-cli-closed.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, compare, fail-details, scope:issue-specific, pwsh-not-required, TL2
# #2956 S4/S8, the fail-closed shapes in one CLI run (one base worktree): a number with no marker
# (a port) that differs, the same line cut at 8192 bytes on both sides, a violation added on line 2
# of a multi-line message, and a failure added outside any case. Each is (c), never a proof.
# Also the outline's fifth shape: a changed test file is file-verdict-preexisting test-file-changed,
# and a line it adds on the branch is still shown and disclosed in the completion note (S9).
# Fixture and helpers: feature-2956-baseline-compare-cli/_lib.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# Pin the state and plans dirs here, before changed_note below runs node; helpers.sh re-pins them
# to the fixture's own dirs once _lib.sh has sourced it (rules/test/fixture-isolation.md).
harness_isolate "$(make_tmp)"
# shellcheck source=./feature-2956-baseline-compare-cli/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2956-baseline-compare-cli/_lib.sh"

cmp_run closed port cut multi outside changed

case_begin "compare-cli-test-file-changed" "bin/run-tests-baseline"
cmp_expect "S5: a changed test file is file-verdict-preexisting test-file-changed" "file-verdict-preexisting tests/bin/t-changed\.sh test-file-changed"
case_end

case_begin "compare-cli-test-file-changed-new-line-shown" "bin/run-tests-baseline"
cmp_expect "S5: a new line on a changed test keeps the file verdict and shows new=1 with its head" \
  "file-verdict-preexisting tests/bin/t-changed\.sh test-file-changed new=1 head=\[\"case-a\\\\tviolation Z\"\]$"
case_end

case_begin "compare-cli-port-number-kept" "bin/run-tests-baseline"
cmp_expect_new "port: example.com:8080 vs :9090 is (c), the number is kept" port "9090"
case_end

case_begin "compare-cli-cut-line" "bin/run-tests-baseline"
cmp_expect_new "cut: the same line cut at 8192 bytes on both sides is (c)" cut "zzz"
case_end

case_begin "compare-cli-multi-line-message" "bin/run-tests-baseline"
cmp_expect_new "multi-line: a violation added on line 2 of one message is (c)" multi "violation B"
case_end

case_begin "compare-cli-outside-case" "bin/run-tests-baseline"
cmp_expect_new "outside: a failure added outside any case (seq 0, case -) is (c)" outside "stray failure outside any case"
cmp_expect_summary "summary: file_verdict=1 new_on_branch=4, exit 1 (pending (c) lines)" 1 0 1 4
case_end

# changed_note <sid> — the completion note readCompletionNote gives for the session ("" when none).
changed_note() {
  run_with_timeout 15 node -e 'const m = require(process.argv[1] + "/hooks/lib/run-tests-completion-note.js"); process.stdout.write(m.readCompletionNote(process.argv[2]) || "");' \
    "$AGENTS_WIN" "$1" 2>/dev/null
}

# The changed test alone: test-file-changed is auto, so run_tests completes and the note is written.
# This second run replaces RTB_CLI_OUT, so it stays after every case that reads the first run.
cmp_run changednote changed
case_begin "compare-cli-test-file-changed-new-line-disclosed" "bin/run-tests-baseline"
CHG_SID="changednote-$$"
CHG_ST="$(read_step_field "$CHG_SID" run_tests status)"
CHG_BASIS="$(read_step_field "$CHG_SID" run_tests completion_basis)"
if [[ "$RTB_CLI_RC" -eq 0 && "$CHG_ST" == '"complete"' && "$CHG_BASIS" == '"baseline-auto-accepted"' ]]; then
  pass "S9: a changed test with a new line completes on baseline-auto-accepted, exit 0"
else
  fail "S9: expected auto-accepted completion; rc=$RTB_CLI_RC status=$CHG_ST basis=$CHG_BASIS ($(cli_baseline_lines))"
fi
CHG_NOTE="$(changed_note "$CHG_SID")"
CHG_WANT_AUTO="- Unverified tests: 1 failing test(s) auto-accepted without baseline proof (causes: test-file-changed; note: (none))"
CHG_WANT_NEW="- Baseline new failure lines: tests/bin/t-changed.sh (1 new lines, file-verdict-preexisting: case-a"$'\t'"violation Z)"
if printf '%s\n' "$CHG_NOTE" | grep -qxF -- "$CHG_WANT_AUTO"; then
  pass "S9: the completion note names the Unverified tests reason (test-file-changed)"
else
  fail "S9: no '$CHG_WANT_AUTO' line; note=[$CHG_NOTE]"
fi
if printf '%s\n' "$CHG_NOTE" | grep -qxF -- "$CHG_WANT_NEW"; then
  pass "S9: the completion note discloses the new line's count and head"
else
  fail "S9: no '$CHG_WANT_NEW' line; note=[$CHG_NOTE]"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
