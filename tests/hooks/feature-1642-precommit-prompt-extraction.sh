#!/usr/bin/env bash
# tests/hooks/feature-1642-precommit-prompt-extraction.sh
# Tests: hooks/pre-commit, bin/check-prompt-extraction
# Tags: pre-commit, hook, git, prompt-extraction, backstop, scope:issue-specific, scope:feature-1642, layer:TL2
# Issue #1642 — hooks/pre-commit backstop for the prompt-extraction gate. It arms
# only under a 2-condition AND guard: the committed repo IS the agents session repo
# AND .prompt-extraction-allowlist exists in it; any other repo is untouched
# (CPR-UNV). Exit codes (M3 security fix): 1/2/126/127 block — usage errors and a
# missing or non-executable engine are no longer fail-open — while 3 warns and
# continues. TL3 gap: whether git really invokes the hook via core.hooksPath.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRECOMMIT="$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit"

if [ ! -f "$PRECOMMIT" ]; then
    echo "SKIP: hooks/pre-commit not found"
    exit 77
fi
if ! grep -q "check-prompt-extraction" "$PRECOMMIT"; then
    echo "SKIP: hooks/pre-commit has no prompt-extraction backstop yet (issue #1642)"
    exit 77
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# A case that names no settings root gets this file's own fixture, never the
# caller's: no .env, and an empty blocklist the outbound scanner can resolve.
MAIN_ROOT_FIXTURE="$TMPDIR_BASE/agents-main"
mkdir -p "$MAIN_ROOT_FIXTURE"
: > "$MAIN_ROOT_FIXTURE/.private-info-blocklist"
export AGENTS_MAIN_ROOT="$MAIN_ROOT_FIXTURE"

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR
# isolation (#2512): the state dir is pinned file-wide too, not only per hook call.
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_STATE_DIR"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

emit_fence() {
    local n="$1" i
    echo '```bash'
    for ((i = 1; i <= n; i++)); do echo "echo line $i"; done
    echo '```'
}

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
}

# The hook decides "is this my own repo" and finds its engine from the checkout it is
# launched from (hooks/pre-commit _cfg_dir), never from the environment, so each
# agents-like repo carries its own copy of the checkout and its own hook is run.
# shellcheck source=tests/lib/session-repo-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/session-repo-fixture.sh"
# The root-names gate reads this list from the index of its own repo (bin/check-root-names/main.js).
ROOT_NAMES_LIST="tests/bin/feature-2561-root-names-residue.sh"

# An "agents-like" repo: the repo under commit IS the checkout the hook runs from, so
# the hook sees identical git common-dirs. rules/ and skills/ are copied because the
# other own-repo gates (hooks/lib/precommit-agents-repo-gates.sh) validate the whole tree.
#
#   make_agents_like_repo <name> <allowlist:yes|no> <engine-spec>
#     engine-spec = "real"    -> the real bin/check-prompt-extraction
#                 | "none"    -> no engine installed at all
#                 | <integer> -> stub engine exiting with that code
#                 | "noexec"  -> engine present but not executable (rc 126 path)
make_agents_like_repo() {
    local name="$1" allowlist="$2" engine="$3"
    local dir="$TMPDIR_BASE/$name"
    init_repo "$dir"
    session_repo_fixture_create "$dir" hooks bin rules skills "$ROOT_NAMES_LIST" || return 1
    local stub="$dir/bin/check-prompt-extraction"

    case "$engine" in
        real)
            : ;;
        none)
            rm -f "$stub" ;;
        noexec)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$stub"
            chmod 000 "$stub" 2>/dev/null || true
            ;;
        *)
            printf '#!/usr/bin/env bash\necho "stub engine" >&2\nexit %s\n' "$engine" > "$stub"
            chmod +x "$stub"
            ;;
    esac

    if [ "$allowlist" = "yes" ]; then
        printf '# prompt-extraction allowlist\n' > "$dir/.prompt-extraction-allowlist"
    fi
    echo "init" > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "initial"
    # Untracked, as in a real checkout: the scanner needs a list at the settings root.
    : > "$dir/.private-info-blocklist"
    echo "$dir"
}

