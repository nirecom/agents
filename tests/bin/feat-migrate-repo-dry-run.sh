#!/bin/bash
# Tests: bin/github-issues/migration/orchestrate.sh
# Tags: migration, repo, github, issues, bin, scope:issue-specific
# Tests for feat/migrate-repo — orchestrate.sh --dry-run. Dry-run must:
#   - Exit 0
#   - Create no state file, no .github/, no commits
#   - Never invoke gh (mock exits 99 if called)
#   - Print Step 3 ordering gate as SKIPPED
# RED: fails clean while orchestrate.sh is missing.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/orchestrate.sh"

# Keep workflow state and plans writes out of the real $HOME (rules/test/fixture-isolation.md).
ISOLATION_ROOT="$(mktemp -d)"
readonly ISOLATION_ROOT
trap 'rm -rf "$ISOLATION_ROOT"' EXIT
export WORKFLOW_STATE_DIR="$ISOLATION_ROOT/state" WORKFLOW_PLANS_DIR="$ISOLATION_ROOT/plans"

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
missing=()
[ -f "$ORCH_SCRIPT" ] || missing+=("bin/github-issues/migration/orchestrate.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

setup_fixture() {
    TMP="$(mktemp -d)"
    FIXTURE="$TMP/repo"
    mkdir -p "$FIXTURE/docs"
    git init -q "$FIXTURE"
    git -C "$FIXTURE" config core.hooksPath /dev/null
    cat > "$FIXTURE/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1

### Entry 2 (2024-01-02)
Background: test entry 2
Changes: change 2
EOF
    cat > "$FIXTURE/docs/todo.md" <<'EOF'
## Active Work

- task-001: do something
EOF

    # gh-mock for dry-run: log all calls, return sensible no-op values.
    # Destructive calls (issue create/close) must not appear in the log.
    MOCK_DIR="$TMP/mock"
    mkdir -p "$MOCK_DIR"
    cp "$SCRIPT_CHECKOUT_ROOT/tests/fixtures/migration/gh-mock.sh" "$MOCK_DIR/gh"
    chmod +x "$MOCK_DIR/gh"

    MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export MOCK_LOG
    export PATH="$MOCK_DIR:$PATH"
}

teardown_fixture() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG
}

# Run dry-run once and reuse the output across multiple assertions.
setup_fixture
OUT=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$FIXTURE" --dry-run 2>&1)
RC=$?

# --- D1: exits 0
if [ "$RC" -eq 0 ]; then
    pass "D1: orchestrate.sh --dry-run exits 0"
else
    fail "D1: rc=$RC out=$OUT"
fi

# --- D2: no state file
if [ ! -f "$FIXTURE/.migration-state.json" ]; then
    pass "D2: no .migration-state.json created"
else
    fail "D2: state file was created"
fi

# --- D3: no .github/
if [ ! -d "$FIXTURE/.github" ]; then
    pass "D3: no .github/ directory created"
else
    fail "D3: .github/ was created"
fi

# --- D4: Step 3 ordering gate message
if echo "$OUT" | grep -qi "Step 3 ordering gate.*SKIPPED"; then
    pass "D4: Step 3 ordering gate marked SKIPPED"
else
    fail "D4: missing 'Step 3 ordering gate: SKIPPED' in stdout"
fi

# --- D5: no destructive gh calls (issue create / issue close) in dry-run.
# Read-only calls (e.g. gh issue list for pre-flight) are permitted.
destructive=$(grep -E '^gh issue create|^gh issue close' "$MOCK_LOG" 2>/dev/null | wc -l | tr -d ' ')
if [ "$destructive" -eq 0 ]; then
    pass "D5: no destructive gh calls (create/close) in dry-run"
else
    fail "D5: gh called: $(grep -E '^gh issue create|^gh issue close' "$MOCK_LOG" | head -1)"
fi

# --- D6: the backfill step is shown with the repository handed over by flag (#2561).
BACKFILL_LINE="backfill-commit-comments.sh --target-checkout-root $(cd "$FIXTURE" && pwd)"
if printf '%s\n' "$OUT" | grep -qF -- "$BACKFILL_LINE"; then
    pass "D6: backfill step names the repository by --target-checkout-root"
