#!/usr/bin/env bash
# Tests: settings.json
# Tags: TL2, hooks, subagent-dispatch, settings-registration, static, scope:issue-specific, pwsh-not-required
# The hook only runs if settings.json registers it, in its OWN Agent|Task PreToolUse group,
# separate from the jev-shadow-pre group, so the two budgets and failure modes stay independent.

# TL3 gap (what this test does NOT catch): that the host actually fires the group for a real
# Agent dispatch; TL3-hook-subagent-dispatch-prompt.sh P1/P4 observes that.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SETTINGS="$REPO_N/settings.json"
# groups <event> <needle>: "matcher|command|timeout|group-size" per hook whose command contains <needle>.
groups() {
  run_with_timeout 30 node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const out = [];
    for (const g of (s.hooks && s.hooks[process.argv[2]]) || []) {
      for (const h of g.hooks || []) {
        if (String(h.command).includes(process.argv[3])) out.push([g.matcher, h.command, h.timeout, g.hooks.length].join("|"));
      }
    }
    process.stdout.write(out.join("\n"));
  ' "$SETTINGS" "$1" "$2" 2>/dev/null
}

case_begin "R-settings-pre-group" "settings.json"
# shellcheck disable=SC2016  # literal $AGENTS_MAIN_ROOT is the registered text.
check "PreToolUse: exactly one dedicated Agent|Task group for subagent-dispatch-prompt.js, timeout 10" \
  'Agent|Task|node "$AGENTS_MAIN_ROOT/hooks/subagent-dispatch-prompt.js"|10|1' "$(groups PreToolUse subagent-dispatch-prompt.js)"
case_end

case_begin "R-not-elsewhere" "settings.json"
for ev in PostToolUse UserPromptSubmit SessionStart SubagentStart Stop; do
  check "the hook is not registered under $ev" "" "$(groups "$ev" subagent-dispatch-prompt.js)"
done
case_end

case_begin "R-jev-group-separate" "settings.json"
# shellcheck disable=SC2016
check "the jev-shadow-pre group is unchanged and still alone in its group (regression)" \
  'Agent|Task|node "$AGENTS_MAIN_ROOT/hooks/jev-shadow-pre.js"|15|1' "$(groups PreToolUse jev-shadow-pre.js)"
case_end

case_begin "R-registered-hook-exists" "settings.json"
check "the registered hook script exists in this checkout" "present" \
  "$([ -f "$HOOK_JS" ] && echo present || echo absent)"
case_end

finish
