#!/usr/bin/env bash
# Tests: hooks/subagent-dispatch-prompt.js
# Tags: TL2, hooks, subagent-dispatch, json-prompt, scope:issue-specific, pwsh-not-required
# C3: a JSON-object prompt keeps its keys and gets a reserved dispatch_directive key instead
# of a plain-text append; non-object JSON stays on the plain-text path.

# TL3 gap (what this test does NOT catch): whether a real fixed-contract agent still parses the
# rewritten JSON and keeps its three-line reply; TL3-hook-subagent-dispatch-prompt.sh P5 does.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

agent_in() { printf '({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", description: "d", prompt: %s}})' "$1"; }

# shellcheck disable=SC2016  # JS source.
JSON_OK='(() => { const o = JSON.parse(P); const src = JSON.parse(inp.tool_input.prompt); return Object.keys(src).filter((k) => k !== "dispatch_directive").every((k) => JSON.stringify(o[k]) === JSON.stringify(src[k])) && o.dispatch_directive === canon && P.trimEnd().endsWith("}"); })()'

case_begin "J1-compact-object" "hooks/subagent-dispatch-prompt.js"
check "J1: a compact JSON object keeps topic/context/artifact_dir and gains dispatch_directive = canonical line" \
  "true" "$(sdp_probe "$JSON_OK" "$(agent_in 'JSON.stringify({topic: "t", context: "c", artifact_dir: "/x"})')")"
case_end

case_begin "J2-pretty-and-padded" "hooks/subagent-dispatch-prompt.js"
check "J2: pretty-printed JSON is handled like J1 (values kept)" \
  "true" "$(sdp_probe "$JSON_OK" "$(agent_in 'JSON.stringify({topic: "t", context: "c", artifact_dir: "/x"}, null, 2)')")"
check "J2: JSON with leading/trailing whitespace is handled like J1" \
  "true" "$(sdp_probe "$JSON_OK" "$(agent_in '"  \n" + JSON.stringify({topic: "t", nested: {a: [1, "b"]}}) + "\n\t "')")"
case_end

case_begin "J3-directive-already-canonical" "hooks/subagent-dispatch-prompt.js"
check "J3: dispatch_directive already equal to the canonical line is a passthrough ({})" \
  "{}" "$(sdp_probe "$PASSTHROUGH" "$(agent_in 'JSON.stringify({topic: "t", dispatch_directive: canon})')")"
case_end

case_begin "J4-directive-overwritten" "hooks/subagent-dispatch-prompt.js"
check "J4: a different dispatch_directive value (a section reference only) is overwritten with the canonical line" \
  "true" "$(sdp_probe "$JSON_OK" "$(agent_in 'JSON.stringify({topic: "t", dispatch_directive: "Follow the Subagent Dispatch Prompts section of rules/shell-commands.md."})')")"
case_end

case_begin "J5-non-object-plain-path" "hooks/subagent-dispatch-prompt.js"
J5_ROWS=(
  'broken-object|"{\"topic\": \"t\", "'
  'array|JSON.stringify([{topic: "t"}])'
  'json-string|JSON.stringify("just a string")'
)
for row in "${J5_ROWS[@]}"; do
  check "J5[${row%%|*}]: non-object JSON takes the plain-text path (prompt + blank line + canonical line)" \
    "true" "$(sdp_probe 'P === inp.tool_input.prompt + "\n\n" + canon' "$(agent_in "${row#*|}")")"
done
case_end

case_begin "J6-multiline-value-intact" "hooks/subagent-dispatch-prompt.js"
check "J6: a multi-line prior_concerns value with START/END markers is kept character for character" \
  "true" "$(sdp_probe '(() => { const o = JSON.parse(P); return o.prior_concerns === JSON.parse(inp.tool_input.prompt).prior_concerns && o.dispatch_directive === canon; })()' \
    "$(agent_in 'JSON.stringify({target: "hooks/x.js", prior_concerns: "[PRIOR CONCERNS START]\n- C1: `a` \"quoted\" \\\\ back\n\t- tab line\n[PRIOR CONCERNS END]"})')")"
case_end

finish
