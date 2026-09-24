#!/usr/bin/env bash
# Tests: bin/resolve-worktree-path, hooks/workflow-state/resolve-worktree-path.js, hooks/workflow-state/session-id.js, bin/compute-staged-tests-token.js, skills/review-tests/scripts/select-staged-files.sh
# Tags: scope:issue-specific, pwsh-not-required, worktree, session-id, ssot
# Part of tests/fix-882-resolve-worktree-path.sh (rules/coding/file-split.md).
# Cases M-T + R (#2270/#1759/#658): the session id must come from the SSOT
# resolver's supply tier, so a non-native-LLM caller that only exports
# CLAUDE_CODE_SESSION_ID resolves the same worktree a native session does —
# while the filesystem inference tier stays OFF for these callers.
# Cases N/U-W/Y (#2270): legacy SESSION_ID is no longer a supply channel, so CLAUDE_CODE_SESSION_ID decides alone.

# Session ids used only by this part; kept distinct from $SESSION_ID so a case
# can prove WHICH env var the resolver read.
CC_SID="fix-882-cc-sid"
ALT_SID="fix-882-alt-sid"

# Invoke resolveSessionWorktreePath() with NO argument — the H1 site itself, where
# the function derives the id from the env on its own; run_resolver_env exercises
# the H1' bridge instead. Prints the resolved path, or empty for null.
#   $1: SESSION_ID   $2: CLAUDE_CODE_SESSION_ID
run_resolver_js_noarg() {
  (
    cd "$TMPDIR_BASE" || exit 1
    SESSION_ID="$1" \
    CLAUDE_SESSION_ID="" \
    CLAUDE_CODE_SESSION_ID="$2" \
    CLAUDE_ENV_FILE="" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
    AGENTS_CONFIG_DIR="$AGENTS_NODE" \
      bash "$RUN_TIMEOUT" 30 node -e "
const { resolveSessionWorktreePath } = require('$AGENTS_NODE/hooks/workflow-state/resolve-worktree-path.js');
const r = resolveSessionWorktreePath();
process.stdout.write(r === null || r === undefined ? '' : String(r));
"
  ) 2>/dev/null
}

# Run bin/compute-staged-tests-token.js with NO argv[2], so the worktree comes
# from the session-bound resolver alone (issue #1759).
#   $1: SESSION_ID   $2: CLAUDE_CODE_SESSION_ID
run_compute_no_argv() {
  (
    cd "$TMPDIR_BASE" || exit 1
    SESSION_ID="$1" \
    CLAUDE_SESSION_ID="" \
    CLAUDE_CODE_SESSION_ID="$2" \
    CLAUDE_ENV_FILE="" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
    AGENTS_CONFIG_DIR="$AGENTS_NODE" \
      bash "$RUN_TIMEOUT" 30 node "$COMPUTE_JS"
  ) 2>/dev/null
}

