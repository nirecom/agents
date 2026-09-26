#!/usr/bin/env bash
# tests/feature-2134-bash-guard.sh
# Tests: hooks/bash-guard.js, hooks/bash-guard/judge.js, hooks/bash-guard/detect.js, hooks/bash-guard/allow.js, hooks/bash-guard/forbidden-literals.js, hooks/bash-guard/reasons.js, hooks/bash-guard/message.js, hooks/lib/allow-command-list.js, hooks/lib/sentinel-patterns.js, hooks/lib/early-write-gate.js, hooks/workflow-gate/early-gate.js, settings.json, bin/print-forbidden-literals, rules/shell-commands.md
# Tags: hook, bash-guard, pretooluse, classifier, guard, forbidden-literals, interlock, fail-open, notify, self-script-allow, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# THE INCIDENT (#2134). The issuance discipline in rules/shell-commands.md is layer L1 --
# it holds only while the model remembers it, and deviation recurred within and across
# sessions. #2132's Revision retired the L3 lint (a prompt string cannot be classified as
# "issue this" vs "quote this" by regex). Only L4 stops a compound command physically.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PART_DIR="$AGENTS_DIR/tests/hooks/feature-2134-bash-guard"
PROBE_JS="$PART_DIR/judge-probe.js"

# THE CONTRACT UNDER TEST. bash-guard is a PRESENTATION guard, not a safety guard.
# judgeBashCommand(input) returns one of four verdicts, deny > notify > allow > passThrough:
# tool_name must be exactly "Bash" -> the early-write-gate interlock silences it -> parseFailure
# fails OPEN -> detect() decides deny -> detectIneffective() decides notify -> matchSelfScript()
# decides allow -> otherwise passThrough. Every fail-open lands on passThrough, NEVER allow.
# Detection reads only the IR and analysisOf(ir); settings.json allow rules are not consulted.

# OUT OF SCOPE: runInTerminal / runCommands (pwsh dialect, only pinned as out of scope),
# `||` and background `&` (absent from the approved forbidden set), the L1 doc-sync check
# (S5) and the L2 prompt-issuance inventory (S6) -- both have their own suites.

PASS=0
FAIL=0
SKIP=0
ROWS=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# case_begin <name> <target> / case_end: static catalog markers (bin/check-case-markers.sh).
# Local shims instead of tests/lib/harness.sh, whose assert_eq has a different signature.
case_begin() { echo "--- case: $1 ($2) ---"; }
case_end() { :; }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "PASS: $name"; PASS=$((PASS + 1)) ;;
        *) echo "FAIL: $name -- [$hay] does not contain [$needle]"; FAIL=$((FAIL + 1)) ;;
    esac
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "FAIL: $name -- [$hay] must NOT contain [$needle]"; FAIL=$((FAIL + 1)) ;;
        *) echo "PASS: $name"; PASS=$((PASS + 1)) ;;
    esac
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/bg-2134.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): plans dir pinned in the same breath as
# the workflow dir, inherited session ids dropped, and HOME/USERPROFILE pointed at a fixture
# home, so no row can depend on the developer's real ~/.claude (the guard no longer reads its
# permissions.allow, and the empty list keeps that true even if a regression re-adds the read).
CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow"
WORKFLOW_PLANS_DIR="$TMPROOT/plans"
FIXTURE_HOME="$TMPROOT/home"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$FIXTURE_HOME/.claude"
printf '%s\n' '{"permissions":{"allow":[],"deny":[]}}' > "$FIXTURE_HOME/.claude/settings.json"
export CLAUDE_WORKFLOW_DIR WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# The default session must look SETTLED, or the early-write-gate interlock would silence the
# guard for every row in every file and the whole suite would report allow. Sessions that need
# a live gate write their own state in cases-interlock.sh.
BG_STEPS="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate"
bg_settled_state() {
    local sid="$1" step steps=""
    for step in $BG_STEPS; do
        steps="$steps,\"$step\":{\"status\":\"complete\",\"updated_at\":null}"
    done
    printf '{"version":1,"session_id":"%s","created_at":"2026-01-01T00:00:00.000Z","is_bugfix":false,"git_branch":"feature/2134-bash-guard-pretooluse","steps":{%s},"workflow_type":"wf-code"}' \
        "$sid" "${steps#,}" > "$CLAUDE_WORKFLOW_DIR/$sid.json"
}
bg_settled_state "sid-bg-armed"

