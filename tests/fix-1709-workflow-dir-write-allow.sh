#!/usr/bin/env bash
# tests/fix-1709-workflow-dir-write-allow.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/bash-write-scope.js
# Tags: enforce-worktree, non-git-cwd, workflow-state-dir, fail-closed, symlink, default-path, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - enforce-worktree.js firing as a real PreToolUse hook inside a live claude -p
#   session with a real non-git CWD (here the CWD is a temp dir and stdin is piped).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# #1709a - enforce-worktree's non-git-CWD path is fail-CLOSED: when the repo root
# cannot be determined AND target extraction cannot use one of the narrow allow
# helpers (plans-dir / scratchpad), a Bash write is blocked. That correctly denies
# arbitrary external writes, but it also denies the off-clearance pipeline's own
# writes into the workflow STATE dir (<CLAUDE_WORKFLOW_DIR>, canonically
# $HOME/.claude/projects/workflow), which is exactly where token/marker bookkeeping
# lives. The fix adds areAllBashTargetsUnderWorkflowDir() to bash-write-scope.js and
# wires it into the same non-git-CWD branch as the plans-dir/scratchpad helpers.
#
# Command shape: every case uses a SEQUENCED command (`mkdir -p ... && echo ... >`).
# Sequencing is what routes the command past the fast-path allows into the
# fail-closed block, so it is the shape that actually exercises the branch under
# test. A non-sequenced single redirect is already allowed today (asserted as W0
# below so a future change cannot silently make this file vacuous).
#
# ---------------------------------------------------------------------------
# ASSERTION CONTRACT (strict - see classify()).
#
# An earlier revision treated "the output does not contain a block decision" as
# ALLOW. enforce-worktree.js always exits 0 and always prints either
# JSON.stringify({}) (allow) or {"decision":"block",...}; it prints NOTHING only
# when it bails out early (e.g. the WORKFLOW_OFF marker branch) or when it
# crashes. Under the old rule a crash, a run-with-timeout 124, or an early bail
# all scored as "allow" - a false green on the exact branch under test. Each of
# those is now its own verdict token, so only an affirmative "{}" is an allow.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/enforce-worktree.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf1709'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Per-run fixtures: WFDIR is the workflow STATE dir; NONGIT is the (non-git) CWD.
WFROOT=$(make_tmp)          # stands in for $HOME/.claude/projects
WFDIR="$WFROOT/workflow"
OTHERDIR="$WFROOT/other"    # sibling project dir - must stay blocked
mkdir -p "$WFDIR" "$OTHERDIR"
NONGIT=$(make_tmp)
WFDIR_N=$(node_path "$WFDIR"); OTHER_N=$(node_path "$OTHERDIR")

mk_input() { "$RWT" 10 node -e "
process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wf1709sid',tool_input:{command:process.argv[1]}}));" "$1"; }

# run_hook <command> -> "<rc>|<stdout, newlines stripped>"
run_hook() {
    local cmd="$1" hi out rc
    hi=$(mk_input "$cmd")
    out=$( cd "$NONGIT" && printf '%s' "$hi" | CLAUDE_WORKFLOW_DIR="$WFDIR_N" WORKFLOW_PLANS_DIR="$WFDIR_N" \
        ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 15 node "$HOOK" 2>/dev/null )
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# run_hook_default_home <home-dir> <command> -> "<rc>|<stdout>"
# CLAUDE_WORKFLOW_DIR is UNSET here (env -u), so the hook must fall back to
# getWorkflowDir()'s canonical default, $HOME/.claude/projects/workflow.
# HOME and USERPROFILE are both redirected because os.homedir() prefers
# USERPROFILE on win32 and HOME elsewhere.
run_hook_default_home() {
    local hm="$1" cmd="$2" hi out rc hm_n
    hm_n=$(node_path "$hm")
    hi=$(mk_input "$cmd")
    out=$( cd "$NONGIT" && printf '%s' "$hi" | env -u CLAUDE_WORKFLOW_DIR -u WORKFLOW_PLANS_DIR \
        HOME="$hm_n" USERPROFILE="$hm_n" \
        ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 15 node "$HOOK" 2>/dev/null )
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# classify "<rc>|<out>" -> allow | block | timeout | crash:<rc> | no-output | unrecognized
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        124) printf 'timeout'; return ;;
        0)   ;;
        *)   printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'no-output'; return; }
    case "$out" in
        *'"decision":"block"'*) printf 'block'; return ;;
        '{}')                   printf 'allow'; return ;;
    esac
    printf 'unrecognized'
}

