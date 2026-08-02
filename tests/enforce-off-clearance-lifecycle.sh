#!/usr/bin/env bash
# tests/enforce-off-clearance-lifecycle.sh
# Tests: hooks/supervisor-off-proposal-shim.js, hooks/lib/consume-exact-file.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, bin/request-off-clearance
# Tags: off-clearance, clearance-token, single-use, multi-sentinel, race, toctou, provenance, emergency-off, pretooluse, security, scope:common, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The shim firing as a REAL PreToolUse hook inside a live claude -p session
#   (here it is a node subprocess fed synthetic stdin), i.e. that settings.json
#   really routes Bash/runInTerminal/runCommands to it.
# - A real UserPromptSubmit writing the provenance marker (the marker is built
#   here from the same SSOT builder the real writer uses).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 round-5, lifecycle half)
#
# A clearance is a SINGLE-USE grant: one Phase1 examination authorizes exactly one
# OFF activation, and one user skill invocation vouches for exactly one emergency
# activation. Three separate defects each let one grant cover N activations:
#
#   L-1 (codex HIGH) ONE TOOL CALL, N SENTINELS. The shim validated the FIRST OFF
#       sentinel it found and then let the whole call through — but the activation
#       layer applies EVERY element of a runCommands array and every `&&` part of a
#       Bash command. Two sentinels were therefore validated once, claimed once and
#       activated twice; and because the EMERGENCY form exits early, putting it
#       FIRST smuggled a normal (gated) OFF past Phase1 entirely.
#   L-2 (MEDIUM)     READ-THEN-UNLINK RACES ON THE PATHNAME. Between a consumer's
#       read and its unlink the record can be replaced, so the unlink destroys a
#       LIVE record nobody inspected. Removal is now identity-bound
#       (hooks/lib/consume-exact-file.js).
#   L-3 (MEDIUM)     EMERGENCY PROVENANCE WAS NOT SINGLE-USE. Two handlers could
#       both read the one marker; the first unlinked it and the second read ENOENT
#       as "already consumed — counts as mine", so ONE user invocation attributed
#       TWO activations.
#
# EXCLUSION PRIMITIVE. The obvious fix for L-2/L-3 — rename the record to a private
# name — DOES NOT HOLD ON WINDOWS: measured with 6 concurrent renames of one source,
# all six returned success. Exclusive create (`wx`) is the primitive that does hold
# on both families, so no assertion here may assume rename-based exclusion.
#
# CONCURRENCY, ASSERTED AS AN INVARIANT. The racing sections assert
# "exactly ONE winner, N-1 losers, no record and no claim file left behind" — a
# property that holds under EVERY interleaving, including the degenerate one where
# the racers happen to run serially. Nothing here depends on the processes actually
# overlapping, so there is no flake window; overlapping only makes the test
# stronger, never necessary.
#
# ASSERTION CONTRACT: the shim exits 0 (allow) or exits 2 having printed
# {"decision":"block",...}. Anything else (timeout, crash, empty) is its own
# verdict token and can never score as an allow — see classify().
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
PROBE="$AGENTS_DIR/tests/enforce-off-clearance-lifecycle/probe.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'offlife'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# H0 - harness self-check: without these, every case below proves nothing.
for f in "$SHIM" "$PROBE"; do
    if [ ! -f "$f" ]; then
        fail "H0 required file MISSING: $f - every case below would be vacuous"
        echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
    fi
done
pass "H0 shim + probe present"

# Protected suffixes come from the SSOT, so a renamed suffix fails here loudly
# instead of turning the fixtures into files nothing protects.
SUF=$("$RWT" 10 node "$PROBE" suffixes "$_AGENTS_DIR_NODE" 2>/dev/null)
TOKEN_SUF=$(printf '%s' "$SUF" | awk '{print $1}')
CLAIMED_SUF=$(printf '%s' "$SUF" | awk '{print $2}')
MARKER_SUF=$(printf '%s' "$SUF" | awk '{print $3}')
if [ -z "$TOKEN_SUF" ] || [ -z "$CLAIMED_SUF" ] || [ -z "$MARKER_SUF" ]; then
    fail "H1 protected-suffix SSOT not introspectable via probe.js"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 protected suffixes introspected from hooks/lib/protected-basenames.js"

# --- sentinel text, assembled from fragments --------------------------------
# Never spell a complete sentinel literally: this file's own text is read by hooks
# and by the transcript, and an emittable sentinel in a test fixture is exactly the
# accident the sentinel design is meant to make impossible.
_O="<<"
WF_BOUND="echo \"${_O}WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] next-step bug blocks progress>>\""
WT_BOUND="echo \"${_O}WORKFLOW_ENFORCE_WORKTREE_OFF: [workflow-bug] worktree guard false block>>\""
WF_EMERG="echo \"${_O}WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: examiner itself is broken>>\""
WF_LOOK="echo \"${_O}WORKFLOW_ENFORCE_WORKFLOW_OFF>>\""
WT_LOOK="echo \"${_O}WORKFLOW_ENFORCE_WORKTREE_OFF>>\""

json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
mk_bash_json() { printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"%s"}}' "$1" "$(json_esc "$2")"; }
# mk_runcommands_json <sid> <cmd>...
mk_runcommands_json() {
    local sid="$1"; shift
    local body="" c
    for c in "$@"; do
        [ -n "$body" ] && body="$body,"
        body="$body\"$(json_esc "$c")\""
    done
    printf '{"tool_name":"runCommands","session_id":"%s","tool_input":{"commands":[%s]}}' "$sid" "$body"
}

# run_shim <workflow_dir_node> <run_cwd> <stdin-json> -> "<rc>|<stdout>"
# The CWD is a clean temp dir so resolveWorkflowSessionId()'s WORKTREE_NOTES.md
# read cannot pick up the developer's real session id.
run_shim() {
    local tn="$1" cwd="$2" input="$3" out rc
    out=$(cd "$cwd" && WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 15 node "$SHIM" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# classify "<rc>|<out>" -> allow | block | timeout | crash:<rc> | unrecognized
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        124) printf 'timeout'; return ;;
        0)   [ -z "$out" ] && { printf 'allow'; return; }; printf 'unrecognized'; return ;;
        2)   case "$out" in *'"decision":"block"'*) printf 'block'; return ;; esac
             printf 'unrecognized'; return ;;
        *)   printf 'crash:%s' "$rc"; return ;;
    esac
}
assert_verdict() {
    local label="$1" want="$2" raw="$3" got
    got="$(classify "$raw")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [raw=$(printf '%.200s' "$raw")]"; fi
}

PARTS_DIR="$AGENTS_DIR/tests/enforce-off-clearance-lifecycle"
# shellcheck source=./enforce-off-clearance-lifecycle/cases-multi-sentinel.sh
. "$PARTS_DIR/cases-multi-sentinel.sh"
# shellcheck source=./enforce-off-clearance-lifecycle/cases-single-use.sh
. "$PARTS_DIR/cases-single-use.sh"

run_M_multi_sentinel   # L-1
run_C_consume_contract # L-2 (deterministic contract)
run_C_consume_race     # L-2 (concurrent invariant)
run_P_provenance       # L-3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
