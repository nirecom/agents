#!/usr/bin/env bash
# tests/fix-2108-subagent-artifact-write-path.sh
# Tests: hooks/workflow-gate/early-gate.js, hooks/workflow-gate/early-gate-allowlist.js, hooks/workflow-gate/early-gate-messages.js, hooks/lib/active-session-ids.js, hooks/workflow-state/session-id.js, hooks/lib/protected-basenames.js, hooks/lib/basename-glob-normalize.js, hooks/lib/claude-scratchpad-base.js, hooks/lib/subagent-detect.js, hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/block-clearance-token-write/bash-scan/scan.js, hooks/block-clearance-token-write/bash-scan/argv-scan.js, hooks/block-clearance-token-write/bash-target-context/classify.js, hooks/enforce-worktree.js, hooks/enforce-worktree/handle-bash-write.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/enforce-worktree/bash-write-scope/segment-checks.js, hooks/enforce-worktree/git-repo-detection.js
# Tags: workflow-gate, early-gate, scratchpad, plans-dir, subagent, protected-basename, block-message, symlink, fault-injection, security, scope:issue-specific, pwsh-not-required, TL2
set -u

# TL3 gap (what this test does NOT catch):
# - The gate and the two write guards firing as REAL PreToolUse hooks in a live
#   claude -p session: settings.json matcher routing is asserted STATICALLY only
#   (Section C2). Covered live by tests/TL3-hook-early-gate-allowlist-write.sh.
# - A real subagent payload: `agent_id` is synthesized, so "a subagent receives this
#   message and can write to the named scratchpad" is a premise, not an observation.
# - Real permission failures in the workflow dir (C1c-ii): that readdir fault is only
#   injectable where chmod bites, and is skipped elsewhere.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# WHAT THIS FILE DEFENDS (#2108) — two defects leave a subagent with no legal exit:
# (1) early-gate.js Tier 1/2 block every Write/Edit/MultiEdit except into PLANS_DIR,
#     and offer only routes a subagent cannot take (skill call, sentinel). Sections A+B.
# (2) protected-basenames.js classifies on the basename SUFFIX alone — the stem is
#     never examined — so artifact names ending in a protected kind
#     (`issue-2108-survey.gh-env`) read as forged clearance state. PR #2089 widened
#     PROTECTED_STATE_KINDS to 9 kinds, widening that surface. Sections C1..C4.
# (2) is a SECURITY boundary change, so every false-positive case is paired with the
# true-positive it must not weaken (CPR-ORTH), plus C1c fail-closed and C1d cross-session.
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# TEST-FIRST: authored before early-gate-allowlist.js, early-gate-messages.js and
# hooks/lib/active-session-ids.js exist. Until /write-code lands them the expected
# failure signature is "module not found" for those three, plus stem-rule assertion
# failures in C1/C1b (the classifier still ignores its new `opts`). Do not route around it.
# MUTATION PROBE (post-implementation, part of /write-code verification): once
# protected-basenames.js gains SID_UUID_BODY / SID_TS_BODY / SID_CANONICAL_EXACT_RE /
# SID_CANONICAL_TAIL_RE, run `bin/mutation-probe.sh hooks/lib/protected-basenames.js`.
# It cannot run now — the constants do not exist, so the probe has nothing to mutate.
AGENTS_NODE="$(node_path "$AGENTS_DIR")"

