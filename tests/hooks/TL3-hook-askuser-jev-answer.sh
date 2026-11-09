#!/usr/bin/env bash
# Tests: hooks/pre-tool-use-askuser-jev.js
# Tags: TL3, hooks, pretooluse, askuserquestion, updated-input, jev, askuser-answer, live-host-dispatch, scope:issue-specific, pwsh-not-required, test-lang-exception:e2e, dialog-id, route-log, step-match, mock-server
# #2764: the real hook answers a `claude -p` AskUserQuestion that follows a real SKILL.md line
# only for a low dialog ID at a declared step; otherwise a control_request reaches the host.
# stream-json + `--permission-prompt-tool stdio` is the only shape that offers AskUserQuestion;
# stdin closes after one message, so host-bound cases run shorter and assert the control_request.
# TL3 gap: an interactive (TTY) session is not run here; neither is the real Jev service (the mock
# answers by key). The day-to-day TL2 runner is tests/hooks/feature-2764-askuser-jev.js.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
if [[ ! -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ]]; then
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

# shellcheck source=tests/hooks/feature-2460-jev-shadow/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2460-jev-shadow/_lib.sh"
mock_start

SEED_JS="$(np "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2764-askuser-jev/tl3-seed.js")"
HOOK_JS="$REPO_N/hooks/pre-tool-use-askuser-jev.js"
QUESTION="Which codename should you print?"
OTHER="Alpha-7391"
PICK="Bravo-2846"

# skill_line <skill> <dialog ID>: the SKILL.md line that carries `metadata.source=<dialog-id>`.
skill_line() {
  grep -m1 -F "metadata.source=$2" "$SCRIPT_CHECKOUT_ROOT/skills/$1/SKILL.md" 2>/dev/null
}

# run_case <name> <seed> <skill> <dialog ID> <sid> <timeout>: one `claude -p` run on a fresh fixture.
# Sets RC, STREAM (stream-json output), ROUTES (the route log) and LINE (the SKILL.md line used).
run_case() {
  local name="$1" seed="$2" skill="$3" id="$4" sid="$5" secs="$6" prompt
  fx_new "$name"
  mkdir -p "$FX/proj/.claude"
  STREAM="$FX/io/stream.jsonl"; ROUTES="$FX/state/logs/askuser-routes.jsonl"; RC=0
  LINE="$(skill_line "$skill" "$id")"
  run_with_timeout 60 node "$SEED_JS" "$(np "$FX")" "$seed" "$sid" > "$FX/io/seed.out" 2>&1 || RC=98
  jq -n --arg cmd "node \"$HOOK_JS\"" \
    '{hooks: {PreToolUse: [{matcher: "AskUserQuestion", hooks: [{type: "command", command: $cmd, timeout: 10}]}]}}' \
    > "$FX/proj/.claude/settings.json"
  prompt="You are following this instruction line from a skill: <<${LINE}>>. Use the AskUserQuestion tool exactly once, setting metadata.source exactly as that line says. Ask the single question '$QUESTION' with header 'Codename', multiSelect false, and exactly two options labeled '$OTHER' (first) and '$PICK' (second). After you get the answer, reply with only the label that was chosen, verbatim."
  jq -cn --arg p "$prompt" '{type: "user", message: {role: "user", content: $p}}' > "$FX/io/input.jsonl"
  [[ "$RC" -eq 0 ]] || return 0
  (
    cd "$FX/proj" || exit 97
    unset CLAUDECODE CLAUDE_CODE_SESSION_ID JEV_AUTO_SKIP_ASKUSER
    export JEV=on JEV_AUTO_CLARIFICATIONS=on JEV_BASE_URL="$MOCK_URL" TYPESAFE_API_KEY="$SENTINEL_KEY"
    run_with_timeout "$secs" claude -p --session-id "$sid" --setting-sources project \
      --input-format stream-json --output-format stream-json --verbose \
      --permission-prompt-tool stdio < "$FX/io/input.jsonl" > "$STREAM" 2> "$FX/io/claude.err"
  ) || RC=$?
}
ctrl_count() { jq -r 'select(.type=="control_request") | .type' "$STREAM" 2>/dev/null | grep -c control_request; }
route_of() { jq -r --arg id "$1" 'select(.dialog_id==$id) | "\(.route)/\(.step)/\(.jev_called)"' "$ROUTES" 2>/dev/null | head -n 1; }

# The mock answers the second option of the first question (q0o1) with confidence.
mock_mode '{"echo":true,"capture":true,"defaultP":0.02,"keyProbs":{"q0o1":0.97,"q0_o1":0.97}}'

case_begin "a-low-id-at-its-step-is-answered" "hooks/pre-tool-use-askuser-jev.js"
run_case a runTests run-tests run-tests.calibrate "5e1d2c3b-2764-4a01-8a9b-0c1d2e3f4a01" 180
if [[ -n "$LINE" ]]; then pass "a: run-tests/SKILL.md carries metadata.source=run-tests.calibrate"
else fail "a: no SKILL.md line carries metadata.source=run-tests.calibrate" "skills/run-tests/SKILL.md"; fi
check "a: claude -p completed (rc)" "0" "$RC"
check "a: no control_request reached the host" "0" "$(ctrl_count)"
check "a: route answered at run_tests, Jev called" "answered/run_tests/true" "$(route_of run-tests.calibrate)"
RESULT="$(jq -r 'select(.type=="result") | .result // empty' "$STREAM" 2>/dev/null | tr -d '\r')"
if printf '%s' "$RESULT" | grep -qF "$PICK"; then pass "a: the model's reply carries Jev's answer $PICK"
else fail "a: the model's reply does not carry $PICK" "result=[$(printf '%s' "$RESULT" | head -c 300)]"; fi
case_end

case_begin "b-high-id-reaches-the-user" "hooks/pre-tool-use-askuser-jev.js"
run_case b writeCode write-code write-code.edit-plan-approve "5e1d2c3b-2764-4a01-8a9b-0c1d2e3f4a02" 90
if [[ -n "$LINE" ]]; then pass "b: write-code/SKILL.md carries metadata.source=write-code.edit-plan-approve"
else fail "b: no SKILL.md line carries metadata.source=write-code.edit-plan-approve" "skills/write-code/SKILL.md"; fi
N="$(ctrl_count)"
if [[ "${N:-0}" -ge 1 ]]; then pass "b: the dialog reached the host as a control_request"
else fail "b: no control_request reached the host" "rc=$RC"; fi
check "b: route high, Jev not called" "high/null/false" "$(route_of write-code.edit-plan-approve)"
case_end

case_begin "c-low-id-outside-its-step-reaches-the-user" "hooks/pre-tool-use-askuser-jev.js"
run_case c writeCode run-tests run-tests.calibrate "5e1d2c3b-2764-4a01-8a9b-0c1d2e3f4a03" 90
N="$(ctrl_count)"
if [[ "${N:-0}" -ge 1 ]]; then pass "c: the dialog reached the host as a control_request"
else fail "c: no control_request reached the host" "rc=$RC"; fi
check "c: route step-mismatch at write_code, Jev not called" "step-mismatch/write_code/false" "$(route_of run-tests.calibrate)"
case_end

finish
