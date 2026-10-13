#!/usr/bin/env bash
# filename: tests/skills/feature-772-bootstrap-e2e.sh
# Tests: skills/merge-to-main/scripts/bootstrap-complete.sh
# Tags: bootstrap, worktree-end, e2e, new-repo, scope:issue-specific, deliver, user-verification, security, merge-to-main
#
# Tests the bootstrap-complete script for issue #772 (moved to /merge-to-main by #2527).
# This script runs in /merge-to-main (MM-3b) when the remote was empty at
# session start — it pushes the initial commit, then sets the default branch
# on the remote via `gh repo edit`.

set -u
# TL3 gap (not caught here): /merge-to-main MM-3b passing the live session id to the script, and a real
# empty GitHub remote. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_COMPLETE="$SCRIPT_CHECKOUT_ROOT/skills/merge-to-main/scripts/bootstrap-complete.sh"

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
    echo "FAIL: precondition missing — skills/merge-to-main/scripts/bootstrap-complete.sh (TDD: write source next)"
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
readonly TMPDIR_BASE
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation: the UV gate (E6+) reads workflow state through read-step-status.
_to_node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
mkdir -p "$TMPDIR_BASE/wf-state" "$TMPDIR_BASE/wf-plans"
WORKFLOW_STATE_DIR="$(_to_node_path "$TMPDIR_BASE/wf-state")"
WORKFLOW_PLANS_DIR="$(_to_node_path "$TMPDIR_BASE/wf-plans")"
export WORKFLOW_STATE_DIR WORKFLOW_PLANS_DIR
unset CLAUDE_CODE_SESSION_ID
READ_STEP_STATUS="$SCRIPT_CHECKOUT_ROOT/bin/workflow/read-step-status"

# seed_uv <sid> <status> — real state API: a v5 state whose user_verification has <status>.
seed_uv() {
    node -e '
const S = require(process.argv[1]);
const [sid, status] = process.argv.slice(2);
S.writeState(sid, S.createInitialState(sid, { cwd: "/fixture/772", git_branch: "main" }));
S.markStep(sid, "user_verification", status);
' "$(_to_node_path "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state")" "$1" "$2"
}
uv_status() { node "$READ_STEP_STATUS" --session "$1" --step user_verification 2>&1; }

SID_UV_OK="e2e772-uv-complete"
SID_UV_PENDING="e2e772-uv-pending"
SID_UV_SKIPPED="e2e772-uv-skipped"
SID_UV_NONE="e2e772-uv-none"
SID_UV_CORRUPT="e2e772-uv-corrupt"
seed_uv "$SID_UV_OK" complete
seed_uv "$SID_UV_PENDING" pending
seed_uv "$SID_UV_SKIPPED" skipped
printf '{not json' > "$TMPDIR_BASE/wf-state/$SID_UV_CORRUPT.json"

# Preconditions: the seeded fixtures read back as intended through the real CLI.
for _pre in "$SID_UV_OK=status=complete" "$SID_UV_PENDING=status=pending" \
            "$SID_UV_SKIPPED=status=skipped" "$SID_UV_NONE=NONE" "$SID_UV_CORRUPT=NONE"; do
    _sid="${_pre%%=*}"; _want="${_pre#*=}"
    _got="$(uv_status "$_sid")"
    if [[ "$_got" == "$_want" ]]; then
        pass "precondition: $_sid reads back $_want"
    else
        fail "precondition: $_sid want=[$_want] got=[$_got]"
    fi
done

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
    PUSH_LOG="$TMP/push.log"
    : > "$PUSH_LOG"
    export PUSH_MOCK_LOG="$PUSH_LOG"
}

