#!/usr/bin/env bash
# tests/skills/feature-2544-run-tests-background-procedure.sh
# Tests: skills/run-tests/scripts/show-dispatch-outcome.sh, skills/_shared/worker-dispatch.md, skills/run-tests/SKILL.md
# Tags: skills, run-tests, dispatch, background, TL1, TL2, scope:issue-specific, pwsh-not-required
#
# #2544: a long test-runner dispatch runs in the background; its result is read back from
# the outcome file the dispatcher wrote, rendered as the same YAML a foreground dispatch prints.
# TL3 gap (what this test does NOT catch):
# - the real run_in_background completion notice reaching the model
# - the model actually following WD-BG instead of the foreground WD-3/WD-4 path

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPROOT="$(make_tmp)"; readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# shellcheck source=tests/lib/dispatch-outcome-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/dispatch-outcome-fixture.sh"

ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
TOOL_JS="$ROOT_N/tests/lib/workflow-state-tool.js"
LOCAL_SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/run-tests/SKILL.md"
LOCAL_WD_MD="$SCRIPT_CHECKOUT_ROOT/skills/_shared/worker-dispatch.md"
SHOW_SCRIPT="$SCRIPT_CHECKOUT_ROOT/skills/run-tests/scripts/show-dispatch-outcome.sh"
# Twelve failing paths: more than any display cap a renderer might apply.
FAILING='["tests/bin/f01.sh","tests/bin/f02.sh","tests/bin/f03.sh","tests/bin/f04.sh","tests/bin/f05.sh","tests/bin/f06.sh","tests/bin/f07.sh","tests/bin/f08.sh","tests/bin/f09.sh","tests/bin/f10.sh","tests/bin/f11.sh","tests/bin/f12.sh"]'
TAIL='["ok 1 - tests/bin/p1.sh","not ok 2 - tests/bin/f01.sh","Results: PASS=3  FAIL=12  SKIP=1"]'

tool() { run_with_timeout 30 node "$TOOL_JS" "$ROOT_N" "$@" 2>/dev/null || echo "ERR:tool-crashed"; }
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing $(printf '%q' "$3") in $(printf '%q' "$2")" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1" "unexpected $(printf '%q' "$3")" ;; *) pass "$1" ;; esac; }
sid_of() { printf 'bgp-%s-%s' "$1" "$$"; }

# show <sid> — sets OUT and RC; runs from a neutral directory.
show() {
  RC=0
  OUT="$(cd "$TMPROOT" && run_with_timeout 60 bash "$SHOW_SCRIPT" --session "$1" 2>/dev/null)" || RC=$?
  OUT="$(printf '%s' "$OUT" | tr -d '\r')"
}
line_n() { printf '%s\n' "$OUT" | sed -n "${1}p"; }
after_sep() { printf '%s\n' "$OUT" | awk 'seen { print } $0 == "---" && !seen { seen = 1 }'; }
no_duration() { printf '%s\n' "$1" | grep -v '^duration_seconds:'; }
# foreground_yaml — what a foreground dispatch prints for the placed fail result (emit.render).
foreground_yaml() {
  node - "$ROOT_N" "$FAILING" "$TAIL" <<'JS'
const [root, failing, tail] = process.argv.slice(-3);
const emit = require(root + "/bin/worker-dispatch/emit.js");
const reg = require(root + "/hooks/lib/worker-dispatch-registry.js");
process.stdout.write(emit.render(reg.workers["test-runner"], {
  status: "fail", exitCode: 1, durationSeconds: 1, summary: "PASS=3 FAIL=12 SKIP=1",
  failingTests: JSON.parse(failing), logTail: JSON.parse(tail),
  runContract: { pass: 3, fail: 12, skip: 1, executed: 16 },
}));
JS
}
# md_block <file> <label> — the lines of one step label up to the next step label or heading.
md_block() { awk -v a="^$2([^A-Za-z0-9-]|\$)" 'on && (/^(WD|RNT)-[0-9A-Z]+[.: ]/ || /^## /) { on = 0 } $0 ~ a { on = 1 } on' "$1"; }
fence_blocks() { awk '/^[[:space:]]*```/ { if (on && n >= 3) bad++; on = !on; n = 0; next } on { n++ } END { print bad + 0 }' "$1"; }

