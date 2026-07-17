#!/bin/bash
# Tests: bin/check-verification-gate.sh
# Tags: verification-gate, risk-category, user-verified, pwsh-required, scope:issue-specific
# Tests for issue #833 — bin/check-verification-gate.sh
# Verifies risk-category classifier interface before source implementation (TDD).
# RED: this suite fails clean while bin/check-verification-gate.sh is missing.
#
# L3 gap (what this test does NOT catch):
# - Whether the preflight AskUserQuestion actually fires in a live Claude Code session
# - Whether WORKFLOW_USER_VERIFIED sentinel emission is properly gated (protocol-level behavior)
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration, hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="$AGENTS_DIR/bin/check-verification-gate.sh"
FIXTURE_DIR="$AGENTS_DIR/tests/fixtures/check-verification-gate"
SETTINGS_WITH_FOO="$FIXTURE_DIR/settings-with-foo.json"
SETTINGS_EMPTY="$FIXTURE_DIR/settings-empty.json"

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
if [ ! -f "$CHECK_SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/check-verification-gate.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Also gate on fixtures so we don't silently regress on fixture rename.
missing_fixtures=()
[ -f "$SETTINGS_WITH_FOO" ] || missing_fixtures+=("tests/fixtures/check-verification-gate/settings-with-foo.json")
[ -f "$SETTINGS_EMPTY" ]    || missing_fixtures+=("tests/fixtures/check-verification-gate/settings-empty.json")
if [ "${#missing_fixtures[@]}" -gt 0 ]; then
    for f in "${missing_fixtures[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing_fixtures[@]} failed"
    exit 1
fi

# Per-test scratch dir holder
TMP=""
setup_tmp() {
    TMP="$(mktemp -d)"
}
teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    TMP=""
}

# Run the CLI under test; capture stdout/stderr separately.
# Usage: run_gate <args...>
# Sets: GATE_STDOUT, GATE_STDERR, GATE_RC
run_gate() {
    local out_file err_file
    out_file="$(mktemp)"
    err_file="$(mktemp)"
    run_with_timeout 15 bash "$CHECK_SCRIPT" "$@" >"$out_file" 2>"$err_file"
    GATE_RC=$?
    GATE_STDOUT="$(cat "$out_file")"
    GATE_STDERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

# Extract category tokens from stdout (one per line).
# Stdout line format: "CATEGORY: <token>\tQUESTION: <text>"
gate_tokens() {
    printf '%s\n' "$GATE_STDOUT" | sed -n 's/^CATEGORY: \([^	]*\)	.*/\1/p'
}

# ============================================================================
# Normal cases (1–5)
# ============================================================================

# --- 1: Empty file list → empty stdout, exit 0
run_gate --files
if [ "$GATE_RC" -eq 0 ] && [ -z "$GATE_STDOUT" ]; then
    pass "1: empty --files → empty stdout, exit 0"
else
    fail "1: rc=$GATE_RC stdout=[$GATE_STDOUT] stderr=$GATE_STDERR"
fi

# --- 2: install/foo.ps1 → installer AND pwsh-required, exit 0
run_gate --files install/foo.ps1
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] \
    && echo "$tokens" | grep -q "installer" \
    && echo "$tokens" | grep -q "pwsh-required"; then
    pass "2: install/foo.ps1 → installer + pwsh-required"
else
    fail "2: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi

# --- 3: settings.json modified → hook-registration
run_gate --files settings.json
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "hook-registration"; then
    pass "3: settings.json → hook-registration"
else
    fail "3: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi

# --- 4: skills/worktree-end/SKILL.md → skill-orchestration
run_gate --files skills/worktree-end/SKILL.md
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "skill-orchestration"; then
    pass "4: skills/worktree-end/SKILL.md → skill-orchestration"
else
    fail "4: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi

# --- 5: skills/_shared/test-design.md → skill-orchestration (recursive glob)
run_gate --files skills/_shared/test-design.md
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "skill-orchestration"; then
    pass "5: skills/_shared/test-design.md → skill-orchestration (recursive)"
else
    fail "5: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi

# ============================================================================
# Edge cases (6–10)
# ============================================================================

# --- 6: --files empty list (no positional values) → empty stdout, exit 0
run_gate --files
if [ "$GATE_RC" -eq 0 ] && [ -z "$GATE_STDOUT" ]; then
    pass "6: --files empty list → empty stdout, exit 0"
