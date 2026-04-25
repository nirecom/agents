#!/usr/bin/env bash
# Tests for workflow-gate.js: resolveRepoDir, hasStagedTestChanges, hasStagedDocChanges
# Branch: fix/workflow-gate-unix-path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_UNIX="$REPO_ROOT/claude-global/hooks/workflow-gate.js"

# Convert to Windows path for Node.js require
if command -v cygpath >/dev/null 2>&1; then
  HOOK_WIN="$(cygpath -w "$HOOK_UNIX")"
else
  HOOK_WIN="$HOOK_UNIX"
fi

PASS=0
FAIL=0
ERRORS=()

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

assert_true() {
  local name="$1" actual="$2"
  if [ "$actual" = "true" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected true, got '$actual')"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

assert_false() {
  local name="$1" actual="$2"
  if [ "$actual" = "false" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected false, got '$actual')"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

assert_contains() {
  local name="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    expected to contain: $expected"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

# Helper: run Node with HOOK_PATH env var to avoid escaping issues
node_hook() {
  HOOK_PATH="$HOOK_WIN" run_with_timeout node "$@"
}

# ============================================================
# Section A: resolveRepoDir unit tests
# ============================================================
echo ""
echo "=== A. resolveRepoDir unit tests ==="

# N1: /c/git/dotfiles -> C:\git\dotfiles
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /c/git/dotfiles commit -m "msg"'));
EOF
)
assert_eq 'N1: /c/path -> C:\git\dotfiles' 'C:\git\dotfiles' "$result"

# N2: /C/Users/foo/bar -> C:\Users\foo\bar
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /C/Users/foo/bar commit -m "msg"'));
EOF
)
assert_eq 'N2: /C/path (uppercase) -> C:\Users\foo\bar' 'C:\Users\foo\bar' "$result"

# N3: C:\git\dotfiles -> C:\git\dotfiles (no conversion)
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C C:\\git\\dotfiles commit -m "msg"'));
EOF
)
assert_eq 'N3: Windows path unchanged' 'C:\git\dotfiles' "$result"

# N4: no -C flag -> process.cwd()
expected_cwd=$(node --input-type=module <<'EOF'
process.stdout.write(process.cwd());
EOF
)
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git commit -m "msg"'));
EOF
)
assert_eq "N4: no -C -> process.cwd()" "$expected_cwd" "$result"

# E1: /c -> C:\
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /c commit -m "msg"'));
EOF
)
assert_eq 'E1: /c -> C:\' 'C:\' "$result"

# E2: /git/dotfiles (no drive letter) -> unchanged
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /git/dotfiles commit -m "msg"'));
EOF
)
assert_eq "E2: /git/dotfiles (no drive) -> unchanged" '/git/dotfiles' "$result"

# E3: . -> .
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C . commit -m "msg"'));
EOF
)
assert_eq "E3: dot path -> dot" '.' "$result"

# ============================================================
# Section B: hasStagedTestChanges / hasStagedDocChanges integration
# ============================================================
echo ""
echo "=== B. hasStagedTestChanges / hasStagedDocChanges integration tests ==="

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_repo() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test User"
}

to_win_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p"
  else
    echo "$p"
  fi
}

# I1: tests/foo.sh staged -> hasStagedTestChanges = true
REPO1="$TMPDIR_BASE/repo1"
mkdir -p "$REPO1"
setup_repo "$REPO1"
mkdir -p "$REPO1/tests"
echo "# test" > "$REPO1/tests/foo.sh"
git -C "$REPO1" add "tests/foo.sh"
REPO1_WIN="$(to_win_path "$REPO1")"

result=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO1_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedTestChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedTestChanges(process.env.REPO_DIR)));
EOF
)
assert_true "I1: tests/foo.sh staged -> hasStagedTestChanges=true" "$result"