# Hook paths are NATIVE (AGENTS_NODE), not msys-style: every invocation below sets
# MSYS_NO_PATHCONV=1, which suppresses the /c/... -> C:/... rewrite, and node would
# otherwise resolve /c/git/... against the current drive and read nothing on stdin.
GATE_HOOK="$AGENTS_NODE/hooks/workflow-gate.js"
EW_HOOK="$AGENTS_NODE/hooks/enforce-worktree.js"
BCTW_HOOK="$AGENTS_NODE/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PB_NODE="$AGENTS_NODE/hooks/lib/protected-basenames.js"
MARKER_GATE_NODE="$AGENTS_NODE/hooks/enforce-worktree/bash-write-scope/marker-gate.js"
ALLOWLIST_NODE="$AGENTS_NODE/hooks/workflow-gate/early-gate-allowlist.js"
MESSAGES_NODE="$AGENTS_NODE/hooks/workflow-gate/early-gate-messages.js"
ACTIVE_SIDS_NODE="$AGENTS_NODE/hooks/lib/active-session-ids.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name - missing $(printf '%q' "$needle") in $(printf '%.240s' "$hay")" ;;
    esac
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) fail "$name - unexpectedly found $(printf '%q' "$needle")" ;;
        *) pass "$name" ;;
    esac
}
assert_ge() {
    local name="$1" want_min="$2" got="$3"
    case "$got" in
        ''|*[!0-9]*) fail "$name - got non-numeric $(printf '%q' "$got")" ;;
        *) if [ "$got" -ge "$want_min" ]; then pass "$name"
           else fail "$name - want>=$want_min got=$got"; fi ;;
    esac
}

# Fixture isolation (rules/test/fixture-isolation.md): session-id env is UNSET at file
# scope and re-set explicitly per case — every section branches on the effective sid,
# so an ambient value would silently flip the verdict under test.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE SCRATCHPAD 2>/dev/null || true

TMPBASE="$(node -e "var o=require('os'),p=require('path'),f=require('fs');var d=p.join(o.tmpdir(),'test-2108-'+process.pid);f.mkdirSync(d,{recursive:true});process.stdout.write(d);" 2>/dev/null)"
[ -z "$TMPBASE" ] && { echo "FAIL: could not create temp base"; exit 1; }
TMPBASE_SH="$TMPBASE"
command -v cygpath >/dev/null 2>&1 && TMPBASE_SH="$(cygpath -u "$TMPBASE" 2>/dev/null || printf '%s' "$TMPBASE")"

WFDIR_SH="$TMPBASE_SH/workflow-state"; mkdir -p "$WFDIR_SH"
PLANS_SH="$TMPBASE_SH/plans"; mkdir -p "$PLANS_SH"
WFDIR="$(node_path "$WFDIR_SH")"
PLANS="$(node_path "$PLANS_SH")"

# Dual-pin: CLAUDE_WORKFLOW_DIR without WORKFLOW_PLANS_DIR leaks supervisor writes
# into the developer's real ~/.workflow-plans (rules/test/fixture-isolation.md).
export CLAUDE_WORKFLOW_DIR="$WFDIR"
export WORKFLOW_PLANS_DIR="$PLANS"

NEUTRAL_CWD="$TMPBASE_SH/neutral"; mkdir -p "$NEUTRAL_CWD"

FIX_REPO="$TMPBASE_SH/repo"; mkdir -p "$FIX_REPO"
REPO_OK=no
if command -v git >/dev/null 2>&1; then
    git -C "$FIX_REPO" init -q -b main >/dev/null 2>&1
    git -C "$FIX_REPO" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$FIX_REPO" config user.email test@example.com >/dev/null 2>&1
    git -C "$FIX_REPO" config user.name Test >/dev/null 2>&1
    echo init > "$FIX_REPO/README.md"
    git -C "$FIX_REPO" add README.md >/dev/null 2>&1
    git -C "$FIX_REPO" -c commit.gpgsign=false commit -q --no-verify -m init >/dev/null 2>&1
    [ -d "$FIX_REPO/.git" ] && REPO_OK=yes
fi
FIX_REPO_NODE="$(node_path "$FIX_REPO")"