else
    fail "D6: missing '$BACKFILL_LINE' in: $(printf '%s\n' "$OUT" | grep -F backfill-commit-comments)"
fi

teardown_fixture

# --- D7: the self-repo guard sees the same repo through its other worktree.
# A main and a linked worktree of one repo, each holding orchestrate.sh; run from
# one with the other as the target, both directions. A path-string compare misses it.
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
ORCH_REL="bin/github-issues/migration/orchestrate.sh"
setup_fixture
PAIR_MAIN="$TMP/pair-main"
mkdir -p "$PAIR_MAIN/docs"
cp "$FIXTURE/docs/history.md" "$FIXTURE/docs/todo.md" "$PAIR_MAIN/docs/"
pair_ok=0
if script_checkout_fixture_copy "$PAIR_MAIN" bin \
    && git init -q "$PAIR_MAIN" \
    && git -C "$PAIR_MAIN" config core.hooksPath /dev/null \
    && git -C "$PAIR_MAIN" config core.autocrlf false \
    && git -C "$PAIR_MAIN" add -A \
    && git -C "$PAIR_MAIN" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture \
    && git -C "$PAIR_MAIN" worktree add -q -b pair "$TMP/pair-linked"; then
    pair_ok=1
fi
if [ "$pair_ok" -eq 1 ]; then
    PAIR_MAIN="$(cd "$PAIR_MAIN" && pwd -P)"
    PAIR_LINKED="$(cd "$TMP/pair-linked" && pwd -P)"
    for dir in linked-to-main main-to-linked; do
        if [ "$dir" = linked-to-main ]; then from="$PAIR_LINKED"; to="$PAIR_MAIN"; else from="$PAIR_MAIN"; to="$PAIR_LINKED"; fi
        OUT7=$(run_with_timeout 60 bash "$from/$ORCH_REL" "$to" --dry-run 2>&1)
        RC7=$?
        if [ "$RC7" -eq 0 ] && printf '%s\n' "$OUT7" | grep -q "SELF_REPO_DETECTED"; then
            pass "D7[$dir]: the other worktree of the same repo is reported as SELF_REPO_DETECTED"
        else
            fail "D7[$dir]: rc=$RC7, no SELF_REPO_DETECTED in: $(printf '%s\n' "$OUT7" | head -3)"
        fi
    done
else
    fail "D7: worktree pair fixture could not be built"
fi
teardown_fixture

# --- D8-D12: the first run stops on an allowlist file the user has not committed (#2473 run-0021).
commit_fixture() {
    git -C "$FIXTURE" config core.autocrlf false
    git -C "$FIXTURE" config core.excludesFile "$FIXTURE/.git/info/exclude"
    git -C "$FIXTURE" add -A
    git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture
}

# run_orch <args...> — sets RC, STDOUT_TXT and STDERR_TXT. The check runs before the gh pre-flight, so a logged gh call proves the run passed it.
run_orch() {
    env -u MIGRATE_ACK_EXISTING_ISSUES -u MIGRATE_ACK_UP_TO_ISSUE_N -u MIGRATE_ACK_SELF_COUNT_AT_ACK \
        bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 bash "$ORCH_SCRIPT" "$FIXTURE" "$@" \
        > "$TMP/stdout" 2> "$TMP/stderr"
    RC=$?
    STDOUT_TXT="$(cat "$TMP/stdout")"
    STDERR_TXT="$(cat "$TMP/stderr")"
}

# --- D8: live, no state file, dirty allowlist file → stop before gh and state_init.
setup_fixture
printf 'node_modules\n' > "$FIXTURE/.gitignore"
commit_fixture
printf 'node_modules\nmine\n' > "$FIXTURE/.gitignore"
GITIGNORE_BEFORE="$(cat "$FIXTURE/.gitignore")"
run_orch
if [ "$RC" -eq 1 ] && printf '%s\n' "$STDERR_TXT" | grep -qF ".gitignore"; then
    pass "D8a: live first run on a dirty allowlist file exits 1 naming the path on stderr"
