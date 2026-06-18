#!/usr/bin/env bash
# Tests: bin/compute-staged-tests-token.js
# Tags: scope:issue-specific, workflow-gate, review-tests, staged-token
# RED for issue #882 — TDD: CLI does not exist yet.
#
# `bin/compute-staged-tests-token.js` resolves the correct repo dir for
# computing a staged-tests fingerprint when invoked from the main worktree
# (e.g. from PreCompact / Stop hooks where process.cwd() is the main
# checkout, not the linked worktree where the user staged tests).
#
# Contract (planned):
#   1. Enumerate worktrees via `git worktree list --porcelain`.
#   2. For each non-main worktree, check `git diff --cached --name-only -z`
#      for paths starting with `tests/` or `test/`.
#   3. First worktree with staged tests → call
#      computeStagedTestsToken(repoDir) from
#      hooks/workflow-gate/review-tests-evidence.js and print to stdout.
#   4. None found → fail-open to process.cwd().
#   5. Always exits 0; all exceptions swallowed.
#
# L3 gap: real Claude Code Stop/PreCompact hook integration is exercised
# only at the orchestration layer; this test pins the CLI contract only.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$AGENTS_DIR/bin/compute-staged-tests-token.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"
    else perl -e 'alarm 60; exec @ARGV' -- "$@"; fi
}

# Per-run temp dir (use Node tmpdir for Windows path consistency).
TMP_ROOT="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
TEST_ROOT="$TMP_ROOT/compute-staged-tests-token-$$"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT" 2>/dev/null || true' EXIT

# Set AGENTS_CONFIG_DIR so the CLI can require() review-tests-evidence.js.
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

# ── CLI existence check (TDD gate) ────────────────────────────────────────
if [ ! -f "$CLI" ]; then
    skip "CLI bin/compute-staged-tests-token.js does not exist yet (TDD: write-code will create it)"
    echo ""
    echo "=== Results ==="
    echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    # Exit non-zero so the test reports RED until the CLI is implemented.
    exit 1
fi

# ── Helper: build a git repo with optional linked worktree + staged file ──
# $1 = scenario dir, $2 = staged path in linked worktree (empty = none),
# $3 = create linked worktree? ("yes"/"no")
setup_repo() {
    local scenario="$1" staged_rel="$2" make_linked="$3"
    local main="$scenario/main"
    mkdir -p "$main"
    (
        cd "$main" || exit 1
        git init -q -b main
        git config user.email "test@example.com"
        git config user.name "test"
        echo "seed" > README.md
        git add README.md
        git -c commit.gpgsign=false commit -q -m "seed"
    )
    if [ "$make_linked" = "yes" ]; then
        local linked="$scenario/linked"
        (
            cd "$main" || exit 1
            git worktree add -q -b "feat-$$-$RANDOM" "$linked" >/dev/null 2>&1
        )
        if [ -n "$staged_rel" ]; then
            local staged_abs="$linked/$staged_rel"
            mkdir -p "$(dirname "$staged_abs")"
            echo "test body" > "$staged_abs"
            (cd "$linked" && git add "$staged_rel")
        fi
    fi
    echo "$main"
}

# ── CST-NORMAL-1: linked worktree with staged tests/ file → non-empty token ──
echo "=== CST-NORMAL-1: linked worktree with staged tests/dummy.sh ==="
SC1="$TEST_ROOT/sc1"
MAIN1=$(setup_repo "$SC1" "tests/dummy.sh" "yes")
OUT1=$(cd "$MAIN1" && run_with_timeout node "$CLI" 2>/dev/null)
RC1=$?
if [ $RC1 -ne 0 ]; then
    fail "CST-NORMAL-1 CLI exited non-zero (rc=$RC1)"
elif [ -z "$OUT1" ]; then
    fail "CST-NORMAL-1 expected non-empty token, got empty stdout"
elif [ ${#OUT1} -lt 8 ]; then
    fail "CST-NORMAL-1 token suspiciously short: '$OUT1'"
else
    pass "CST-NORMAL-1 produced token: $OUT1"
fi

# ── CST-NORMAL-2: main only, no staged files → empty stdout + exit 0 ─────
echo "=== CST-NORMAL-2: main worktree only, nothing staged ==="
SC2="$TEST_ROOT/sc2"
MAIN2=$(setup_repo "$SC2" "" "no")
OUT2=$(cd "$MAIN2" && run_with_timeout node "$CLI" 2>/dev/null)
RC2=$?
if [ $RC2 -ne 0 ]; then
    fail "CST-NORMAL-2 expected exit 0, got rc=$RC2"
elif [ -n "$OUT2" ]; then
    fail "CST-NORMAL-2 expected empty stdout, got: '$OUT2'"
else
    pass "CST-NORMAL-2 empty stdout + exit 0"
fi

# ── CST-EDGE-1: linked worktree with staged non-tests file ────────────────
echo "=== CST-EDGE-1: linked worktree with staged README.md (not tests/) ==="
SC3="$TEST_ROOT/sc3"
MAIN3=$(setup_repo "$SC3" "" "yes")
# stage a non-test file in the linked worktree
LINKED3="$SC3/linked"
echo "edit" >> "$LINKED3/README.md"
(cd "$LINKED3" && git add README.md)
OUT3=$(cd "$MAIN3" && run_with_timeout node "$CLI" 2>/dev/null)
RC3=$?
if [ $RC3 -ne 0 ]; then
    fail "CST-EDGE-1 expected exit 0, got rc=$RC3"
else
    # Either empty stdout (no tests staged in any worktree) OR a fail-open
    # token from process.cwd() — both are documented as acceptable.
    pass "CST-EDGE-1 exit 0 (stdout='$OUT3'; empty or fail-open token both acceptable)"
fi

# ── CST-ERROR-1: non-git directory → exit 0 + empty stdout ────────────────
echo "=== CST-ERROR-1: CLI run from non-git directory ==="
SC4="$TEST_ROOT/sc4-not-a-repo"
mkdir -p "$SC4"
OUT4=$(cd "$SC4" && run_with_timeout node "$CLI" 2>/dev/null)
RC4=$?
if [ $RC4 -ne 0 ]; then
    fail "CST-ERROR-1 expected exit 0, got rc=$RC4"
elif [ -n "$OUT4" ]; then
    fail "CST-ERROR-1 expected empty stdout, got: '$OUT4'"
else
    pass "CST-ERROR-1 non-git dir → empty stdout + exit 0"
fi

# ── Results ───────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