# I2: docs/ops.md staged -> hasStagedDocChanges = true
REPO2="$TMPDIR_BASE/repo2"
mkdir -p "$REPO2"
setup_repo "$REPO2"
mkdir -p "$REPO2/docs"
echo "# ops" > "$REPO2/docs/ops.md"
git -C "$REPO2" add "docs/ops.md"
REPO2_WIN="$(to_win_path "$REPO2")"

result=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO2_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedDocChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedDocChanges(process.env.REPO_DIR)));
EOF
)
assert_true "I2: docs/ops.md staged -> hasStagedDocChanges=true" "$result"

# I3: src/main.js only -> both false
REPO3="$TMPDIR_BASE/repo3"
mkdir -p "$REPO3"
setup_repo "$REPO3"
mkdir -p "$REPO3/src"
echo "// main" > "$REPO3/src/main.js"
git -C "$REPO3" add "src/main.js"
REPO3_WIN="$(to_win_path "$REPO3")"

result_test=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO3_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedTestChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedTestChanges(process.env.REPO_DIR)));
EOF
)
result_doc=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO3_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedDocChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedDocChanges(process.env.REPO_DIR)));
EOF
)
assert_false "I3: src/main.js only -> hasStagedTestChanges=false" "$result_test"
assert_false "I3: src/main.js only -> hasStagedDocChanges=false" "$result_doc"

# ============================================================
# Section C: error handling
# ============================================================
echo ""
echo "=== C. error handling tests ==="

# Er1: nonexistent cwd -> false + stderr warning
STDERR_TMP="$TMPDIR_BASE/stderr_er1.txt"
result=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="/nonexistent/path/that/does/not/exist" \
  run_with_timeout node --input-type=module 2>"$STDERR_TMP" <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedTestChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedTestChanges(process.env.REPO_DIR)));
EOF
)
stderr_out=$(cat "$STDERR_TMP")

assert_false "Er1: nonexistent cwd -> hasStagedTestChanges=false" "$result"
assert_contains "Er1: nonexistent cwd -> stderr warning contains 'workflow-gate'" "workflow-gate" "$stderr_out"

# ============================================================
# Section D: parseGitCArg unit tests (git-command.js)
# ============================================================
echo ""
echo "=== D. parseGitCArg unit tests (requires git-command.js) ==="

GIT_COMMAND_JS="$REPO_ROOT/claude-global/hooks/lib/parse-git-args.js"
GIT_COMMAND_JS_WIN="$(to_win_path "$GIT_COMMAND_JS")"

if ! PARSE_GIT_ARGS_PATH="$GIT_COMMAND_JS_WIN" node --input-type=module 2>/dev/null <<'NODEEOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
require(process.env.PARSE_GIT_ARGS_PATH);
NODEEOF
then
  echo "  SKIP: parse-git-args.js not yet implemented — skipping D/E-Q/G sections"
  SKIP_DEG=1
else
  SKIP_DEG=0
fi

