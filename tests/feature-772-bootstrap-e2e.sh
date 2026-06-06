#!/usr/bin/env bash
# filename: tests/feature-772-bootstrap-e2e.sh
# Tests: skills/worktree-end/scripts/bootstrap-complete.sh
# Tags: bootstrap, worktree-end, e2e, new-repo
#
# Tests the bootstrap-complete script for issue #772.
# This script runs at the end of /worktree-end when the remote was empty at
# session start — it pushes the initial commit, then sets the default branch
# on the remote via `gh repo edit`.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_COMPLETE="$AGENTS_DIR/skills/worktree-end/scripts/bootstrap-complete.sh"

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

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$BOOTSTRAP_COMPLETE" ]; then
    echo "FAIL: precondition missing — skills/worktree-end/scripts/bootstrap-complete.sh (TDD: write source next)"
    echo ""
    echo "Results: 0 passed, 1 failed (expected RED — source not yet implemented)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir shared between bash and Node.js
# (mktemp -d on MSYS returns /tmp/... which Node on Windows can't resolve)
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests772e2e.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Set up a tmp directory + mock binaries. Each test:
#   - creates a fake repo with an initial commit
#   - writes mock `git` and `gh` shells to MOCK_DIR
#   - prepends MOCK_DIR to PATH
#   - runs the script
setup_env() {
    TMP="$(mktemp -d "${TMPDIR_BASE}/e2e.XXXXXXXX")"
    MOCK_DIR="$TMP/mock"
    REPO="$TMP/repo"
    mkdir -p "$MOCK_DIR" "$REPO"

    # Initialize the repo using the REAL git so it has a commit + branch.
    git -C "$REPO" init -q -b main
    git -C "$REPO" config user.email "test@example.com"
    git -C "$REPO" config user.name "Test"
    # Disable global core.hooksPath (points to agents/hooks pre-commit which
    # blocks commits from the main worktree). Per-repo override wins.
    git -C "$REPO" config core.hooksPath ""
    echo "init" > "$REPO/README.md"
    git -C "$REPO" add README.md
    git -C "$REPO" commit -q -m "initial" --no-verify

    OLD_PATH="$PATH"
    # Path with mocks first; real git still reachable for setup outside the script.
    export PATH="$MOCK_DIR:$PATH"
    GH_LOG="$TMP/gh.log"
    : > "$GH_LOG"
    export GH_MOCK_LOG="$GH_LOG"
    PROBE_LOG="$TMP/probe.log"
    : > "$PROBE_LOG"
    export PROBE_MOCK_LOG="$PROBE_LOG"
}

teardown_env() {
    export PATH="$OLD_PATH"
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
    unset TMP MOCK_DIR REPO OLD_PATH GH_LOG GH_MOCK_LOG PROBE_LOG PROBE_MOCK_LOG
}

# Mock git: pass through to real git EXCEPT for `push` which is configurable.
# Reads GIT_PUSH_EXIT (default 0) and GIT_PUSH_STDERR.
write_mock_git_push() {
    local exit_code="$1" stderr_str="${2:-}"
    cat > "$MOCK_DIR/git" <<EOF
#!/usr/bin/env bash
# First arg "push"? Mock it.
for arg in "\$@"; do
  if [ "\$arg" = "push" ]; then
    printf '%s' "$stderr_str" >&2
    exit $exit_code
  fi
done
# Otherwise delegate to the real git (skip our mock dir).
real_git="\$(PATH="\$(echo "\$PATH" | sed 's|$MOCK_DIR:||')" command -v git)"
exec "\$real_git" "\$@"
EOF
    chmod +x "$MOCK_DIR/git"
}

# Mock gh: log every invocation; configurable exit code for `repo edit`.
write_mock_gh() {
    local repo_edit_exit="${1:-0}"
    cat > "$MOCK_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "\$GH_MOCK_LOG"
if [ "\$1" = "repo" ] && [ "\$2" = "edit" ]; then
    exit $repo_edit_exit
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/gh"
}