case_begin "wd-bg-section-and-rnt7-reference" "skills/_shared/worker-dispatch.md"
WDBG="$(md_block "$LOCAL_WD_MD" WD-BG)"
if [ -n "$WDBG" ]; then pass "WD-BG step present"; else fail "WD-BG step missing from worker-dispatch.md"; fi
has "WD-BG: limited to test-runner" "$WDBG" "test-runner"
has "WD-BG: dispatches with run_in_background" "$WDBG" "run_in_background"
has "WD-BG: pauses the stop guard" "$WDBG" "WORKFLOW_NEXT_STEP_PAUSE"
has "WD-BG: resumes the stop guard" "$WDBG" "WORKFLOW_NEXT_STEP_RESUME"
has "WD-BG: reads the result through the display script" "$WDBG" "show-dispatch-outcome.sh"
has "WD-BG: present branch" "$WDBG" "OUTCOME=present"
has "WD-BG: shows the reason when not present" "$WDBG" "OUTCOME_REASON"
has "WD-BG: absent is runner-error" "$WDBG" "runner-error"
has "WD-BG: re-run publishes a new --seq" "$WDBG" "--seq"
if printf '%s\n' "$WDBG" | grep -qi 'output file'; then pass "WD-BG: says the task output file is no evidence"; else fail "WD-BG: no word on the background task output file"; fi
RNT7="$(md_block "$LOCAL_SKILL_MD" RNT-7)"
has "RNT-7 points at WD-BG" "$RNT7" "WD-BG"
has "RNT-7 names the shared protocol" "$RNT7" "skills/_shared/worker-dispatch.md"
ck "no [\"--all\"] test_args in SKILL.md" "0" "$(grep -cF '["--all"]' "$LOCAL_SKILL_MD")"
case_end

case_begin "prompt-files-keep-their-form" "skills/run-tests/SKILL.md"
LINES="$(awk 'END { print NR }' "$LOCAL_SKILL_MD")"
if [ "$LINES" -le 100 ]; then pass "SKILL.md at most 100 lines ($LINES)"; else fail "SKILL.md over 100 lines" "lines=$LINES"; fi
LINES="$(awk 'END { print NR }' "$LOCAL_WD_MD")"
if [ "$LINES" -le 100 ]; then pass "worker-dispatch.md at most 100 lines ($LINES)"; else fail "worker-dispatch.md over 100 lines" "lines=$LINES"; fi
ck "SKILL.md: no fenced block of 3 or more lines" "0" "$(fence_blocks "$LOCAL_SKILL_MD")"
ck "worker-dispatch.md: no fenced block" "0" "$(grep -c '^[[:space:]]*```' "$LOCAL_WD_MD")"
ck "fence counter sees a long block (self-check)" "1" "$(printf '```\na\nb\nc\n```\n' | awk '/^[[:space:]]*```/ { if (on && n >= 3) bad++; on = !on; n = 0; next } on { n++ } END { print bad + 0 }')"
case_end

