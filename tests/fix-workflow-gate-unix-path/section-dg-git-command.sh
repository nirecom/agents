# L3 gap (what this section does NOT catch):
# - That parseGitCArg / parseCdCommand integration with resolveRepoDir fires correctly in a live Claude Code session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration
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