# Mock probe (re-probe via bootstrap-state.js). Honors BOOTSTRAP_REPROBE_RESULT
# which can be set to "empty-repo" or "ok".
write_mock_probe() {
    # The script may call the probe via `node hooks/lib/bootstrap-state.js` or via
    # a CLI. We can't know without the implementation, so we provide BOTH:
    #   (a) BOOTSTRAP_PROBE_OVERRIDE env var that the script is expected to honor
    #       when testing (set via the test).
    #   (b) For implementations that call node directly, we substitute a
    #       BOOTSTRAP_STATE_LIB env hook (set by the test).
    :  # No-op; the test sets BOOTSTRAP_REPROBE_RESULT in the environment.
}

# Run the script. Args: <repo> [<expected exit>]
run_bootstrap() {
    local repo="$1"
    BOOTSTRAP_OUT="$(run_with_timeout 30 env \
        BOOTSTRAP_REPROBE_RESULT="${BOOTSTRAP_REPROBE_RESULT:-empty-repo}" \
        bash "$BOOTSTRAP_COMPLETE" --repo "$repo" --remote origin --default-branch main 2>&1)"
    BOOTSTRAP_EXIT=$?
}

# Extract a JSON field from BOOTSTRAP_OUT (last line that parses as JSON).
json_field() {
    local field="$1"
    node -e "
const out = process.argv[1] || '';
const lines = out.split(/\r?\n/).filter(Boolean);
for (let i = lines.length - 1; i >= 0; i--) {
  try {
    const j = JSON.parse(lines[i]);
    if (j && Object.prototype.hasOwnProperty.call(j, process.argv[2])) {
      console.log(String(j[process.argv[2]]));
      process.exit(0);
    }
  } catch (e) {}
}
console.log('');
" "$BOOTSTRAP_OUT" "$field" 2>/dev/null || echo ""
}

# ============================================================================
# Normal cases
# ============================================================================

# E1: push succeeds → exit 0, stdout JSON contains bootstrap_commit_sha
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO"
SHA="$(json_field bootstrap_commit_sha)"
if [ "$BOOTSTRAP_EXIT" = "0" ] && [ -n "$SHA" ]; then
    pass "E1: push succeeds → exit 0, JSON has bootstrap_commit_sha"
else
    fail "E1: exit=$BOOTSTRAP_EXIT sha=$SHA out=$BOOTSTRAP_OUT"
fi
teardown_env

# E2: gh repo edit called with --default-branch main
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO"
if grep -q "repo edit" "$GH_LOG" && grep -q -- "--default-branch main" "$GH_LOG"; then
    pass "E2: gh repo edit called with --default-branch main"
else
    fail "E2: gh log did not show 'repo edit --default-branch main'. Log: $(cat "$GH_LOG" 2>/dev/null)"
fi
teardown_env

# ============================================================================
# Error cases
# ============================================================================

# E3: re-probe shows non-empty remote (race) → exit 2
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=ok
run_bootstrap "$REPO"
if [ "$BOOTSTRAP_EXIT" = "2" ]; then
    pass "E3: re-probe shows non-empty remote → exit 2"
else
    fail "E3: expected exit 2, got $BOOTSTRAP_EXIT. out=$BOOTSTRAP_OUT"
fi
teardown_env

# E4: push fails → exit 3
setup_env
write_mock_git_push 1 "fatal: unable to push: rejected"
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO"
if [ "$BOOTSTRAP_EXIT" = "3" ]; then
    pass "E4: push fails → exit 3"
else
    fail "E4: expected exit 3, got $BOOTSTRAP_EXIT. out=$BOOTSTRAP_OUT"
fi
teardown_env

# ============================================================================
# Edge cases
# ============================================================================

# E5: gh repo edit fails (permission) → warn only, JSON has default_branch_set: false
setup_env
write_mock_git_push 0
write_mock_gh 1
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO"
DBS="$(json_field default_branch_set)"
if [ "$BOOTSTRAP_EXIT" = "0" ] && [ "$DBS" = "false" ]; then
    pass "E5: gh repo edit fails → warn only, default_branch_set=false"
else
    fail "E5: expected exit 0 + default_branch_set=false, got exit=$BOOTSTRAP_EXIT dbs=$DBS out=$BOOTSTRAP_OUT"
fi
teardown_env

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
