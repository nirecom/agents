#!/usr/bin/env bash
# tests/bin/feature-step-durations.sh
# Tests: bin/step-durations.js, bin/step-durations/sources.js, bin/step-durations/render.js
# Tags: step-durations, workflow-state, transcript, report, csv, TL2, scope:common
# TL3 gap (what this test does NOT catch):
# - transcripts written by a real Claude Code session (record shapes beyond the fixture's subset)
# Closest-to-action mitigation: none needed — the CLI is read-only and has no risk category.
set -u
AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"

SD="$(np "$AGENTS_DIR/bin/step-durations.js")"
ROOT="$(make_tmp)"
trap 'rm -rf "$ROOT"' EXIT
ROOT="$(np "$ROOT")"
export HOME="$ROOT/home"
export CLAUDE_WORKFLOW_DIR="$ROOT/workflow"
export WORKFLOW_PLANS_DIR="$ROOT/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$ROOT/projects"
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
mkdir -p "$HOME" "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR/c--fixture-repo"
cd "$ROOT" || exit 1

SID_A="aaaaaaaa-1111-2222-3333-444444444444" # state file, 2026-03-15, 60 min (20 + 40)
SID_B="bbbbbbbb-1111-2222-3333-444444444444" # transcript only, 2026-04-15, 30 min user wait
SID_C="cccccccc-1111-2222-3333-444444444444" # state file, years old
SID_D="dddddddd-1111-2222-3333-444444444444" # state file, started 2 h ago

printf '%s\n' '{"events":[
{"kind":"step_status","step":"outline","status":"in_progress","at":"2026-03-15T12:00:00.000Z","seq":1},
{"kind":"step_status","step":"outline","status":"complete","at":"2026-03-15T12:20:00.000Z","seq":2},
{"kind":"step_status","step":"detail","status":"complete","at":"2026-03-15T13:00:00.000Z","seq":3}]}' > "$CLAUDE_WORKFLOW_DIR/$SID_A.json"

printf '%s\n' '{"events":[
{"kind":"step_status","step":"outline","status":"complete","at":"2020-06-15T12:00:00.000Z","seq":1},
{"kind":"step_status","step":"detail","status":"complete","at":"2020-06-15T12:30:00.000Z","seq":2}]}' > "$CLAUDE_WORKFLOW_DIR/$SID_C.json"

T_D1="$(node -e 'console.log(new Date(Date.now()-7200000).toISOString())')"
T_D2="$(node -e 'console.log(new Date(Date.now()-3600000).toISOString())')"
printf '{"events":[{"kind":"step_status","step":"outline","status":"in_progress","at":"%s","seq":1},{"kind":"step_status","step":"outline","status":"complete","at":"%s","seq":2}]}\n' "$T_D1" "$T_D2" > "$CLAUDE_WORKFLOW_DIR/$SID_D.json"

TR_B="$CLAUDE_TRANSCRIPT_BASE_DIR/c--fixture-repo/$SID_B.jsonl"
printf '%s\n' \
  '{"type":"user","timestamp":"2026-04-15T12:00:00.000Z","message":{"role":"user","content":"start the task"}}' \
  '{"type":"assistant","timestamp":"2026-04-15T12:05:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"make-outline-plan"}}]}}' \
  '{"type":"user","timestamp":"2026-04-15T12:35:00.000Z","message":{"role":"user","content":"looks good, continue"}}' \
  '{"type":"assistant","timestamp":"2026-04-15T12:40:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Skill","input":{"skill":"write-code"}}]}}' \
  '{"type":"assistant","timestamp":"2026-04-15T13:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}' \
  > "$TR_B"

BOM=$'\xEF\xBB\xBF'
CR=$'\r'

case_begin "state-file-session-markdown" "bin/step-durations/render.js"
out="$(node "$SD" --session aaaaaaaa)"
rc=$?
assert_eq "$rc" "0"
case "$out" in
  *"| aaaaaaaa | - | state | 1.0 | 1.0 | (0.0) | 1.0 |"*) pass "md summary row for state session" ;;
  *) fail "md summary row for state session" "$out" ;;