else
    fail "D8a: rc=$RC stderr=$STDERR_TXT"
fi
if [ "$RC" -eq 1 ] && [ ! -s "$MOCK_LOG" ]; then
    pass "D8b: gh is never called"
else
    fail "D8b: rc=$RC gh log: $(head -3 "$MOCK_LOG")"
fi
if [ "$RC" -eq 1 ] && [ ! -e "$FIXTURE/.migration-state.json" ] && [ "$(cat "$FIXTURE/.gitignore")" = "$GITIGNORE_BEFORE" ]; then
    pass "D8c: no state file, and .gitignore keeps the user's content"
else
    fail "D8c: rc=$RC state file present=$([ -e "$FIXTURE/.migration-state.json" ] && echo yes || echo no) .gitignore=$(cat "$FIXTURE/.gitignore")"
fi
teardown_fixture

# --- D9: live, state file present → the check does not run. Later steps are not asserted.
setup_fixture
printf 'node_modules\n' > "$FIXTURE/.gitignore"
printf '.migration-state.json\n' >> "$FIXTURE/.gitignore"
commit_fixture
printf '{"schema_version":2,"current_step":1}\n' > "$FIXTURE/.migration-state.json"
printf 'mine\n' >> "$FIXTURE/.gitignore"
run_orch --from-step 2 --ack-skipped-steps
if grep -q '^gh issue list' "$MOCK_LOG"; then
    pass "D9: a run with a state file passes the check and reaches the gh pre-flight"
else
    fail "D9: rc=$RC gh log empty, stderr=$STDERR_TXT"
fi
teardown_fixture

# --- D9d-D9e: --dry-run, state file present, dirty → no warning (D10 warns on the same dirty file without one).
setup_fixture
printf 'node_modules\n.migration-state.json\n' > "$FIXTURE/.gitignore"
commit_fixture
printf '{"schema_version":2,"current_step":1}\n' > "$FIXTURE/.migration-state.json"
printf 'mine\n' >> "$FIXTURE/.gitignore"
run_orch --dry-run
if [[ "$RC" -eq 0 ]] && ! printf '%s\n%s\n' "$STDOUT_TXT" "$STDERR_TXT" | grep -qF "UNCOMMITTED_ALLOWLIST"; then
    pass "D9d: --dry-run with a state file exits 0 with neither UNCOMMITTED_ALLOWLIST warning"
else
    fail "D9d: rc=$RC stdout=$(printf '%s\n' "$STDOUT_TXT" | grep -F UNCOMMITTED_ALLOWLIST) stderr=$STDERR_TXT"
fi
if printf '%s\n' "$STDOUT_TXT" | grep -qi "Step 3 ordering gate.*SKIPPED"; then
    pass "D9e: --dry-run with a state file continues through the steps"
else
    fail "D9e: dry-run did not reach Step 3 (rc=$RC) stderr=$STDERR_TXT"
fi
teardown_fixture

# --- D10: --dry-run, no state file, dirty → WARNING names the path and the run continues.
setup_fixture
printf 'node_modules\n' > "$FIXTURE/.gitignore"
commit_fixture
printf 'mine\n' >> "$FIXTURE/.gitignore"
run_orch --dry-run
if [ "$RC" -eq 0 ] && printf '%s\n%s\n' "$STDOUT_TXT" "$STDERR_TXT" | tr -d '\r' | grep -qxF "WARNING: UNCOMMITTED_ALLOWLIST: .gitignore"; then
    pass "D10a: --dry-run warns with UNCOMMITTED_ALLOWLIST and exits 0"
else
    fail "D10a: rc=$RC stdout=$(printf '%s\n' "$STDOUT_TXT" | head -5) stderr=$STDERR_TXT"
fi
if printf '%s\n' "$STDOUT_TXT" | grep -qi "Step 3 ordering gate.*SKIPPED"; then
    pass "D10b: --dry-run continues through the steps after the warning"
else
    fail "D10b: dry-run did not reach Step 3 (rc=$RC)"
