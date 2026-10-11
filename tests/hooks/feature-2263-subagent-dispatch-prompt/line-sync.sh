#!/usr/bin/env bash
# Tests: hooks/subagent-dispatch-prompt.js, rules/shell-commands.md
# Tags: TL2, hooks, subagent-dispatch, line-sync, negative-control, scope:issue-specific, pwsh-not-required
# R6: the hook's canonical line, its exemption tool set and its JSON key are copies of what
# rules/shell-commands.md says; a rename on either side must fail here, not drift silently.

# TL3 gap (what this test does NOT catch): wording the rule changes OUTSIDE the canonical line
# (the surrounding prose); only the line, the tool trio and the key are pinned.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PLACEHOLDER_PATH='<AGENTS_MAIN_ROOT>/rules/shell-commands.md'
LS_CANON_ERE='^[[:space:]]*([>-][[:space:]]*)?Read `<AGENTS_MAIN_ROOT>/rules/shell-commands\.md`'

# section_text <file>: the `## Subagent Dispatch Prompts` section body (empty when absent).
section_text() {
  [ -f "$1" ] || return 0
  awk '/^## Subagent Dispatch Prompts[[:space:]]*$/ { on = 1; print; next } on && /^## / { exit } on { print }' "$1"
}
# rule_canon <file>: every canonical line in the section, list/quote marker and edges trimmed.
rule_canon() {
  section_text "$1" | grep -E -- "$LS_CANON_ERE" | sed -E 's/^[[:space:]]*([>-][[:space:]]*)?//; s/[[:space:]]+$//'
}
# same_line <file>: "match" when the file's single canonical line equals the test's split copy.
same_line() {
  local got
  got="$(rule_canon "$1")"
  if [ "$got" = "$CANON_PRE$PLACEHOLDER_PATH$CANON_POST" ]; then printf 'match'; else printf 'mismatch'; fi
}

RULE_CANON="$(rule_canon "$RULES_FILE")"
export SDP_RULE_CANON="$RULE_CANON" SDP_PLACEHOLDER_PATH="$PLACEHOLDER_PATH"

case_begin "LS1-rule-line-equals-template" "rules/shell-commands.md"
check "LS1: the rule's Subagent Dispatch Prompts section has exactly one canonical line" \
  "1" "$(if [ -n "$RULE_CANON" ]; then printf '%s\n' "$RULE_CANON" | wc -l | tr -d ' '; else echo 0; fi)"
check "LS1: that line equals the template the hook tests split at the rule-path slot" "match" "$(same_line "$RULES_FILE")"
case_end

case_begin "LS2-hook-line-equals-rule-line" "hooks/subagent-dispatch-prompt.js"
check "LS2: the hook's appended line, with its absolute path mapped back to the placeholder, equals the rule's line" \
  "true" "$(sdp_probe '(() => { const last = P.split(/\r?\n/).pop(); return env.SDP_RULE_CANON.length > 0 && last.split(env.SDP_RULE_PATH).join(env.SDP_PLACEHOLDER_PATH) === env.SDP_RULE_CANON; })()' \
    '({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", description: "d", prompt: "Do the task."}})')"
case_end

case_begin "LS3-exemption-tool-set" "hooks/subagent-dispatch-prompt.js"
FX_AGENTS="$TMPROOT/ls-agents"
mkdir -p "$FX_AGENTS"
CANDIDATES=(Bash Edit Glob Grep Read WebFetch WebSearch Write)
for t in "${CANDIDATES[@]}"; do
  # File names are lower-cased: subagent_type must match ^[a-z0-9-]+$ to be looked up at all.
  printf -- '---\nname: ls-%s\ndescription: fixture\ntools: Read, %s\n---\n' "${t,,}" "$t" > "$FX_AGENTS/ls-${t,,}.md"
done
export SDP_LS_AGENTS
SDP_LS_AGENTS="$(np "$FX_AGENTS")"
HOOK_SET=""
for t in "${CANDIDATES[@]}"; do
  [ "$(sdp_probe 'typeof P === "string"' "({tool_name: \"Agent\", tool_input: {subagent_type: \"ls-${t,,}\", prompt: \"Do the task.\"}})" '({agentsDir: env.SDP_LS_AGENTS})')" = "true" ] && HOOK_SET="$HOOK_SET${HOOK_SET:+,}$t"
done
RULE_TOOL_LINE="$(section_text "$RULES_FILE" | grep -E '\bBash\b' | grep -E '\bWrite\b' | grep -E '\bEdit\b' | grep -Ev -- "$LS_CANON_ERE" | head -n1)"
RULE_SET=""
for t in "${CANDIDATES[@]}"; do
  printf '%s' "$RULE_TOOL_LINE" | grep -qE "\\b$t\\b" && RULE_SET="$RULE_SET${RULE_SET:+,}$t"
done
check "LS3: the rule's exemption line names exactly the trio Bash, Edit, Write" "Bash,Edit,Write" "$RULE_SET"
check "LS3: the tools that make the hook append are exactly the rule's trio" "${RULE_SET:-<rule-line-missing>}" "$HOOK_SET"
case_end

case_begin "LS4-json-key" "hooks/subagent-dispatch-prompt.js"
RULE_KEY="$(section_text "$RULES_FILE" | grep -oE '`dispatch_directive`' | head -n1 | tr -d '`')"
check "LS4: the rule's section names the JSON key dispatch_directive" "dispatch_directive" "$RULE_KEY"
check "LS4: the only key the hook adds to a JSON prompt is the rule's key" "${RULE_KEY:-<rule-key-missing>}" \
  "$(sdp_probe '(() => { const o = JSON.parse(P); return Object.keys(o).filter((k) => !(k in JSON.parse(inp.tool_input.prompt))).join(","); })()' \
    '({tool_name: "Agent", tool_input: {subagent_type: "general-purpose", prompt: JSON.stringify({topic: "t"})}})')"
case_end

case_begin "LS5-negative-control" "rules/shell-commands.md"
mkdir -p "$TMPROOT/ls5"
printf '## Subagent Dispatch Prompts\n\n> %s\n\n## Next\n' "$CANON_PRE$PLACEHOLDER_PATH$CANON_POST" > "$TMPROOT/ls5/good.md"
printf '## Subagent Dispatch Prompts\n\n> %s\n\n## Next\n' "$CANON_PRE$PLACEHOLDER_PATH${CANON_POST/final report/closing report}" > "$TMPROOT/ls5/one-word.md"
printf '## Other\n\n> %s\n\n## Subagent Dispatch Prompts\n\nNo line here.\n' "$CANON_PRE$PLACEHOLDER_PATH$CANON_POST" > "$TMPROOT/ls5/out-of-section.md"
check "LS5[good]: the extraction accepts a fixture carrying the exact line" "match" "$(same_line "$TMPROOT/ls5/good.md")"
check "LS5[one-word]: a one-word change (final -> closing) is a mismatch" "mismatch" "$(same_line "$TMPROOT/ls5/one-word.md")"
check "LS5[out-of-section]: the line outside the section does not count" "mismatch" "$(same_line "$TMPROOT/ls5/out-of-section.md")"
case_end

finish