else
    fail "6: rc=$GATE_RC stdout=[$GATE_STDOUT] stderr=$GATE_STDERR"
fi

# --- 7: --stdin with single blank line → empty stdout, exit 0
GATE_STDOUT=""; GATE_STDERR=""; GATE_RC=0
out_file="$(mktemp)"; err_file="$(mktemp)"
printf '\n' | run_with_timeout 15 bash "$CHECK_SCRIPT" --stdin >"$out_file" 2>"$err_file"
GATE_RC=$?
GATE_STDOUT="$(cat "$out_file")"
GATE_STDERR="$(cat "$err_file")"
rm -f "$out_file" "$err_file"
if [ "$GATE_RC" -eq 0 ] && [ -z "$GATE_STDOUT" ]; then
    pass "7: --stdin with blank line → empty stdout, exit 0"
else
    fail "7: rc=$GATE_RC stdout=[$GATE_STDOUT] stderr=$GATE_STDERR"
fi

# --- 8: File matches two categories → both tokens emitted, sorted lexicographically
# install/foo.ps1 → installer + pwsh-required. "installer" < "pwsh-required" lex.
run_gate --files install/foo.ps1
tokens_sorted="$(gate_tokens)"
expected=$'installer\npwsh-required'
if [ "$GATE_RC" -eq 0 ] && [ "$tokens_sorted" = "$expected" ]; then
    pass "8: two-category file → both tokens, sorted lexicographically"
else
    fail "8: rc=$GATE_RC tokens=[$tokens_sorted] expected=[$expected]"
fi

# --- 9: Same category triggered by two files → emitted once (dedupe)
run_gate --files skills/a/SKILL.md skills/b/SKILL.md
count="$(gate_tokens | grep -c '^skill-orchestration$' || true)"
if [ "$GATE_RC" -eq 0 ] && [ "$count" = "1" ]; then
    pass "9: dedupe — skill-orchestration emitted exactly once"
else
    fail "9: rc=$GATE_RC count=$count tokens=[$(gate_tokens | tr '\n' ' ')]"
fi

# --- 10: Path with spaces → no word-splitting bug
setup_tmp
spaced="$TMP/path with spaces/install/foo.ps1"
mkdir -p "$(dirname "$spaced")"
: > "$spaced"
run_gate --files "$spaced"
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "installer"; then
    pass "10: path with spaces → installer (no word-split)"
else
    fail "10: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi
teardown_tmp

# ============================================================================
# Error cases (11–12)
# ============================================================================

# --- 11: Unknown flag → exit 2, stderr usage line
run_gate --not-a-flag
if [ "$GATE_RC" -eq 2 ] && [ -n "$GATE_STDERR" ]; then
    pass "11: unknown flag → exit 2 with stderr"
else
    fail "11: rc=$GATE_RC stderr=[$GATE_STDERR]"
fi

# --- 12: --files and --stdin both supplied → exit 2
run_gate --files install/foo.ps1 --stdin
if [ "$GATE_RC" -eq 2 ]; then
    pass "12: --files + --stdin together → exit 2"
else
    fail "12: rc=$GATE_RC stderr=[$GATE_STDERR]"
fi

# ============================================================================
# Security cases (13–14)
# ============================================================================

# --- 13: Path containing $(rm -rf /) literal → treated as literal path, not evaluated
canary13="$(mktemp)"
: > "$canary13"
run_gate --files '$(rm -rf '"$canary13"')'
if [ "$GATE_RC" -eq 0 ] && [ -z "$GATE_STDOUT" ] && [ -f "$canary13" ]; then
    pass "13: command-substitution literal → no eval, empty stdout"
else
    fail "13: rc=$GATE_RC stdout=[$GATE_STDOUT] canary_exists=$([ -f "$canary13" ] && echo yes || echo no)"
fi
rm -f "$canary13"

# --- 14: Path containing newline injection → handled safely
# Embed a newline; expect no crash, exit 0 or 2 acceptable (well-defined),
# and no category match for the nonsense path.
nl_path=$'install/evil\nsettings.json'
run_gate --files "$nl_path"
if { [ "$GATE_RC" -eq 0 ] || [ "$GATE_RC" -eq 2 ]; }; then
    pass "14: newline-in-path handled safely (rc=$GATE_RC)"
