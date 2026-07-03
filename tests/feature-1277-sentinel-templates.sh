#!/usr/bin/env bash
# Tests: bin/review-sentinel-templates
# Tags: scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Behavior differences between Git Bash on Windows and bash on Linux/macOS for git diff output
# - Interaction with actual git remote state (origin/main) in a real repo
# Closest-to-action mitigation: run-tests step will validate on the actual repo after write-code.
set -uo pipefail

PASS=0; FAIL=0

SCRIPT="$AGENTS_CONFIG_DIR/bin/review-sentinel-templates"
[ -x "$SCRIPT" ] || { echo "SKIP: bin/review-sentinel-templates not found — skipping tests"; exit 77; }

# ---------------------------------------------------------------------------
# Portable timeout wrapper (from rules/test/macos-timeout.md)
# ---------------------------------------------------------------------------
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — missing $(printf '%q' "$needle") in output"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "FAIL: $name — unexpected $(printf '%q' "$needle") in output"; FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"; PASS=$((PASS + 1))
  fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Empty hooks dir so temp repos never inherit global git hooks (e.g. ENFORCE_WORKTREE).
EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"

# ---------------------------------------------------------------------------
# Helper: fresh isolated temp git repo with main + clean initial commit
# ---------------------------------------------------------------------------
make_git_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config core.hooksPath "$EMPTY_HOOKS_DIR"
  git -C "$dir" config core.autocrlf false
  git -C "$dir" checkout -q -b main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  echo "initial" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "initial"
  echo "$dir"
}

# Helper: run the script in a repo dir; captures OUTPUT and EXIT globals.
run_in() {
  local dir="$1"; shift
  EXIT=0
  OUTPUT=$(cd "$dir" && run_with_timeout bash "$SCRIPT" "$@" 2>&1) || EXIT=$?
}

# ===========================================================================
# T1: diff mode — only scope-outside files changed → SKIPPED, exit 0
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/lib"
echo 'const x = "<<WORKFLOW_FOO: <bad>>>";' > "$REPO/lib/thing.js"
git -C "$REPO" add lib/thing.js
git -C "$REPO" commit -q -m "add out-of-scope js"
run_in "$REPO" --base HEAD~1
assert_eq "T1 exit 0 (no scope files)" "0" "$EXIT"
assert_contains "T1 SKIPPED header" "$OUTPUT" "## Sentinel Template Review: SKIPPED"

# ===========================================================================
# T2: angle-bracket placeholder in payload of changed markdown → HARD, exit 1
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/rules"
echo 'echo "<<WORKFLOW_FOO_BAR: <one-line summary>>>"' > "$REPO/rules/a.md"
git -C "$REPO" add rules/a.md
git -C "$REPO" commit -q -m "add rules with angle payload"
run_in "$REPO" --base HEAD~1
assert_eq "T2 exit 1 (angle in payload)" "1" "$EXIT"
assert_contains "T2 PERFORMED header" "$OUTPUT" "## Sentinel Template Review: PERFORMED"
assert_contains "T2 HARD line" "$OUTPUT" "HARD:"

# ===========================================================================
# T3: name uses brace, payload has angle → HARD detected
#     <<WORKFLOW_CONFIRM_{STAGE}: <one-line summary>>>
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/rules"
echo 'echo "<<WORKFLOW_CONFIRM_{STAGE}: <one-line summary>>>"' > "$REPO/rules/b.md"
git -C "$REPO" add rules/b.md
git -C "$REPO" commit -q -m "add brace-name angle-payload"
run_in "$REPO" --base HEAD~1
assert_eq "T3 exit 1 (brace name, angle payload)" "1" "$EXIT"
assert_contains "T3 HARD line" "$OUTPUT" "HARD:"

# ===========================================================================
# T4: both brace form → no HARD (false-positive guard)
#     <<WORKFLOW_CONFIRM_{STAGE}: {one-line summary}>>>
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/rules"
echo 'echo "<<WORKFLOW_CONFIRM_{STAGE}: {one-line summary}>>>"' > "$REPO/rules/c.md"
git -C "$REPO" add rules/c.md
git -C "$REPO" commit -q -m "add both-brace form"
run_in "$REPO" --base HEAD~1
assert_eq "T4 exit 0 (both brace)" "0" "$EXIT"
assert_contains "T4 PERFORMED header" "$OUTPUT" "## Sentinel Template Review: PERFORMED"
assert_not_contains "T4 no HARD" "$OUTPUT" "HARD:"