esac
case "$out" in
  *"| outline | "*" | 20 | (0) | 20 |"*"| detail | "*" | 40 | (0) | 40 |"*) pass "md segments from complete events" ;;
  *) fail "md segments from complete events" "$out" ;;
esac
case_end

case_begin "transcript-only-session-skill-labels" "bin/step-durations/sources.js"
out="$(node "$SD" --session bbbbbbbb --format csv)"
assert_eq "$(printf '%s\n' "$out" | tr -d '\r' | awk -F, '$1=="segment"{print $4":"$5}' | paste -sd' ' -)" "transcript:(最初の skill まで) transcript:outline transcript:write_code"
case_end

case_begin "transcript-user-wait-excluded" "bin/step-durations/sources.js"
out="$(node "$SD" --session bbbbbbbb --format csv)"
assert_eq "$(printf '%s\n' "$out" | tr -d '\r' | awk -F, '$1=="segment" && $5=="outline"{print $9"/"$10"/"$11}')" "35.0/30.0/5.0"
assert_eq "$(printf '%s\n' "$out" | tr -d '\r' | awk -F, '$1=="session"{print $8"/"$9"/"$10"/"$11}')" "60.0/60.0/30.0/30.0"
case_end

case_begin "csv-header-and-rows" "bin/step-durations/render.js"
out="$(node "$SD" --format csv --session aaaaaaaa)"
first="$(printf '%s\n' "$out" | head -n 1)"
first="${first#"$BOM"}"
first="${first%"$CR"}"
assert_eq "$first" "kind,session,title,source,segment,start,end,wall_min,span_min,wait_min,net_min"
assert_eq "$(printf '%s\n' "$out" | grep -c "^session,$SID_A,")" "1"
assert_eq "$(printf '%s\n' "$out" | grep -c "^segment,$SID_A,")" "2"
case_end

case_begin "period-and-session-filters" "bin/step-durations.js"
assert_eq "$(node "$SD" --format csv --session bbbb | grep -c '^session,')" "1"
assert_eq "$(node "$SD" --format csv --since 2026-03-01 --until 2026-03-31 | grep '^session,' | cut -d, -f2 | paste -sd' ' -)" "$SID_A"
assert_eq "$(node "$SD" --format csv --since 2026-04-01 --until 2026-04-30 | grep '^session,' | cut -d, -f2 | paste -sd' ' -)" "$SID_B"
assert_eq "$(node "$SD" --format csv --days 1 | grep '^session,' | cut -d, -f2 | paste -sd' ' -)" "$SID_D"
assert_eq "$(node "$SD" --format csv | grep -c '^session,')" "4"
case_end

case_begin "usage-errors-exit-2" "bin/step-durations.js"
bad=""
for args in "--bogus" "--days 0" "--days 3 --since 2026-01-01" "--format xml" "--since 2026-02-30" "--out"; do
  # shellcheck disable=SC2086  # word-split the argument string on purpose
  node "$SD" $args >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || bad="$bad [$args -> $rc]"
done
assert_eq "$bad" ""
help="$(node "$SD" --help)"
rc=$?
assert_eq "$rc" "0"
case "$help" in
  Usage:*) pass "--help prints usage" ;;
  *) fail "--help prints usage" "$help" ;;
esac
case_end

case_begin "out-file-written-stdout-empty" "bin/step-durations.js"
stdout="$(node "$SD" --format csv --out "$ROOT/report.csv" 2>/dev/null)"
rc=$?
assert_eq "$rc" "0"
assert_eq "$stdout" ""
if [ -f "$ROOT/report.csv" ] && grep -q "^session,$SID_A," "$ROOT/report.csv"; then
  pass "--out file contains the report"
else
  fail "--out file contains the report"
fi
case_end

echo "# PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