run_cases_2270_ssot() {

# ---------------------------------------------------------------------------
# Case M [RED before C1]: CLAUDE_CODE_SESSION_ID is the ONLY session id in the
# env — the reliable variable in a non-native-LLM tool's environment (#2270).
# The CLI must resolve that session's linked worktree exactly as SESSION_ID does.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$CC_SID" "$WTA_NODE"
caseM_got="$(run_resolver_env "" "$CC_SID" "$TMPDIR_BASE")"
if [[ "$caseM_got" = "$WTA_NODE" ]]; then
  pass "Case M (CLAUDE_CODE_SESSION_ID only -> linked worktree): got '$caseM_got'"
else
  fail "Case M (CLAUDE_CODE_SESSION_ID only -> linked worktree): got '$caseM_got', expected '$WTA_NODE'"
fi

# ---------------------------------------------------------------------------
# Case N [#2270 H1']: SESSION_ID and CLAUDE_CODE_SESSION_ID name DIFFERENT
# sessions whose states point at different worktrees. SESSION_ID is not read at
# all, so there is no disagreement to arbitrate: the bridge answers the session
# the CANONICAL variable names (wtB). A wtA answer would mean the legacy variable
# is still being promoted into sessionIdFromInput.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$ALT_SID" "$WTA_NODE"
write_state_for "$CC_SID" "$WTB_NODE"
caseN_got="$(run_resolver_env "$ALT_SID" "$CC_SID" "$TMPDIR_BASE")"
if [[ "$caseN_got" = "$WTB_NODE" ]]; then
  pass "Case N (bridge, stray SESSION_ID ignored -> CLAUDE_CODE_SESSION_ID's worktree): got '$caseN_got'"
else
  fail "Case N (bridge, stray SESSION_ID ignored): got '$caseN_got', expected '$WTB_NODE' (wtA = legacy var still read)"
fi

# ---------------------------------------------------------------------------
# Case N2: the answer is stable. A second identical invocation must return the
# same path — a resolver that fell back to a filesystem trace would start
# agreeing with whichever session touched the tree most recently.
# ---------------------------------------------------------------------------
caseN2_got="$(run_resolver_env "$ALT_SID" "$CC_SID" "$TMPDIR_BASE")"
if [[ "$caseN2_got" = "$caseN_got" ]]; then
  pass "Case N2 (answer is idempotent): repeat run matched"
else
  fail "Case N2 (answer is idempotent): first '$caseN_got', repeat '$caseN2_got'"
fi

# ---------------------------------------------------------------------------
# Case U [#2270 H1]: the same env at the JS site. Hook consumers call
# resolveSessionWorktreePath() in-process and never reach the bridge, so the
# supply tier has to rank identically at
# hooks/workflow-state/resolve-worktree-path.js on its own (CPR-ORTH with Case N).
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$ALT_SID" "$WTA_NODE"
write_state_for "$CC_SID" "$WTB_NODE"
caseU_got="$(run_resolver_js_noarg "$ALT_SID" "$CC_SID")"
if [[ "$caseU_got" = "$WTB_NODE" ]]; then
  pass "Case U (JS site, stray SESSION_ID ignored): got '$caseU_got'"
else
  fail "Case U (JS site, stray SESSION_ID ignored): got '$caseU_got', expected '$WTB_NODE'"
fi

# ---------------------------------------------------------------------------
# Case V: JS site, CLAUDE_CODE_SESSION_ID alone. The canonical variable is the
# only one reliably set in a Bash-tool subprocess (#1082), so demoting the legacy
# read must not cost the canonical one its resolution.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$CC_SID" "$WTA_NODE"
caseV_got="$(run_resolver_js_noarg "" "$CC_SID")"
if [[ "$caseV_got" = "$WTA_NODE" ]]; then
  pass "Case V (JS site, CLAUDE_CODE_SESSION_ID only -> linked worktree): got '$caseV_got'"
else
  fail "Case V (JS site, CLAUDE_CODE_SESSION_ID only -> linked worktree): got '$caseV_got', expected '$WTA_NODE'"
fi

# ---------------------------------------------------------------------------
# Case W [#2270 core]: JS site, legacy SESSION_ID alone. SESSION_ID is an
# OUTPUT label (skill scripts export it for plan-artifact prefixes), never an
# input channel, so a process carrying only it resolves nothing — the caller is
# expected to supply CLAUDE_CODE_SESSION_ID or an explicit id instead.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$ALT_SID" "$WTA_NODE"
caseW_got="$(run_resolver_js_noarg "$ALT_SID" "")"
if [[ -z "$caseW_got" ]]; then
  pass "Case W (JS site, legacy SESSION_ID only -> empty): empty as expected"
else
  fail "Case W (JS site, legacy SESSION_ID only -> empty): got '$caseW_got', expected empty (SESSION_ID is not a supply channel)"
fi

# ---------------------------------------------------------------------------
# Case X: both variables carry the SAME id. The canonical one decides, and the
# presence of the legacy one changes nothing — the boundary case for Case N.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$CC_SID" "$WTA_NODE"
caseX_got="$(run_resolver_env "$CC_SID" "$CC_SID" "$TMPDIR_BASE")"
if [[ "$caseX_got" = "$WTA_NODE" ]]; then
  pass "Case X (bridge, both vars agree -> linked worktree): got '$caseX_got'"
else
  fail "Case X (bridge, both vars agree -> linked worktree): got '$caseX_got', expected '$WTA_NODE'"
fi

# ---------------------------------------------------------------------------
# Case O [RED before C1]: CLAUDE_CODE_SESSION_ID names a session with no state
# file. The CLI's documented contract distinguishes "no id" (empty) from "id
# but no state" (NOSTATE) — the widened read must produce NOSTATE, not empty,
# or select-staged-files.sh loses its cwd fallback for these callers.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
caseO_got="$(run_resolver_env "" "$CC_SID" "$TMPDIR_BASE")"
if [[ "$caseO_got" = "NOSTATE" ]]; then
  pass "Case O (CLAUDE_CODE_SESSION_ID, no state -> NOSTATE): got 'NOSTATE'"
else
  fail "Case O (CLAUDE_CODE_SESSION_ID, no state -> NOSTATE): got '$caseO_got', expected 'NOSTATE'"
fi

# ---------------------------------------------------------------------------
# Case P: the main-worktree rejection is id-source-independent. Passes today
# only because the id is ignored entirely; after C1 it becomes the real
# assertion that Case B's fail-closed rule survives the widened read.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$CC_SID" "$MAIN_NODE"
caseP_got="$(run_resolver_env "" "$CC_SID" "$TMPDIR_BASE")"
if [[ -z "$caseP_got" ]]; then
  pass "Case P (CLAUDE_CODE_SESSION_ID + main-worktree state -> empty): empty as expected"
else
  fail "Case P (CLAUDE_CODE_SESSION_ID + main-worktree state -> empty): got '$caseP_got', expected empty"
fi

# ---------------------------------------------------------------------------
# Case S [RED before C1, #658]: the end-to-end shape of the bug. /review-tests
# runs select-staged-files.sh from the main worktree with only
# CLAUDE_CODE_SESSION_ID set; today the resolver returns empty and the script
# exits 3 ("no staged files"), silently reviewing nothing.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$CC_SID" "$WTA_NODE"
run_select "$MAIN_REPO" "" "nostate" "wta" "$CC_SID"
caseS_got="$SELECT_OUT"
if [[ "$SELECT_RC" -ne 3 ]] && echo "$caseS_got" | grep -q "fixture-wta.sh" \
   && ! echo "$caseS_got" | grep -q "fixture-main.sh"; then
  pass "Case S (select-staged-files via CLAUDE_CODE_SESSION_ID): wtA files, rc=$SELECT_RC"
else
  fail "Case S (select-staged-files via CLAUDE_CODE_SESSION_ID): rc=$SELECT_RC out='$caseS_got', expected rc!=3 with fixture-wta.sh only"
fi

# ---------------------------------------------------------------------------
# Case T: inference stays OFF. No session id in the env at all, but CWD is wtB
# whose WORKTREE_NOTES.md advertises $NOTES_SID, and that session's state points
# at wtA. A resolver that fell through to the filesystem tier would answer wtA;
# the CLI must answer empty, exactly as Case C does.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$NOTES_SID" "$WTA_NODE"
caseT_got="$(run_resolver_env "" "" "$WTB")"
if [[ -z "$caseT_got" ]]; then
  pass "Case T (no supplied id, WORKTREE_NOTES bait ignored): empty as expected"
else
  fail "Case T (no supplied id, WORKTREE_NOTES bait ignored): got '$caseT_got', expected empty (inference tier must stay off)"
fi

# ---------------------------------------------------------------------------
# Case R [RED before C1, #1759]: the same widened read reached through
# compute-staged-tests-token.js with no argv[2]. A stale/empty token here makes
# the pre-commit review-tests gate block forever.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$CC_SID" "$WTA_NODE"
# The token must equal Case H's — the token computed with wtA passed EXPLICITLY as
# argv[2]. Merely non-empty would also be satisfied by a token fingerprinting the
# WRONG worktree, which is the failure #1759 is about: the gate compares this token
# against the one it computes at commit time in the session's own worktree.
caseR_got="$(run_compute_no_argv "" "$CC_SID")"
if [[ -n "$caseR_got" && "$caseR_got" = "$caseH_got" ]]; then
  pass "Case R (staged-tests token via CLAUDE_CODE_SESSION_ID): matches wtA's token '$caseR_got'"
else
  fail "Case R (staged-tests token via CLAUDE_CODE_SESSION_ID): got '$caseR_got', expected Case H's wtA token '$caseH_got'"
fi

# ---------------------------------------------------------------------------
# Case Y [#2270 downstream / #658]: the consumer that observed the live failure —
# /review-tests running select-staged-files.sh from the main worktree with a
# stray SESSION_ID in the env. The canonical variable names the wtB session, so
# the review set is wtB's staged files: neither wtA's (legacy variable read) nor
# the main worktree's (cwd fallback), and never rc=3 (silent skip) or 124 (hang).
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$ALT_SID" "$WTA_NODE"
write_state_for "$CC_SID" "$WTB_NODE"
# wtB needs its own staged test file so "which worktree" is readable from stdout
# and from the token (Case Y2); the dispatcher stages only wtA and main.
mkdir -p "$WTB/tests"
echo "# wtB worktree test file - selected only via CLAUDE_CODE_SESSION_ID" > "$WTB/tests/fixture-wtb.sh"
git -C "$WTB" add tests/fixture-wtb.sh
run_select "$MAIN_REPO" "$ALT_SID" "nostate" "wta" "$CC_SID"
caseY_got="$SELECT_OUT"
if [[ "$SELECT_RC" -ne 3 ]] && echo "$caseY_got" | grep -q "fixture-wtb.sh" \
   && ! echo "$caseY_got" | grep -q "fixture-wta.sh" \
   && ! echo "$caseY_got" | grep -q "fixture-main.sh"; then
  pass "Case Y (stray SESSION_ID -> select follows CLAUDE_CODE_SESSION_ID to wtB): rc=$SELECT_RC"
else
  fail "Case Y (stray SESSION_ID -> select follows CLAUDE_CODE_SESSION_ID to wtB): rc=$SELECT_RC out='$caseY_got', expected fixture-wtb.sh only with rc!=3 (124 = hang)"
fi

# ---------------------------------------------------------------------------
# Case Y2 [#2270 downstream / #1759]: the token side of Case Y. The token
# fingerprints the SAME worktree the selection used, so it must be non-empty and
# must NOT equal Case H's wtA token — a wtA fingerprint here is what makes the
# pre-commit review-tests gate compare against a tree nobody reviewed.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
write_state_for "$ALT_SID" "$WTA_NODE"
write_state_for "$CC_SID" "$WTB_NODE"
caseY2_got="$(run_compute_no_argv "$ALT_SID" "$CC_SID")"
if [[ -n "$caseY2_got" && "$caseY2_got" != "$caseH_got" ]]; then
  pass "Case Y2 (token follows CLAUDE_CODE_SESSION_ID to wtB): got '$caseY2_got'"
else
  fail "Case Y2 (token follows CLAUDE_CODE_SESSION_ID to wtB): got '$caseY2_got', expected non-empty and different from wtA's token '$caseH_got'"
fi

# ---------------------------------------------------------------------------
# Case Y3: both consumers land on the SAME worktree. A pairing where select
# reviews one tree and the token fingerprints another is the permanent-gate-block
# shape — one half reports what it read, the other hands the gate a fingerprint
# of something else. The pair must agree, run after run.
# ---------------------------------------------------------------------------
if [[ "$SELECT_RC" -ne 3 ]] && echo "$caseY_got" | grep -q "fixture-wtb.sh" \
   && [[ -n "$caseY2_got" && "$caseY2_got" != "$caseH_got" ]]; then
  pass "Case Y3 (selection and token both resolve wtB): no half-open gate state"
else
  fail "Case Y3 (selection and token both resolve wtB): select rc=$SELECT_RC out='$caseY_got', token='$caseY2_got'"
fi

}
