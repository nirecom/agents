# L3 gap (what this section does NOT catch):
# - That additionalDirectories detection fires correctly during a real Claude Code
#   session switching between linked worktrees (live hook dispatch path)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration
# ============================================================
# Section H: additionalDirectories detection tests
# ============================================================
echo ""
echo "=== H. additionalDirectories detection tests ==="

TMPDIR_PRIMARY_UNIX=$(mktemp -d)
TMPDIR_SIBLING_UNIX=$(mktemp -d)
# Convert to Windows-native paths for Node.js (Git Bash /tmp/ is not visible to Node)
if command -v cygpath >/dev/null 2>&1; then
  TMPDIR_PRIMARY_WIN="$(cygpath -w "$TMPDIR_PRIMARY_UNIX")"
  TMPDIR_SIBLING_WIN="$(cygpath -w "$TMPDIR_SIBLING_UNIX")"
else
  TMPDIR_PRIMARY_WIN="$TMPDIR_PRIMARY_UNIX"
  TMPDIR_SIBLING_WIN="$TMPDIR_SIBLING_UNIX"
fi
# Normalize backslashes → forward slashes for JSON and comparison
TMPDIR_PRIMARY_JS="${TMPDIR_PRIMARY_WIN//\\//}"
TMPDIR_SIBLING_JS="${TMPDIR_SIBLING_WIN//\\//}"

# Init two bare git repos (use Unix paths for git commands — Git Bash handles them).
# `-c core.hooksPath=` neutralizes the globally-configured agents pre-commit hook so
# it does not fire inside these throwaway temp repos (which look like main worktrees
# to the hook because --git-common-dir == --git-dir).
git -C "$TMPDIR_PRIMARY_UNIX" init -q
git -C "$TMPDIR_PRIMARY_UNIX" -c core.hooksPath= commit --allow-empty -q -m "init"
git -C "$TMPDIR_SIBLING_UNIX" init -q
git -C "$TMPDIR_SIBLING_UNIX" -c core.hooksPath= commit --allow-empty -q -m "init"

# Temporarily replace settings.json with a mock that lists only the sibling.
# findAdditionalDirectories() reads ~/.claude/settings.json first, then falls back to
# agents/settings.json — so mock both to ensure the test environment is deterministic
# regardless of whether ~/.claude/settings.json is an installed file or a symlink.
HOOKS_DIR="$(dirname "$HOOK_UNIX")"
AGENTS_ROOT="$(dirname "$HOOKS_DIR")"
REAL_SETTINGS="$AGENTS_ROOT/settings.json"
MOCK_SETTINGS="$AGENTS_ROOT/settings.json.bak"
cp "$REAL_SETTINGS" "$MOCK_SETTINGS"
printf '{"permissions":{"additionalDirectories":["%s"]}}' "$TMPDIR_SIBLING_JS" > "$REAL_SETTINGS"

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_SETTINGS_BAK=""
if [ -e "$CLAUDE_SETTINGS" ] && [ ! -L "$CLAUDE_SETTINGS" ]; then
  CLAUDE_SETTINGS_BAK="$CLAUDE_SETTINGS.test-bak.$$"
  mv "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS_BAK"
  printf '{"permissions":{"additionalDirectories":["%s"]}}' "$TMPDIR_SIBLING_JS" > "$CLAUDE_SETTINGS"
fi

# H1: primary has staged changes → return primary
touch "$TMPDIR_PRIMARY_UNIX/file.txt"
git -C "$TMPDIR_PRIMARY_UNIX" add file.txt
result=$(
  CLAUDE_PROJECT_DIR="$TMPDIR_PRIMARY_JS" HOOK_PATH="$HOOK_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git commit -m "test"'));
EOF
)
git -C "$TMPDIR_PRIMARY_UNIX" restore --staged file.txt
if [ "$result" = "$TMPDIR_PRIMARY_JS" ]; then
  echo "  PASS: H1: staged in primary -> returns primary"
  PASS=$((PASS + 1))
else
  echo "  FAIL: H1: expected '$TMPDIR_PRIMARY_JS', got '$result'"
  FAIL=$((FAIL + 1))
  ERRORS+=("H1: staged in primary -> returns primary")
fi

# H2: only sibling has staged changes → return sibling
touch "$TMPDIR_SIBLING_UNIX/file.txt"
git -C "$TMPDIR_SIBLING_UNIX" add file.txt
result=$(
  CLAUDE_PROJECT_DIR="$TMPDIR_PRIMARY_JS" HOOK_PATH="$HOOK_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git commit -m "test"'));
EOF
)
git -C "$TMPDIR_SIBLING_UNIX" restore --staged file.txt
if [ "$result" = "$TMPDIR_SIBLING_JS" ]; then
  echo "  PASS: H2: staged only in sibling -> returns sibling"
  PASS=$((PASS + 1))
else
  echo "  FAIL: H2: expected '$TMPDIR_SIBLING_JS', got '$result'"
  FAIL=$((FAIL + 1))
  ERRORS+=("H2: staged only in sibling -> returns sibling")
fi

# H3: nothing staged → return primary (fallback)
result=$(
  CLAUDE_PROJECT_DIR="$TMPDIR_PRIMARY_JS" HOOK_PATH="$HOOK_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git commit -m "test"'));
EOF
)
if [ "$result" = "$TMPDIR_PRIMARY_JS" ]; then
  echo "  PASS: H3: nothing staged -> fallback to primary"
  PASS=$((PASS + 1))
else
  echo "  FAIL: H3: expected '$TMPDIR_PRIMARY_JS', got '$result'"
  FAIL=$((FAIL + 1))
  ERRORS+=("H3: nothing staged -> fallback to primary")
fi

# Restore real settings.json
mv "$MOCK_SETTINGS" "$REAL_SETTINGS"
if [ -n "$CLAUDE_SETTINGS_BAK" ]; then
  mv "$CLAUDE_SETTINGS_BAK" "$CLAUDE_SETTINGS"
fi
rm -rf "$TMPDIR_PRIMARY_UNIX" "$TMPDIR_SIBLING_UNIX"
