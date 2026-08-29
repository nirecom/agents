#!/usr/bin/env bash
# Tests: hooks/workflow-gate/early-gate-allowlist.js, hooks/lib/claude-scratchpad-base.js, hooks/enforce-worktree/git-repo-detection.js, hooks/workflow-gate.js
# Tags: workflow-gate, early-gate, allowlist, scratchpad, plans-dir, symlink, containment, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).
# Section A22 — the allowlist roots are LEXICAL prefixes, so a symlink placed inside one
# is a path that passes containment while resolving somewhere else entirely. A21 covers
# the textual escapes (`..`, sibling-prefix, case); this covers the FILESYSTEM one, which
# no amount of path.resolve() sees. The scratchpad route has a second, non-lexical clause
# (findRepoRoot must answer null) and that clause is what actually closes the hole.
SY_OK=no
SY_WHY=""
SY_REPO=""
SY_VICTIM_SH=""
SY_LINK_FWD=""
SY_OUTLINK_FWD=""
SY_PLANSLINK_FWD=""
SY_WFLINK_SCRATCH_FWD=""
SY_WFLINK_PLANS_FWD=""

# The victim's body: distinctive so the negative assertion compares content, not existence.
SY_GENUINE="GENUINE-REPO-FILE-A22"
# The workflow-state victim (A22-6): a state file of its own, never SID_T1's — every
# later section reads SID_T1's record, so laundering a write onto it would rewrite the
# fixture the rest of the file depends on rather than demonstrate the escape.
SY_WFVICTIM_SID="sid2108a22"
SY_WFGENUINE='{"session_id":"sid2108a22","GENUINE":"WORKFLOW-STATE-A22"}'
# Canonically shaped so isClearanceBearingStem() answers on SHAPE alone — the A22-7
# block must not depend on this sid being in the observed set.
SY_WFTOKEN_SID="a2200000-0000-4000-8000-00000000a22c"

# _sy_classify <tool> <path> [scratchpad-root] -> "plans" | "scratchpad" | "null"
_sy_classify() {
    local tool="$1" p="$2" sp="${3:-}"
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        if [ -n "$sp" ]; then export SCRATCHPAD="$sp"; else unset SCRATCHPAD; fi
        run_probe -e "const m=require(process.argv[1]);process.stdout.write(String(m.classifyEarlyWriteAllow(process.argv[2],{file_path:process.argv[3]})))" \
            "$ALLOWLIST_NODE" "$tool" "$p"
    )
}

_sy_read() { if [ -e "$1" ]; then cat "$1"; else printf '<absent>'; fi; }

# _sy_bctw <path> -> decision. The SECOND layer (hooks/block-clearance-token-write.js),
# needed by A22-7: the early gate is not the only hook standing between a laundered path
# and forged clearance state, and a residual in one layer is only tolerable while the
# other one still fires. Same stdin shape and same verdict vocabulary as run_gate.
_sy_bctw() {
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE SCRATCHPAD
        gate_decision "$(run_hook_capture "$(mk_edit_input Write "$SID_T1" "$1")" "$RWT" 20 node "$BCTW_HOOK")"
    )
}

# _sy_gated_write <tool> <target-fwd> <target-sh> <content> [scratchpad] -> decision.
# On approve the write is really performed, so a blocked row can assert the victim file.
_sy_gated_write() {
    local tool="$1" fwd="$2" shp="$3" content="$4" sp="${5:-$SCRATCH_C}" d
    d="$(gate_decision "$(run_gate "$(mk_edit_input "$tool" "$SID_T1" "$fwd")" "$sp")")"
    [ "$d" = "approve" ] && printf '%s' "$content" > "$shp"
    printf '%s' "$d"
}

