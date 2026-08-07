#!/usr/bin/env bash
# tests/feature-1642-precommit-prompt-extraction.sh
# Tests: hooks/pre-commit, bin/check-prompt-extraction
# Tags: pre-commit, hook, git, prompt-extraction, backstop, scope:issue-specific, scope:feature-1642, layer:TL2
#
# Issue #1642 — hooks/pre-commit backstop for the prompt-extraction gate.
#
# The backstop is armed only under a 2-condition AND guard:
#   (a) the repo being committed to IS the agents session repo, AND
#   (b) .prompt-extraction-allowlist exists in that repo.
# Any other repo is untouched (CPR-UNV: no implicit environment branching).
#
# Exit-code mapping enforced here (M3 security fix):
#   1 / 2 / 126 / 127 -> commit blocked (usage errors and missing/non-executable
#                        engine are no longer fail-open)
#   3                 -> warning on stderr, commit continues (infra error only;
#                        the backstop is a safety net, not an availability
#                        dependency)
#
# TL3 gap (what this test does NOT catch):
# - Whether git actually invokes hooks/pre-commit via core.hooksPath in a real checkout.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRECOMMIT="$AGENTS_DIR/hooks/pre-commit"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

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

# ---------------------------------------------------------------------------
# An "agents-like" repo: it is simultaneously the repo under commit AND the
# AGENTS_CONFIG_DIR, so isAgentsSessionRepo() sees identical git common-dirs.
# Node helpers referenced by pre-commit are re-exported from the real checkout
# via one-line shims so the fixture stays tiny.
#
#   make_agents_like_repo <name> <allowlist:yes|no> <engine-spec>
#     engine-spec = "real"    -> exec the real bin/check-prompt-extraction
#                 | "none"    -> no engine installed at all
#                 | <integer> -> stub engine exiting with that code
#                 | "noexec"  -> engine present but not executable (rc 126 path)
# ---------------------------------------------------------------------------
make_agents_like_repo() {
    local name="$1" allowlist="$2" engine="$3"
    local dir="$TMPDIR_BASE/$name"
    init_repo "$dir"
    mkdir -p "$dir/hooks/lib" "$dir/bin" "$dir/rules"
    printf 'module.exports = require("%s/hooks/workflow-state.js");\n' "$_AGENTS_DIR_NODE" \
        > "$dir/hooks/workflow-state.js"
    printf 'module.exports = require("%s/hooks/lib/session-markers.js");\n' "$_AGENTS_DIR_NODE" \
        > "$dir/hooks/lib/session-markers.js"
    printf 'module.exports = require("%s/hooks/lib/precommit-exclude-check.js");\n' "$_AGENTS_DIR_NODE" \
        > "$dir/hooks/lib/precommit-exclude-check.js"
    echo "// stub marker" > "$dir/hooks/enforce-worktree.js"

    case "$engine" in
        real)
            printf '#!/usr/bin/env bash\nexec bash "%s/bin/check-prompt-extraction" "$@"\n' \
                "$AGENTS_DIR" > "$dir/bin/check-prompt-extraction"
            chmod +x "$dir/bin/check-prompt-extraction"
            ;;
        none)
            : ;;
        noexec)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/check-prompt-extraction"
            chmod 000 "$dir/bin/check-prompt-extraction" 2>/dev/null || true
            ;;
        *)
            printf '#!/usr/bin/env bash\necho "stub engine" >&2\nexit %s\n' "$engine" \
                > "$dir/bin/check-prompt-extraction"
            chmod +x "$dir/bin/check-prompt-extraction"
            ;;
    esac

    if [ "$allowlist" = "yes" ]; then
        printf '# prompt-extraction allowlist\n' > "$dir/.prompt-extraction-allowlist"
    fi
    echo "init" > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "initial"
    echo "$dir"
}

stage_violation() {
    local repo="$1"
    mkdir -p "$repo/rules"
    { echo "# Bloated rule"; echo ""; emit_fence 12; } > "$repo/rules/bloated.md"
    git -C "$repo" add rules/bloated.md
}

stage_clean() {
    local repo="$1"
    mkdir -p "$repo/rules"
    { echo "# Lean rule"; echo ""; echo "One short sentence."; } > "$repo/rules/lean.md"
    git -C "$repo" add rules/lean.md
}

OUT=""
RC=0
# run_precommit <cwd> [ENV=VAL ...]
run_precommit() {
    local cwd="$1"; shift
    RC=0
    OUT="$( (cd "$cwd" && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID && run_with_timeout 60 env "$@" bash "$PRECOMMIT") 2>&1 )" || RC=$?
}

write_env_file() {
    local sid="$1"
    local f="$TMPDIR_BASE/envfile-$RANDOM-$$"
    printf 'CLAUDE_SESSION_ID=%s\n' "$sid" > "$f"
    echo "$f"
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
    run_precommit "$other" "AGENTS_CONFIG_DIR=$cfg" "ENFORCE_WORKTREE=off"
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
    run_precommit "$repo" "AGENTS_CONFIG_DIR=$repo" "ENFORCE_WORKTREE=off"
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
    run_precommit "$other" "AGENTS_CONFIG_DIR=$cfg" "ENFORCE_WORKTREE=off"
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
    run_precommit "$repo" "AGENTS_CONFIG_DIR=$repo" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 0 ]; then
        pass "T01c: agents repo without an allowlist -> backstop skipped, commit passes"
    else
        fail "T01c: expected exit 0, got $RC" "$OUT"
    fi
}

# T03 — session-marker bypass. Both markers are honoured (detail plan C2 決定,
#       rules/workflow-off.md: WORKFLOW_OFF subsumes WORKTREE_OFF, so the
#       backstop must treat them symmetrically — CPR-ORTH).
assert_marker_skips_backstop() {
    local label="$1" marker="$2" tag="$3"
    local repo; repo="$(make_agents_like_repo "cfg-$tag" yes real)"
    local sid="pe1642$tag"
    local wfdir="$TMPDIR_BASE/wf-$tag"
    mkdir -p "$wfdir"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.$marker"
    local envfile; envfile="$(write_env_file "$sid")"
    stage_violation "$repo"
    run_precommit "$repo" \
        "AGENTS_CONFIG_DIR=$repo" \
        "ENFORCE_WORKTREE=off" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile"
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
    local envfile; envfile="$(write_env_file "pe1642t03c")"
    stage_violation "$repo"
    run_precommit "$repo" \
        "AGENTS_CONFIG_DIR=$repo" \
        "ENFORCE_WORKTREE=off" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile"
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
    run_precommit "$repo" "AGENTS_CONFIG_DIR=$repo" "ENFORCE_WORKTREE=off"
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
    run_precommit "$repo" "AGENTS_CONFIG_DIR=$repo" "ENFORCE_WORKTREE=off"
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
    run_precommit "$repo" "AGENTS_CONFIG_DIR=$repo" "ENFORCE_WORKTREE=off"
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
    run_precommit "$linked" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=on"
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