if [ "${SKIP_DEG:-1}" = "0" ]; then
  GIT_CMD_WIN="$GIT_COMMAND_JS_WIN"

  # D1: unquoted path
  result=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git -C c:/git/dotfiles commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "D1: unquoted path" "c:/git/dotfiles" "$result"

  # D2: double-quoted path
  result=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git -C "c:/LLM/ai-specs" commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq 'D2: double-quoted path' "c:/LLM/ai-specs" "$result"

  # D3: single-quoted path
  result=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg("git -C 'c:/LLM/ai-specs' commit");
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "D3: single-quoted path" "c:/LLM/ai-specs" "$result"

  # D4: path with spaces
  result=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git -C "c:/with space/repo" commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "D4: path with spaces" "c:/with space/repo" "$result"

  # D5: Unix-style path (no conversion — returns raw)
  result=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git -C "/c/git/dotfiles" commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "D5: unix-style path returns raw" "/c/git/dotfiles" "$result"

  # D6: unterminated quote -> null
  result=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git -C "c:/unterminated commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "D6: unterminated quote -> null" "null" "$result"

  # D7: no -C flag -> null
  result=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git commit -m "msg"');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "D7: no -C flag -> null" "null" "$result"

  # D8: Idempotency — same result on second call
  result1=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git -C "c:/LLM/ai-specs" commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  result2=$(GIT_CMD_PATH="$GIT_CMD_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { parseGitCArg } = require(process.env.GIT_CMD_PATH);
const r = parseGitCArg('git -C "c:/LLM/ai-specs" commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "D8: idempotency — same result on repeat call" "$result1" "$result2"
fi

# ============================================================
# Section E: resolveRepoDir — quoted path (requires git-command.js)
# ============================================================
echo ""
echo "=== E. resolveRepoDir quoted-path tests (requires git-command.js) ==="

if [ "${SKIP_DEG:-1}" = "0" ]; then
  # E-Q1: double-quoted Windows path with spaces -> backslash path on win32
  result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C "c:/LLM/ai-specs" commit'));
EOF
  )
  if [ "$(uname -s | tr '[:upper:]' '[:lower:]')" = "windows_nt" ] || echo "$OS" | grep -qi windows 2>/dev/null; then
    expected_eq='c:\LLM\ai-specs'
  else
    # On non-Windows, toNativePath is a no-op so forward slashes remain
    expected_eq='c:/LLM/ai-specs'
  fi
  assert_eq 'E-Q1: double-quoted -> backslash path' "$expected_eq" "$result"

  # E-Q2: single-quoted path
  result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir("git -C 'c:/LLM/ai-specs' commit"));
EOF
  )
  assert_eq 'E-Q2: single-quoted -> native path' "$expected_eq" "$result"

  # E-Q3: path with spaces
  result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C "c:/path with spaces/repo" commit'));
EOF
  )
  if [ "$(uname -s | tr '[:upper:]' '[:lower:]')" = "windows_nt" ] || echo "$OS" | grep -qi windows 2>/dev/null; then
    expected_spaces='c:\path with spaces\repo'
  else
    expected_spaces='c:/path with spaces/repo'
  fi
  assert_eq 'E-Q3: path with spaces -> native path' "$expected_spaces" "$result"

  # E-Q4: unterminated quote -> fallback to cwd or CLAUDE_PROJECT_DIR
  result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
const r = resolveRepoDir('git -C "c:/broken commit');
// should not be the broken string — should be cwd or CLAUDE_PROJECT_DIR
const expected = process.env.CLAUDE_PROJECT_DIR || process.cwd();
process.stdout.write(r === expected ? 'fallback-ok' : 'fallback-fail:' + r);
EOF
  )
  assert_eq 'E-Q4: unterminated quote -> fallback to cwd' "fallback-ok" "$result"
else
  echo "  SKIP: git-command.js not yet implemented"
fi

# ============================================================
# Section F: commit detection — fail-open bypass regression (Security)
# ============================================================
echo ""
echo "=== F. commit detection regression tests ==="

# F-neg1 (Security/Bug): current \S+ regex misses quoted path with space -> approve fires (known bug)
# This test PASSES before the fix (confirms the bug exists), and must be removed/skipped after fix.
# SKIP_IF_FIXED=1
result=$(run_with_timeout node --input-type=module <<'EOF'
// Reproduces the current bug in workflow-gate.js line 94
// \S+ does not match past the first space in "c:/with space/repo"
const cmd = 'git -C "c:/with space/repo" commit -m "msg"';
const commitMatch = cmd.match(/^git\s+(?:-C\s+\S+\s+)?commit\s/);
process.stdout.write(commitMatch ? 'true' : 'false');
EOF
)
assert_false "F-neg1: (Security/Bug) current \\S+ regex misses quoted path with space -> approve (known bug)" "$result"

