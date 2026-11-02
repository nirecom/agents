#!/usr/bin/env bash
# Tests: hooks/pre-tool-use-askuser-jev.js
# Tags: TL3, hooks, pretooluse, askuserquestion, updated-input, jev, askuser-answer, live-host-dispatch, scope:issue-specific, pwsh-not-required, test-lang-exception:e2e
# Step 0 spike of #2461/#2764: a PreToolUse hook on AskUserQuestion returning "allow" plus
# updatedInput {questions, answers} must hand that answer to the model in a real `claude -p`.

# Why stream-json, not `--output-format json`: plain `claude -p` leaves AskUserQuestion out of
# the tool list (even with `--tools AskUserQuestion`); the tool is offered only when a host can
# answer prompts, so the run takes the SDK host shape (`--permission-prompt-tool stdio`). stdin
# closes after the one user message, so a prompt routed to the host (a `control_request`)
# could never be answered: the assertions require none.

set -uo pipefail

# TL3 gap: the spike drives a test-local stub hook with a fixed answer, not the real
# hooks/pre-tool-use-askuser-jev.js — the real hook and its settings.json registration are
# wired at write_code; the day-to-day TL2 runner is tests/hooks/feature-2764-askuser-jev.js.
# An interactive (TTY) session is not run here, and partial answers are out of scope (the plan
# auto-answers only when every question has an answer).
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
if [ ! -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ]; then
  echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off; then
  echo "SKIP: requires RUN_TL3=on in .env (Anthropic-billable)" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not found" >&2; exit 77
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found" >&2; exit 77
fi

readonly BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
export WORKFLOW_STATE_DIR="$BASE/workflow" WORKFLOW_PLANS_DIR="$BASE/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"

SESSION_UUID="5e1d2c3b-2461-4764-8a9b-0c1d2e3f4a5b"
QUESTION="Which codename should you print?"
PICK="Bravo-2846"
OTHER="Alpha-7391"
PROJ="$BASE/proj"
RECORD="$BASE/io/hook-record.jsonl"
STUB="$BASE/io/stub-askuser-hook.js"
OUT="$BASE/io/stream.jsonl"
mkdir -p "$PROJ/.claude" "$BASE/io"
harness_git_init "$PROJ"

# The stub answers every question with the option whose label starts with "Bravo" (else the
# first option), the exact updatedInput shape the askuser-answer adapter is to return.
cat > "$STUB" <<'EOF'
const fs = require("fs");
const recordFile = process.argv[2];
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  let input = {};
  try { input = JSON.parse(raw); } catch (_e) { input = {}; }
  const ti = input.tool_input || {};
  const questions = Array.isArray(ti.questions) ? ti.questions : [];
  const answers = {};
  for (const q of questions) {
    const opts = Array.isArray(q.options) ? q.options : [];
    const hit = opts.find((o) => String(o.label).startsWith("Bravo")) || opts[0];
    if (hit) answers[q.question] = hit.label;
  }
  const out = { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow",
    permissionDecisionReason: "TL3 stub auto-answer", updatedInput: { questions, answers } } };
  try { fs.appendFileSync(recordFile, JSON.stringify({ input, out }) + "\n"); } catch (_e) { /* evidence only */ }
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
});
EOF

# settings.json carries only the hook under test (claude-e2e.md fixture hygiene).
jq -n --arg cmd "node \"$(np "$STUB")\" \"$(np "$RECORD")\"" \
  '{hooks: {PreToolUse: [{matcher: "AskUserQuestion", hooks: [{type: "command", command: $cmd, timeout: 10}]}]}}' \
  > "$PROJ/.claude/settings.json"

ASK_PROMPT="Use the AskUserQuestion tool exactly once. Ask the single question '$QUESTION' with header 'Codename', multiSelect false, and exactly two options labeled '$OTHER' and '$PICK'. After you get the answer, reply with only the label that was chosen, verbatim, and nothing else. Do not guess; use the tool's answer."
jq -cn --arg p "$ASK_PROMPT" '{type: "user", message: {role: "user", content: $p}}' > "$BASE/io/input.jsonl"

unset CLAUDECODE
RC=0
( cd "$PROJ" && unset CLAUDE_CODE_SESSION_ID && \
  run_with_timeout 180 claude -p \
    --session-id "$SESSION_UUID" \
    --setting-sources project \
    --input-format stream-json \
    --output-format stream-json --verbose \
    --permission-prompt-tool stdio \
    < "$BASE/io/input.jsonl" > "$OUT" 2> "$BASE/io/claude.err" ) || RC=$?

