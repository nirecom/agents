#!/usr/bin/env bash
# Tests: hooks/block-post-edit-size.js, hooks/confirm-checkpoint.js
# Tags: hook, pretooluse, size-limits, block, hook-registration, live-host-dispatch, TL3, run-e2e, scope:common, layer:TL3
# Real-host seam of the two size gates: over-HARD Edit and over-HARD CONFIRM_DETAIL echo are refused
# in a live `claude -p` turn, under-limit controls go through (TL2: feature-2631-confirm-size.js).
set -uo pipefail
# TL3 gap (what this test does NOT catch):
# - the registration in the deployable settings.json (this fixture writes its own minimal one)
# - a host whose model declines the requested tool call (the logger control then fails)
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || { echo "SKIP: bin/get-config-var not executable" >&2; exit 77; }
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && { echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77; }
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not found" >&2; exit 77; }

# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# Dual-pin per rules/test/fixture-isolation.md, before any hook or bin call.
BASE="$(make_tmp)"; readonly BASE
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/workflow-state" "$BASE/plans" "$BASE/no-transcripts"
export WORKFLOW_STATE_DIR="$BASE/workflow-state" WORKFLOW_PLANS_DIR="$BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$BASE/no-transcripts"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"

ROOT_M="$(np "$SCRIPT_CHECKOUT_ROOT")"
REPO="$BASE/repo"; MOCKBIN="$BASE/bin"; MARKS="$BASE/marks"; CFG="$BASE/cfg"
mkdir -p "$REPO/.claude" "$REPO/bin" "$MOCKBIN" "$MARKS" "$CFG"
MARKS_M="$(np "$MARKS")"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# SAFETY: shadow `gh` so the session cannot reach any remote.
printf '#!/usr/bin/env bash\necho "gh is disabled in this TL3 fixture" >&2\nexit 1\n' > "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

# Config root the hooks read (.env under AGENTS_MAIN_ROOT). CONFIRM_DETAIL=off keeps the #2513
# plan-link deny out of the control turn; the size deny runs before that off exit by contract.
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=off\nPLAN_LANG=english\nPLAN_SYNC_REMOTE_URL=\n' > "$CFG/.env"
CFG_M="$(np "$CFG")"

# make_lines <n> — exactly n newline-terminated lines "v1 line <i>".
make_lines() { local i; for ((i = 1; i <= $1; i++)); do printf 'v1 line %d\n' "$i"; done; }
make_lines 500 > "$REPO/bin/over.js"
make_lines 10 > "$REPO/bin/small.js"
OVER_SHA="$(git hash-object "$REPO/bin/over.js")"

# Logger: the positive control that the model really attempted each tool call.
cat > "$BASE/logger.js" <<'EOF'
const fs = require("fs");
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  try {
    const i = JSON.parse(raw);
    const t = i.tool_input || {};
    fs.appendFileSync(process.argv[2], JSON.stringify({ sid: i.session_id, tool: i.tool_name, file: t.file_path || "", cmd: t.command || "" }) + "\n");
  } catch (_) { /* a logger never blocks */ }
  process.stdout.write("");
});
EOF
LOGGER_M="$(np "$BASE/logger.js")"
LOG_M="$MARKS_M/tools.jsonl"

cat > "$REPO/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit|editFiles", "hooks": [
        { "type": "command", "command": "node \"$ROOT_M/hooks/block-post-edit-size.js\"", "timeout": 5 } ] },
      { "matcher": "Bash|runInTerminal|runCommands", "hooks": [
        { "type": "command", "command": "node \"$ROOT_M/hooks/confirm-checkpoint.js\"", "timeout": 10 } ] },
      { "matcher": "Edit|Bash", "hooks": [
        { "type": "command", "command": "node \"$LOGGER_M\" \"$LOG_M\"", "timeout": 5 } ] }
    ]
  }
}
EOF

T_EDIT="dddddddd-2631-4000-8000-000000000001"
T_PLAN_OVER="dddddddd-2631-4000-8000-000000000002"
T_PLAN_OK="dddddddd-2631-4000-8000-000000000003"

# started_state <sid> — a v5 state with one settled step, so sizeCheckActive(sid) is true.
started_state() {
  local at
  at="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  printf '{"version":5,"session_id":"%s","created_at":"%s","session_start_context":{"cwd":"%s","git_branch":"feature/f2631-fixture"},"events":[{"at":"%s","kind":"step_status","step":"workflow_init","status":"complete","provenance":"observed","origin":"mark-step","seq":1}]}\n' \
    "$1" "$at" "$(np "$REPO")" "$at" > "$BASE/workflow-state/$1.json"
}
# plan_of <sid> <n> — the session's detail plan of exactly n English lines.
plan_of() { local i; for ((i = 1; i <= $2; i++)); do printf 'Line %d of the fixture plan.\n' "$i"; done > "$BASE/plans/$1-detail.md"; }
for t in "$T_EDIT" "$T_PLAN_OVER" "$T_PLAN_OK"; do started_state "$t"; done
plan_of "$T_PLAN_OVER" 501
plan_of "$T_PLAN_OK" 10

unset CLAUDECODE