fi
if [ "$RC" -eq 0 ] && [ ! -e "$FIXTURE/.migration-state.json" ]; then
    pass "D10c: a dirty --dry-run leaves no state file"
else
    fail "D10c: rc=$RC state file present=$([ -e "$FIXTURE/.migration-state.json" ] && echo yes || echo no)"
fi
teardown_fixture

# --- D11: --dry-run, clean → no WARNING.
setup_fixture
commit_fixture
run_orch --dry-run
if [ "$RC" -eq 0 ] && ! printf '%s\n%s\n' "$STDOUT_TXT" "$STDERR_TXT" | grep -qF "UNCOMMITTED_ALLOWLIST"; then
    pass "D11: --dry-run on a clean allowlist gives no warning"
else
    fail "D11: rc=$RC stdout=$(printf '%s\n' "$STDOUT_TXT" | grep -F UNCOMMITTED_ALLOWLIST)"
fi
teardown_fixture

# --- D12: live, no state file, clean → the check lets the run through to the --stage gate.
setup_fixture
commit_fixture
run_orch --from-step 2 --ack-skipped-steps
if grep -q '^gh issue list' "$MOCK_LOG" && printf '%s\n' "$STDERR_TXT" | grep -q -- "requires --stage"; then
    pass "D12: a clean first run passes the check and reaches the --stage gate"
else
    fail "D12: rc=$RC stderr=$STDERR_TXT"
fi
teardown_fixture

# --- D13-D14: a target that is no git checkout makes the check itself fail (exit 1).
setup_non_git_fixture() {
    setup_fixture
    rm -rf "$FIXTURE/.git"
    export GIT_CEILING_DIRECTORIES="$TMP"
    if git -C "$FIXTURE" rev-parse --git-dir >/dev/null 2>&1; then
        fail "D13-D14 precondition: the fixture still resolves to a git repository"
    fi
}

# --- D13: live → stop before gh and state_init.
setup_non_git_fixture
run_orch
if [ "$RC" -eq 1 ] && [ ! -s "$MOCK_LOG" ]; then
    pass "D13a: live on a target that is no git checkout exits 1 and never calls gh"
else
    fail "D13a: rc=$RC gh log: $(head -3 "$MOCK_LOG") stderr=$STDERR_TXT"
fi
if [ "$RC" -eq 1 ] && [ ! -e "$FIXTURE/.migration-state.json" ] && [ ! -e "$FIXTURE/.gitignore" ]; then
    pass "D13b: no state file and no .gitignore are written"
else
    fail "D13b: rc=$RC state file present=$([ -e "$FIXTURE/.migration-state.json" ] && echo yes || echo no) .gitignore present=$([ -e "$FIXTURE/.gitignore" ] && echo yes || echo no)"
fi
unset GIT_CEILING_DIRECTORIES
teardown_fixture

# --- D14: --dry-run → WARNING and the run continues.
setup_non_git_fixture
run_orch --dry-run
if [ "$RC" -eq 0 ] && printf '%s\n%s\n' "$STDOUT_TXT" "$STDERR_TXT" | grep -qF "WARNING: UNCOMMITTED_ALLOWLIST_CHECK_FAILED"; then
    pass "D14a: --dry-run warns with UNCOMMITTED_ALLOWLIST_CHECK_FAILED and exits 0"
else
    fail "D14a: rc=$RC stdout=$(printf '%s\n' "$STDOUT_TXT" | head -5) stderr=$STDERR_TXT"
fi
if printf '%s\n' "$STDOUT_TXT" | grep -qi "Step 3 ordering gate.*SKIPPED"; then
    pass "D14b: --dry-run continues through the steps after the warning"
else
    fail "D14b: dry-run did not reach Step 3 (rc=$RC) stderr=$STDERR_TXT"
fi
if [ "$RC" -eq 0 ] && [ ! -e "$FIXTURE/.migration-state.json" ]; then
    pass "D14c: the --dry-run leaves no state file"
else
    fail "D14c: rc=$RC state file present=$([ -e "$FIXTURE/.migration-state.json" ] && echo yes || echo no)"
fi
unset GIT_CEILING_DIRECTORIES
teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
