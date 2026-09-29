#!/usr/bin/env bash
# Tests: bin/stage-review-scope-files.js
# Tags: workflow, review-tests, scope-delta, cli, TL2, scope:issue-specific
#
# Tests for bin/stage-review-scope-files.js:
#   STAGED output, SKIPPED tests/excluded/outside-worktree, untracked, deletions,
#   exit 2/3 error paths, /c/... style worktree path.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

CLI="$AGENTS_DIR/bin/stage-review-scope-files.js"
CLI_EXISTS=1
[ -f "$CLI" ] || CLI_EXISTS=0

TMPDIR_BASE="$(make_tmp)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE"

# Fixture git repo
REPO="$TMPDIR_BASE/repo"
harness_git_init "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Initial commit
mkdir -p "$REPO/skills/x" "$REPO/rules" "$REPO/docs" "$REPO/tests/a" "$REPO/bin"
echo "SKILL" > "$REPO/skills/x/SKILL.md"
echo "rule" > "$REPO/rules/y.md"
echo "doc" > "$REPO/docs/x.md"
echo "# test" > "$REPO/tests/a/b.sh"
echo "initial" > "$REPO/CHANGELOG.md"
echo "readme" > "$REPO/README.md"
git -C "$REPO" add .
git -C "$REPO" commit -q -m "init"

REPO_NP="$(np "$REPO")"

run_cli() {
  run_with_timeout 15 node "$(np "$CLI")" "$@"
}

# ============================================================
# T1: exit 2 when no --worktree argument
# ============================================================
T1() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T1.exit2-no-worktree" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  local rc=0
  run_cli 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] && pass "T1. no --worktree → exit 2" || fail "T1. no --worktree → exit 2" "got exit $rc"
}

# ============================================================
# T2: exit 3 when worktree is not a git repository
# ============================================================
T2() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T2.exit3-not-git" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  local noRepo="$TMPDIR_BASE/notgit"
  mkdir -p "$noRepo"
  local rc=0
  run_cli --worktree "$(np "$noRepo")" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] && pass "T2. non-git worktree → exit 3" || fail "T2. non-git worktree → exit 3" "got exit $rc"
}

# ============================================================
# T3: STAGED for modified tracked file and untracked new file (both in args)
# ============================================================
T3() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T3.staged-modified-and-untracked" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  # Modify tracked skill
  echo "SKILL v2" > "$REPO/skills/x/SKILL.md"
  # New untracked impl file
  echo "new tool" > "$REPO/bin/new-tool"
  local out rc=0
  out=$(run_cli --worktree "$REPO_NP" "$REPO_NP/skills/x/SKILL.md" "$REPO_NP/bin/new-tool" 2>/dev/null) || rc=$?
  local staged_skill staged_new
  staged_skill=$(printf '%s\n' "$out" | grep "^STAGED" | grep -c "SKILL.md" || true)
  staged_new=$(printf '%s\n' "$out" | grep "^STAGED" | grep -c "new-tool" || true)
  # Clean up index for later tests
  git -C "$REPO" restore --staged skills/x/SKILL.md bin/new-tool 2>/dev/null || true
  git -C "$REPO" checkout -- skills/x/SKILL.md 2>/dev/null || true
  rm -f "$REPO/bin/new-tool"
  [ "$staged_skill" -ge 1 ] && pass "T3. STAGED for modified SKILL.md" || fail "T3. STAGED for modified SKILL.md" "$out"
  [ "$staged_new" -ge 1 ] && pass "T3. STAGED for untracked new-tool" || fail "T3. STAGED for untracked new-tool" "$out"
}