# Staged under agents/ (a prompt-extraction target: bin/lib/prompt-extraction/targets.js),
# not rules/: an unlisted rules/*.md is itself blocked by the own-repo rules-notation gate.
stage_violation() {
    local repo="$1"
    mkdir -p "$repo/agents"
    { echo "# Bloated prompt"; echo ""; emit_fence 12; } > "$repo/agents/bloated.md"
    git -C "$repo" add agents/bloated.md
}

stage_clean() {
    local repo="$1"
    mkdir -p "$repo/agents"
    { echo "# Lean prompt"; echo ""; echo "One short sentence."; } > "$repo/agents/lean.md"
    git -C "$repo" add agents/lean.md
}

OUT=""
RC=0
# run_precommit <cwd> <checkout whose hooks/pre-commit runs> [ENV=VAL ...]
run_precommit() {
    local cwd="$1" hook_root="$2"; shift 2
    RC=0
    OUT="$( (cd "$cwd" && unset CLAUDE_CODE_SESSION_ID && run_with_timeout 60 env "$@" bash "$hook_root/hooks/pre-commit") 2>&1 )" || RC=$?
}

# ============================================================================
# Tests
# ============================================================================

# T01: an unrelated repo (no .prompt-extraction-allowlist) is never touched.
t01_other_repo_untouched() {
    local cfg; cfg="$(make_agents_like_repo cfg01 yes real)"
    local other="$TMPDIR_BASE/other01"
    init_repo "$other"
    echo "init" > "$other/README.md"
    git -C "$other" add README.md
    git -C "$other" commit -q -m "initial"
    stage_violation "$other"
    run_precommit "$other" "$cfg" "AGENTS_MAIN_ROOT=$cfg" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 0 ]; then
        pass "T01: foreign repo without an allowlist -> backstop skipped, commit passes"
    else
        fail "T01: expected exit 0, got $RC" "$OUT"
    fi
}

# T02: agents session repo + allowlist present + staged violation -> blocked.
t02_agents_repo_blocked() {
    local repo; repo="$(make_agents_like_repo cfg02 yes real)"
    stage_violation "$repo"
    run_precommit "$repo" "$repo" "AGENTS_MAIN_ROOT=$repo" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 1 ]; then
        pass "T02: staged extraction violation -> commit blocked (exit 1)"
    else
        fail "T02: expected exit 1, got $RC" "$OUT"
    fi
    if printf '%s\n' "$OUT" | grep -qi "bloated.md\|prompt"; then
        pass "T02: block message identifies the offending prompt file"
    else
        fail "T02: block message does not name the violation" "$OUT"
    fi
}

# T01b: a foreign repo that DOES carry a .prompt-extraction-allowlist is still
#       untouched. The guard is a 2-condition AND — allowlist presence alone must
#       never arm the backstop in someone else's repository (CPR-UNV).
t01b_foreign_repo_with_allowlist_untouched() {
    local cfg; cfg="$(make_agents_like_repo cfg01b yes real)"
    local other="$TMPDIR_BASE/other01b"
    init_repo "$other"
    echo "init" > "$other/README.md"
    # Same filename, different repo: only the git common-dir distinguishes them.
    printf '# prompt-extraction allowlist\n' > "$other/.prompt-extraction-allowlist"
    git -C "$other" add -A
    git -C "$other" commit -q -m "initial"
    stage_violation "$other"
    run_precommit "$other" "$cfg" "AGENTS_MAIN_ROOT=$cfg" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 0 ]; then
        pass "T01b: foreign repo WITH an allowlist -> still skipped (repo identity gates it)"
    else
        fail "T01b: expected exit 0, got $RC — the backstop leaked into a foreign repo" "$OUT"
    fi
    if printf '%s\n' "$OUT" | grep -q "bloated.md"; then
        fail "T01b: the foreign repo's staged file was scanned" "$OUT"
    else
        pass "T01b: the foreign repo's staged file was never scanned"
    fi
}

