#!/usr/bin/env bash
# tests/skills/feature-2263-subagent-dispatch-prompts.sh
# Tests: agents/web-researcher.md, agents/security-scanner.md, agents/issue-create-survey-worker.md, rules/shell-commands.md, skills/write-code/SKILL.md, skills/write-tests/SKILL.md
# Tags: TL2, skills, agents, rules, prompt, dispatch, subagent, inventory, scope:issue-specific, pwsh-not-required
# #2263: every Agent-tool dispatch site points at the Subagent Dispatch Prompts section of
# rules/shell-commands.md (inventory), no dispatch site escapes the tables (detection), and
# fixed-output-contract / JSON-input agents are classified against the canonical line.

# TL3 gap (what this test does NOT catch): whether a dispatching model actually copies the
# canonical line into its prompt; only the SKILL text is read. The hook in
# tests/hooks/feature-2263-subagent-dispatch-prompt.sh backs up an omitted line at runtime.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
unset CLAUDE_CODE_SESSION_ID

ck() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

# --- Shared predicates; every part and its negative controls call these with a <root>. ---
SECTION_NAME='Subagent Dispatch Prompts'
JSON_KEY='dispatch_directive'
WRITE_TOOLS_ERE='\b(Bash|Write|Edit)\b'

# inv_verdict <root> <file> <anchor-ere> <lo> <hi> <form>
#   -> yes | file-missing | anchor-missing | no-ref | no-json-key
# A reference line names the section within [anchor+lo, anchor+hi]; form json also needs the key.
inv_verdict() {
  local f="$1/$2" n s e lines
  [ -f "$f" ] || { printf 'file-missing'; return; }
  n="$(grep -n -m1 -E -- "$3" "$f" | cut -d: -f1)"
  [ -n "$n" ] || { printf 'anchor-missing'; return; }
  s=$((n + $4)); [ "$s" -ge 1 ] || s=1
  e=$((n + $5))
  lines="$(sed -n "${s},${e}p" "$f" | grep -F -- "$SECTION_NAME")"
  [ -n "$lines" ] || { printf 'no-ref'; return; }
  if [ "$6" = "json" ]; then
    printf '%s\n' "$lines" | grep -qF -- "$JSON_KEY" || { printf 'no-json-key'; return; }
  fi
  printf 'yes'
}

# agent_tools_line <agent-md> -> the frontmatter tools: value (empty when none)
agent_tools_line() { [ -f "$1" ] && sed -n '1,/^---$/{/^tools:/p}' "$1" | head -n1 | sed 's/^tools:[[:space:]]*//'; }
# agent_exempt <agent-md> -> yes|no : a tools: line exists and names none of Bash/Write/Edit
agent_exempt() {
  local t
  t="$(agent_tools_line "$1")"
  [ -n "$t" ] || { printf 'no'; return; }
  printf '%s' "$t" | grep -qE -- "$WRITE_TOOLS_ERE" && printf 'no' || printf 'yes'
}

# rule_has_unless <rules-md> -> yes|no : the section's canonical line carries the
# output-contract unless clause (same token as S3 in the feature-2140 dispatch-prompts part).
rule_has_unless() {
  [ -f "$1" ] || { printf 'no'; return; }
  awk '/^## Subagent Dispatch Prompts[[:space:]]*$/ { on = 1; next } on && /^## / { exit } on { print }' "$1" \
    | grep -E -- '^[[:space:]]*([>-][[:space:]]*)?Read `<AGENTS_MAIN_ROOT>/rules/shell-commands\.md`' \
    | grep -qE -- 'unless .*output contract.*exact shape' && printf 'yes' || printf 'no'
}

ROWS=0
ROWS_EXPECTED=52  # inventory 21 + detection coverage 21 + contract-precedence CP2 10 (#2460).

PART_DIR="$SCRIPT_CHECKOUT_ROOT/tests/skills/feature-2263-subagent-dispatch-prompts"
. "$PART_DIR/inventory.sh"
. "$PART_DIR/detection.sh"
. "$PART_DIR/contract-precedence.sh"
. "$PART_DIR/negative-controls.sh"

case_begin "budget-rows-executed" "rules/shell-commands.md"
ck "budget: every table row in the four parts executed (a short count means an empty or unreachable table)" \
  "$ROWS_EXPECTED" "$ROWS"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