# Symlink creation is a PRIVILEGE on Windows, not a filesystem feature, so it is probed
# with a real fs.symlinkSync rather than inferred from `uname` (CPR-UNV: no implicit
# branch on the environment). `junction` is ignored on POSIX, so one call covers both.
_sy_setup() {
    local base="$TMPBASE_SH/symlink-containment" out
    SY_OK=no; SY_WHY=""
    rm -rf "$base" 2>/dev/null || true
    mkdir -p "$base/outside"
    rm -rf "$SCRATCH_C_FWD/repolink" "$SCRATCH_C_FWD/outlink" "$PLANS_SH/repolink" \
        "$SCRATCH_C_FWD/wfstatelink" "$PLANS_SH/wfstatelink" 2>/dev/null || true

    if [ "$REPO_OK" != yes ]; then
        SY_WHY="the git fixture repo is unavailable, so findRepoRoot() has nothing to detect"
        return
    fi
    SY_REPO="$base/repo"
    mkdir -p "$SY_REPO/hooks"
    git -C "$SY_REPO" init -q -b main >/dev/null 2>&1
    git -C "$SY_REPO" config core.hooksPath /dev/null >/dev/null 2>&1
    if [ ! -d "$SY_REPO/.git" ]; then
        SY_WHY="git init failed for the A22 fixture repo"
        return
    fi
    SY_VICTIM_SH="$SY_REPO/hooks/victim.js"
    printf '%s' "$SY_GENUINE" > "$SY_VICTIM_SH"

    cat > "$PROBE_DIR/sy-link-probe.js" <<'PROBE_EOF'
"use strict";
// argv: pairs of <target> <linkPath>. Prints "OK" or "FAIL <code>" — the caller turns a
// FAIL into SKIP rows, because unprivileged Windows accounts cannot create symlinks.
const fs = require("fs");
try {
  for (let i = 2; i + 1 < process.argv.length; i += 2) {
    fs.symlinkSync(process.argv[i], process.argv[i + 1], "junction");
  }
  process.stdout.write("OK");
} catch (e) { process.stdout.write("FAIL " + (e.code || e.message)); }
PROBE_EOF
    # The last two pairs aim at the WORKFLOW-STATE dir (A22-6/A22-7), planted in BOTH
    # allow roots because the two routes reach the allowlist through different clauses.
    out="$(run_probe "$PROBE_DIR/sy-link-probe.js" \
        "$(node_path "$SY_REPO")" "$(node_path "$SCRATCH_C_FWD/repolink")" \
        "$(node_path "$base/outside")" "$(node_path "$SCRATCH_C_FWD/outlink")" \
        "$(node_path "$SY_REPO")" "$(node_path "$PLANS_SH/repolink")" \
        "$(node_path "$WFDIR_SH")" "$(node_path "$SCRATCH_C_FWD/wfstatelink")" \
        "$(node_path "$WFDIR_SH")" "$(node_path "$PLANS_SH/wfstatelink")")"
    if [ "$out" != "OK" ]; then
        SY_WHY="fs.symlinkSync refused on this host ($out) — symlink creation needs elevation or Developer Mode"
        return
    fi
    if [ ! -e "$SCRATCH_C_FWD/repolink/hooks/victim.js" ]; then
        SY_WHY="the link was created but does not traverse (${SCRATCH_C_FWD}/repolink)"
        return
    fi
    # Same precondition for the workflow-state links: SID_T1's record is written at file
    # scope, so reaching it through the link proves traversal without creating anything.
    if [ ! -e "$SCRATCH_C_FWD/wfstatelink/${SID_T1}.json" ] || [ ! -e "$PLANS_SH/wfstatelink/${SID_T1}.json" ]; then
        SY_WHY="the workflow-state links were created but do not traverse to $WFDIR_SH"
        return
    fi
    SY_LINK_FWD="${SCRATCH_C_FWD}/repolink"
    SY_OUTLINK_FWD="${SCRATCH_C_FWD}/outlink"
    SY_PLANSLINK_FWD="${PLANS_FWD}/repolink"
    SY_WFLINK_SCRATCH_FWD="${SCRATCH_C_FWD}/wfstatelink"
    SY_WFLINK_PLANS_FWD="${PLANS_FWD}/wfstatelink"
    SY_OK=yes
}