else
    fail "14: rc=$GATE_RC stdout=[$GATE_STDOUT] stderr=$GATE_STDERR"
fi

# ============================================================================
# Idempotency (15)
# ============================================================================

# --- 15: Running twice with same --files produces identical byte-for-byte stdout
run_gate --files install/foo.ps1 settings.json
out1="$GATE_STDOUT"
run_gate --files install/foo.ps1 settings.json
out2="$GATE_STDOUT"
if [ "$out1" = "$out2" ] && [ -n "$out1" ]; then
    pass "15: idempotent — two runs produce identical stdout"
else
    fail "15: out1=[$out1] out2=[$out2]"
fi

# ============================================================================
# Hook-registration cases (16–18)
# ============================================================================

# --- 16: hooks/foo.js modified AND foo registered in settings → hook-registration
setup_tmp
hook_foo="$TMP/hooks/foo.js"
mkdir -p "$(dirname "$hook_foo")"
echo "// registered hook" > "$hook_foo"
run_gate --files "$hook_foo" --settings-path "$SETTINGS_WITH_FOO"
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "hook-registration"; then
    pass "16: hooks/foo.js + registered → hook-registration"
else
    fail "16: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi
teardown_tmp

# --- 17: hooks/orphan.js modified, NOT registered → NO hook-registration
setup_tmp
hook_orphan="$TMP/hooks/orphan.js"
mkdir -p "$(dirname "$hook_orphan")"
echo "// orphan hook" > "$hook_orphan"
run_gate --files "$hook_orphan" --settings-path "$SETTINGS_EMPTY"
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && ! echo "$tokens" | grep -q "hook-registration"; then
    pass "17: orphan hook + not registered → no hook-registration"
else
    fail "17: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi
teardown_tmp

# --- 18: settings.json itself modified (no hooks/*.js staged) → hook-registration
run_gate --files settings.json --settings-path "$SETTINGS_EMPTY"
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "hook-registration"; then
    pass "18: settings.json alone → hook-registration"
else
    fail "18: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi

# ============================================================================
# Skill-orchestration cases (19–20)
# ============================================================================

# --- 19: skills/some-skill/SKILL.md modified → skill-orchestration
run_gate --files skills/some-skill/SKILL.md
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "skill-orchestration"; then
    pass "19: skills/<name>/SKILL.md → skill-orchestration"
else
    fail "19: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi

# --- 20: skills/_shared/foo.md → skill-orchestration (recursive coverage)
run_gate --files skills/_shared/foo.md
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "skill-orchestration"; then
    pass "20: skills/_shared/foo.md → skill-orchestration (recursive)"
else
    fail "20: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi

# ============================================================================
# Pwsh-required body-scan (21–22)
# ============================================================================

# --- 21: hooks/foo.js body contains 'powershell' → pwsh-required
setup_tmp
hook_pwsh="$TMP/hooks/pwsh-touching.js"
mkdir -p "$(dirname "$hook_pwsh")"
cat > "$hook_pwsh" <<'EOF'
// This hook spawns powershell.exe to do its job.
const { spawn } = require('child_process');
spawn('powershell', ['-NoProfile', '-Command', 'Get-ChildItem']);
EOF
run_gate --files "$hook_pwsh"
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens" | grep -q "pwsh-required"; then
    pass "21: hook body mentions powershell → pwsh-required"
else
    fail "21: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi
teardown_tmp

# --- 22: Same body but '# Tags: pwsh-not-required' → opt-out, no pwsh-required
setup_tmp
hook_optout="$TMP/hooks/pwsh-optout.js"
mkdir -p "$(dirname "$hook_optout")"
cat > "$hook_optout" <<'EOF'
// Tags: pwsh-not-required
// This hook mentions powershell only in a string literal for documentation.
const note = 'powershell handled separately';
console.log(note);
EOF
run_gate --files "$hook_optout"
tokens="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && ! echo "$tokens" | grep -q "pwsh-required"; then
    pass "22: hook body has pwsh-not-required tag → opt-out"
else
    fail "22: rc=$GATE_RC tokens=[$tokens] stderr=$GATE_STDERR"
fi
teardown_tmp

