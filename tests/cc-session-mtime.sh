#!/bin/bash
# Tests: bin/cc-session-mtime, bin/cc-session-mtime.ps1
# Tags: bin, mtime, session, pwsh-required, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Actual VS Code restart scenario where the extension writes metadata entries live
# - macOS BSD touch -d format differences from GNU touch (GNU assumed here)
# - PS1 timezone edge cases when local TZ differs significantly from UTC
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: pwsh-required

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CC_SESSION_MTIME="$REPO_DIR/bin/cc-session-mtime"
CC_SESSION_MTIME_PS1="$REPO_DIR/bin/cc-session-mtime.ps1"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
skip() { echo "  SKIP: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

make_claude_dir() {
    local d="$1"
    mkdir -p "$d/projects/test-proj"
}

echo "=== cc-session-mtime (bash) tests ==="

# --- Normal: mtime set to last timestamp value ---
echo "[bash] Normal: mtime set to last timestamp value"
CLAUDE1="$TMPDIR_BASE/test1/.claude"
make_claude_dir "$CLAUDE1"
echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE1/projects/test-proj/session.jsonl"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE1/projects/test-proj/session.jsonl"
expected_mtime=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
run_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE1" || run_exit=$?
if [ "$run_exit" -ne 0 ]; then
    fail "mtime set to last timestamp value: cc-session-mtime exited $run_exit (binary missing or error)"
elif [ -n "$expected_mtime" ]; then
    actual=$(stat -c %Y "$CLAUDE1/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
    if [ "$actual" -eq "$expected_mtime" ]; then
        pass "mtime set to last timestamp value"
    else
        fail "mtime wrong: expected $expected_mtime got $actual"
    fi
else
    skip "date -d not available on this platform"
fi

# --- Normal: --dry-run does not change mtime ---
echo "[bash] Normal: --dry-run does not change mtime"
CLAUDE2="$TMPDIR_BASE/test2/.claude"
make_claude_dir "$CLAUDE2"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"hello"}' > "$CLAUDE2/projects/test-proj/session.jsonl"
# Set mtime to a known old value
touch -d "2020-01-01T00:00:00Z" "$CLAUDE2/projects/test-proj/session.jsonl" 2>/dev/null || true
before_mtime=$(stat -c %Y "$CLAUDE2/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
dry_exit=0
dry_output=$("$CC_SESSION_MTIME" --dry-run --claude-dir "$CLAUDE2" 2>&1) || dry_exit=$?
after_mtime=$(stat -c %Y "$CLAUDE2/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
if [ "$dry_exit" -ne 0 ] && [ -z "$dry_output" ]; then
    fail "--dry-run: cc-session-mtime exited $dry_exit (binary missing or error)"
else
    if [ "$before_mtime" -eq "$after_mtime" ]; then
        pass "--dry-run does not change mtime"
    else
        fail "--dry-run changed mtime (before=$before_mtime after=$after_mtime)"
    fi
    if echo "$dry_output" | grep -qi "would"; then
        pass "--dry-run output contains 'would'"
    else
        fail "--dry-run output does not contain 'would': $dry_output"
    fi
fi

# --- Edge: metadata tail — last timestamp line (not last line) is used ---
echo "[bash] Edge: metadata tail — last timestamp line used (bug regression)"
CLAUDE3="$TMPDIR_BASE/test3/.claude"
make_claude_dir "$CLAUDE3"
echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE3/projects/test-proj/session.jsonl"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE3/projects/test-proj/session.jsonl"
echo '{"ai-title":"My session","mode":"auto"}' >> "$CLAUDE3/projects/test-proj/session.jsonl"
expected_mtime=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
run3_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE3" || run3_exit=$?
if [ "$run3_exit" -ne 0 ]; then
    fail "metadata tail: cc-session-mtime exited $run3_exit (binary missing or error)"
elif [ -n "$expected_mtime" ]; then
    actual=$(stat -c %Y "$CLAUDE3/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
    wrong_mtime=$(date -d "2024-06-01T08:00:00.000Z" +%s 2>/dev/null || echo "")
    if [ "$actual" -eq "$expected_mtime" ]; then
        pass "metadata tail: mtime from last timestamp line T2"
    elif [ -n "$wrong_mtime" ] && [ "$actual" -eq "$wrong_mtime" ]; then
        fail "metadata tail: mtime set to T1 (head-1 fallback bug) instead of T2"
    else
        fail "metadata tail: mtime wrong (expected=$expected_mtime got=$actual)"
    fi
else
    skip "date -d not available on this platform"
fi

# --- Edge: no timestamp lines → file skipped, exit 0 ---
echo "[bash] Edge: no timestamp lines → skipped"
CLAUDE4="$TMPDIR_BASE/test4/.claude"
make_claude_dir "$CLAUDE4"
echo '{"ai-title":"no timestamps here","mode":"auto"}' > "$CLAUDE4/projects/test-proj/session.jsonl"
touch -d "2020-01-01T00:00:00Z" "$CLAUDE4/projects/test-proj/session.jsonl" 2>/dev/null || true
before_mtime=$(stat -c %Y "$CLAUDE4/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
exit_code=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE4" 2>/dev/null || exit_code=$?
after_mtime=$(stat -c %Y "$CLAUDE4/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
if [ "$exit_code" -eq 0 ]; then
    pass "no-timestamp file: exit 0"
else
    fail "no-timestamp file: exit $exit_code (expected 0)"
fi
if [ "$before_mtime" -eq "$after_mtime" ]; then
    pass "no-timestamp file: mtime unchanged"
else
    fail "no-timestamp file: mtime changed unexpectedly"
fi

# --- Edge: .history.jsonl is excluded ---
echo "[bash] Edge: .history.jsonl excluded"
CLAUDE5="$TMPDIR_BASE/test5/.claude"
make_claude_dir "$CLAUDE5"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"history entry"}' > "$CLAUDE5/projects/.history.jsonl"
touch -d "2020-01-01T00:00:00Z" "$CLAUDE5/projects/.history.jsonl" 2>/dev/null || true
before_mtime=$(stat -c %Y "$CLAUDE5/projects/.history.jsonl" 2>/dev/null || echo "0")
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE5" 2>/dev/null || true
after_mtime=$(stat -c %Y "$CLAUDE5/projects/.history.jsonl" 2>/dev/null || echo "0")
if [ "$before_mtime" -eq "$after_mtime" ]; then
    pass ".history.jsonl excluded from mtime restore"
else
    fail ".history.jsonl was processed (mtime changed)"
fi

# --- Edge: --claude-dir flag uses specified dir ---
echo "[bash] Edge: --claude-dir flag"
CLAUDE6="$TMPDIR_BASE/test6/.claude"
make_claude_dir "$CLAUDE6"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"hello"}' > "$CLAUDE6/projects/test-proj/session.jsonl"
expected_mtime=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
run6_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE6" || run6_exit=$?
if [ "$run6_exit" -ne 0 ]; then
    fail "--claude-dir: cc-session-mtime exited $run6_exit (binary missing or error)"
elif [ -n "$expected_mtime" ]; then
    actual=$(stat -c %Y "$CLAUDE6/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
    if [ "$actual" -eq "$expected_mtime" ]; then
        pass "--claude-dir flag uses specified directory"
    else
        fail "--claude-dir: mtime wrong (expected=$expected_mtime got=$actual)"
    fi
else
    skip "date -d not available on this platform"
fi

echo ""
echo "=== cc-session-mtime.ps1 tests (skipped if pwsh unavailable) ==="

if ! command -v pwsh >/dev/null 2>&1; then
    skip "pwsh not available — PS1 tests skipped"
else
    # --- PS1 Normal: mtime set to last timestamp value ---
    echo "[pwsh] Normal: mtime set to last timestamp value"
    CLAUDE_PS1="$TMPDIR_BASE/test-ps1/.claude"
    make_claude_dir "$CLAUDE_PS1"
    echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE_PS1/projects/test-proj/session.jsonl"
    echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE_PS1/projects/test-proj/session.jsonl"
    ps1_result=$(pwsh -NoProfile -Command "
\$ErrorActionPreference = 'Stop'
& '$(cygpath -w "$CC_SESSION_MTIME_PS1" 2>/dev/null || echo "$CC_SESSION_MTIME_PS1")' -ClaudeDir '$(cygpath -w "$CLAUDE_PS1" 2>/dev/null || echo "$CLAUDE_PS1")'
\$f = Get-Item '$(cygpath -w "$CLAUDE_PS1/projects/test-proj/session.jsonl" 2>/dev/null || echo "$CLAUDE_PS1/projects/test-proj/session.jsonl")'
\$expected = [datetime]::Parse('2024-06-01T10:30:00.000Z').ToLocalTime()
\$diff = [math]::Abs((\$f.LastWriteTime - \$expected).TotalSeconds)
if (\$diff -lt 2) { Write-Output 'PASS' } else { Write-Output \"FAIL: mtime=\$(\$f.LastWriteTime) expected=\$expected\" }
" 2>&1) || true
    if echo "$ps1_result" | grep -q "^PASS"; then
        pass "PS1: mtime set to last timestamp value"
    else
        fail "PS1: mtime wrong: $ps1_result"
    fi

    # --- PS1 Edge: metadata tail ---
    echo "[pwsh] Edge: metadata tail"
    CLAUDE_PS1_2="$TMPDIR_BASE/test-ps1-2/.claude"
    make_claude_dir "$CLAUDE_PS1_2"
    echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE_PS1_2/projects/test-proj/session.jsonl"
    echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE_PS1_2/projects/test-proj/session.jsonl"
    echo '{"ai-title":"My session","mode":"auto"}' >> "$CLAUDE_PS1_2/projects/test-proj/session.jsonl"
    ps1_result2=$(pwsh -NoProfile -Command "
\$ErrorActionPreference = 'Stop'
& '$(cygpath -w "$CC_SESSION_MTIME_PS1" 2>/dev/null || echo "$CC_SESSION_MTIME_PS1")' -ClaudeDir '$(cygpath -w "$CLAUDE_PS1_2" 2>/dev/null || echo "$CLAUDE_PS1_2")'
\$f = Get-Item '$(cygpath -w "$CLAUDE_PS1_2/projects/test-proj/session.jsonl" 2>/dev/null || echo "$CLAUDE_PS1_2/projects/test-proj/session.jsonl")'
\$expected = [datetime]::Parse('2024-06-01T10:30:00.000Z').ToLocalTime()
\$diff = [math]::Abs((\$f.LastWriteTime - \$expected).TotalSeconds)
if (\$diff -lt 2) { Write-Output 'PASS' } else { Write-Output \"FAIL: mtime=\$(\$f.LastWriteTime) expected=\$expected\" }
" 2>&1) || true
    if echo "$ps1_result2" | grep -q "^PASS"; then
        pass "PS1: metadata tail: mtime from last timestamp line"
    else
        fail "PS1: metadata tail: mtime wrong: $ps1_result2"
    fi
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
