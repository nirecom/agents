#!/bin/bash
# Tests for pre-commit hook: auto-unstage effortLevel-only changes in settings.json
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/claude-global/hooks/pre-commit"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# --- Helpers ---

setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo/claude-global"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    # Base settings.json without effortLevel
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest"
}
EOF
    git -C "$repo" add claude-global/settings.json
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

run_hook_in_repo() {
    local repo="$1"
    # Run only the effortLevel section of the hook (skip private-info scanning)
    git -C "$repo" diff --cached --name-only | grep -qx "claude-global/settings.json" || return 0
    local SETTINGS="claude-global/settings.json"
    local STRIP_EFFORT='let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{const j=JSON.parse(d);delete j.effortLevel;delete j.model;console.log(JSON.stringify(j))})'
    local HEAD_CLEAN STAGED_CLEAN
    HEAD_CLEAN="$(git -C "$repo" show "HEAD:$SETTINGS" 2>/dev/null | node -e "$STRIP_EFFORT" 2>/dev/null || true)"
    STAGED_CLEAN="$(git -C "$repo" show ":$SETTINGS" 2>/dev/null | node -e "$STRIP_EFFORT" 2>/dev/null || true)"
    if [ -n "$HEAD_CLEAN" ] && [ "$HEAD_CLEAN" = "$STAGED_CLEAN" ]; then
        git -C "$repo" reset HEAD -- "$SETTINGS" >/dev/null 2>&1
        echo "unstaged"
        return 0
    fi
    echo "kept"
}

# --- Test: effortLevel-only addition is unstaged ---
test_effort_only_added() {
    local repo
    repo="$(setup_repo "effort-add")"
    # Add effortLevel
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "effortLevel": "medium"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "unstaged" ]; then
        # Verify file is no longer staged
        local staged
        staged="$(git -C "$repo" diff --cached --name-only)"
        if [ -z "$staged" ]; then
            pass "effortLevel-only addition is auto-unstaged"
        else
            fail "effortLevel-only addition: unstaged reported but file still staged"
        fi
    else
        fail "effortLevel-only addition was not unstaged (got: $result)"
    fi
}

# --- Test: effortLevel-only change (value update) is unstaged ---
test_effort_value_change() {
    local repo
    repo="$(setup_repo "effort-change")"
    # Commit with effortLevel=high
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "effortLevel": "high"
}
EOF
    git -C "$repo" add claude-global/settings.json
    git -C "$repo" commit -q -m "add effort high"
    # Change to medium
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "effortLevel": "medium"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "unstaged" ]; then
        pass "effortLevel value change is auto-unstaged"
    else
        fail "effortLevel value change was not unstaged (got: $result)"
    fi
}

# --- Test: effortLevel removal is unstaged ---
test_effort_removal() {
    local repo
    repo="$(setup_repo "effort-remove")"
    # Commit with effortLevel
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "effortLevel": "high"
}
EOF
    git -C "$repo" add claude-global/settings.json
    git -C "$repo" commit -q -m "add effort"
    # Remove effortLevel
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "unstaged" ]; then
        pass "effortLevel removal is auto-unstaged"
    else
        fail "effortLevel removal was not unstaged (got: $result)"
    fi
}

# --- Test: real content change is NOT unstaged ---
test_real_change_kept() {
    local repo
    repo="$(setup_repo "real-change")"
    # Change autoUpdatesChannel
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "beta"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "kept" ]; then
        pass "real content change is kept staged"
    else
        fail "real content change was unstaged (should be kept)"
    fi
}

# --- Test: mixed change (effortLevel + real) is NOT unstaged ---
test_mixed_change_kept() {
    local repo
    repo="$(setup_repo "mixed-change")"
    # Change both autoUpdatesChannel and add effortLevel
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "beta",
  "effortLevel": "medium"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "kept" ]; then
        pass "mixed change (effortLevel + real) is kept staged"
    else
        fail "mixed change was unstaged (should be kept)"
    fi
}

# --- Test: settings.json not staged does nothing ---
test_not_staged() {
    local repo
    repo="$(setup_repo "not-staged")"
    # Modify but don't stage
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "effortLevel": "medium"
}
EOF
    local result
    result="$(run_hook_in_repo "$repo")"
    # Should return empty (grep -qx fails, returns 0 early)
    if [ -z "$result" ]; then
        pass "unstaged settings.json is ignored"
    else
        fail "unstaged settings.json was processed (got: $result)"
    fi
}

# --- Test: model-only addition is unstaged ---
test_model_only_added() {
    local repo
    repo="$(setup_repo "model-add")"
    # Add model
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "model": "sonnet"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "unstaged" ]; then
        local staged
        staged="$(git -C "$repo" diff --cached --name-only)"
        if [ -z "$staged" ]; then
            pass "model-only addition is auto-unstaged"
        else
            fail "model-only addition: unstaged reported but file still staged"
        fi
    else
        fail "model-only addition was not unstaged (got: $result)"
    fi
}

# --- Test: model-only value change is unstaged ---
test_model_value_change() {
    local repo
    repo="$(setup_repo "model-change")"
    # Commit with model=sonnet
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "model": "sonnet"
}
EOF
    git -C "$repo" add claude-global/settings.json
    git -C "$repo" commit -q -m "add model sonnet"
    # Change to opus
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "model": "opus"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "unstaged" ]; then
        pass "model value change is auto-unstaged"
    else
        fail "model value change was not unstaged (got: $result)"
    fi
}

# --- Test: model removal is unstaged ---
test_model_removal() {
    local repo
    repo="$(setup_repo "model-remove")"
    # Commit with model
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "model": "sonnet"
}
EOF
    git -C "$repo" add claude-global/settings.json
    git -C "$repo" commit -q -m "add model"
    # Remove model
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "unstaged" ]; then
        pass "model removal is auto-unstaged"
    else
        fail "model removal was not unstaged (got: $result)"
    fi
}

# --- Test: effortLevel + model only (no other changes) is unstaged ---
test_effort_and_model_only() {
    local repo
    repo="$(setup_repo "effort-model-only")"
    # Add both effortLevel and model
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "latest",
  "effortLevel": "medium",
  "model": "sonnet"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "unstaged" ]; then
        pass "effortLevel+model only addition is auto-unstaged"
    else
        fail "effortLevel+model only addition was not unstaged (got: $result)"
    fi
}

# --- Test: model + real change is NOT unstaged ---
test_model_and_real_change() {
    local repo
    repo="$(setup_repo "model-real-change")"
    # Add model and change autoUpdatesChannel
    cat > "$repo/claude-global/settings.json" <<'EOF'
{
  "autoUpdatesChannel": "beta",
  "model": "sonnet"
}
EOF
    git -C "$repo" add claude-global/settings.json
    local result
    result="$(run_hook_in_repo "$repo")"
    if [ "$result" = "kept" ]; then
        pass "model + real change is kept staged"
    else
        fail "model + real change was unstaged (should be kept)"
    fi
}

# --- Run tests ---
test_effort_only_added
test_effort_value_change
test_effort_removal
test_real_change_kept
test_mixed_change_kept
test_not_staged
test_model_only_added
test_model_value_change
test_model_removal
test_effort_and_model_only
test_model_and_real_change

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