run_A22_symlink_containment() {
    local tool d

    _sy_setup
    if [ "$SY_OK" != yes ]; then
        skip "A22 symlink containment: $SY_WHY"
        return
    fi

    # A22-0 — the fixture's own precondition. The link must really reach the repo file, or
    # every block below could be a block on a non-existent path instead of on containment.
    assert_eq "A22-0 the scratchpad symlink really resolves to the repo file" "$SY_GENUINE" \
        "$(_sy_read "$SY_LINK_FWD/hooks/victim.js")"

    # A22-1 — THE REQUIREMENT. The path is lexically inside the scratchpad allow root, so
    # the prefix clause says yes; findRepoRoot() runs `git rev-parse` with the LINK as cwd,
    # which the OS resolves through, and the repo clause then says no. Verdict: not allowed.
    assert_eq "A22-1 scratchpad symlink into a repo is NOT allowlisted" "null" \
        "$(_sy_classify Write "$SY_LINK_FWD/hooks/victim.js" "$SCRATCH_C")"

    # A22-1b — the discriminator. Same allow root, same depth, no symlink hop: allowed.
    # Without it A22-1 would also pass against an allowlist that had simply stopped working.
    assert_eq "A22-1b control: a plain path in the same scratchpad IS allowlisted" "scratchpad" \
        "$(_sy_classify Write "$SCRATCH_C_FWD/plain-note.md" "$SCRATCH_C")"

    # A22-2 — through the REAL gate hook, on all three allowlist tools (CPR-ORTH). The
    # predicate answering `null` only matters if the gate then blocks, and each tool
    # arrives at the allowlist from a different EARLY_GATE_TOOLS branch.
    for tool in Write Edit MultiEdit; do
        assert_eq "A22-2 $tool through the scratchpad symlink is blocked by the gate" "block" \
            "$(gate_decision "$(run_gate "$(mk_edit_input "$tool" "$SID_T1" "$SY_LINK_FWD/hooks/victim.js")" "$SCRATCH_C")")"
        assert_eq "A22-2b control ($tool): the same tool on a plain scratchpad path is allowed" "approve" \
            "$(gate_decision "$(run_gate "$(mk_edit_input "$tool" "$SID_T1" "$SCRATCH_C_FWD/plain-note.md")" "$SCRATCH_C")")"
    done

    # A22-3 — PATTERN 1 (protection-fix-tests.md). Verdict strings are not protection: the
    # write is really executed on approve, so the repo file itself is the assertion.
    assert_eq "A22-3 the laundered write to a repo file is blocked" "block" \
        "$(_sy_gated_write Write "$SY_LINK_FWD/hooks/victim.js" "$SY_VICTIM_SH" "FORGED-VIA-SYMLINK")"
    assert_eq "A22-3 the repo file survived byte-for-byte" "$SY_GENUINE" \
        "$(_sy_read "$SY_VICTIM_SH")"
    rm -f "$SY_REPO/hooks/new-file.js" 2>/dev/null || true
    assert_eq "A22-3 a NEW file laundered into the repo is blocked too" "block" \
        "$(_sy_gated_write Write "$SY_LINK_FWD/hooks/new-file.js" "$SY_REPO/hooks/new-file.js" "FORGED-VIA-SYMLINK")"
    assert_eq "A22-3 ... and never appeared on disk" "<absent>" \
        "$(_sy_read "$SY_REPO/hooks/new-file.js")"
    # HARNESS PROOF: the helper must be able to write, or both rows above are false-green.
    rm -f "$SCRATCH_C_FWD/plain-note.md" 2>/dev/null || true
    assert_eq "A22-3 harness proof: the allowed scratchpad write is approved" "approve" \
        "$(_sy_gated_write Write "$SCRATCH_C_FWD/plain-note.md" "$SCRATCH_C_FWD/plain-note.md" "ALLOWED-BODY-A22")"
    assert_eq "A22-3 harness proof: ... and the bytes are on disk" "ALLOWED-BODY-A22" \
        "$(_sy_read "$SCRATCH_C_FWD/plain-note.md")"

    _sy_characterize_lexical_residuals
    _sy_workflow_state_escape
}

