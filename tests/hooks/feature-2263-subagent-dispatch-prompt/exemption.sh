#!/usr/bin/env bash
# Tests: hooks/subagent-dispatch-prompt.js
# Tags: TL2, hooks, subagent-dispatch, exemption, negative-control, scope:issue-specific, pwsh-not-required
# C1: a named agent whose tools: line lists none of Bash/Write/Edit is left alone; everything
# else (built-ins, unknown names, missing tools: line, path-shaped names) gets the append.

# TL3 gap (what this test does NOT catch): whether the host resolves a project-level
# .claude/agents definition ahead of agents/<type>.md; the hook only reads its own checkout.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

FX_AGENTS="$TMPROOT/fx/agents"
mkdir -p "$FX_AGENTS/a"
fx_agent() { # <file> <tools-line or empty>
  { printf -- '---\nname: fixture\ndescription: fixture agent\n'
    [ -n "$2" ] && printf 'tools: %s\n' "$2"
    printf -- '---\n\nFixture body.\n'; } > "$1"
}
fx_agent "$FX_AGENTS/fx-read-glob.md" "Read, Glob"
fx_agent "$FX_AGENTS/fx-read-bash.md" "Read, Bash"
fx_agent "$FX_AGENTS/fx-read-write.md" "Read, Write"
fx_agent "$FX_AGENTS/fx-read-edit.md" "Read, Edit"
fx_agent "$FX_AGENTS/fx-no-tools.md" ""
fx_agent "$FX_AGENTS/fx-bracket-bash.md" "[Read, Bash]"
fx_agent "$FX_AGENTS/fx-bracket-read.md" "[Read, Glob]"
# E4 decoys: read-only definitions reachable ONLY if the hook builds a path from a bad name.
fx_agent "$FX_AGENTS/a/b.md" "Read"
export SDP_FX_AGENTS
SDP_FX_AGENTS="$(np "$FX_AGENTS")"
FX_OPTS='({agentsDir: env.SDP_FX_AGENTS})'

typed_in() { printf '({tool_name: "Agent", tool_input: {subagent_type: "%s", description: "d", prompt: "Do the task."}})' "$1"; }

case_begin "E1-real-readonly-agents-exempt" "hooks/subagent-dispatch-prompt.js"
for t in complexity-judge refactor-prompts-judge; do
  check "E1[$t]: the real read-only agent is a passthrough ({})" "{}" "$(sdp_probe "$PASSTHROUGH" "$(typed_in "$t")")"
done
case_end

case_begin "E2-fixture-tools-line" "hooks/subagent-dispatch-prompt.js"
check "E2[Read, Glob]: a fixture agent without Bash/Write/Edit is a passthrough ({})" \
  "{}" "$(sdp_probe "$PASSTHROUGH" "$(typed_in fx-read-glob)" "$FX_OPTS")"
for t in fx-read-bash fx-read-write fx-read-edit fx-no-tools; do
  check "E2[$t]: the fixture agent gets exactly one canonical line appended" \
    "true" "$(sdp_probe "$APPENDED_ONCE" "$(typed_in "$t")" "$FX_OPTS")"
done
check "E2[bracketed Read, Glob]: a bracketed read-only tools list is still a passthrough ({})" \
  "{}" "$(sdp_probe "$PASSTHROUGH" "$(typed_in fx-bracket-read)" "$FX_OPTS")"
check "E2[bracketed Read, Bash]: a bracketed list carrying Bash gets the append" \
  "true" "$(sdp_probe "$APPENDED_ONCE" "$(typed_in fx-bracket-bash)" "$FX_OPTS")"
case_end

case_begin "E3-no-definition-file" "hooks/subagent-dispatch-prompt.js"
for t in general-purpose Explore Plan fixture-unknown; do
  check "E3[$t]: a name with no definition file gets the append" \
    "true" "$(sdp_probe "$APPENDED_ONCE" "$(typed_in "$t")" "$FX_OPTS")"
done
case_end

case_begin "E4-path-shaped-name" "hooks/subagent-dispatch-prompt.js"
check "E4[../agents/fx-read-glob]: a traversal-shaped name appends even though the resolved file is read-only" \
  "true" "$(sdp_probe "$APPENDED_ONCE" "$(typed_in ../agents/fx-read-glob)" "$FX_OPTS")"
check "E4[a/b]: a slash-bearing name appends even though a/b.md is read-only" \
  "true" "$(sdp_probe "$APPENDED_ONCE" "$(typed_in a/b)" "$FX_OPTS")"
check "E4[../agents/complexity-judge]: the real tree is not reached through a traversal name either" \
  "true" "$(sdp_probe "$APPENDED_ONCE" "$(typed_in ../agents/complexity-judge)")"
case_end

case_begin "E5-real-bash-agents-not-exempt" "hooks/subagent-dispatch-prompt.js"
for t in web-researcher security-scanner issue-create-survey-worker; do
  check "E5[$t]: the real Bash-carrying agent gets the append" \
    "true" "$(sdp_probe "$APPENDED_ONCE" "$(typed_in "$t")")"
done
case_end

finish
