#!/usr/bin/env bash
# Tests: hooks/subagent-dispatch-prompt.js
# Tags: TL2, hooks, subagent-dispatch, canonical-line, negative-control, scope:issue-specific, pwsh-not-required
# C2: the append is skipped ONLY when one whole trimmed line equals the canonical line with an
# absolute rule path; a heading mention, a placeholder, a relative path or a reworded line all append.

# TL3 gap (what this test does NOT catch): a dispatcher that writes the line with a path the
# subagent cannot read; only TL3-hook-subagent-dispatch-prompt.sh P1 sees a real Read.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

agent_in() { printf '({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", description: "d", prompt: %s}})' "$1"; }

echo "=== canonical line present: skip the append ==="
case_begin "CM-skip-when-present" "hooks/subagent-dispatch-prompt.js"
CM_SKIP_ROWS=(
  'posix|"Do the task.\n\n" + canonFor("/home/u/agents/rules/shell-commands.md")'
  'windows|"Do the task.\n\n" + canonFor("C:/git/agents/rules/shell-commands.md")'
  'worktree|"Do the task.\n\n" + canonFor("C:/git/worktrees/9999-x/agents/rules/shell-commands.md")'
  'surrounding-space|"Do the task.\n\n   " + canon + "  \t\nMore text after."'
  'first-line|canon + "\nDo the task."'
)
for row in "${CM_SKIP_ROWS[@]}"; do
  check "CM-skip[${row%%|*}]: a standalone canonical line with an absolute path is a passthrough ({})" \
    "{}" "$(sdp_probe "$PASSTHROUGH" "$(agent_in "${row#*|}")")"
done
case_end

echo "=== near-miss lines: append exactly one canonical line (N1-N6) ==="
case_begin "CM-N-near-miss-appends" "hooks/subagent-dispatch-prompt.js"
CM_N_ROWS=(
  'N1-section-reference-only|"Do the task. Follow the Subagent Dispatch Prompts section of rules/shell-commands.md."'
  'N2-pasted-rule-placeholder|"Review this rule text:\n\n## Subagent Dispatch Prompts\n\n" + canonFor("<AGENTS_MAIN_ROOT>/rules/shell-commands.md") + "\n\nIs it clear?"'
  'N3-relative-path|"Do the task.\n\n" + canonFor("rules/shell-commands.md")'
  'N4-embedded-mid-sentence|"Do the task, and note: " + canon + " Thanks."'
  'N5-reworded-no-unless|"Do the task.\n\n" + canon.replace(/ unless your own output contract fixes the exact shape of your reply\./, ".")'
  'N5-reworded-no-deviations|"Do the task.\n\n" + canon.replace("`Command-form deviations`", "`deviations`")'
  'N6-unexpanded-env|"Do the task.\n\n" + canonFor("$AGENTS_MAIN_ROOT/rules/shell-commands.md")'
)
for row in "${CM_N_ROWS[@]}"; do
  check "CM-${row%%|*}: the output prompt carries exactly one absolute-path canonical line" \
    "true" "$(sdp_probe "$APPENDED_ONCE" "$(agent_in "${row#*|}")")"
done
case_end

case_begin "CM-N-original-kept" "hooks/subagent-dispatch-prompt.js"
check "CM-N2: the pasted rule text survives verbatim ahead of the appended line" \
  "true" "$(sdp_probe 'typeof P === "string" && P.startsWith(inp.tool_input.prompt) && P.length > inp.tool_input.prompt.length' "$(agent_in "${CM_N_ROWS[1]#*|}")")"
case_end

finish
