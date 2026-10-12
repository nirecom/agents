#!/usr/bin/env bash
# Tests: hooks/gate-plan-skill-advance.js, settings.json
# Tags: hook-registration, skill-gate, pretooluse, plan-approval, live-host-dispatch, TL3, run-e2e, scope:common, pwsh-not-required, dup-group-keep:distinct-layer
# Real-host seam for the PreToolUse Skill gate: a denied skill's body never runs (canary absent).
# The TL2 sibling feature-2277-plan-approval-gate.sh feeds composed payloads only.
#
# TL3 gap (what this test does NOT catch):
# - A user-level skill of the same name shadowing the project probe skill on a host that
#   loads user skills despite --setting-sources project (the approved control then fails).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# Dual-pin per rules/test/fixture-isolation.md, before any hook or bin call.
BASE="$(make_tmp)"; readonly BASE
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/workflow-state" "$BASE/plans" "$BASE/no-transcripts"
export WORKFLOW_STATE_DIR="$BASE/workflow-state" WORKFLOW_PLANS_DIR="$BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$BASE/no-transcripts"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || { echo "SKIP: bin/get-config-var not executable" >&2; exit 77; }
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && { echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77; }
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not found" >&2; exit 77; }

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
HELPER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-gate-plan-skill-advance/tl3-helper.js"
ENTRY_DRV="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2170-capture-echo-guard/real-hook-entry.js"
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"

REPO="$BASE/repo"; MOCKBIN="$BASE/bin"; MARKS="$BASE/marks"
mkdir -p "$REPO/.claude/skills/make-outline-plan" "$MOCKBIN" "$MARKS"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# SAFETY: shadow `gh` so the session cannot reach any remote.
printf '#!/usr/bin/env bash\necho "gh is disabled in this TL3 fixture" >&2\nexit 1\n' > "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

# Inert probe skill under the gated name; its body's only effect is the canary file.
MARKS_M="$(np "$MARKS")"
cat > "$REPO/.claude/skills/make-outline-plan/SKILL.md" <<EOF
---
name: make-outline-plan
description: Inert TL3 probe standing in for the gated outline skill.
user-invocable: true
---

Use the Write tool to create the file $MARKS_M/skill-body-ran with the content ok. Then stop.
EOF

# The REAL PreToolUse registration lifted out of the deployable settings.json — a
# hand-written matcher would test this file's author, not the artifact that ships.
node "$ENTRY_DRV" --emit "gate-plan-skill-advance.js" > "$REPO/.claude/settings.json"
if grep -q 'NOT_REGISTERED\|SETTINGS_UNREADABLE\|BAD_MODE' "$REPO/.claude/settings.json"; then
    echo "FAIL: gate-plan-skill-advance.js is not registered in the real settings.json (awaiting implementation)" >&2
    exit 1
fi

T_DENY="cccccccc-2277-4000-8000-000000000001"
T_ALLOW="cccccccc-2277-4000-8000-000000000002"
for pair in "$T_DENY:unapproved" "$T_ALLOW:approved"; do
    got="$( (cd "$BASE" && run_with_timeout 30 node "$HELPER" seed "${pair%%:*}" "${pair##*:}") 2>&1)"
    if [ "$got" != "SEEDED" ]; then echo "FAIL: fixture seed $pair — $got" >&2; exit 1; fi
done

unset CLAUDECODE

declare -A TURN_RC=()
# run_turn <session-uuid> — the CLI's exit code is kept: a timeout must not look like a deny.
run_turn() {
    local rc=0
    rm -f "$MARKS/skill-body-ran"
    ( cd "$REPO" && PATH="$MOCKBIN:$PATH" run_with_timeout 180 claude -p \
        "Invoke the make-outline-plan skill with the Skill tool and follow it. If the Skill call is refused, report the refusal verbatim, do not retry, do not use any other tool, and stop." \
        --session-id "$1" --setting-sources project --dangerously-skip-permissions \
        --output-format json >"$BASE/$1.out" 2>&1 ) || rc=$?
    TURN_RC["$1"]=$rc
    if [ -f "$MARKS/skill-body-ran" ]; then touch "$MARKS/$1.ran"; fi
}
# probe <session-uuid> — Skill tool_use / tool_result facts from the CLI output and transcript.
probe() {
    local root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" f ev
    ev=("$(np "$BASE/$1.out")")
    if [ -d "$root" ]; then
        while IFS= read -r f; do [ -n "$f" ] && ev+=("$(np "$f")"); done < <(find "$root" -maxdepth 2 -type f -name "$1.jsonl" 2>/dev/null)
    fi
    run_with_timeout 30 node "$HELPER" probe make-outline-plan CONFIRM_INTENT "${ev[@]}" 2>/dev/null
}

echo "=== A: prior stage (clarify_intent) unapproved — the Skill call is denied ==="
run_turn "$T_DENY"
echo "=== B: positive control — prior stage approved — the Skill proceeds ==="
run_turn "$T_ALLOW"
A="$(probe "$T_DENY")"; B="$(probe "$T_ALLOW")"

case_begin "live-turns-completed" "settings.json"
for t in "$T_DENY" "$T_ALLOW"; do
    if [ "${TURN_RC[$t]}" -eq 0 ]; then pass "turn-$t-cli-exited-zero"
    else fail "turn-$t-cli-exited-zero" "claude -p exited ${TURN_RC[$t]} (124 = the 180s timeout fired)"; fi
done
got="$(field "$A" attempted)"
if [ "$got" = "true" ]; then pass "unapproved-turn-attempted-the-skill"
else fail "unapproved-turn-attempted-the-skill" "no Skill(make-outline-plan) tool_use (attempted=$got) — the absent canary proves nothing"; fi
case_end

case_begin "live-skill-denied-when-prior-unapproved" "hooks/gate-plan-skill-advance.js"
if [ -f "$MARKS/$T_DENY.ran" ]; then
    fail "unapproved-skill-body-never-ran" "the gated skill body executed although clarify_intent was unapproved"
else
    pass "unapproved-skill-body-never-ran"
fi
got="$(field "$A" result_error)"
if [ "$got" = "true" ]; then pass "unapproved-skill-result-is-an-error"
else fail "unapproved-skill-result-is-an-error" "result_error=$got — a denied Skill call must come back as an error result"; fi
got="$(field "$A" marker)"
if [ "$got" = "true" ]; then pass "unapproved-denial-is-the-skill-gates"
else fail "unapproved-denial-is-the-skill-gates" "the error result does not name CONFIRM_INTENT (marker=$got) — refused for an unrelated reason"; fi
case_end

case_begin "live-skill-proceeds-when-prior-approved" "hooks/gate-plan-skill-advance.js"
# Positive control: without it an absent canary only proves nothing ran at all.
if [ -f "$MARKS/$T_ALLOW.ran" ]; then pass "approved-skill-body-did-run"
else fail "approved-skill-body-did-run" "the approved turn left no canary — the gate over-blocks, or the probe skill never loaded"; fi
got="$(field "$B" marker)"
if [ "$got" != "true" ]; then pass "approved-turn-not-refused-by-the-gate"
else fail "approved-turn-not-refused-by-the-gate" "marker=$got — the approved prior stage was still denied"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