# --- CHARACTERIZATION, NOT REQUIREMENT ------------------------------------------------
# claude-scratchpad-base.js already records the residual in prose ("prefix checks are
# lexical ... tracked as pre-existing"). These rows put a number on it: they name exactly
# which symlink shapes the current allowlist still admits, so closing the residual shows
# up as a failing row rather than as a silently different behaviour.
_sy_characterize_lexical_residuals() {
    # A22-4 — the PLANS route has no repo clause at all: containment there is purely
    # lexical, so a link planted in the plans dir launders a write into a real repo.
    # SKIPPED: asserting a BLOCK here.
    # Because: isUnderPlansDir() is a resolved-prefix comparison by design and the plans
    # dir is user-owned state, not an agent-writable directory — an agent that can plant
    # this link can already write the target directly.
    # L3 gap: whether the plans dir is ever agent-writable in a real deployment. Only
    # realpath-based containment (fs.realpathSync on both sides before the prefix test)
    # would close it, and that is a change to the allowlist, not to this suite.
    assert_eq "A22-4 residual: a plans-dir symlink into a repo IS still allowlisted" "plans" \
        "$(_sy_classify Write "$SY_PLANSLINK_FWD/hooks/victim.js")"
    assert_eq "A22-4 residual: ... and the gate therefore approves it" "approve" \
        "$(gate_decision "$(run_gate "$(mk_edit_input Write "$SID_T1" "$SY_PLANSLINK_FWD/hooks/victim.js")" "-")")"

    # A22-5 — the scratchpad route's own residual, and simultaneously the DISCRIMINATOR
    # for A22-1: an identical symlink hop out of the allow root is allowed when the
    # destination is not a repo. So A22-1's block is attributable to the repo-containment
    # clause specifically, and not to symlinks being rejected as a class.
    # SKIPPED: asserting a BLOCK here.
    # Because: the destination is outside every repo, so the write cannot reach source
    # under version control — the boundary this allowlist exists to defend.
    # L3 gap: a non-repo destination that is still sensitive (another session's state
    # dir, a credentials file) — realpath containment is again the only closure.
    assert_eq "A22-5 residual: a scratchpad symlink to a NON-repo dir is still allowlisted" "scratchpad" \
        "$(_sy_classify Write "$SY_OUTLINK_FWD/note.md" "$SCRATCH_C")"
}