# Pseudo session scratchpads: <os-tmpdir>/claude/<slug>/<sid>/scratchpad
# (same shape as tests/fix-1441-new-item-scratchpad-allow.sh:50-60).
mk_scratch() {
    node -e "var o=require('os'),p=require('path'),f=require('fs');var d=p.join(o.tmpdir(),'claude','c--test-2108',process.argv[1],'scratchpad');f.mkdirSync(d,{recursive:true});process.stdout.write(d);" "$1" 2>/dev/null
}
SCRATCH_A="$(mk_scratch sessA)"
SCRATCH_B="$(mk_scratch sessB)"
SCRATCH_C="$(mk_scratch sessC)"
CLAUDE_BASE="$(node -e "var o=require('os'),p=require('path');process.stdout.write(p.join(o.tmpdir(),'claude'));" 2>/dev/null)"
SCRATCH_A_FWD="${SCRATCH_A//\\//}"
SCRATCH_B_FWD="${SCRATCH_B//\\//}"
SCRATCH_C_FWD="${SCRATCH_C//\\//}"
CLAUDE_BASE_FWD="${CLAUDE_BASE//\\//}"
PLANS_FWD="${PLANS//\\//}"
REPO_FWD="${FIX_REPO_NODE//\\//}"
CLAUDE_SLUG_DIR="$(dirname "$(dirname "$SCRATCH_A")")"

cleanup() {
    rm -rf "$TMPBASE_SH" 2>/dev/null || true
    [ -n "${CLAUDE_SLUG_DIR:-}" ] && rm -rf "$CLAUDE_SLUG_DIR" 2>/dev/null || true
    return 0
}
trap cleanup EXIT

NOW_ISO="$(node -e "process.stdout.write(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"

# tier1 fixture: workflow_init pending. tier2 fixture: workflow_init complete +
# clarify_intent pending. Both must produce IDENTICAL verdicts in Section A (CPR-ORTH).
write_state() {
    local sid="$1" wi="$2" ci="$3"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"workflow_init":{"status":"%s","updated_at":"%s"},"clarify_intent":{"status":"%s","updated_at":null},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO" "$wi" "$NOW_ISO" "$ci" > "$WFDIR_SH/${sid}.json"
}
SID_T1="sid2108t1"
SID_T2="sid2108t2"
write_state "$SID_T1" pending pending
write_state "$SID_T2" complete pending

json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# mk_edit_input <tool> <sid> <path> [agent_id]
mk_edit_input() {
    local tool="$1" sid="$2" fp="$3" agent="${4:-}" agentfld=""
    [ -n "$agent" ] && agentfld="$(printf ',"agent_id":"%s"' "$agent")"
    if [ "$tool" = "MultiEdit" ]; then
        printf '{"session_id":"%s"%s,"tool_name":"MultiEdit","tool_input":{"file_path":"%s","edits":[{"old_string":"a","new_string":"b"}]}}' \
            "$sid" "$agentfld" "$(json_esc "$fp")"
    else
        printf '{"session_id":"%s"%s,"tool_name":"%s","tool_input":{"file_path":"%s","content":"x"}}' \
            "$sid" "$agentfld" "$tool" "$(json_esc "$fp")"
    fi
}

# EXIT-STATUS CAPTURE (review C1). Empty stdout is the protocol's fall-through ALLOW,
# and a crashed/timed-out subprocess also prints nothing — so discarding the exit status
# turns every crash into a silent "approve". Every hook here exits 0 for approve AND for
# block (asserted by H0-rc below), so a non-zero status is never a verdict; carry it out
# of the subshell as a token rather than letting it collapse into the empty-stdout allow.
# run_hook_capture <stdin-json> <cmd> [args...] -> stdout (+ <<HOOK_EXIT_n>> on failure)
run_hook_capture() {
    local input="$1"; shift
    local out rc
    out="$(printf '%s' "$input" | MSYS_NO_PATHCONV=1 "$@" 2>/dev/null)"
    rc=$?
    printf '%s' "$out"
    [ "$rc" -ne 0 ] && printf '<<HOOK_EXIT_%s>>' "$rc"
    return 0
}

# run_gate <stdin-json> [SCRATCHPAD value, or "-" to unset] -> raw stdout
run_gate() {
    local input="$1" sp="${2:--}"
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        if [ "$sp" = "-" ]; then unset SCRATCHPAD; else export SCRATCHPAD="$sp"; fi
        run_hook_capture "$input" "$RWT" 20 node "$GATE_HOOK"
    )
}

