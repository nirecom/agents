#!/usr/bin/env bash
# Tests: hooks/subagent-dispatch-prompt.js
# Tags: TL2, hooks, subagent-dispatch, updated-input, fail-open, scope:issue-specific, pwsh-not-required
# D1-D8: the plain-text append path of decide() and the stdin main() path.

# TL3 gap (what this test does NOT catch): whether the real host honours updatedInput for an
# Agent call; tests/hooks/TL3-hook-subagent-dispatch-prompt.sh P1/P2 observes that.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

GP_INPUT='({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", description: "fixture task", prompt: "Summarise the README.", model: "sonnet", run_in_background: true, x_future: {k: [1, 2]}}})'

echo "=== decide(): plain-text append ==="
case_begin "D1-append-canonical-line" "hooks/subagent-dispatch-prompt.js"
check "D1: an Agent prompt without the canonical line gets prompt + blank line + canonical line" \
  "true" "$(sdp_probe 'P === inp.tool_input.prompt + "\n\n" + canon' "$GP_INPUT")"
case_end

case_begin "D2-fields-preserved" "hooks/subagent-dispatch-prompt.js"
check "D2: every original field (description, subagent_type, model, run_in_background, x_future) survives by value" \
  "true" "$(sdp_probe '(() => { const u = out.hookSpecificOutput.updatedInput, t = inp.tool_input; return ["description", "subagent_type", "model", "run_in_background", "x_future"].every((k) => JSON.stringify(u[k]) === JSON.stringify(t[k])); })()' "$GP_INPUT")"
check "D2: the hookEventName is PreToolUse" "PreToolUse" "$(sdp_probe 'out.hookSpecificOutput.hookEventName' "$GP_INPUT")"
case_end

case_begin "D3-no-permission-decision" "hooks/subagent-dispatch-prompt.js"
check "D3: the output carries no permissionDecision (the hook never approves or denies)" \
  "absent|true" "$(sdp_probe '(JSON.stringify(out).includes("permissionDecision") ? "present" : "absent") + "|" + (typeof P === "string")' "$GP_INPUT")"
case_end

case_begin "D4-idempotent" "hooks/subagent-dispatch-prompt.js"
check "D4: feeding D1's output back in is a passthrough ({})" \
  "{}" "$(sdp_probe "$PASSTHROUGH" '({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", description: "d", prompt: "Summarise the README.\n\n" + canon}})')"
case_end

case_begin "D5-task-tool-name" "hooks/subagent-dispatch-prompt.js"
check "D5: the legacy Task tool name gets the same append" \
  "true" "$(sdp_probe 'P === inp.tool_input.prompt + "\n\n" + canon' '({tool_name: "Task", tool_input: {subagent_type: "general-purpose", description: "d", prompt: "Summarise the README."}})')"
case_end

case_begin "D6-out-of-scope-passthrough" "hooks/subagent-dispatch-prompt.js"
D6_ROWS=(
  'bash|({tool_name: "Bash", tool_input: {command: "ls", prompt: "x"}})'
  'skill|({tool_name: "Skill", tool_input: {skill: "review-tests", prompt: "x"}})'
  'no-tool-input|({tool_name: "Agent"})'
  'tool-input-string|({tool_name: "Agent", tool_input: "prompt"})'
  'prompt-number|({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", prompt: 42}})'
  'prompt-empty|({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", prompt: ""}})'
  'prompt-missing|({tool_name: "Agent", tool_input: {subagent_type: "general-purpose"}})'
  'null-input|null'
)
for row in "${D6_ROWS[@]}"; do
  check "D6[${row%%|*}]: out-of-scope input is a passthrough ({})" "{}" "$(sdp_probe "$PASSTHROUGH" "${row#*|}")"
done
case_end

echo "=== main(): stdin path ==="
case_begin "D7-main-fail-open" "hooks/subagent-dispatch-prompt.js"
printf '%s' '{not json' > "$TMPROOT/d7-bad.json"
: > "$TMPROOT/d7-empty.json"
check "D7: malformed stdin -> {} with exit 0" "0|{}" "$(sdp_main "$TMPROOT/d7-bad.json")"
check "D7: empty stdin -> {} with exit 0" "0|{}" "$(sdp_main "$TMPROOT/d7-empty.json")"
printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"d","prompt":"Summarise the README."}}' > "$TMPROOT/d7-good.json"
D7_OUT="$(sdp_main "$TMPROOT/d7-good.json")"
check "D7: a well-formed Agent payload through stdin exits 0 with an updatedInput carrying the rule path" \
  "0|yes|yes" "${D7_OUT%%|*}|$(case "$D7_OUT" in *'"updatedInput"'*) echo yes ;; *) echo no ;; esac)|$(case "$D7_OUT" in *"$SDP_RULE_PATH"*) echo yes ;; *) echo no ;; esac)"
case_end

case_begin "D8-literal-absolute-path" "hooks/subagent-dispatch-prompt.js"
check "D8: the appended line names this checkout's rule file as a literal absolute path, with no \$" \
  "true|false|true" "$(sdp_probe '(() => { const last = P.split(/\r?\n/).pop(); return [last.includes(env.SDP_RULE_PATH), last.includes("$"), /^Read `(?:[A-Za-z]:)?\//.test(last)].join("|"); })()' "$GP_INPUT")"
case_end

finish