assert_verdict() {
    local label="$1" want="$2" raw="$3" got
    got="$(classify "$raw")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [raw=$(printf '%.200s' "$raw")]"; fi
}
assert_allow() { assert_verdict "$1" allow "$2"; }
assert_block() { assert_verdict "$1" block "$2"; }

# W0 - baseline sanity: a NON-sequenced write into a non-git dir is already allowed.
# Guards against this file becoming vacuous if the sequencing routing changes.
assert_allow "W0 baseline: non-sequenced redirect into workflow dir" \
    "$(run_hook "echo x > $WFDIR_N/wf1709sid.json")"

# (a) sequenced write whose targets are all under the workflow state dir -> allow.
#     RED until areAllBashTargetsUnderWorkflowDir() is wired into the non-git-CWD branch.
assert_allow "A1 sequenced write under workflow state dir" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $WFDIR_N/wf1709sid.json")"

# (a2) H4 #1780 regression fix - PROTECTED_MARKER_BASENAME_RE. A write whose
# basename is a clearance/marker file (.workflow-off / .worktree-off /
# .issue-close-verified / .next-step-paused) under the workflow state dir must
# NOT be fast-allowed by areAllBashTargetsUnderWorkflowDir() anymore - it now
# falls through to normal fail-closed enforcement and BLOCKs. Formerly (pre-H4)
# this was asserted as an ALLOW, which was exactly the WORKFLOW_OFF clearance
# bypass the H4 fix closes: a single unguarded sequenced Bash write could forge
# a session marker file. This case is VULNERABLE-BEHAVIOR-LOCKED to assert_block.
assert_block "A2 sequenced write of a clearance-marker file (.workflow-off) under workflow state dir (H4 #1780)" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $WFDIR_N/wf1709sid.workflow-off")"
assert_block "A3 sequenced write of a clearance-marker file (.worktree-off) under workflow state dir (H4 #1780)" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $WFDIR_N/wf1709sid.worktree-off")"
assert_block "A4 sequenced write of a clearance-marker file (.issue-close-verified) under workflow state dir (H4 #1780)" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $WFDIR_N/wf1709sid.issue-close-verified")"

# (b) sibling path under the same .claude/projects parent -> must STILL block.
#     The allow must be scoped to the workflow dir itself, not its parent.
assert_block "B1 sequenced write to a SIBLING projects dir" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $OTHER_N/wf1709sid.json")"
assert_block "B2 mixed targets (workflow dir + sibling) -> not all under workflow dir" \
    "$(run_hook "echo a > $WFDIR_N/ok.json && echo b > $OTHER_N/leak.json")"

# (c) '..' traversal out of the workflow dir -> must STILL block (fail-closed).
assert_block "C1 sequenced write with '..' traversal out of the workflow dir" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $WFDIR_N/../escape.json")"
assert_block "C2 deeper '..' traversal segment inside the path" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $WFDIR_N/sub/../../escape2.json")"

# ---------------------------------------------------------------------------
# (H2) #1780 H-2 - per-segment scope check, not the flat merged target list.
#
# Old bug: enforce-worktree.js's hoisted #1709 allow called
# areAllBashTargetsUnderWorkflowDir(targets) on the FLAT merged target list
# BEFORE the sequencing guard. A sequenced command mixing one extractable
# workflow-dir write with a non-extractable/out-of-scope write (e.g. a `bash
# -c "rm somefile"` segment, which is a genuine write per isInterpreterCWriteIR
# but contributes NO write target to the flat collector) was wrongly ALLOWED,
# because the flat list contained only the workflow-dir target. Verified
# directly against bash-write-scope.js: for this exact command, the OLD flat
# check areAllBashTargetsUnderWorkflowDir(flatTargets) returns true (single
# target, under the workflow dir) while the NEW per-segment
# areAllWriteSegmentsUnderWorkflowDir(ir) returns false, because the `bash -c`
# segment hits isInterpreterCWriteIR (a targetless-write predicate) and fails
# closed. A plain `bash ./scripts/build.sh` (no -c body) does NOT reproduce
# this: it matches no write predicate at all and is transparently skipped as
# a read segment by both the old and new code, so it is not a useful
# regression case here.
# F1 is RED before the H-2 fix (flat check says allow), GREEN after (per-segment
# check fails closed on the targetless bash -c write).
# ---------------------------------------------------------------------------
assert_block "F1 sequenced: extractable workflow-dir write + non-extractable bash -c write segment (H-2 #1780)" \
    "$(run_hook "echo x > \"$WFDIR_N/probe.txt\" && bash -c \"rm somefile\"")"