# ============================================================
# T4: SKIPPED test for tests/a/b.sh; SKIPPED excluded for docs, CHANGELOG.md, README.md
# ============================================================
T4() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T4.skipped-categories" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  # Modify all these files so they would otherwise be stageable
  echo "test mod" >> "$REPO/tests/a/b.sh"
  echo "doc mod" >> "$REPO/docs/x.md"
  echo "changelog mod" >> "$REPO/CHANGELOG.md"
  echo "readme mod" >> "$REPO/README.md"
  local out
  out=$(run_cli --worktree "$REPO_NP" \
    "$REPO_NP/tests/a/b.sh" \
    "$REPO_NP/docs/x.md" \
    "$REPO_NP/CHANGELOG.md" \
    "$REPO_NP/README.md" 2>/dev/null) || true
  # Restore
  git -C "$REPO" checkout -- tests/a/b.sh docs/x.md CHANGELOG.md README.md 2>/dev/null || true
  local skip_test skip_docs skip_chg skip_rdme
  skip_test=$(printf '%s\n' "$out" | grep "SKIPPED" | grep "b.sh" | grep -ci "test" || true)
  skip_docs=$(printf '%s\n' "$out" | grep "SKIPPED" | grep "x.md" | grep -ci "excluded" || true)
  skip_chg=$(printf '%s\n' "$out" | grep "SKIPPED" | grep "CHANGELOG" | grep -ci "excluded" || true)
  skip_rdme=$(printf '%s\n' "$out" | grep "SKIPPED" | grep "README" | grep -ci "excluded" || true)
  [ "$skip_test" -ge 1 ] && pass "T4. SKIPPED test for tests/a/b.sh" || fail "T4. SKIPPED test for tests/a/b.sh" "$out"
  [ "$skip_docs" -ge 1 ] && pass "T4. SKIPPED excluded for docs/x.md" || fail "T4. SKIPPED excluded for docs/x.md" "$out"
  [ "$skip_chg" -ge 1 ] && pass "T4. SKIPPED excluded for CHANGELOG.md" || fail "T4. SKIPPED excluded for CHANGELOG.md" "$out"
  [ "$skip_rdme" -ge 1 ] && pass "T4. SKIPPED excluded for README.md" || fail "T4. SKIPPED excluded for README.md" "$out"
}

# ============================================================
# T5: tracked unstaged change NOT in args also gets staged (rules/y.md)
#     untracked file NOT in args is NOT staged
# ============================================================
T5() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T5.tracked-unstaged-auto-staged" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  # Modify tracked impl file not in args
  echo "rule v2" > "$REPO/rules/y.md"
  # New untracked file not in args
  echo "invisible" > "$REPO/bin/unseen-file"
  # Also modify skills/x/SKILL.md which IS in args
  echo "SKILL v3" > "$REPO/skills/x/SKILL.md"
  local out
  out=$(run_cli --worktree "$REPO_NP" "$REPO_NP/skills/x/SKILL.md" 2>/dev/null) || true
  local staged_rule staged_unseen
  staged_rule=$(printf '%s\n' "$out" | grep "^STAGED" | grep -c "y.md" || true)
  staged_unseen=$(printf '%s\n' "$out" | grep "^STAGED" | grep -c "unseen-file" || true)
  # Clean up
  git -C "$REPO" restore --staged skills/x/SKILL.md rules/y.md 2>/dev/null || true
  git -C "$REPO" checkout -- skills/x/SKILL.md rules/y.md 2>/dev/null || true
  rm -f "$REPO/bin/unseen-file"
  [ "$staged_rule" -ge 1 ] && pass "T5. tracked unstaged rules/y.md auto-staged" \
    || fail "T5. tracked unstaged rules/y.md auto-staged" "$out"
  [ "$staged_unseen" -eq 0 ] && pass "T5. untracked not-in-args NOT staged" \
    || fail "T5. untracked not-in-args NOT staged" "$out"
}

# ============================================================
# T6: deleted file in args → deletion staged
# ============================================================
T6() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T6.deletion-staged" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  # Add an impl file, commit it, then delete it
  echo "to be removed" > "$REPO/bin/old-tool.js"
  git -C "$REPO" add bin/old-tool.js
  git -C "$REPO" commit -q -m "add old-tool.js"
  rm -f "$REPO/bin/old-tool.js"
  local out rc=0
  out=$(run_cli --worktree "$REPO_NP" "$REPO_NP/bin/old-tool.js" 2>/dev/null) || rc=$?
  # Verify it was staged as deletion (git status should show D in index)
  local staged_del
  staged_del=$(git -C "$REPO" diff --cached --name-status 2>/dev/null | grep -c "^D.*old-tool" || true)
  # Restore
  git -C "$REPO" restore --staged bin/old-tool.js 2>/dev/null || true
  [ "$staged_del" -ge 1 ] && pass "T6. deleted file in args → deletion staged" \
    || fail "T6. deleted file in args → deletion staged" "out=$out staged_del=$staged_del"
}