case_begin "show-outcome-present-renders-the-foreground-yaml" "skills/run-tests/scripts/show-dispatch-outcome.sh"
if [ -f "$SHOW_SCRIPT" ]; then pass "show-dispatch-outcome.sh exists"; else fail "show-dispatch-outcome.sh missing (not implemented yet)"; fi
SID="$(sid_of present)"
STEM="$(dispatch_outcome_place "$SID" 3 fail 3 12 1 "$ROOT_N" "$FAILING" "$TAIL")"
ck "fixture: stem placed" "worker-test-runner-3" "$STEM"
N0="$(tool count "$SID")"
show "$SID"
ck "present: exit 0" "0" "$RC"
ck "present: line 1" "DISPATCH_STEM=$STEM" "$(line_n 1)"
ck "present: line 2" "OUTCOME=present" "$(line_n 2)"
ck "present: line 3" "OUTCOME_REASON=-" "$(line_n 3)"
ck "present: line 4 separator" "---" "$(line_n 4)"
YAML="$(after_sep)"
ck "present: RUN_CONTRACT line first after the separator" "RUN_CONTRACT: PASS=3 FAIL=12 SKIP=1 EXECUTED=16" "$(printf '%s\n' "$YAML" | sed -n 1p)"
ck "present: all twelve failing tests listed" "12" "$(printf '%s\n' "$YAML" | grep -c "^  - 'tests/bin/f[0-9][0-9]\.sh'$")"
WANT="$(foreground_yaml)"
if [ -n "$WANT" ]; then pass "oracle: foreground render produced YAML"; else fail "oracle: foreground render empty"; fi
ck "present: YAML equals the foreground dispatch except duration_seconds" "$(no_duration "$WANT")" "$(no_duration "$YAML")"
ck "present: one duration_seconds line" "1" "$(printf '%s\n' "$YAML" | grep -c '^duration_seconds: [0-9][0-9]*$')"
ck "present: read-only (no state event)" "$N0" "$(tool count "$SID")"
ck "present: read-only (no ingested marker)" "no" "$(tool ctlhas "$SID" "$STEM.ingested")"
lacks "present: no run_tests status printed" "$OUT" "RUN_TESTS_STATUS"
case_end

case_begin "show-outcome-absent-or-untrusted-prints-no-yaml" "skills/run-tests/scripts/show-dispatch-outcome.sh"
SID="$(sid_of none)"
show "$SID"
ck "no dispatch: exit 0" "0" "$RC"
ck "no dispatch: line 1" "DISPATCH_STEM=none" "$(line_n 1)"
ck "no dispatch: line 2" "OUTCOME=absent" "$(line_n 2)"
ck "no dispatch: line 4 separator" "---" "$(line_n 4)"
ck "no dispatch: nothing after the separator" "" "$(after_sep | tr -d '[:space:]')"
SID="$(sid_of absent)"
STEM="$(dispatch_outcome_place "$SID" 1 pass 2 0 0 "$ROOT_N")"
ck "fixture: outcome removed" "ok" "$(tool ctlrm "$SID" "$STEM.outcome.json")"
show "$SID"
ck "not yet written: exit 0" "0" "$RC"
ck "not yet written: line 1" "DISPATCH_STEM=$STEM" "$(line_n 1)"
ck "not yet written: line 2" "OUTCOME=absent" "$(line_n 2)"
ck "not yet written: nothing after the separator" "" "$(after_sep | tr -d '[:space:]')"
lacks "not yet written: no RUN_CONTRACT" "$OUT" "RUN_CONTRACT:"
SID="$(sid_of untrusted)"
STEM="$(dispatch_outcome_place "$SID" 1 pass 2 0 0 "$ROOT_N")"
ck "fixture: payload bytes replaced" "ok" "$(tool ctl "$SID" "$STEM.json" '{"test_args":[],"cwd":"elsewhere","timeout_seconds":300}')"
show "$SID"
ck "untrusted: exit 0" "0" "$RC"
ck "untrusted: line 1" "DISPATCH_STEM=$STEM" "$(line_n 1)"
ck "untrusted: line 2" "OUTCOME=untrusted" "$(line_n 2)"
REASON="$(line_n 3)"
case "$REASON" in OUTCOME_REASON=-|OUTCOME_REASON=) fail "untrusted: reason left blank" "line=$REASON" ;; OUTCOME_REASON=*) pass "untrusted: reason named" ;; *) fail "untrusted: line 3 is no reason header" "line=$REASON" ;; esac
ck "untrusted: nothing after the separator" "" "$(after_sep | tr -d '[:space:]')"
lacks "untrusted: no pass status leaks" "$OUT" "status: pass"
RC=0
(cd "$TMPROOT" && run_with_timeout 60 bash "$SHOW_SCRIPT" --session "bad/sid" >/dev/null 2>&1) || RC=$?
ck "malformed session id: exit 2" "2" "$RC"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