# T01c: the agents session repo WITHOUT an allowlist is also skipped — the other
#       half of the AND guard (symmetric counterpart of T01b, CPR-ORTH).
t01c_agents_repo_without_allowlist_skipped() {
    local repo; repo="$(make_agents_like_repo cfg01c no real)"
    stage_violation "$repo"
    run_precommit "$repo" "$repo" "AGENTS_MAIN_ROOT=$repo" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 0 ]; then
        pass "T01c: agents repo without an allowlist -> backstop skipped, commit passes"
    else
        fail "T01c: expected exit 0, got $RC" "$OUT"
    fi
}

# T03 — session-marker bypass. Both markers are honoured (detail plan C2 decision,
#       rules/workflow-off.md: WORKFLOW_OFF subsumes WORKTREE_OFF, so the
#       backstop must treat them symmetrically — CPR-ORTH).
assert_marker_skips_backstop() {
    local label="$1" marker="$2" tag="$3"
    local repo; repo="$(make_agents_like_repo "cfg-$tag" yes real)"
    local sid="pe1642$tag"
    local wfdir="$TMPDIR_BASE/wf-$tag"
    mkdir -p "$wfdir"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.$marker"
    stage_violation "$repo"
    run_precommit "$repo" "$repo" \
        "AGENTS_MAIN_ROOT=$repo" \
        "ENFORCE_WORKTREE=off" \
        "WORKFLOW_STATE_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        "CLAUDE_CODE_SESSION_ID=$sid"
    if [ "$RC" -eq 0 ]; then
        pass "$label: .$marker marker -> backstop skipped, commit passes"
    else
        fail "$label: expected exit 0 under .$marker, got $RC" "$OUT"
    fi
}

t03_workflow_off_skips_backstop() {
    assert_marker_skips_backstop "T03" "workflow-off" "t03"
}

# T03b: .worktree-off must bypass the backstop exactly as .workflow-off does.
t03b_worktree_off_skips_backstop() {
    assert_marker_skips_backstop "T03b" "worktree-off" "t03b"
}

# T03c: control — with the SAME fixture but no marker file present, the very same
#       staged violation blocks. Without this, T03/T03b would pass even if the
#       backstop never ran for an unrelated reason.
t03c_no_marker_still_blocks() {
    local repo; repo="$(make_agents_like_repo cfg03c yes real)"
    local wfdir="$TMPDIR_BASE/wf03c"
    mkdir -p "$wfdir"
    stage_violation "$repo"
    run_precommit "$repo" "$repo" \
        "AGENTS_MAIN_ROOT=$repo" \
        "ENFORCE_WORKTREE=off" \
        "WORKFLOW_STATE_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        "CLAUDE_CODE_SESSION_ID=pe1642t03c"
    if [ "$RC" -eq 1 ]; then
        pass "T03c: no marker present -> the same staged violation blocks (exit 1)"
    else
        fail "T03c: expected exit 1 without any bypass marker, got $RC" "$OUT"
    fi
}

# Shared assertion for the "warn but continue" exit codes.
assert_warns_and_continues() {
    local label="$1" repo="$2"
    stage_clean "$repo"
    run_precommit "$repo" "$repo" "AGENTS_MAIN_ROOT=$repo" "ENFORCE_WORKTREE=off"
    if [ "$RC" -ne 0 ]; then
        fail "$label: expected exit 0 (commit continues), got $RC" "$OUT"
        return
    fi
    pass "$label: commit continues (exit 0)"
    if printf '%s\n' "$OUT" | grep -qi "prompt-extraction\|prompt extraction"; then
        pass "$label: a warning was emitted"
    else
        fail "$label: no warning emitted" "$OUT"
    fi
}

