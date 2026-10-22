# tests/agents/feature-wip-state/_lib.sh
# Shared preamble of the feature-wip-state entrypoints (#2723 split): counters, timeout wrapper, fixture helpers, the gh mock factory.
# Sourced by tests/agents/feature-wip-state{,-abandon,-new,-resolver}.sh after they set SCRIPT_CHECKOUT_ROOT; not executed directly.

TARGET="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# make_origin_fixture <dir> [<origin-url>]
#   #1899: repo identity resolves from the ORIGIN remote via bin/github-issues/lib/origin-repo.sh, not
#   `gh repo view`, so a fixture CWD must be a git repo with a github.com origin.
#   Creates <dir>, git-inits it, disables git hooks (rules/test/fixture-isolation.md), adds the origin
#   (default https://github.com/nirecom/agents.git). Deliberately NO WORKTREE_NOTES.md: priority-6
#   session-id resolution reads it and the SID-isolation cases depend on its absence.
make_origin_fixture() {
    local dir="$1"
    local url="${2:-https://github.com/nirecom/agents.git}"
    mkdir -p "$dir"
    git -C "$dir" init -q >/dev/null 2>&1
    git -C "$dir" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$dir" remote remove origin >/dev/null 2>&1 || true
    git -C "$dir" remote add origin "$url" >/dev/null 2>&1
}

# make_git_fixture_no_origin <dir> — git repo with NO origin remote.
make_git_fixture_no_origin() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q >/dev/null 2>&1
    git -C "$dir" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$dir" remote remove origin >/dev/null 2>&1 || true
}

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/wip-state.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 68 failed"
    exit 1
fi

SCRIPT_DIR="$SCRIPT_CHECKOUT_ROOT/tests/agents"
SUB_DIR="$SCRIPT_DIR/feature-wip-state"
# shellcheck source=/dev/null
. "$SUB_DIR/setup.sh"

wip_finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}