# gate_decision <raw stdout> -> approve | block | timeout | crash | unrecognized
# `timeout` and `crash` are DISTINCT from `approve`: an empty stdout is the fall-through
# allow only when the process actually exited 0. Neither is a value any table row expects,
# so a crash surfaces as a FAIL naming the status instead of satisfying an `approve`.
gate_decision() {
    local out="$1"
    case "$out" in
        # 124 = GNU timeout; 142 = SIGALRM (perl fallback); 137 = SIGKILL — budget, not allow.
        *'<<HOOK_EXIT_124>>'*|*'<<HOOK_EXIT_142>>'*|*'<<HOOK_EXIT_137>>'*) printf 'timeout'; return ;;
        *'<<HOOK_EXIT_'*) printf 'crash'; return ;;
    esac
    out="$(printf '%s' "$out" | tr -d '\r\n')"
    [ -z "$out" ] && { printf 'approve'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
        '{}')                     printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}

# A crashed subprocess has no reason string — returning its partial stdout would let an
# `assert_contains` match on debris. Empty is what the B0/B8-0 guards already catch.
gate_reason() {
    case "$1" in *'<<HOOK_EXIT_'*) printf ''; return ;; esac
    printf '%s' "$1" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write(String(JSON.parse(d).reason||''))}catch(e){process.stdout.write('')}})" 2>/dev/null
}

run_probe() { "$RWT" 25 node "$@" 2>/dev/null; }

PROBE_DIR="$TMPBASE_SH/probes"; mkdir -p "$PROBE_DIR"

# H0 - harness self-check. Without the entrypoints every case below is vacuous.
if [ -f "$GATE_HOOK" ]; then pass "H0 workflow-gate.js present"
else fail "H0 workflow-gate.js MISSING at $GATE_HOOK - Sections A/B would be vacuous"; fi
if [ -f "$AGENTS_DIR/hooks/lib/protected-basenames.js" ]; then pass "H0 protected-basenames.js present"
else fail "H0 hooks/lib/protected-basenames.js MISSING - Sections C1..C3 would be vacuous"; fi
if [ "$REPO_OK" = yes ]; then pass "H0 git fixture repo built"
else skip "H0 git unavailable - in-repo block cases and Section D fall back to path-shape only"; fi

# H0-rc — the EXIT-STATUS CONTRACT gate_decision() rests on (review C1). It maps a
# non-zero status to `crash`/`timeout`, which is only sound while both verdicts exit 0.
# Asserted on a real ALLOW and a real BLOCK, because a hook that started signalling
# `block` by exit status would silently turn every block row into "crash" and every
# crash into an unnoticed approve. Run before any section so the failure is legible.
H0_ALLOW_OUT="$(run_gate "$(mk_edit_input Write "sid2108-absent" "$PLANS_FWD/probe.md")" "-")"
H0_BLOCK_OUT="$(run_gate "$(mk_edit_input Write "$SID_T1" "/tmp/h0-block-probe.md")" "-")"
assert_not_contains "H0-rc allow-path hook subprocess exits 0" "<<HOOK_EXIT_" "$H0_ALLOW_OUT"
assert_not_contains "H0-rc block-path hook subprocess exits 0" "<<HOOK_EXIT_" "$H0_BLOCK_OUT"
# And the capture helper itself must actually be able to REPORT a failure - a marker
# that never appears would make the two assertions above vacuous (Pattern 4).
assert_contains "H0-rc capture helper reports a non-zero exit" "<<HOOK_EXIT_" \
    "$(run_hook_capture "" node -e "process.exit(3)")"
assert_eq "H0-rc gate_decision maps a non-zero exit to crash" "crash" \
    "$(gate_decision "$(run_hook_capture "" node -e "process.exit(3)")")"