# F2 companion (motivating case): every target in a sequenced, nested-subdir
# write genuinely resolves under the workflow dir -> must stay ALLOW.
assert_allow "F2 sequenced write into a nested subdir, all targets under workflow dir (H-2 companion)" \
    "$(run_hook "mkdir -p \"$WFDIR_N/sub\" && echo x > \"$WFDIR_N/sub/f\"")"

# ---------------------------------------------------------------------------
# (d) DEFAULT workflow dir - CLAUDE_WORKFLOW_DIR UNSET.
#
# Cases A1/A2/B1/B2 all set CLAUDE_WORKFLOW_DIR explicitly, so they only ever
# exercise the env-var arm of getWorkflowDir(). The arm that real sessions
# actually use is the fallback, path.join(os.homedir(), '.claude','projects',
# 'workflow'). If the new helper is written against the env var alone (or
# resolves the default differently from getWorkflowDir), every case above still
# passes while the shipped behaviour is broken. HOME/USERPROFILE are redirected
# to a controlled temp dir so the fallback is exercised without touching the
# real profile.
# D1 is RED until S-2 (same reason as A1/A2); D2 must be green already.
# ---------------------------------------------------------------------------
FAKEHOME=$(make_tmp)
FH_WF="$FAKEHOME/.claude/projects/workflow"
FH_OTHER="$FAKEHOME/.claude/projects/other"
mkdir -p "$FH_WF" "$FH_OTHER"
FH_WF_N=$(node_path "$FH_WF"); FH_OTHER_N=$(node_path "$FH_OTHER")

assert_verdict "D1 default workflow dir (CLAUDE_WORKFLOW_DIR unset): sequenced write under \$HOME/.claude/projects/workflow" \
    allow "$(run_hook_default_home "$FAKEHOME" "mkdir -p $FH_WF_N && echo x > $FH_WF_N/wf1709sid.json")"
assert_verdict "D2 default workflow dir: sequenced write to SIBLING \$HOME/.claude/projects/other still blocked" \
    block "$(run_hook_default_home "$FAKEHOME" "mkdir -p $FH_WF_N && echo x > $FH_OTHER_N/leak.json")"

# ---------------------------------------------------------------------------
# (e) SYMLINK ESCAPE - a path that is LEXICALLY beneath the workflow dir but
#     actually resolves outside it must be BLOCKED.
#
# Why this case exists: the planned areAllBashTargetsUnderWorkflowDir() uses
# nodePath.resolve() + a prefix comparison, which is purely LEXICAL - it
# normalises '..' segments (covered by C1/C2) but never consults the filesystem,
# so a symlinked directory inside the workflow dir is a containment bypass:
# <workflowDir>/escape -> <arbitrary external dir> is lexically "under" the
# workflow dir and would be handed a write allow.
#
# CURRENT STATUS (read this before trusting a green): today this case passes
# VACUOUSLY - every sequenced command in a non-git CWD is blocked by the
# fail-closed branch, so the block has nothing to do with symlink awareness.
# It becomes a real assertion the moment S-2 lands, and at that point it FAILS
# unless the helper resolves symlinks (fs.realpathSync.native, with a
# fail-closed catch for a non-existent path) before the prefix comparison.
# That is a requirement this test imposes on the S-2 implementation; the
# detail plan as written specifies lexical resolution only.
# ---------------------------------------------------------------------------
# try_symlink <target> <linkpath>: plain ln -s first; on Git Bash/MSYS that silently
# degrades to a directory COPY, which would make E1/E2 assert nothing, so the
# nativestrict variant is retried and the result is verified with -L.
try_symlink() {
    ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    rm -r -f "$2" 2>/dev/null
    MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    return 1
}
EXTDIR=$(make_tmp)                 # stands in for a protected location outside the workflow dir
SYMLINK="$WFDIR/escape"
if try_symlink "$EXTDIR" "$SYMLINK"; then
    SYM_N=$(node_path "$SYMLINK")
    assert_block "E1 write via a symlink inside the workflow dir pointing OUTSIDE it (lexically contained, actually escaping)" \
        "$(run_hook "mkdir -p $WFDIR_N && echo x > $SYM_N/leak.json")"
    assert_block "E2 symlink escape with a nested path segment" \
        "$(run_hook "mkdir -p $WFDIR_N && echo x > $SYM_N/sub/leak2.json")"