# ===========================================================================
# T5: 2-bracket miscount with angle: <<WORKFLOW_FOO_BAR: {reason}>" → HARD, exit 1
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/skills/foo"
echo 'echo "<<WORKFLOW_FOO_BAR: {reason}>>"' > "$REPO/skills/foo/SKILL.md"
git -C "$REPO" add skills/foo/SKILL.md
git -C "$REPO" commit -q -m "add bracket miscount"
run_in "$REPO" --base HEAD~1
assert_eq "T5 exit 1 (bracket miscount)" "1" "$EXIT"
assert_contains "T5 HARD line" "$OUTPUT" "HARD:"

# ===========================================================================
# T6: --all mode with only valid fixture files → PERFORMED, exit 0
# ===========================================================================
ALLDIR="$TMPDIR_BASE/allscan"
mkdir -p "$ALLDIR/rules" "$ALLDIR/skills/foo" "$ALLDIR/agents"
echo 'echo "<<WORKFLOW_CONFIRM_{STAGE}: {one-line summary}>>>"' > "$ALLDIR/rules/valid.md"
echo 'echo "<<WORKFLOW_USER_VERIFIED: {reason}>>>"' > "$ALLDIR/skills/foo/SKILL.md"
echo 'echo "<<WORKFLOW_FOO_BAR: {reason}>>>"' > "$ALLDIR/agents/valid.md"
run_in "$ALLDIR" --all
assert_eq "T6 exit 0 (--all valid)" "0" "$EXIT"
assert_contains "T6 PERFORMED header" "$OUTPUT" "## Sentinel Template Review: PERFORMED"
assert_not_contains "T6 no HARD" "$OUTPUT" "HARD:"

# ===========================================================================
# T7: changed file, correct brace + correct bracket count → PERFORMED, exit 0
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/agents"
echo 'echo "<<WORKFLOW_FOO_BAR: {reason}>>>"' > "$REPO/agents/d.md"
git -C "$REPO" add agents/d.md
git -C "$REPO" commit -q -m "add valid sentinel"
run_in "$REPO" --base HEAD~1
assert_eq "T7 exit 0 (valid changed file)" "0" "$EXIT"
assert_contains "T7 PERFORMED header" "$OUTPUT" "## Sentinel Template Review: PERFORMED"
assert_not_contains "T7 no HARD" "$OUTPUT" "HARD:"

# ===========================================================================
# T8: --base + --all simultaneously → SKIPPED (mutually exclusive)
# ===========================================================================
run_in "$TMPDIR_BASE" --all --base HEAD
assert_contains "T8 SKIPPED (mutually exclusive)" "$OUTPUT" "## Sentinel Template Review: SKIPPED"

# ===========================================================================
# T9: non-existent base ref → SKIPPED (merge-base fails)
# ===========================================================================
REPO=$(make_git_repo)
run_in "$REPO" --base does-not-exist-ref
assert_contains "T9 SKIPPED (bad base ref)" "$OUTPUT" "## Sentinel Template Review: SKIPPED"

# ===========================================================================
# T10: pure 2-bracket miscount, no angle bracket → HARD (C4 guard)
#      reason>>"  — line has only 2 '>' before the closing quote
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/rules"
echo 'echo "<<WORKFLOW_FOO_BAR: reason>>"' > "$REPO/rules/e.md"
git -C "$REPO" add rules/e.md
git -C "$REPO" commit -q -m "add pure miscount"
run_in "$REPO" --base HEAD~1
assert_eq "T10 exit 1 (pure miscount)" "1" "$EXIT"
assert_contains "T10 HARD line" "$OUTPUT" "HARD:"

# ===========================================================================
# T11: single file with both Pattern 1 AND Pattern 2 violations → HARD, exit 1
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/rules"
printf '%s\n%s\n' \
  'echo "<<WORKFLOW_FOO: <reason>>>"' \
  'echo "<<WORKFLOW_BAR: {reason}>"' \
  > "$REPO/rules/multi.md"
git -C "$REPO" add rules/multi.md
git -C "$REPO" commit -q -m "add file with both violation types"
run_in "$REPO" --base HEAD~1
assert_eq "T11 exit 1 (multi-violation file)" "1" "$EXIT"
assert_contains "T11 HARD line" "$OUTPUT" "HARD:"

# ===========================================================================
# T12: multiple changed files each with violations → exit 1 (aggregate)
# ===========================================================================
REPO=$(make_git_repo)
git -C "$REPO" checkout -q -b feat
mkdir -p "$REPO/rules" "$REPO/agents"
echo 'echo "<<WORKFLOW_FOO: <reason>>>"' > "$REPO/rules/f.md"
echo 'echo "<<WORKFLOW_BAR: {reason}>"'  > "$REPO/agents/g.md"
git -C "$REPO" add rules/f.md agents/g.md
git -C "$REPO" commit -q -m "add two violating files"
run_in "$REPO" --base HEAD~1
assert_eq "T12 exit 1 (multi-file violations)" "1" "$EXIT"
assert_contains "T12 HARD line" "$OUTPUT" "HARD:"

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
