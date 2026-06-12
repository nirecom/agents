#!/bin/bash
# Tests: bin/check-verification-gate.sh
# Tags: verification-gate, risk-category, user-verified, pwsh-required
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