# ============================================================================
# WE-8 path: branch-commit fallback when staged is empty (cases 23-24)
# Issue #1316 — check-verification-gate.sh auto mode must fall back to
# `git diff $(git merge-base HEAD <default-branch>)...HEAD --name-only`
# when `git diff --cached --name-only` is empty (nothing staged yet, e.g.
# at the WE-8 pre-final-report gate before the final commit).
#
# EXPECTED: cases 23-24 FAIL until the WE-8 fallback is implemented in
#           bin/check-verification-gate.sh auto mode.
# ============================================================================

setup_wt_repo() {
    # Build a git repo on a feature branch with a committed hooks/foo.js.
    local repo="$1"
    mkdir -p "$repo/hooks"
    (
        cd "$repo"
        # Use explicit -b main so the default branch is deterministic regardless
        # of host git config (avoids ambiguity between main/master).
        git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
        git config user.email test@example.com
        git config user.name Test
        git config commit.gpgsign false
        echo "initial" > README.md
        git -c core.hooksPath="" add README.md
        git -c core.hooksPath="" commit -q -m initial
        # Switch to feature branch.
        git -c core.hooksPath="" switch -q -c feature/test-wt
        # Commit hooks/foo.js on the feature branch.
        echo "// registered hook" > hooks/foo.js
        git -c core.hooksPath="" add hooks/foo.js
        git -c core.hooksPath="" commit -q -m "add hooks/foo.js"
    )
}

# --- 23: WE-8 path: staged empty + branch has hooks/foo.js committed
#         → auto mode returns hook-registration.
# Requires: auto mode falls back to `git diff <merge-base>...HEAD --name-only`.
setup_tmp
wt_repo="$TMP/wt-repo"
setup_wt_repo "$wt_repo"
# Build a temp settings file that registers foo.
tmp_settings="$TMP/settings-with-foo.json"
cp "$SETTINGS_WITH_FOO" "$tmp_settings"
# Run check-verification-gate.sh in auto mode from within the feature branch repo.
# Staged index is empty (no git add done after the commit above).
out_file23="$(mktemp)"; err_file23="$(mktemp)"
rc23=0
(
    cd "$wt_repo"
    SETTINGS_PATH="$tmp_settings" \
    run_with_timeout 15 bash "$CHECK_SCRIPT" --settings-path "$tmp_settings" \
        >"$out_file23" 2>"$err_file23"
) || rc23=$?
GATE_RC=$rc23
GATE_STDOUT="$(cat "$out_file23")"
tokens23="$(printf '%s\n' "$GATE_STDOUT" | sed -n 's/^CATEGORY: \([^	]*\)	.*/\1/p' | tr '\n' ' ')"
if [ "$rc23" -eq 0 ] && echo "$tokens23" | grep -q "hook-registration"; then
    pass "23: WE-8 path (staged empty, branch has hooks/foo.js) → hook-registration via fallback"
else
    fail "23: rc=$rc23 expected hook-registration from branch-commit fallback, got tokens=[$tokens23] stderr=[$(head -2 "$err_file23")]"
fi
rm -f "$out_file23" "$err_file23"
teardown_tmp

# --- 24: Non-regression — existing staged-file path still works after WE-8 patch.
#         hooks/foo.js staged (not committed) → hook-registration (original case 16).
setup_tmp
hook_foo24="$TMP/hooks/foo.js"
mkdir -p "$(dirname "$hook_foo24")"
echo "// registered hook" > "$hook_foo24"
run_gate --files "$hook_foo24" --settings-path "$SETTINGS_WITH_FOO"
tokens24="$(gate_tokens | tr '\n' ' ')"
if [ "$GATE_RC" -eq 0 ] && echo "$tokens24" | grep -q "hook-registration"; then
    pass "24: non-regression — staged hooks/foo.js + registered → hook-registration (unchanged)"
else
    fail "24: rc=$GATE_RC tokens=[$tokens24] stderr=$GATE_STDERR"
fi
teardown_tmp

