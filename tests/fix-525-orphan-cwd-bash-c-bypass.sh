#!/usr/bin/env bash
# tests/fix-525-orphan-cwd-bash-c-bypass.sh
# Tests: hooks/enforce-worktree.js Change ④ (lines 358-368)
# Tags: enforce-worktree, orphan-cwd, bash-c, fail-closed, issue-525
#
# Change ④: when repoRoot is null (non-git CWD or parseFailure) and toolName is
# Bash, block (fail-closed). Previously, null repoRoot in Bash path fell through
# to main-checkout logic and ultimately allowed the command (fail-open).
#
# Expected: All T1.x tests PASS (fix is already in place).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}/fix-525-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

# ─────────────────────────────────────────────────────────────────────────────
# Setup helpers
# ─────────────────────────────────────────────────────────────────────────────

setup_main_repo() {
  local name="$1"
  local repo="$TMPDIR_BASE/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config core.hooksPath /dev/null
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial" 2>/dev/null
  echo "$repo"
}

setup_orphan_dir() {
  local name="$1"
  local dir="$TMPDIR_BASE/$name"
  mkdir -p "$dir"
  echo "$dir"
}

# Build JSON payload and run enforce-worktree.js from the given cwd.
# Extra env key=value pairs can be passed after cwd.
run_bash_guard() {
  local cmd="$1" cwd="$2"
  shift 2
  local env_args=()
  local kv
  for kv in "$@"; do env_args+=("$kv"); done

  local payload
  payload="$(node -e '
const data = { tool_name: "Bash", tool_input: { command: process.argv[1] }, cwd: process.argv[2] };
process.stdout.write(JSON.stringify(data));
' -- "$cmd" "$cwd")"

  ( cd "$cwd" && env -i PATH="$PATH" HOME="${HOME:-$TMPDIR_BASE}" \
      "${env_args[@]}" \
      node "$AGENTS_DIR/hooks/enforce-worktree.js" <<< "$payload" )
}

# Check helpers
guard_blocks() {
  # Hook outputs {"decision":"block",...} or {"block":true,...} when blocking.
  local out="$1"
  echo "$out" | grep -qE '"decision"\s*:\s*"block"|"block"\s*:\s*true'
}