# Evidence for the spike report (written before the asserts so a FAIL still leaves it).
if [ -n "${TL3_ASKUSER_EVIDENCE_TO:-}" ]; then
  cp "$OUT" "$TL3_ASKUSER_EVIDENCE_TO.stream.jsonl" 2>/dev/null || true
  cp "$RECORD" "$TL3_ASKUSER_EVIDENCE_TO.hook-record.jsonl" 2>/dev/null || true
  cp "$BASE/io/claude.err" "$TL3_ASKUSER_EVIDENCE_TO.claude.err" 2>/dev/null || true
fi

case_begin "S0-run-completes-without-host-prompt" "hooks/pre-tool-use-askuser-jev.js"
# A prompt routed to the host could never be answered (stdin is closed): it would hang to the
# 180 s timeout (124) or end the run in error.
if [ "$RC" -eq 0 ]; then pass "S0: claude -p completed with rc=0"
else fail "S0: claude -p exited rc=$RC (124 = timeout)" "stderr tail: $(tail -c 300 "$BASE/io/claude.err" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"; fi
TOOLS_HAS="$(jq -r 'select(.type=="system" and .subtype=="init") | (.tools // []) | index("AskUserQuestion") != null' "$OUT" 2>/dev/null | head -n 1)"
if [ "$TOOLS_HAS" = "true" ]; then pass "S0: AskUserQuestion is in the session's tool list (non-vacuity)"
else fail "S0: AskUserQuestion is not offered in this run" "init tools has it=[$TOOLS_HAS]"; fi
CTRL_N="$(jq -r 'select(.type=="control_request") | .type' "$OUT" 2>/dev/null | grep -c control_request)"
if [ "${CTRL_N:-0}" = "0" ]; then pass "S0: no control_request reached the host (no dialog)"
else fail "S0: $CTRL_N control_request message(s) reached the host" "$(grep -m1 control_request "$OUT" | head -c 300)"; fi
case_end

case_begin "S1-hook-saw-askuserquestion" "hooks/pre-tool-use-askuser-jev.js"
HOOK_Q="$(head -n 1 "$RECORD" 2>/dev/null | jq -r '.input.tool_input.questions[0].question // empty' 2>/dev/null)"
HOOK_ANS="$(head -n 1 "$RECORD" 2>/dev/null | jq -r --arg q "$HOOK_Q" '.out.hookSpecificOutput.updatedInput.answers[$q] // empty' 2>/dev/null)"
if [ -n "$HOOK_Q" ] && [ "$HOOK_ANS" = "$PICK" ]; then pass "S1: the stub ran on AskUserQuestion and answered [$HOOK_Q] -> $PICK"
else fail "S1: the stub did not answer an AskUserQuestion call" "question=[$HOOK_Q] answer=[$HOOK_ANS] record=$(head -c 400 "$RECORD" 2>/dev/null)"; fi
case_end

case_begin "S2-model-received-the-answer" "hooks/pre-tool-use-askuser-jev.js"
# The AskUserQuestion tool_result carries the stub's answer, accepted by the hook's decision.
TR_TEXT="$(jq -r 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | (.content | if type=="array" then map(.text // "") | join(" ") else tostring end)' "$OUT" 2>/dev/null | tr -d '\r')"
if printf '%s' "$TR_TEXT" | grep -qF "=\"$PICK\""; then pass "S2: the AskUserQuestion tool_result carries the answer $PICK"
else fail "S2: no tool_result carries the answer $PICK" "tool_result=[$(printf '%s' "$TR_TEXT" | head -c 300)]"; fi
DEC_SRC="$(jq -r 'select(.type=="user") | (.tool_result_meta // [])[] | .permission_decision | "\(.decision)/\(.source)"' "$OUT" 2>/dev/null | head -n 1)"
if [ "$DEC_SRC" = "accept/hook" ] || [ -z "$DEC_SRC" ]; then pass "S2: the tool use was accepted by the hook (meta=[${DEC_SRC:-absent}])"
else fail "S2: the tool use was not accepted by the hook" "meta=[$DEC_SRC]"; fi
RESULT="$(jq -r 'select(.type=="result") | .result // empty' "$OUT" 2>/dev/null | tr -d '\r')"
if printf '%s' "$RESULT" | grep -qF "$PICK" && ! printf '%s' "$RESULT" | grep -qF "$OTHER"; then
  pass "S2: the model's final reply carries the stub's answer $PICK only"
else fail "S2: the model's reply does not carry the stub's answer" "result=[$(printf '%s' "$RESULT" | head -c 300)]"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
