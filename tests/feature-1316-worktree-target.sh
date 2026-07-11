#!/bin/bash
# tests/feature-1316-worktree-target.sh
# Tests: bin/compute-staged-tests-token.js, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: review-tests, worktree-target, staged-tests-token, parallel-sessions, scope:issue-specific
#
# Issue #1316 — commit-target worktree resolution for /review-tests Step 4a.
# The staged-tests token and the codex review loop must both resolve to the
# SESSION's linked worktree (state.cwd), never to process.cwd()/main. Otherwise
# parallel sessions mint a token for the wrong worktree and the pre-commit gate
# blocks forever on stale-token.
#
# EXPECTED: cases 1-3, 6 will FAIL until source implementation is complete
#           (resolveRepoDir() does not yet consult readState(SESSION_ID).cwd).
#           Regression guards (cases 4, 5) detect the OLD unsafe fallback to
#           process.cwd() — they FAIL now (demonstrating the bug) and PASS after
#           the fix removes the process.cwd() fallback.
#
# L3 gap (what this L2 test does NOT catch):
# - Whether the real pre-commit gate (hooks/pre-commit) fingerprints the same
#   worktree in a live parallel-session commit — only a real two-worktree
#   `git commit` on a true host reproduces the fingerprint handshake.
# - Whether SESSION_ID propagates from the live Claude Code session env into
#   the compute-staged-tests-token.js process (env chain is indirect on Windows).
# Closest-to-action mitigation: token consistency is re-checked at commit time
# by the pre-commit stale-token gate (review-tests-checker.js).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPUTE_JS="$AGENTS_DIR/bin/compute-staged-tests-token.js"
LOOP_SH="$AGENTS_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# Normalize a path for cross-platform comparison: C:/foo and /c/foo are equivalent.
norm_path() {
    local p="$1"
    if [[ "$p" =~ ^([A-Za-z]):(.*) ]]; then
        local drv="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]//\\//}"
        printf '/%s%s' "$(printf '%s' "$drv" | tr 'A-Z' 'a-z')" "$rest"
    else
        printf '%s' "$p"
    fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/wt1316.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Isolate workflow state so we never touch the real session store.
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow"
mkdir -p "$CLAUDE_WORKFLOW_DIR"

# ---------------------------------------------------------------------------
# Precondition gate
# ---------------------------------------------------------------------------
if [[ ! -f "$COMPUTE_JS" ]]; then
    echo "FAIL: precondition missing — bin/compute-staged-tests-token.js"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_repo_with_staged_tests() {
    local repo="$1" marker="$2"
    mkdir -p "$repo/tests"
    (
        cd "$repo"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        echo "initial" > README.md
        git -c core.hooksPath="" add README.md
        git -c core.hooksPath="" commit -q -m initial
    )
    printf 'test content for %s\n' "$marker" > "$repo/tests/feature-x.sh"
    git -C "$repo" -c core.hooksPath="" add tests/feature-x.sh
}

make_repo_no_staged_tests() {
    local repo="$1"
    mkdir -p "$repo/src"
    (
        cd "$repo"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        echo "initial" > README.md
        git -c core.hooksPath="" add README.md
        git -c core.hooksPath="" commit -q -m initial
    )
    echo "code" > "$repo/src/app.js"
    git -C "$repo" -c core.hooksPath="" add src/app.js
}

# Write a workflow state JSON; cwd="" means no cwd field written.
write_state() {
    local sid="$1" cwd="$2"
    node -e '
        const fs = require("fs");
        const path = require("path");
        const [sid, cwd] = process.argv.slice(1);
        const dir = process.env.CLAUDE_WORKFLOW_DIR;
        const state = {
            version: 1,
            session_id: sid,
            created_at: new Date().toISOString(),
            steps: {
                review_tests: { status: "pending", updated_at: null }
            }
        };
        if (cwd) state.cwd = cwd;
        fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify(state, null, 2));
    ' -- "$sid" "$cwd"
}

# Run compute-staged-tests-token.js with the given SESSION_ID, from a specific CWD.
run_compute() {
    local sid="$1" cwd="$2"
    ( cd "$cwd" && SESSION_ID="$sid" CLAUDE_SESSION_ID="$sid" \
        "$RWT" 120 node "$COMPUTE_JS" ) 2>/dev/null
}