else
    skip "E1/E2 symlink escape - could not create a real symlink here (Windows without developer mode / MSYS winsymlinks). The containment requirement on S-2 stands regardless; verify on a POSIX host."
fi

# ---------------------------------------------------------------------------
# (S) F-3 (security-scanner round 6) - symlink indirection around a PROTECTED
# marker basename. `ln -s <wf>/<sid>.workflow-off <wf>/lnk` where the marker
# does NOT exist yet (it is about to be forged BY the write through the link)
# used to make fs.realpathSync(head) throw ENOENT - Node's realpath requires
# the FINAL resolved target to exist, and it never does at this pre-write
# moment. The old catch-branch treated that identically to "not a symlink at
# all" and fell back to the LEXICAL basename ("lnk"), which never matches
# PROTECTED_MARKER_BASENAME_RE, so the write sailed through the workflow-dir
# fast-allow and forged the marker. The fix peeks with lstatSync/readlinkSync
# in the catch-branch and follows an existing symlink (even to a nonexistent
# target) via realResolve() again, so the eventual basename check sees
# "sid.workflow-off", not "lnk", and falls through to normal (blocking)
# enforcement instead of the fast-allow.
# ---------------------------------------------------------------------------
SYM2_TARGET="$WFDIR/wf1709sid.workflow-off"   # NOT pre-created - marker doesn't exist yet
SYM2_LINK="$WFDIR/lnk"
if try_symlink "$SYM2_TARGET" "$SYM2_LINK"; then
    SYM2_N=$(node_path "$SYM2_LINK")
    assert_block "S1 write through a symlink to a not-yet-existing marker basename (F-3 round-6)" \
        "$(run_hook "mkdir -p $WFDIR_N && echo x > $SYM2_N")"
else
    skip "S1 symlink-to-nonexistent-marker - could not create a real symlink here (Windows without developer mode / MSYS winsymlinks). The F-3 requirement stands regardless; verify on a POSIX host."
fi

# S2 control - a normal, non-symlink file under the workflow dir must stay
# ALLOW (guards against over-blocking: the F-3 lstat/readlink peek must not
# make ordinary non-symlink files look like markers).
assert_allow "S2 control: sequenced write to a normal (non-symlink) file under workflow dir (F-3 control)" \
    "$(run_hook "mkdir -p $WFDIR_N && echo x > $WFDIR_N/plainfile.txt")"

# S3 - symlink CHAIN (symlink -> symlink -> not-yet-existing marker), guarding
# the MAX_SYMLINK_HOPS-bounded recursive follow inside realResolve().
SYM3_MID="$WFDIR/lnk-mid"
SYM3_OUTER="$WFDIR/lnk-outer"
if try_symlink "$SYM2_TARGET" "$SYM3_MID" && try_symlink "$SYM3_MID" "$SYM3_OUTER"; then
    SYM3_N=$(node_path "$SYM3_OUTER")
    assert_block "S3 write through a two-hop symlink chain to a not-yet-existing marker (F-3 MAX_SYMLINK_HOPS)" \
        "$(run_hook "mkdir -p $WFDIR_N && echo x > $SYM3_N")"
else
    skip "S3 symlink-chain-to-nonexistent-marker - could not create real symlinks here (Windows without developer mode / MSYS winsymlinks)."
fi

rm -r -f "$WFROOT" "$NONGIT" "$FAKEHOME" "$EXTDIR" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