teardown_env() {
    export PATH="$OLD_PATH"
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
    unset TMP MOCK_DIR REPO OLD_PATH GH_LOG GH_MOCK_LOG PROBE_LOG PROBE_MOCK_LOG PUSH_LOG PUSH_MOCK_LOG
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
    echo "git \$*" >> "\${PUSH_MOCK_LOG:-/dev/null}"
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

# Run the script (flag style). Args: <repo> [<extra flag>...]
run_bootstrap() {
    local repo="$1"; shift
    BOOTSTRAP_OUT="$(run_with_timeout 30 env \
        BOOTSTRAP_REPROBE_RESULT="${BOOTSTRAP_REPROBE_RESULT:-empty-repo}" \
        bash "$BOOTSTRAP_COMPLETE" --repo "$repo" --remote origin --default-branch main "$@" 2>&1)"
    BOOTSTRAP_EXIT=$?
}

# Run the script (positional SKILL.md style). Args: <repo> <branch> <owner/repo> [<sid>]
run_bootstrap_positional() {
    BOOTSTRAP_OUT="$(run_with_timeout 30 env \
        BOOTSTRAP_REPROBE_RESULT="${BOOTSTRAP_REPROBE_RESULT:-empty-repo}" \
        bash "$BOOTSTRAP_COMPLETE" "$@" 2>&1)"
    BOOTSTRAP_EXIT=$?
}

# push_count — number of mocked `git push` invocations in this env.
push_count() { if [[ -s "$PUSH_LOG" ]]; then wc -l < "$PUSH_LOG" | tr -d ' '; else echo 0; fi; }

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
run_bootstrap "$REPO" --session "$SID_UV_OK"
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
run_bootstrap "$REPO" --session "$SID_UV_OK"
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
run_bootstrap "$REPO" --session "$SID_UV_OK"
if [ "$BOOTSTRAP_EXIT" = "2" ]; then
    pass "E3: re-probe shows non-empty remote → exit 2"
else
    fail "E3: expected exit 2, got $BOOTSTRAP_EXIT. out=$BOOTSTRAP_OUT"
fi
teardown_env

# E4: push fails → exit 3, no `gh repo edit`, and the remote is left exactly as it was
# (a real empty bare remote: no heads appear and its HEAD symref is untouched).
setup_env
write_mock_git_push 1 "fatal: unable to push: rejected"
write_mock_gh 0
git init -q --bare -b main "$TMP/remote.git"
git -C "$TMP/remote.git" config core.hooksPath /dev/null
git -C "$REPO" remote add origin "$TMP/remote.git"
E4_HEADS_BEFORE="$(git -C "$TMP/remote.git" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
E4_SYMREF_BEFORE="$(git -C "$TMP/remote.git" symbolic-ref HEAD)"
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO" --session "$SID_UV_OK"
E4_EDITS="$(grep -c "repo edit" "$GH_LOG" 2>/dev/null || true)"
E4_HEADS_AFTER="$(git -C "$TMP/remote.git" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
E4_SYMREF_AFTER="$(git -C "$TMP/remote.git" symbolic-ref HEAD)"
if [ "$BOOTSTRAP_EXIT" = "3" ]; then
    pass "E4: push fails → exit 3"
else
    fail "E4: expected exit 3, got $BOOTSTRAP_EXIT. out=$BOOTSTRAP_OUT"
fi
if [ "$(push_count)" = "1" ]; then
    pass "E4: the failing push was attempted exactly once"
else
    fail "E4: expected 1 push attempt, got $(push_count)"
fi
if [ "${E4_EDITS:-0}" = "0" ]; then
    pass "E4: push failure → gh repo edit invoked 0 times"
else
    fail "E4: expected 0 gh repo edit calls after a failed push, got $E4_EDITS. gh log: $(cat "$GH_LOG")"
fi
if [ -z "$E4_HEADS_BEFORE" ] && [ "$E4_HEADS_AFTER" = "$E4_HEADS_BEFORE" ] \
    && [ "$E4_SYMREF_AFTER" = "$E4_SYMREF_BEFORE" ]; then
    pass "E4: remote default branch unchanged (no heads, HEAD symref $E4_SYMREF_AFTER)"
else
    fail "E4: remote changed: heads before=[$E4_HEADS_BEFORE] after=[$E4_HEADS_AFTER] symref before=[$E4_SYMREF_BEFORE] after=[$E4_SYMREF_AFTER]"
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
run_bootstrap "$REPO" --session "$SID_UV_OK"
DBS="$(json_field default_branch_set)"
if [ "$BOOTSTRAP_EXIT" = "0" ] && [ "$DBS" = "false" ]; then
    pass "E5: gh repo edit fails → warn only, default_branch_set=false"
else
    fail "E5: expected exit 0 + default_branch_set=false, got exit=$BOOTSTRAP_EXIT dbs=$DBS out=$BOOTSTRAP_OUT"
fi
teardown_env

# ============================================================================
# user_verification gate (F4): the push to the default branch of an empty
# remote must not bypass UV. Exit 4 = UV not complete; exit 1 = bad session id.
# ============================================================================

# expect_blocked <label> <want-exit> [<stderr-substring>] — exit code + zero pushes + no gh repo edit.
expect_blocked() {
    local label="$1" want="$2" needle="${3:-}" pushes edits
    pushes="$(push_count)"
    edits="$(grep -c "repo edit" "$GH_LOG" 2>/dev/null || true)"
    edits="${edits:-0}"
    if [[ "$BOOTSTRAP_EXIT" == "$want" && "$pushes" == "0" && "$edits" == "0" ]] \
        && { [[ -z "$needle" ]] || [[ "$BOOTSTRAP_OUT" == *"$needle"* ]]; }; then
        pass "$label"
    else
        fail "$label: want exit=$want pushes=0 repo-edits=0${needle:+ msg~$needle}, got exit=$BOOTSTRAP_EXIT pushes=$pushes repo-edits=$edits out=$BOOTSTRAP_OUT"
    fi
}

# E6: UV recorded but pending → exit 4, no push, stderr names user_verification
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO" --session "$SID_UV_PENDING"
expect_blocked "E6: UV pending → exit 4, no push" 4 user_verification
teardown_env

# E6b: positional form, UV pending → exit 4, no push
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap_positional "$REPO" main example/repo "$SID_UV_PENDING"
expect_blocked "E6b: positional, UV pending → exit 4, no push" 4 user_verification
teardown_env

# E7: no recorded state for the session (read-step-status → NONE) → exit 4, no push
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO" --session "$SID_UV_NONE"
expect_blocked "E7: no state (NONE) → exit 4, no push" 4 user_verification
teardown_env

# E8: no session id supplied → exit 1, no push
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO"
expect_blocked "E8: no --session → exit 1, no push" 1
teardown_env

# E8b: positional form with only 3 args → exit 1, no push
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap_positional "$REPO" main example/repo
expect_blocked "E8b: positional without SESSION_ID → exit 1, no push" 1
teardown_env

# E8c: no env fallback — CLAUDE_CODE_SESSION_ID of a UV-complete session is ignored
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
export CLAUDE_CODE_SESSION_ID="$SID_UV_OK"
run_bootstrap "$REPO"
unset CLAUDE_CODE_SESSION_ID
expect_blocked "E8c: CLAUDE_CODE_SESSION_ID not read → exit 1, no push" 1
teardown_env

# E9: malformed session ids → exit 1, no push (flag and positional forms)
for _bad in 'bad/../id' 'x$(y)' 'a b'; do
    setup_env
    write_mock_git_push 0
    write_mock_gh 0
    export BOOTSTRAP_REPROBE_RESULT=empty-repo
    run_bootstrap "$REPO" --session "$_bad"
    expect_blocked "E9: malformed --session [$_bad] → exit 1, no push" 1
    : > "$PUSH_LOG"
    : > "$GH_LOG"
    run_bootstrap_positional "$REPO" main example/repo "$_bad"
    expect_blocked "E9: malformed positional SESSION_ID [$_bad] → exit 1, no push" 1
    teardown_env
done

# E10: UV check precedes the re-probe — re-probe=ok + UV pending → exit 4 (not 2)
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=ok
run_bootstrap "$REPO" --session "$SID_UV_PENDING"
expect_blocked "E10: UV gate runs before re-probe → exit 4 (not 2)" 4 user_verification
teardown_env

# E11: positional form with SESSION_ID + UV complete → reaches push, exit 0
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap_positional "$REPO" main example/repo "$SID_UV_OK"
SHA="$(json_field bootstrap_commit_sha)"
if [[ "$BOOTSTRAP_EXIT" == "0" && -n "$SHA" && "$(push_count)" == "1" ]]; then
    pass "E11: positional + UV complete → push once, exit 0"
else
    fail "E11: exit=$BOOTSTRAP_EXIT sha=$SHA pushes=$(push_count) out=$BOOTSTRAP_OUT"
fi
teardown_env

# E12: only exactly status=complete proceeds — skipped UV → exit 4, no push
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO" --session "$SID_UV_SKIPPED"
expect_blocked "E12: UV skipped → exit 4, no push" 4 user_verification
teardown_env

# E13: corrupt state file (read-step-status → NONE) → exit 4, no push
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO" --session "$SID_UV_CORRUPT"
expect_blocked "E13: corrupt state → exit 4, no push" 4 user_verification
teardown_env

# E14: flag-style UV complete → exactly one push (E1 asserts the exit; this pins the push)
setup_env
write_mock_git_push 0
write_mock_gh 0
export BOOTSTRAP_REPROBE_RESULT=empty-repo
run_bootstrap "$REPO" --session "$SID_UV_OK"
if [[ "$BOOTSTRAP_EXIT" == "0" && "$(push_count)" == "1" ]]; then
    pass "E14: --session + UV complete → push once"
else
    fail "E14: exit=$BOOTSTRAP_EXIT pushes=$(push_count) out=$BOOTSTRAP_OUT"
fi
teardown_env

# E15: idempotency — a real empty bare remote and the live re-probe (no BOOTSTRAP_REPROBE_RESULT):
# the first run pushes once and edits once; a second run sees a populated remote, exits 2,
# and performs no additional push or gh repo edit.
setup_env
write_mock_gh 0
cat > "$MOCK_DIR/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "push" ]; then echo "git \$*" >> "\${PUSH_MOCK_LOG:-/dev/null}"; break; fi
done
real_git="\$(PATH="\$(echo "\$PATH" | sed 's|$MOCK_DIR:||')" command -v git)"
exec "\$real_git" "\$@"
EOF
chmod +x "$MOCK_DIR/git"
git init -q --bare -b main "$TMP/remote.git"
git -C "$REPO" remote add origin "$TMP/remote.git"
unset BOOTSTRAP_REPROBE_RESULT
run_with_timeout 30 bash "$BOOTSTRAP_COMPLETE" --repo "$REPO" --remote origin --default-branch main --session "$SID_UV_OK" > "$TMP/run1.out" 2>&1
RUN1_EXIT=$?
RUN1_PUSHES="$(push_count)"
RUN1_EDITS="$(grep -c "repo edit" "$GH_LOG" || true)"
run_with_timeout 30 bash "$BOOTSTRAP_COMPLETE" --repo "$REPO" --remote origin --default-branch main --session "$SID_UV_OK" > "$TMP/run2.out" 2>&1
RUN2_EXIT=$?
RUN2_PUSHES="$(push_count)"
RUN2_EDITS="$(grep -c "repo edit" "$GH_LOG" || true)"
REMOTE_MAIN="$(git -C "$TMP/remote.git" rev-parse --verify -q refs/heads/main || true)"
if [[ "$RUN1_EXIT" == "0" && "$RUN1_PUSHES" == "1" && "$RUN1_EDITS" == "1" && -n "$REMOTE_MAIN" ]]; then
    pass "E15: first run against an empty bare remote → push once, repo edit once, remote main set"
else
    fail "E15: run1 exit=$RUN1_EXIT pushes=$RUN1_PUSHES edits=$RUN1_EDITS remote_main=$REMOTE_MAIN out=$(cat "$TMP/run1.out")"
fi
if [[ "$RUN2_EXIT" == "2" && "$RUN2_PUSHES" == "1" && "$RUN2_EDITS" == "1" ]]; then
    pass "E15: second run → exit 2, no additional push or gh repo edit"
else
    fail "E15: run2 exit=$RUN2_EXIT pushes=$RUN2_PUSHES edits=$RUN2_EDITS out=$(cat "$TMP/run2.out")"
fi
teardown_env

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