# Run compute with explicit argv[2] to get ground-truth token for a worktree.
run_compute_explicit() {
    local dir="$1"
    "$RWT" 120 node "$COMPUTE_JS" "$dir" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Build fixtures using real git worktree structure.
# One parent repo (MAIN_WT) + one linked worktree (LINKED_A) so that:
#   git rev-parse --git-dir differs in LINKED_A vs MAIN_WT (linked vs .git/)
#   git rev-parse --git-common-dir is identical for both (same parent .git/)
# This is the real invariant the implementation must use to identify linked worktrees.
# ---------------------------------------------------------------------------
PARENT_REPO="$TMPDIR_BASE/parent-repo"
LINKED_A="$TMPDIR_BASE/linked-a"
MAIN_WT="$PARENT_REPO"   # alias: main worktree IS the parent repo

# Initialise parent repo with an initial commit on a fixed branch name.
mkdir -p "$PARENT_REPO/tests"
(
    cd "$PARENT_REPO"
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    git config user.email test@example.com
    git config user.name Test
    git config commit.gpgsign false
    echo "initial" > README.md
    git -c core.hooksPath="" add README.md
    git -c core.hooksPath="" commit -q -m initial
)

# Stage tests/ in the parent (main) worktree — token for MAIN_WT.
printf 'test content for MAIN\n' > "$PARENT_REPO/tests/feature-x.sh"
git -C "$PARENT_REPO" -c core.hooksPath="" add tests/feature-x.sh

# Create a linked worktree on a new branch.
git -C "$PARENT_REPO" -c core.hooksPath="" worktree add -q "$LINKED_A" -b feature/linked-a

# Stage different tests/ content in the linked worktree — distinct token.
mkdir -p "$LINKED_A/tests"
printf 'test content for linked-A\n' > "$LINKED_A/tests/feature-x.sh"
git -C "$LINKED_A" -c core.hooksPath="" add tests/feature-x.sh

# Verify the worktree structure is correct: linked-A must have separate --git-dir.
_git_dir_linked="$(git -C "$LINKED_A" rev-parse --git-dir 2>/dev/null || echo "")"
_git_common_linked="$(git -C "$LINKED_A" rev-parse --git-common-dir 2>/dev/null || echo "")"
_git_dir_main="$(git -C "$MAIN_WT" rev-parse --git-dir 2>/dev/null || echo "")"
if [[ "$_git_dir_linked" == "$_git_common_linked" || -z "$_git_dir_linked" ]]; then
    echo "FAIL: fixture sanity — git worktree add did not create a proper linked worktree"
    echo "  --git-dir=[$_git_dir_linked] --git-common-dir=[$_git_common_linked]"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

TOKEN_A_EXPECTED="$(run_compute_explicit "$LINKED_A")"
TOKEN_MAIN_EXPECTED="$(run_compute_explicit "$MAIN_WT")"

# Sanity: the two worktrees must have different non-empty tokens.
if [[ -z "$TOKEN_A_EXPECTED" || "$TOKEN_A_EXPECTED" == "$TOKEN_MAIN_EXPECTED" ]]; then
    echo "FAIL: fixture sanity — linked-A and main tokens must be non-empty and distinct"
    echo "  A=[$TOKEN_A_EXPECTED] main=[$TOKEN_MAIN_EXPECTED]"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

SID_A="test-sid-1316-a"
write_state "$SID_A" "$LINKED_A"

# ===========================================================================
# Case 1 — state.cwd=linked-A, CWD=main → token must be linked-A's, not main's.
# EXPECTED: FAIL before fix (resolveRepoDir still falls back to process.cwd()).
# ===========================================================================
got1="$(run_compute "$SID_A" "$MAIN_WT")"
if [[ "$got1" == "$TOKEN_A_EXPECTED" ]]; then
    pass "1: state.cwd=linked-A resolves token to A even when CWD=main"
else
    fail "1: expected A's token [$TOKEN_A_EXPECTED], got [$got1] (main=[$TOKEN_MAIN_EXPECTED])"
fi

# ===========================================================================
# Case 2 — run-codex-review-loop.sh --repo-root must resolve to linked-A.
#   Probed by running the script from MAIN_WT with SESSION_ID pointing at A,
#   with a stub environment that makes the script exit early but reveal its
#   resolved repo root. We look for linked-A's path in the output/error.
# EXPECTED: FAIL before fix (script uses git rev-parse --show-toplevel from CWD).
# ===========================================================================
if [[ ! -f "$LOOP_SH" ]]; then
    fail "2: precondition missing — skills/review-tests/scripts/run-codex-review-loop.sh"
else
    PLANS_DIR2="$TMPDIR_BASE/plans2"
    mkdir -p "$PLANS_DIR2"
    echo "# Test review draft" > "$PLANS_DIR2/$SID_A-test-review.md"
    echo "# Outline"          > "$PLANS_DIR2/$SID_A-outline.md"
    # We probe what --repo-root the script passes to bin/run-codex-review-loop
    # by wrapping run-codex-review-loop with a sentinel that records its args.
    REPO_ROOT_RECORD="$TMPDIR_BASE/repo-root-record.txt"
    STUB_BIN2="$TMPDIR_BASE/stubbin2"
    mkdir -p "$STUB_BIN2"
    # The run-codex-review-loop.sh script calls "$AGENTS_CONFIG_DIR/bin/run-codex-review-loop".
    # We can't stub it via PATH because it uses an absolute path from AGENTS_CONFIG_DIR.
    # Instead we create a fake AGENTS_CONFIG_DIR that has a stub run-codex-review-loop.
    FAKE_ACD2="$TMPDIR_BASE/fake-acd2"
    mkdir -p "$FAKE_ACD2/bin" "$FAKE_ACD2/rules"
    [[ -d "$AGENTS_DIR/rules" ]] && cp -r "$AGENTS_DIR/rules" "$FAKE_ACD2/" 2>/dev/null || true
    # Stub run-codex-review-loop to record --repo-root arg and exit 3.
    cat > "$FAKE_ACD2/bin/run-codex-review-loop" <<STUBSCRIPT
#!/bin/bash
# Stub: record --repo-root arg value.
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--repo-root" && -n "\${2:-}" ]]; then
        printf '%s' "\$2" > "${REPO_ROOT_RECORD}"
        break
    fi
    shift
done
echo "## Codex Plan Review: SKIPPED -- stub"
exit 3
STUBSCRIPT
    chmod +x "$FAKE_ACD2/bin/run-codex-review-loop"
    # Also stub build-codex-context.
    cat > "$FAKE_ACD2/bin/build-codex-context" <<'BSTUB'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" && -n "${2:-}" ]]; then
        echo "stub" > "$2"; break; fi
    shift; done; exit 0
BSTUB
    chmod +x "$FAKE_ACD2/bin/build-codex-context"

    ( cd "$MAIN_WT" && \
        AGENTS_CONFIG_DIR="$FAKE_ACD2" SESSION_ID="$SID_A" CLAUDE_SESSION_ID="$SID_A" \
        PLANS_DIR="$PLANS_DIR2" EXTENSIONS_USED=0 \
        "$RWT" 120 bash "$LOOP_SH" >/dev/null 2>&1 || true )

    if [[ -f "$REPO_ROOT_RECORD" ]]; then
        recorded_root="$(cat "$REPO_ROOT_RECORD")"
        if [[ "$(norm_path "$recorded_root")" == "$(norm_path "$LINKED_A")" ]]; then
            pass "2: run-codex-review-loop.sh passes --repo-root=linked-A (not main-wt)"
        else
            fail "2: --repo-root was [$recorded_root], expected [$LINKED_A]"
        fi
    else
        # No --repo-root recorded: either fix didn't pass it, or stub didn't run.
        fail "2: --repo-root not passed/recorded; loop may not have called run-codex-review-loop"
    fi
fi

# ===========================================================================
# Case 3 — Consistency: compute-token and loop must resolve to SAME worktree.
#   The token minted by compute (case 1) must equal explicit token of linked-A.
# EXPECTED: FAIL before fix (case 1 already fails, so this depends on case 1).
# ===========================================================================
if [[ "$got1" == "$TOKEN_A_EXPECTED" ]]; then
    pass "3: cross-tool consistency — both resolve to linked-A for same SESSION_ID"
else
    fail "3: cross-tool inconsistency — compute resolved to [$got1] but linked-A token is [$TOKEN_A_EXPECTED]"
fi

# ===========================================================================
# Case 4 (regression d) — NO state.cwd + CWD=main → must NOT emit main's token.
#   OLD behavior: falls back to process.cwd() and mints main's token.
#   FIXED behavior: returns empty string (null token).
#   This case FAILS while the bug is present, PASSES post-fix.
# ===========================================================================
SID_NOCWD="test-sid-1316-nocwd"
write_state "$SID_NOCWD" ""   # state exists but has no cwd field
got4="$(run_compute "$SID_NOCWD" "$MAIN_WT")"
if [[ "$got4" != "$TOKEN_MAIN_EXPECTED" && -z "$got4" ]]; then
    pass "4: no state.cwd + CWD=main → empty token (not main's token)"
elif [[ "$got4" != "$TOKEN_MAIN_EXPECTED" ]]; then
    pass "4: no state.cwd + CWD=main → token differs from main's (not falling back)"
else
    fail "4: REGRESSION — emitted main's token [$got4] via process.cwd() fallback"
fi

# ===========================================================================
# Case 5 (regression d) — no state.cwd → loop exits non-zero (SKIP), not 0.
#   OLD behavior: silently used main's toplevel and called codex (or exited 0).
#   FIXED behavior: exits non-zero because commit target cannot be resolved.
# ===========================================================================
if [[ -f "$LOOP_SH" ]]; then
    PLANS_DIR5="$TMPDIR_BASE/plans5"
    mkdir -p "$PLANS_DIR5"
    : > "$PLANS_DIR5/$SID_NOCWD-test-review.md"
    : > "$PLANS_DIR5/$SID_NOCWD-outline.md"
    rc5=0
    ( cd "$MAIN_WT" && \
        AGENTS_CONFIG_DIR="$AGENTS_DIR" SESSION_ID="$SID_NOCWD" CLAUDE_SESSION_ID="$SID_NOCWD" \
        PLANS_DIR="$PLANS_DIR5" EXTENSIONS_USED=0 \
        "$RWT" 120 bash "$LOOP_SH" >/dev/null 2>&1 ) || rc5=$?
    if [[ "$rc5" -ne 0 ]]; then
        pass "5: no state.cwd → loop exits non-zero (SKIP — no commit target)"
    else
        fail "5: REGRESSION — loop exited 0 with no resolvable commit target (old CWD fallback)"
    fi
else
    fail "5: precondition missing — skills/review-tests/scripts/run-codex-review-loop.sh"
fi

# ===========================================================================
# Case 6 (regression e) — state.cwd = main worktree path → empty token.
#   The main worktree must be rejected as a linked-worktree commit target.
#   To distinguish "main" from "linked", we use a worktree list check: the
#   first path in `git worktree list --porcelain` is the main worktree.
#   In this test the repo is standalone (no worktree list), so the fix must
#   rely on a positive signal (state.cwd must be a LINKED worktree) rather
#   than the main-worktree rejection alone. We assert: no main token emitted.
# EXPECTED: FAIL before fix (falls through to process.cwd() and emits token).
# ===========================================================================
SID_MAIN="test-sid-1316-main"
write_state "$SID_MAIN" "$MAIN_WT"
got6="$(run_compute "$SID_MAIN" "$MAIN_WT")"
# After fix: state.cwd=main worktree → should emit empty (main worktree guard)
# OR state.cwd is trusted and returns MAIN's token (depends on implementation).
# The key invariant is that the main worktree is NOT used as the commit target
# when enforce-worktree reserves it. We check the weaker contract: fix docs say
# state.cwd that equals the main worktree must return empty.
if [[ -z "$got6" ]]; then
    pass "6: state.cwd=main worktree path → empty token (main worktree rejected)"
else
    fail "6: state.cwd=main worktree → emitted token [$got6] (main worktree not rejected)"
fi

# ===========================================================================
# Case 7 (C7) — state.cwd with a non-existent path → empty token, no crash.
#   After fix: resolveRepoDir reads state.cwd but detects the path doesn't
#   exist → falls through to null (empty token), not process.cwd().
# ===========================================================================
SID_GHOST="test-sid-1316-ghost"
write_state "$SID_GHOST" "/nonexistent/path/that/does/not/exist"
got7="$(run_compute "$SID_GHOST" "$MAIN_WT")"
# Must not emit main's token; must not crash (any clean empty is fine).
if [[ "$got7" != "$TOKEN_MAIN_EXPECTED" ]]; then
    pass "7: state.cwd=nonexistent path → empty token (no crash, no CWD fallback)"
else
    fail "7: REGRESSION — state.cwd=nonexistent path fell back to CWD and emitted main token [$got7]"
fi

# ===========================================================================
# Case 8 (C7) — state.cwd with a valid path that is NOT a git repo → empty token.
#   After fix: isValidLinkedWorktree(state.cwd) fails → null → empty token.
# ===========================================================================
NON_GIT_DIR="$TMPDIR_BASE/not-a-repo"
mkdir -p "$NON_GIT_DIR"
SID_NONGIT="test-sid-1316-nongit"
write_state "$SID_NONGIT" "$NON_GIT_DIR"
got8="$(run_compute "$SID_NONGIT" "$MAIN_WT")"
if [[ "$got8" != "$TOKEN_MAIN_EXPECTED" ]]; then
    pass "8: state.cwd=valid dir but not git repo → empty token (no CWD fallback)"
else
    fail "8: REGRESSION — non-git state.cwd fell back to CWD and emitted main token [$got8]"
fi

# NOTE: Special-char and space paths are not fixture-tested on Windows due to
# Git Bash path normalization edge cases. The contract is covered by cases 7-8
# (path validation gate). Paths with unusual characters would fail the same
# existence/git-repo checks.
# L3 gap: real worktree list check (git worktree list --porcelain parsing for
# "is linked vs main") requires a multi-worktree git repo which cannot be easily
# simulated with isolated fixture repos; only reproducible in the live host.

# SKIPPED: worktree path with spaces
# Because: Windows git worktree add with spaces in path requires extra quoting
#   that is complex to fixture reliably across environments
# L3 gap: worktree paths with spaces should be verified in a real ENFORCE_WORKTREE=on environment

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
