# ---------------------------------------------------------------------------
# === session-start.js: Normal cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== session-start: Normal cases ==="

# Test 35: With CLAUDE_ENV_FILE set → file contains CLAUDE_SESSION_ID=abc123
REPO=$(setup_repo)
ENV_FILE="$TMPDIR_BASE/claude-env-$RANDOM.txt"
touch "$ENV_FILE"
echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_ENV_FILE="$ENV_FILE" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
if grep -qx "CLAUDE_SESSION_ID=abc123" "$ENV_FILE" 2>/dev/null; then
    pass "35. CLAUDE_ENV_FILE → file contains KEY=VALUE line (no export prefix)"
else
    fail "35. CLAUDE_ENV_FILE → expected exact line 'CLAUDE_SESSION_ID=abc123', file content: $(cat "$ENV_FILE" 2>/dev/null || echo '(not found)')"
fi

# Test 36: stdout is valid JSON (may include additionalContext)
REPO=$(setup_repo)
STDOUT=$(echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true)
if [[ "$STDOUT" == "{"* ]] || [[ "$STDOUT" == "" ]]; then
    pass "36. session-start stdout is valid JSON"
else
    fail "36. session-start stdout → expected valid JSON starting with '{', got: '$STDOUT'"
fi

# Test 37: Zombie cleanup — state file with all updated_at 8 days ago → deleted
REPO=$(setup_repo)
SID_ZOMBIE="zombie-$RANDOM"
mkdir -p "$WORKFLOW_DIR"
ZOMBIE_FILE="$WORKFLOW_DIR/${SID_ZOMBIE}.json"
# updated_at values set to 8 days ago in JSON content — cleanup checks JSON timestamps
EIGHT_DAYS_AGO=$(node -e "console.log(new Date(Date.now()-8*24*60*60*1000).toISOString())" 2>/dev/null || echo "2026-04-03T10:00:00.000Z")
cat > "$ZOMBIE_FILE" <<EOF
{
  "version": 1,
  "session_id": "$SID_ZOMBIE",
  "created_at": "$EIGHT_DAYS_AGO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "outline":           {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "detail":            {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "write_tests":       {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "review_tests":      {"status": "skipped", "updated_at": "$EIGHT_DAYS_AGO"},
    "review_security":   {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "run_tests":         {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "docs":              {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "user_verification": {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"}
  }
}
EOF
echo '{"session_id":"new-session"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
if [ ! -f "$ZOMBIE_FILE" ]; then
    pass "37. Zombie cleanup: 8-day-old state file deleted"
else
    fail "37. Zombie cleanup: state file still exists: $ZOMBIE_FILE"
fi

# Test 38: State file with updated_at 3 days ago → NOT deleted
REPO=$(setup_repo)
SID_RECENT="recent-$RANDOM"
mkdir -p "$WORKFLOW_DIR"
RECENT_FILE="$WORKFLOW_DIR/${SID_RECENT}.json"
THREE_DAYS_AGO=$(node -e "console.log(new Date(Date.now()-3*24*60*60*1000).toISOString())" 2>/dev/null || echo "2026-04-08T10:00:00.000Z")
cat > "$RECENT_FILE" <<EOF
{
  "version": 1,
  "session_id": "$SID_RECENT",
  "created_at": "$THREE_DAYS_AGO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "outline":           {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "detail":            {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "write_tests":       {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "review_tests":      {"status": "skipped", "updated_at": "$THREE_DAYS_AGO"},
    "review_security":   {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "run_tests":         {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "docs":              {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "user_verification": {"status": "complete", "updated_at": "$THREE_DAYS_AGO"}
  }
}
EOF
echo '{"session_id":"new-session"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
if [ -f "$RECENT_FILE" ]; then
    pass "38. Recent state file (3 days) NOT deleted by zombie cleanup"
else
    fail "38. Recent state file was incorrectly deleted"
fi

# ---------------------------------------------------------------------------
# === session-start.js: Edge cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== session-start: Edge cases ==="

# Test 39: CLAUDE_ENV_FILE not set → exits 0, no error
REPO=$(setup_repo)
if echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null; then
    pass "39. CLAUDE_ENV_FILE not set → exits 0"
else
    fail "39. CLAUDE_ENV_FILE not set → expected exit 0, got non-zero"
fi

# Test 40: .git/workflow/ directory doesn't exist → cleanup runs without error
REPO=$(setup_repo)
# Do NOT create the workflow directory — verify no crash
if echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null; then
    pass "40. Missing workflow dir → cleanup runs without error"
else
    fail "40. Missing workflow dir → session-start crashed (exit non-zero)"
fi

# Test 41: stdin is invalid JSON → exits 0 (fail-open for SessionStart)
REPO=$(setup_repo)
if echo 'NOT VALID JSON' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null; then
    pass "41. Invalid JSON stdin → exits 0 (fail-open)"
else
    fail "41. Invalid JSON stdin → expected exit 0 (fail-open), got non-zero"
fi

# ---------------------------------------------------------------------------
# === is-private-repo.js: toNativePath / resolveRepoDir ===
# ---------------------------------------------------------------------------

echo ""
echo "=== is-private-repo: toNativePath / resolveRepoDir ==="

# Test 42: toNativePath converts /c/... to C:/... on win32
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/c/git/dotfiles'));
" 2>/dev/null)
[ "$RESULT" = "C:/git/dotfiles" ] && pass "42. toNativePath /c/git/dotfiles → C:/git/dotfiles" || fail "42. toNativePath: expected C:/git/dotfiles, got '$RESULT'"

# Test 43: toNativePath handles different drive letters
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/d/foo/bar'));
" 2>/dev/null)
[ "$RESULT" = "D:/foo/bar" ] && pass "43. toNativePath /d/foo/bar → D:/foo/bar" || fail "43. toNativePath: expected D:/foo/bar, got '$RESULT'"

# Test 44: toNativePath leaves already-Windows paths unchanged
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('C:/git/dotfiles'));
" 2>/dev/null)
[ "$RESULT" = "C:/git/dotfiles" ] && pass "44. toNativePath C:/git/dotfiles → C:/git/dotfiles (no change)" || fail "44. toNativePath: expected C:/git/dotfiles, got '$RESULT'"

# Test 45: toNativePath leaves relative paths unchanged
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('.'));
" 2>/dev/null)
[ "$RESULT" = "." ] && pass "45. toNativePath '.' → '.' (no change)" || fail "45. toNativePath: expected '.', got '$RESULT'"

# Test 46: toNativePath leaves Linux-style non-drive paths unchanged on win32
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/usr/local/bin'));
" 2>/dev/null)
[ "$RESULT" = "/usr/local/bin" ] && pass "46. toNativePath /usr/local/bin → /usr/local/bin (no change)" || fail "46. toNativePath: expected /usr/local/bin, got '$RESULT'"

# Test 47: toNativePath handles single-char drive with trailing slash
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/z/'));
" 2>/dev/null)
[ "$RESULT" = "Z:/" ] && pass "47. toNativePath /z/ → Z:/" || fail "47. toNativePath: expected Z:/, got '$RESULT'"

# Test 48: resolveRepoDir converts WSL path via toNativePath on win32 (CLAUDE_PROJECT_DIR unset)
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  delete process.env.HOOK_CWD; delete process.env.CLAUDE_PROJECT_DIR;
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {resolveRepoDir}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(resolveRepoDir('git -C /c/git/dotfiles commit'));
" 2>/dev/null)
[ "$RESULT" = "C:/git/dotfiles" ] && pass "48. resolveRepoDir: WSL path /c/git/dotfiles → C:/git/dotfiles on win32" || fail "48. resolveRepoDir: expected C:/git/dotfiles, got '$RESULT'"

# Test 49: resolveRepoDir returns "." when no -C flag and CLAUDE_PROJECT_DIR unset
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  delete process.env.HOOK_CWD; delete process.env.CLAUDE_PROJECT_DIR;
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {resolveRepoDir}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(resolveRepoDir('git commit'));
" 2>/dev/null)
[ "$RESULT" = "." ] && pass "49. resolveRepoDir: no -C flag → '.'" || fail "49. resolveRepoDir: expected '.', got '$RESULT'"