# ---- case parts (rules/coding/file-split.md: sibling <name>/ folder) --------
PARTS="$AGENTS_DIR/tests/fix-2108-subagent-artifact-write-path"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-allowlist.sh
. "$PARTS/cases-allowlist.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-plans-containment.sh
. "$PARTS/cases-plans-containment.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-symlink-containment.sh
. "$PARTS/cases-symlink-containment.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-messages.sh
. "$PARTS/cases-messages.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-stem-rules.sh
. "$PARTS/cases-stem-rules.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-failclosed.sh
. "$PARTS/cases-failclosed.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-wiring.sh
. "$PARTS/cases-wiring.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-injection.sh
. "$PARTS/cases-injection.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-bctw-bash.sh
. "$PARTS/cases-bctw-bash.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-bctw-command-tools.sh
. "$PARTS/cases-bctw-command-tools.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-sid-boundary.sh
. "$PARTS/cases-sid-boundary.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-worktree-notes.sh
. "$PARTS/cases-worktree-notes.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-notes-enumerate.sh
. "$PARTS/cases-notes-enumerate.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-ghost-sid.sh
. "$PARTS/cases-ghost-sid.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-observe-fault.sh
. "$PARTS/cases-observe-fault.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-resolve-sid-fault.sh
. "$PARTS/cases-resolve-sid-fault.sh"
# shellcheck source=./fix-2108-subagent-artifact-write-path/cases-clearance-wsid-gate.sh
. "$PARTS/cases-clearance-wsid-gate.sh"

run_A_allowlist            # Scope 1+2: Tier 1 and Tier 2 write allowlist, symmetric
run_A18_input_edges        # Scope 1+2: path alias, invalid SCRATCHPAD, empty/non-string targets
run_A21_plans_containment  # Scope 1+2: the PLANS_DIR boundary is containment, not prefix
run_A22_symlink_containment # Scope 1+2: a symlink out of an allowlisted root
run_B_block_messages       # Scope 3: block wording, main vs subagent, both tiers
run_B9_agent_id_edges      # Scope 3: malformed agent_id shapes keep main-context wording
run_C1_stem_rules          # Scope 4: stem predicate TP/FP matrix over all 9 kinds
run_C1b_spelling_split     # Scope 4: clean (exact) vs bash (tail) spelling separation
run_C1c_fail_closed        # Scope 4: unobservable sid set must fall back to blocking
run_C1d_cross_session      # Scope 4: other sessions' markers stay protected (R2b residual)
run_C2_shared_predicate    # both call chains keep ONE stem rule
run_C3_marker_gate         # allow fast-path withheld (NOT an end-to-end verdict)
run_C4_session_ctx_trace   # stdin session_id reaches all four call sites
run_C5_bctw_bash_route     # the Bash branch of block-clearance-token-write, TP/FP pair
run_C6_command_tool_routes # the same boundary on runInTerminal / runCommands (CPR-ORTH)
run_C7_state_faults        # malformed / unreadable / mismatched state entries fail closed
run_C8_sid_boundaries      # near-canonical session-id shapes, one char either side
run_C9_malformed_sid       # malformed stdin session_id must not crash or fail open
run_C10_notes_helpers      # the two WORKTREE_NOTES helpers, extracted and shared (SSOT)
run_C11_enumerate          # every notes-derived sid a reader could resolve to
run_C12_ghost_observation  # planted Session-ID joins the observed set; memo/charset defects
run_C13_ghost_end_to_end   # the ghost-sid write/delete hole through the real hook
run_C14_resolver_pins      # both resolvers' behaviour unchanged by the extraction
run_C15_observe_fault      # the observation dependency faulted where it is consumed
run_C16_resolve_sid_fault  # resolveSessionId faulted at its call site INSIDE the observation
run_C17_interpreter_body   # node -e / python -c bodies: the write vector shell words miss
run_C18_transcript_sid_e2e # session_id omitted: the sid the decision uses is the transcript's
run_D_f1_regression        # poisoned TEMP must not turn the scratchpad allow on
run_E_injection            # the scratchpad allow root is a path boundary, not a prefix
run_A_clearance_wsid_gate  # the FALLBACK clearance wsid must be canonically shaped

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