guard_allows() {
  ! guard_blocks "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== fix-525: orphan-cwd bash-c bypass ==="
echo ""

# T1.1: orphan dir + bash -c "cd <main> && git push origin main" → BLOCK
# Change ④: repoRoot resolves from cd-arg to main, but CWD is orphan.
# findRepoRootForBash uses parseCdCommand → resolves main as startDir → finds
# repo root → but then isMainCheckout(main) → true → block via mainCheckout guard.
test_t1_1() {
  local main; main="$(setup_main_repo "t1-1-main")"
  local orphan; orphan="$(setup_orphan_dir "t1-1-orphan")"
  local cmd="bash -c \"cd $main && git push origin main\""
  local out; out="$(run_bash_guard "$cmd" "$orphan" ENFORCE_WORKTREE=on)"
  if guard_blocks "$out"; then
    pass "T1.1: orphan + bash-c cd <main> && git push → BLOCK"
  else
    fail "T1.1: orphan + bash-c cd <main> && git push should BLOCK (got: $out)"
  fi
}

# T1.2: orphan dir + bash -c "cd <main> && echo x >> README.md" → BLOCK
test_t1_2() {
  local main; main="$(setup_main_repo "t1-2-main")"
  local orphan; orphan="$(setup_orphan_dir "t1-2-orphan")"
  local cmd="bash -c \"cd $main && echo x >> README.md\""
  local out; out="$(run_bash_guard "$cmd" "$orphan" ENFORCE_WORKTREE=on)"
  if guard_blocks "$out"; then
    pass "T1.2: orphan + bash-c cd <main> && echo >> README.md → BLOCK"
  else
    fail "T1.2: orphan + bash-c cd <main> && echo >> README.md should BLOCK (got: $out)"
  fi
}

# T1.3: orphan dir + bash -c "echo x > /tmp/fix525-test.txt" (no cd) → BLOCK
# parseCdCommand finds no cd → startDir = process.cwd() = orphan (non-git) →
# findRepoRootForBash returns null → Change ④ fires → BLOCK.
test_t1_3() {
  local orphan; orphan="$(setup_orphan_dir "t1-3-orphan")"
  local tmpout="$TMPDIR_BASE/fix525-test-t13.txt"
  local cmd="bash -c \"echo x > $tmpout\""
  local out; out="$(run_bash_guard "$cmd" "$orphan" ENFORCE_WORKTREE=on)"
  if guard_blocks "$out"; then
    pass "T1.3: orphan + bash-c echo > /tmp/... (no cd) → BLOCK (fail-closed, no repo root)"
  else
    fail "T1.3: orphan + bash-c echo > /tmp/... should BLOCK via Change ④ (got: $out)"
  fi
}

# T1.4: orphan dir + bash -c "ls /tmp" → check actual source behavior.
# classify("bash -c 'ls /tmp'") → interpreter-c matches, then isReadOnlyInterpreterC
# checks inner body "ls /tmp" → read-only → classify returns "read" → ALLOW early
# (before Change ④ is reached, at line 173: if classify(cmd) !== "write" done()).
test_t1_4() {
  local orphan; orphan="$(setup_orphan_dir "t1-4-orphan")"
  local cmd='bash -c "ls /tmp"'
  local out; out="$(run_bash_guard "$cmd" "$orphan" ENFORCE_WORKTREE=on)"
  if guard_allows "$out"; then
    pass "T1.4: orphan + bash-c ls /tmp → ALLOW (isReadOnlyInterpreterC early-return)"
  else
    fail "T1.4: orphan + bash-c ls /tmp should ALLOW (got: $out)"
  fi
}

# T1.5: main-worktree CWD + bash -c "cd <orphan> && git push" → BLOCK
# CWD is main repo. parseCdCommand finds orphan → startDir = orphan (non-git) →
# findRepoRootForBash returns null → Change ④ fires → BLOCK.
# Alternative: parseCdCommand ignores cd to non-git → falls back to CWD (main) →
# repoRoot = main → isMainCheckout → BLOCK via mainCheckout guard.
test_t1_5() {
  local main; main="$(setup_main_repo "t1-5-main")"
  local orphan; orphan="$(setup_orphan_dir "t1-5-orphan")"
  local cmd="bash -c \"cd $orphan && git push\""
  local out; out="$(run_bash_guard "$cmd" "$main" ENFORCE_WORKTREE=on)"
  if guard_blocks "$out"; then
    pass "T1.5: main CWD + bash-c cd <orphan> && git push → BLOCK"
  else
    fail "T1.5: main CWD + bash-c cd <orphan> && git push should BLOCK (got: $out)"
  fi
}

# T1.6: orphan dir + bash -c "cd /tmp; cd <main>; git push" → BLOCK
# parseCdCommand parses first absolute cd = /tmp (non-git) → startDir=/tmp →
# findRepoRootForBash returns null → Change ④ fires → BLOCK.
test_t1_6() {
  local main; main="$(setup_main_repo "t1-6-main")"
  local orphan; orphan="$(setup_orphan_dir "t1-6-orphan")"
  local cmd="bash -c \"cd /tmp; cd $main; git push\""
  local out; out="$(run_bash_guard "$cmd" "$orphan" ENFORCE_WORKTREE=on)"
  if guard_blocks "$out"; then
    pass "T1.6: orphan + bash-c cd /tmp; cd <main>; git push → BLOCK (first cd=/tmp → null repoRoot)"
  else
    fail "T1.6: orphan + bash-c cd /tmp; cd <main>; git push should BLOCK (got: $out)"
  fi
}

# T1.7: orphan dir + bash -c "cd <main> && cd <orphan> && git push" → BLOCK
# parseCdCommand parses first absolute cd = main → startDir = main →
# findRepoRootForBash finds main as repo root → isMainCheckout(main) → BLOCK.
test_t1_7() {
  local main; main="$(setup_main_repo "t1-7-main")"
  local orphan; orphan="$(setup_orphan_dir "t1-7-orphan")"
  local cmd="bash -c \"cd $main && cd $orphan && git push\""
  local out; out="$(run_bash_guard "$cmd" "$orphan" ENFORCE_WORKTREE=on)"
  if guard_blocks "$out"; then
    pass "T1.7: orphan + bash-c cd <main> && cd <orphan> && git push → BLOCK (first cd=main → mainCheckout)"
  else
    fail "T1.7: orphan + bash-c cd <main> && cd <orphan> && git push should BLOCK (got: $out)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Runner
# ─────────────────────────────────────────────────────────────────────────────

test_t1_1
test_t1_2
test_t1_3
test_t1_4
test_t1_5
test_t1_6
test_t1_7

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