if [ "${SKIP_DEG:-1}" = "0" ]; then
  # F1: new 2-step regex: double-quoted path with space -> commit detected
  result=$(run_with_timeout node --input-type=module <<'EOF'
const cmd = 'git -C "c:/with space/repo" commit -m "msg"';
const isGit = /^git\s/.test(cmd);
const hasCommit = /\scommit(\s|$)/.test(cmd);
process.stdout.write((isGit && hasCommit) ? 'true' : 'false');
EOF
  )
  assert_true "F1: (Security) new 2-step regex: double-quoted path with space -> commit detected" "$result"

  # F2: new 2-step regex: single-quoted path -> commit detected
  result=$(run_with_timeout node --input-type=module <<'EOF'
const cmd = "git -C 'c:/path' commit";
const isGit = /^git\s/.test(cmd);
const hasCommit = /\scommit(\s|$)/.test(cmd);
process.stdout.write((isGit && hasCommit) ? 'true' : 'false');
EOF
  )
  assert_true "F2: (Security) new 2-step regex: single-quoted path -> commit detected" "$result"

  # F3: normal unix-style path -> commit detected
  result=$(run_with_timeout node --input-type=module <<'EOF'
const cmd = 'git -C /c/git/dotfiles commit -m "msg"';
const isGit = /^git\s/.test(cmd);
const hasCommit = /\scommit(\s|$)/.test(cmd);
process.stdout.write((isGit && hasCommit) ? 'true' : 'false');
EOF
  )
  assert_true "F3: (Normal) new 2-step regex: unix-style path -> commit detected" "$result"

  # F4: git status -> not commit
  result=$(run_with_timeout node --input-type=module <<'EOF'
const cmd = 'git status';
const isGit = /^git\s/.test(cmd);
const hasCommit = /\scommit(\s|$)/.test(cmd);
process.stdout.write((isGit && hasCommit) ? 'true' : 'false');
EOF
  )
  assert_false "F4: (Normal) new 2-step regex: git status -> not commit" "$result"
else
  echo "  SKIP F1-F4: git-command.js not yet implemented (new regex lives there)"
fi

# ============================================================
# Section G: is-private-repo extractRepoDirFromCommand — quoted path
# ============================================================
echo ""
echo "=== G. extractRepoDirFromCommand quoted-path tests (requires git-command.js) ==="

if [ "${SKIP_DEG:-1}" = "0" ]; then
  IS_PRIVATE_WIN="$(to_win_path "$REPO_ROOT/claude-global/hooks/lib/is-private-repo.js")"

  # G1: double-quoted Windows path
  result=$(IS_PRIVATE_PATH="$IS_PRIVATE_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { extractRepoDirFromCommand } = require(process.env.IS_PRIVATE_PATH);
const r = extractRepoDirFromCommand('git -C "c:/LLM/ai-specs" commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq 'G1: double-quoted -> c:/LLM/ai-specs' "c:/LLM/ai-specs" "$result"

  # G2: single-quoted path
  result=$(IS_PRIVATE_PATH="$IS_PRIVATE_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { extractRepoDirFromCommand } = require(process.env.IS_PRIVATE_PATH);
const r = extractRepoDirFromCommand("git -C 'c:/path' commit");
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "G2: single-quoted -> c:/path" "c:/path" "$result"

  # G3: path with spaces
  result=$(IS_PRIVATE_PATH="$IS_PRIVATE_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { extractRepoDirFromCommand } = require(process.env.IS_PRIVATE_PATH);
const r = extractRepoDirFromCommand('git -C "path with spaces" commit');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "G3: path with spaces -> path with spaces" "path with spaces" "$result"

  # G4: no -C flag -> null
  result=$(IS_PRIVATE_PATH="$IS_PRIVATE_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { extractRepoDirFromCommand } = require(process.env.IS_PRIVATE_PATH);
const r = extractRepoDirFromCommand('git commit -m "msg"');
process.stdout.write(r === null ? 'null' : r);
EOF
  )
  assert_eq "G4: no -C flag -> null" "null" "$result"
else
  echo "  SKIP: git-command.js not yet implemented"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=============================="
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
fi
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