declare -A TURN_RC=()
# run_turn <session-uuid> <prompt> — the CLI's exit code is kept: a timeout must not look like a deny.
run_turn() {
  local rc=0
  ( cd "$REPO" && PATH="$MOCKBIN:$PATH" AGENTS_MAIN_ROOT="$CFG_M" run_with_timeout 180 claude -p "$2" \
      --session-id "$1" --setting-sources project --dangerously-skip-permissions \
      --output-format json >"$BASE/$1.out" 2>&1 ) || rc=$?
  TURN_RC["$1"]=$rc
}
# attempted <sid> <tool> <needle> — the logger saw that tool call with the needle in its target.
attempted() { grep -F "\"sid\":\"$1\"" "$MARKS/tools.jsonl" 2>/dev/null | grep -F "\"tool\":\"$2\"" | grep -qF -- "$3"; }

echo "=== E: an Edit taking bin/over.js to 501 lines, then a control Edit of bin/small.js ==="
run_turn "$T_EDIT" "This is an automated test fixture. Make exactly two Edit tool calls and nothing else. First: Edit the file bin/over.js, replacing the exact text 'v1 line 500' with 'v1 line 500' followed by a newline and 'v1 line 501'. Second, whatever happened to the first: Edit the file bin/small.js, replacing the exact text 'v1 line 10' with 'v1 line 10' followed by a newline and 'v1 line 11'. If an edit is refused, do not retry it and do not read or write any file another way. Then stop."
CONFIRM_PROMPT="This is an automated test fixture. Run exactly this one Bash command, once, verbatim: echo \"<<WORKFLOW_CONFIRM_DETAIL: ok>>\" > \"$MARKS_M/SID.ran\" -- If the command is refused, report the refusal verbatim, do not retry, do not use any other tool, and stop."
echo "=== C1: a CONFIRM_DETAIL echo whose plan is 501 lines (over HARD 500) ==="
run_turn "$T_PLAN_OVER" "${CONFIRM_PROMPT//SID/$T_PLAN_OVER}"
echo "=== C2: positive control — the same echo with a 10-line plan ==="
run_turn "$T_PLAN_OK" "${CONFIRM_PROMPT//SID/$T_PLAN_OK}"

case_begin "live-turns-completed" "hooks/block-post-edit-size.js"
for t in "$T_EDIT" "$T_PLAN_OVER" "$T_PLAN_OK"; do
  if [ "${TURN_RC[$t]}" -eq 0 ]; then pass "turn-$t-cli-exited-zero"
  else fail "turn-$t-cli-exited-zero" "claude -p exited ${TURN_RC[$t]} (124 = the 180s timeout fired): $(head -c 300 "$BASE/$t.out")"; fi
done
case_end

case_begin "live-over-hard-edit-is-blocked" "hooks/block-post-edit-size.js"
if attempted "$T_EDIT" Edit "bin/over.js"; then pass "over-hard-edit-was-attempted"
else fail "over-hard-edit-was-attempted" "no Edit of bin/over.js reached PreToolUse — an unchanged file proves nothing"; fi
got="$(git hash-object "$REPO/bin/over.js")"
if [ "$got" = "$OVER_SHA" ]; then pass "over-hard-edit-left-the-file-unchanged"
else fail "over-hard-edit-left-the-file-unchanged" "bin/over.js now has $(wc -l < "$REPO/bin/over.js") lines — the HARD block did not hold"; fi
case_end

case_begin "live-under-limit-edit-goes-through" "hooks/block-post-edit-size.js"
if attempted "$T_EDIT" Edit "bin/small.js"; then pass "under-limit-edit-was-attempted"
else fail "under-limit-edit-was-attempted" "no Edit of bin/small.js reached PreToolUse"; fi
got="$(wc -l < "$REPO/bin/small.js" | tr -d ' ')"
if [ "$got" = 11 ]; then pass "under-limit-edit-landed"
else fail "under-limit-edit-landed" "bin/small.js has $got lines, want 11 — the size hook over-blocks"; fi
case_end

case_begin "live-over-hard-confirm-is-denied" "hooks/confirm-checkpoint.js"
if attempted "$T_PLAN_OVER" Bash "WORKFLOW_CONFIRM_DETAIL"; then pass "over-hard-confirm-was-attempted"
else fail "over-hard-confirm-was-attempted" "no CONFIRM_DETAIL Bash call reached PreToolUse — an absent marker proves nothing"; fi
if [ -f "$MARKS/$T_PLAN_OVER.ran" ]; then fail "over-hard-confirm-never-ran" "the CONFIRM echo ran although the plan is over HARD"
else pass "over-hard-confirm-never-ran"; fi
if grep -qF "plan-size" "$BASE/$T_PLAN_OVER.out"; then pass "over-hard-denial-names-plan-size"
else fail "over-hard-denial-names-plan-size" "the turn output does not carry the plan-size reason: $(head -c 300 "$BASE/$T_PLAN_OVER.out")"; fi
case_end

case_begin "live-under-limit-confirm-goes-through" "hooks/confirm-checkpoint.js"
if attempted "$T_PLAN_OK" Bash "WORKFLOW_CONFIRM_DETAIL"; then pass "under-limit-confirm-was-attempted"
else fail "under-limit-confirm-was-attempted" "no CONFIRM_DETAIL Bash call reached PreToolUse"; fi
if [ -f "$MARKS/$T_PLAN_OK.ran" ]; then pass "under-limit-confirm-did-run"
else fail "under-limit-confirm-did-run" "the 10-line plan's echo left no marker — the size gate over-blocks, or the host refused it"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