# T04: engine usage error (exit 2) -> commit blocked (M3: usage errors are no
#      longer fail-open; only infra errors (rc=3) remain warn-and-continue).
t04_exit2_blocks() {
    local repo; repo="$(make_agents_like_repo cfg04 yes 2)"
    stage_clean "$repo"
    run_precommit "$repo" "$repo" "AGENTS_MAIN_ROOT=$repo" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 1 ]; then
        pass "T04: engine exit 2 -> commit blocked (exit 1)"
    else
        fail "T04: expected exit 1 (commit blocked), got $RC" "$OUT"
    fi
    if printf '%s\n' "$OUT" | grep -qi "usage error\|rc=2\|check-prompt-extraction"; then
        pass "T04: block message identifies the usage error"
    else
        fail "T04: no usage-error detail in block message" "$OUT"
    fi
}

# T05: engine infra error (exit 3) -> warn, continue.
t05_exit3_warns() {
    local repo; repo="$(make_agents_like_repo cfg05 yes 3)"
    assert_warns_and_continues "T05: engine exit 3" "$repo"
}

# T06: engine not executable (exit 126) -> commit blocked (M3: not-found /
#      not-executable engine states are no longer fail-open).
t06_exit126_blocks() {
    local repo; repo="$(make_agents_like_repo cfg06 yes noexec)"
    # Some filesystems (Windows/NTFS via Git Bash) ignore chmod 000; skip there.
    if [ -x "$repo/bin/check-prompt-extraction" ]; then
        skip "T06: chmod 000 not honoured on this filesystem — cannot force rc 126"
        return
    fi
    stage_clean "$repo"
    run_precommit "$repo" "$repo" "AGENTS_MAIN_ROOT=$repo" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 1 ]; then
        pass "T06: engine exit 126 (permission denied) -> commit blocked (exit 1)"
    else
        fail "T06: expected exit 1 (commit blocked), got $RC" "$OUT"
    fi
    if printf '%s\n' "$OUT" | grep -qi "not found\|not executable\|rc=126"; then
        pass "T06: block message identifies the not-found/not-executable state"
    else
        fail "T06: no not-found/not-executable detail in block message" "$OUT"
    fi
}

# T07: regression — extracting _session_marker_off() must not change the
#      existing worktree-isolation gate. A commit from a LINKED worktree on a
#      feature branch, with no bypass marker, must still succeed.
t07_worktree_gate_regression() {
    local main="$TMPDIR_BASE/wtmain"
    init_repo "$main"
    echo "init" > "$main/README.md"
    git -C "$main" add README.md
    git -C "$main" commit -q -m "initial"
    local linked="$TMPDIR_BASE/wtlinked"
    if ! git -C "$main" worktree add -q -b feature/pe1642 "$linked" >/dev/null 2>&1; then
        skip "T07: git worktree add unavailable in this environment"
        return
    fi
    git -C "$linked" config core.hooksPath /dev/null
    git -C "$linked" config user.email "test@example.com"
    git -C "$linked" config user.name "Test"
    echo "change" > "$linked/README.md"
    git -C "$linked" add README.md
    run_precommit "$linked" "$SCRIPT_CHECKOUT_ROOT" "ENFORCE_WORKTREE=on"
    if [ "$RC" -eq 0 ]; then
        pass "T07: linked worktree + feature branch still commits under ENFORCE_WORKTREE=on"
    else
        fail "T07: worktree-isolation gate regressed, exit $RC" "$OUT"
    fi
}

run_all() {
    t01_other_repo_untouched
    t01b_foreign_repo_with_allowlist_untouched
    t01c_agents_repo_without_allowlist_skipped
    t02_agents_repo_blocked
    t03_workflow_off_skips_backstop
    t03b_worktree_off_skips_backstop
    t03c_no_marker_still_blocks
    t04_exit2_blocks
    t05_exit3_warns
    t06_exit126_blocks
    t07_worktree_gate_regression
}

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