# --- 25 (C6): WE-8 path — second category: staged empty + branch has skills/foo.md
#         committed → skill-orchestration (not just hook-registration).
#         Verifies the WE-8 fallback applies to all categories, not just hooks.
# EXPECTED: FAIL until the WE-8 fallback is implemented.
setup_wt_repo_skills() {
    local repo="$1"
    mkdir -p "$repo/skills/my-skill"
    (
        cd "$repo"
        git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
        git config user.email test@example.com
        git config user.name Test
        git config commit.gpgsign false
        echo "initial" > README.md
        git -c core.hooksPath="" add README.md
        git -c core.hooksPath="" commit -q -m initial
        git -c core.hooksPath="" switch -q -c feature/skill-test
        echo "# My skill" > skills/my-skill/SKILL.md
        git -c core.hooksPath="" add skills/my-skill/SKILL.md
        git -c core.hooksPath="" commit -q -m "add skill"
    )
}
setup_tmp
skills_repo="$TMP/skills-repo"
setup_wt_repo_skills "$skills_repo"
out_file25="$(mktemp)"; err_file25="$(mktemp)"
GATE_RC25=0
(
    cd "$skills_repo"
    run_with_timeout 15 bash "$CHECK_SCRIPT" >"$out_file25" 2>"$err_file25"
) || GATE_RC25=$?
GATE_STDOUT25="$(cat "$out_file25")"
tokens25="$(printf '%s\n' "$GATE_STDOUT25" | sed -n 's/^CATEGORY: \([^	]*\)	.*/\1/p' | tr '\n' ' ')"
if [ "$GATE_RC25" -eq 0 ] && echo "$tokens25" | grep -q "skill-orchestration"; then
    pass "25: WE-8 path (staged empty, branch has skills/foo.md) → skill-orchestration via fallback"
else
    fail "25: rc=$GATE_RC25 expected skill-orchestration from branch-commit fallback, got tokens=[$tokens25] stderr=[$(head -2 "$err_file25")]"
fi
rm -f "$out_file25" "$err_file25"
teardown_tmp

# --- 26 (C6): WE-8 error case — no git remote / no merge-base available.
#         When the branch has no upstream and git merge-base fails, auto mode
#         must fall back gracefully (exit 0, not crash) — possibly to empty output.
# EXPECTED: PASS both before and after fix (error case must not crash).
setup_tmp
orphan_repo="$TMP/orphan-repo"
mkdir -p "$orphan_repo"
(
    cd "$orphan_repo"
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    git config user.email test@example.com
    git config user.name Test
    git config commit.gpgsign false
    echo "initial" > README.md
    git -c core.hooksPath="" add README.md
    git -c core.hooksPath="" commit -q -m initial
    # Branch with NO main/master parent — no merge-base available.
    git -c core.hooksPath="" switch -q -c feature/orphan-no-base
    echo "code" > app.js
    git -c core.hooksPath="" add app.js
    git -c core.hooksPath="" commit -q -m "app"
)
out_file26="$(mktemp)"; err_file26="$(mktemp)"
(
    cd "$orphan_repo"
    run_with_timeout 15 bash "$CHECK_SCRIPT" >"$out_file26" 2>"$err_file26"
) || rc26=$?
rc26=${rc26:-0}
if [[ "$rc26" -eq 0 || "$rc26" -eq 2 || "$rc26" -eq 3 ]]; then
    pass "26: no merge-base available → auto mode exits cleanly (rc=$rc26, no crash)"
else
    fail "26: unexpected exit code $rc26 when no merge-base available"
fi
rm -f "$out_file26" "$err_file26"
teardown_tmp