# --- A22-6 / A22-7 — THE SECOND PROTECTED DESTINATION ---------------------------------
# A21 and A22-1..A22-5 reason about one destination class: files under version control.
# early-gate.js:33 names TWO — "outside the repo AND outside workflow state". The second,
# hooks/workflow-state's store (CLAUDE_WORKFLOW_DIR, else ~/.claude/projects/workflow), holds
# the records this gate reads to decide: step progress, clearance tokens, markers. It sits
# outside every repo BY CONSTRUCTION, which is exactly why A22-1's clause misses it —
# findRepoRoot() is the allowlist's only non-lexical test and it answers null here. A22-6
# characterizes that opening and executes it; A22-7 pins the second hook standing behind it.
_sy_workflow_state_escape() {
    local tool wf_victim_sh

    wf_victim_sh="$WFDIR_SH/${SY_WFVICTIM_SID}.json"
    printf '%s' "$SY_WFGENUINE" > "$wf_victim_sh"

    # A22-6-0 — fixture precondition on BOTH roots: else every row below reports on nothing.
    assert_eq "A22-6-0 the scratchpad link really resolves into the workflow-state dir" "$SY_WFGENUINE" \
        "$(_sy_read "$SY_WFLINK_SCRATCH_FWD/${SY_WFVICTIM_SID}.json")"
    assert_eq "A22-6-0 the plans-dir link really resolves into the workflow-state dir" "$SY_WFGENUINE" \
        "$(_sy_read "$SY_WFLINK_PLANS_FWD/${SY_WFVICTIM_SID}.json")"

    # A22-6-1/-2 — the residual, one row per route. A22-1 is the discriminator: same allow
    # root, same symlink hop, verdict `null`. Only the destination differs.
    # SKIPPED: asserting "null" / a BLOCK here.
    # Because: closing it takes realpath containment (fs.realpathSync on both sides before
    # the prefix test) inside early-gate-allowlist.js — the same closure A22-4/A22-5 name,
    # and a change to the allowlist rather than to this suite.
    # L3 gap: whether a deployment lets an agent plant the link at all — planting takes a
    # filesystem call this gate never sees (it classifies file_path only).
    assert_eq "A22-6-1 residual: a scratchpad symlink into the workflow-state dir IS allowlisted" "scratchpad" \
        "$(_sy_classify Write "$SY_WFLINK_SCRATCH_FWD/${SY_WFVICTIM_SID}.json" "$SCRATCH_C")"
    assert_eq "A22-6-2 residual: the same link planted in the plans dir IS allowlisted" "plans" \
        "$(_sy_classify Write "$SY_WFLINK_PLANS_FWD/${SY_WFVICTIM_SID}.json")"

    # A22-6-3 — through the REAL gate, all three allowlist tools (CPR-ORTH with A22-2).
    # Paired control: the SAME target named directly is blocked, so an approve is the
    # symlink hop being missed and not the gate ignoring this destination.
    for tool in Write Edit MultiEdit; do
        assert_eq "A22-6-3 $tool through the workflow-state symlink is approved (residual)" "approve" \
            "$(gate_decision "$(run_gate "$(mk_edit_input "$tool" "$SID_T1" "$SY_WFLINK_SCRATCH_FWD/${SY_WFVICTIM_SID}.json")" "$SCRATCH_C")")"
        assert_eq "A22-6-3 control ($tool): the same target named DIRECTLY is blocked" "block" \
            "$(gate_decision "$(run_gate "$(mk_edit_input "$tool" "$SID_T1" "${WFDIR//\\//}/${SY_WFVICTIM_SID}.json")" "$SCRATCH_C")")"
    done

    # A22-6-4 — Pattern 2: executed, not merely classified. The write goes THROUGH the link.
    assert_eq "A22-6-4 the laundered write to a state file is approved (residual)" "approve" \
        "$(_sy_gated_write Write "$SY_WFLINK_SCRATCH_FWD/${SY_WFVICTIM_SID}.json" \
            "$SY_WFLINK_SCRATCH_FWD/${SY_WFVICTIM_SID}.json" "FORGED-STATE-VIA-SYMLINK")"
    assert_eq "A22-6-4 ... and the state file really was overwritten through the link" "FORGED-STATE-VIA-SYMLINK" \
        "$(_sy_read "$wf_victim_sh")"

    # A22-7 — THE REQUIREMENT. A residual in one layer is tolerable only while the next
    # holds: block-clearance-token-write.js matches on the BASENAME and is
    # directory-agnostic, so the laundered path buys nothing against the highest-value
    # target in that directory — a forged OFF-clearance token. Both roots (CPR-ORTH).
    assert_eq "A22-7 a forged clearance token through the SCRATCHPAD link is blocked" "block" \
        "$(_sy_bctw "$SY_WFLINK_SCRATCH_FWD/${SY_WFTOKEN_SID}.off-clearance")"
    assert_eq "A22-7 a forged clearance token through the PLANS link is blocked" "block" \
        "$(_sy_bctw "$SY_WFLINK_PLANS_FWD/${SY_WFTOKEN_SID}.off-clearance")"

    # A22-7b — Pattern 4, the allow direction: an artifact name ending in a protected kind is
    # NOT clearance state (#2108), and without this row A22-7 would also pass against a hook
    # that had simply started blocking every path holding a link.
    assert_eq "A22-7b control: an artifact name through the same link is allowed" "approve" \
        "$(_sy_bctw "$SY_WFLINK_SCRATCH_FWD/issue-2108-survey.gh-env")"

    # A22-7c — attribution: the early gate APPROVES that same token path (A22-6's residual,
    # one basename over), so A22-7's block is the other hook firing and nothing else.
    assert_eq "A22-7c the early gate itself approves the token path (defence is the OTHER hook)" "approve" \
        "$(gate_decision "$(run_gate "$(mk_edit_input Write "$SID_T1" "$SY_WFLINK_SCRATCH_FWD/${SY_WFTOKEN_SID}.off-clearance")" "$SCRATCH_C")")"

    # A22-7d — Pattern 1: a blocked verdict beside a file on disk is not a block.
    assert_eq "A22-7d the forged token never appeared in the workflow-state dir" "<absent>" \
        "$(_sy_read "$WFDIR_SH/${SY_WFTOKEN_SID}.off-clearance")"

    # Later sections enumerate the SHARED fixture workflow dir: the victim must not outlive us.
    rm -f "$wf_victim_sh" 2>/dev/null || true
}