# ============================================================
# T7: path outside worktree → SKIPPED outside-worktree
# ============================================================
T7() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T7.outside-worktree" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  # Use a path that is definitely outside REPO
  local outsidePath
  outsidePath="$(np "$TMPDIR_BASE")/outside/impl.js"
  mkdir -p "$(dirname "$outsidePath")" 2>/dev/null || true
  echo "outside" > "$outsidePath" 2>/dev/null || true
  local out
  out=$(run_cli --worktree "$REPO_NP" "$outsidePath" 2>/dev/null) || true
  local skip_outside
  skip_outside=$(printf '%s\n' "$out" | grep "SKIPPED" | grep -c "outside-worktree" || true)
  [ "$skip_outside" -ge 1 ] && pass "T7. outside worktree → SKIPPED outside-worktree" \
    || fail "T7. outside worktree → SKIPPED outside-worktree" "$out"
}

# ============================================================
# T8: /c/... POSIX drive-letter worktree path accepted
# ============================================================
T8() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T8./c/-path" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  if ! command -v cygpath >/dev/null 2>&1; then skip "T8. /c/... path — cygpath not available (non-Windows)"; return; fi
  # Build the /<drive>/... spelling by hand: `cygpath -u` would pick the /tmp mount instead.
  local win posixRepo drive
  win="$(cygpath -m "$REPO")"
  drive="$(printf '%s' "${win:0:1}" | tr 'A-Z' 'a-z')"
  posixRepo="/${drive}${win:2}"
  case "$posixRepo" in
    /[a-z]/*) ;;
    *) fail "T8. fixture path is /<drive>/..." "got $posixRepo"; return ;;
  esac
  echo "rule t8" > "$REPO/rules/y.md"
  echo "SKILL t8" > "$REPO/skills/x/SKILL.md"
  local out rc=0 tab=$'\t' want got
  out=$(run_cli --worktree "$posixRepo" "$posixRepo/skills/x/SKILL.md" 2>/dev/null) || rc=$?
  git -C "$REPO" restore --staged skills/x/SKILL.md rules/y.md 2>/dev/null || true
  git -C "$REPO" checkout -- skills/x/SKILL.md rules/y.md 2>/dev/null || true
  [ "$rc" -eq 0 ] && pass "T8. /c/... worktree path → exit 0" \
    || fail "T8. /c/... worktree path → exit 0" "got exit $rc; $out"
  want="$(printf '%s\n' "STAGED${tab}rules/y.md" "STAGED${tab}skills/x/SKILL.md")"
  got="$(printf '%s\n' "$out" | tr -d '\r' | grep -v '^$')"
  [ "$got" = "$want" ] && pass "T8. /c/... worktree and path arg → exact STAGED output" \
    || fail "T8. /c/... worktree and path arg → exact STAGED output" "want=[$want] got=[$got]"
}

# ============================================================
# T9: a path with glob characters is staged literally — the argument
#     bin/[x].txt stages only itself, never the untracked bin/x.txt it
#     would match as a glob pathspec
# ============================================================
T9() {
  if [ "$CLI_EXISTS" -eq 0 ]; then fail "T9.literal-glob-path" "bin/stage-review-scope-files.js not yet implemented"; return; fi
  echo "bracket" > "$REPO/bin/[x].txt"
  echo "plain" > "$REPO/bin/x.txt"
  local out cached
  out=$(run_cli --worktree "$REPO_NP" "$REPO_NP/bin/[x].txt" 2>/dev/null) || true
  cached=$(git -C "$REPO" diff --cached --name-only 2>/dev/null)
  # Clean up
  git -C "$REPO" --literal-pathspecs restore --staged "bin/[x].txt" "bin/x.txt" 2>/dev/null || true
  rm -f "$REPO/bin/[x].txt" "$REPO/bin/x.txt"
  printf '%s\n' "$cached" | grep -qxF "bin/[x].txt" \
    && pass "T9. bin/[x].txt staged" || fail "T9. bin/[x].txt staged" "out=$out cached=$cached"
  printf '%s\n' "$cached" | grep -qxF "bin/x.txt" \
    && fail "T9. unrelated bin/x.txt NOT staged" "cached=$cached" || pass "T9. unrelated bin/x.txt NOT staged"
}

T1
T2
T3
T4
T5
T6
T7
T8
T9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