CMDFILE="$TMPROOT/cmd.txt"
WIN_PROBE="$(node_path "$PROBE_JS")"

# probe <mode> <command-text> [sessionId] [toolName] [settingsPath]
# The command text goes through a file so the shell cannot rewrite the literals under test.
# PROBE_HOME swaps in another fixture home for a single call without leaking it to other rows.
probe() {
    local mode="$1" cmd="$2" sid="${3:-}" tool="${4:-}" spath="${5:-}"
    printf '%s' "$cmd" > "$CMDFILE"
    HOME="${PROBE_HOME:-$FIXTURE_HOME}" USERPROFILE="${PROBE_HOME:-$FIXTURE_HOME}" \
        run_with_timeout 30 node "$WIN_PROBE" "$mode" "$(node_path "$CMDFILE")" "$sid" "$tool" "$spath" 2>/dev/null
}

# verdict_of <command-text> [sessionId] [toolName] -> allow | deny | <MISSING:...> | <THREW:...>
verdict_of() {
    local line
    line="$(probe judge "$1" "${2:-}" "${3:-}")"
    case "$line" in
        "<"*) printf '%s' "$line" ;;
        *) printf '%s' "${line%%$'\t'*}" ;;
    esac
}

# verdict_code_of <command-text> [sessionId] [toolName] -> "<verdict>|<code>" (e.g.
# notify|BG-NOTIFY-SENTINEL-NO-ECHO); a <MISSING:...>/<THREW:...> line is returned verbatim.
verdict_code_of() {
    local line rest
    line="$(probe judge "$1" "${2:-}" "${3:-}")"
    case "$line" in
        "<"*) printf '%s' "$line" ;;
        *) rest="${line#*$'\t'}"; printf '%s|%s' "${line%%$'\t'*}" "${rest%%$'\t'*}" ;;
    esac
}

# mkcmd <table-field> -> command text: surrounding padding stripped, a literal two-character
# `\n` turned into a real newline. Tables are `~`-separated so a `|` case survives intact.
mkcmd() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s//\\n/$'\n'}"
}

# EXECUTED-ROW BUDGET. Every table-driven loop increments ROWS and the final case asserts the
# exact total. Without it a drifted heredoc delimiter or an early return in front of a loop
# leaves a file that counts only its failures reporting green. Breakdown: detect 14 +
# allow-direction 13 + hit-scope 5 + xargs-pipe 5 + negative 10 + not-forbidden 3 +
# forbidden-literals-doc-sync 4 + tool-scope 2 + fail-open 3 + interlock 7 + notify-sentinel 19 +
# notify-interpreter 15 + allow-self-script 42 + precedence 8 + message 27 + runtime 19.
ROWS_EXPECTED=196

# TL3 gap (what this test does NOT catch):
# - Whether Claude Code actually INVOKES hooks/bash-guard.js on a real Bash tool call. The
#   registration is asserted structurally and the hook is driven as a real subprocess in
#   cases-runtime-pretooluse.sh, but matcher dispatch is the host's behaviour.
# - Whether the host honours the allow envelope (skips the prompt) and delivers the notify
#   systemMessage/additionalContext -- probed by tests/hooks/TL3-hook-bash-guard-envelope.sh.
# - Whether the 5s hook timeout in settings.json survives a cold Node start.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

. "$PART_DIR/cases-detect.sh"
. "$PART_DIR/cases-allow-direction.sh"
. "$PART_DIR/cases-hit-scope.sh"
. "$PART_DIR/cases-xargs-pipe.sh"
. "$PART_DIR/cases-negative.sh"
. "$PART_DIR/cases-not-forbidden.sh"
. "$PART_DIR/forbidden-literals-doc-sync.sh"
. "$PART_DIR/cases-tool-scope.sh"
. "$PART_DIR/cases-fail-open.sh"
. "$PART_DIR/cases-interlock.sh"
. "$PART_DIR/cases-notify-sentinel.sh"
. "$PART_DIR/cases-notify-interpreter.sh"
. "$PART_DIR/cases-allow-self-script.sh"
. "$PART_DIR/cases-precedence.sh"
. "$PART_DIR/cases-message.sh"
. "$PART_DIR/cases-runtime-pretooluse.sh"

assert_eq "BUDGET: every table-driven loop executed its full row count (a short count means an empty or unreachable table reported green)" \
    "$ROWS_EXPECTED" "$ROWS"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