# --- 27 (C6): staged files exist AND branch has hook changes → staged path takes priority.
#         When git diff --cached returns files, auto mode must use those (the staged set),
#         NOT fall back to the branch-commit diff. This prevents double-counting and
#         ensures staged-path semantics dominate WE-8 fallback semantics.
#
#         Setup: repo on feature/test-wt with hooks/foo.js COMMITTED (branch diff would
#         return hook-registration) but ALSO skills/my-skill/SKILL.md STAGED (index path
#         would return skill-orchestration). After fix, auto mode must see the staged file
#         and return skill-orchestration — NOT fall back to hook-registration from branch.
#
# EXPECTED: FAIL before the WE-8 fallback is implemented with the staged-path priority
#           guard; PASS once the guard is in place (staged non-empty → skip branch diff).
setup_tmp
hybrid_repo="$TMP/hybrid-repo"
mkdir -p "$hybrid_repo/hooks" "$hybrid_repo/skills/my-skill"
(
    cd "$hybrid_repo"
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    git config user.email test@example.com
    git config user.name Test
    git config commit.gpgsign false
    echo "initial" > README.md
    git -c core.hooksPath="" add README.md
    git -c core.hooksPath="" commit -q -m initial
    # Feature branch: commit hooks/foo.js (branch diff = hook-registration).
    git -c core.hooksPath="" switch -q -c feature/hybrid-test
    echo "// registered hook" > hooks/foo.js
    git -c core.hooksPath="" add hooks/foo.js
    git -c core.hooksPath="" commit -q -m "add hooks/foo.js"
    # Now stage skills/my-skill/SKILL.md without committing (staged path = skill-orchestration).
    echo "# My skill" > skills/my-skill/SKILL.md
    git -c core.hooksPath="" add skills/my-skill/SKILL.md
)
hybrid_settings="$TMP/hybrid-settings.json"
cp "$SETTINGS_WITH_FOO" "$hybrid_settings"
out_file27="$(mktemp)"; err_file27="$(mktemp)"
(
    cd "$hybrid_repo"
    run_with_timeout 15 bash "$CHECK_SCRIPT" --settings-path "$hybrid_settings" \
        >"$out_file27" 2>"$err_file27"
) || true
GATE_STDOUT27="$(cat "$out_file27")"
tokens27="$(printf '%s\n' "$GATE_STDOUT27" | sed -n 's/^CATEGORY: \([^	]*\)	.*/\1/p' | tr '\n' ' ')"
# Staged path took priority → only staged file (SKILL.md) was evaluated.
# Must see skill-orchestration and must NOT fall back and also add hook-registration from branch.
if echo "$tokens27" | grep -q "skill-orchestration" && ! echo "$tokens27" | grep -q "hook-registration"; then
    pass "27: staged non-empty + branch has hooks → staged takes priority (skill-orchestration only, no hook-registration)"
elif echo "$tokens27" | grep -q "skill-orchestration"; then
    fail "27: staged took priority for skill but also emitted hook-registration from branch diff (fallback not suppressed)"
else
    fail "27: expected skill-orchestration from staged SKILL.md, got tokens=[$tokens27] stderr=[$(head -2 "$err_file27")]"
fi
rm -f "$out_file27" "$err_file27"
teardown_tmp

# ============================================================================
# Bash-version guard (28-29)
# This classifier depends on bash-4 semantics (associative array MATCHED,
# ${!MATCHED[@]} iteration). The guard rejects bash major < 4 up front.
# AGENTS_BASH_MAJOR_OVERRIDE forces the detected major version for the test.
#
# Exit-code contract: the guard MUST exit 3 (internal-error slot per
# user-verified.md), distinct from usage-error 2 and verdict-produced 0.
# ============================================================================

# --- 28: bash major < 4 → version guard fires: exit 3 + "requires bash" stderr.
# TEST_EXPECTED_FAIL_UNTIL_GUARD_IMPLEMENTED (guard not yet in source)
out28="$(mktemp)"; err28="$(mktemp)"
export AGENTS_BASH_MAJOR_OVERRIDE=3
run_with_timeout 15 bash "$CHECK_SCRIPT" --files foo.md >"$out28" 2>"$err28"
rc28=$?
unset AGENTS_BASH_MAJOR_OVERRIDE
if [ "$rc28" -eq 3 ] && grep -qiE "requires bash" "$err28"; then
    pass "28: bash<4 → exit 3 (internal-error slot) + 'requires bash' stderr"
else
    fail "28: expected exit 3 + 'requires bash'; got rc=$rc28 stderr=[$(cat "$err28")]"
fi
rm -f "$out28" "$err28"

# --- 29: bash major >= 4 → guard passes through; exit is NOT 3 (guard did not
# reject). foo.md matches no category → normal exit 0. Passes pre- and post-fix.
out29="$(mktemp)"; err29="$(mktemp)"
export AGENTS_BASH_MAJOR_OVERRIDE=4
run_with_timeout 15 bash "$CHECK_SCRIPT" --files foo.md >"$out29" 2>"$err29"
rc29=$?
unset AGENTS_BASH_MAJOR_OVERRIDE
if [ "$rc29" -ne 3 ]; then
    pass "29: bash>=4 → guard passes through (rc=$rc29 != 3)"
else
    fail "29: expected rc != 3 (guard should not reject bash 4); got rc=$rc29 stderr=[$(cat "$err29")]"
fi
rm -f "$out29" "$err29"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
