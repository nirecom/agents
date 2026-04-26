#!/bin/bash
# Tests for bin/review-code-codex
# Verifies: SKIPPED/PERFORMED/FAILED status labels, JSONL logging,
# exit-0 guarantee, security (no shell injection from diff content),
# and idempotency.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-code-codex"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Setup: temp git repo with a commit on a branch vs main
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
LOG_DIR="$TMPDIR_BASE/.claude/projects/codex-review"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
echo "init" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "initial"
git -C "$REPO" checkout -q -b feature-test
echo "change" >> "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "feature commit"

# Mock codex bin dir
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"

# Portable: use system timeout if available
_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 70 "$@"
    else
        perl -e 'alarm 70; exec @ARGV' -- "$@"
    fi
}

# Run script in $REPO with a given PATH and HOME
run_in_repo() {
    local _path="${1}"; shift
    local _home="$TMPDIR_BASE"
    (cd "$REPO" && PATH="$_path" HOME="$_home" _timeout bash "$SCRIPT" "$@") || true
}

# ---------------------------------------------------------------------------
# 1. SKIPPED — codex CLI not installed
# Use only minimal system paths so codex (in fnm/nvm/npm dirs) is not found,
# while bash, git, date, mktemp etc. remain accessible.
# ---------------------------------------------------------------------------
MINIMAL_PATH="/usr/local/bin:/usr/bin:/bin"
EXIT_CODE=0
OUTPUT=$(run_in_repo "$MINIMAL_PATH" --base main --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "SKIPPED case: expected exit 0, got $EXIT_CODE"
else
    pass "SKIPPED case: exits 0 when codex not found"
fi

if echo "$OUTPUT" | grep -q "## Codex Review: SKIPPED — codex CLI not installed"; then
    pass "SKIPPED case: correct status label present"
else
    fail "SKIPPED case: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 2. Visibility invariant — status label always present
# ---------------------------------------------------------------------------
if echo "$OUTPUT" | grep -q "## Codex Review:"; then
    pass "Visibility invariant: status label always present in SKIPPED case"
else
    fail "Visibility invariant: no '## Codex Review:' line in SKIPPED output"
fi

# ---------------------------------------------------------------------------
# 3. JSONL logging on SKIPPED
# ---------------------------------------------------------------------------
(cd "$REPO" && PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main >/dev/null 2>&1) || true
if ls "$LOG_DIR"/*.jsonl >/dev/null 2>&1; then
    if grep -q '"status":"skipped"' "$LOG_DIR"/*.jsonl; then
        pass "JSONL logging: skipped status written"
    else
        fail "JSONL logging: expected 'skipped' in JSONL. Contents: $(cat "$LOG_DIR"/*.jsonl 2>/dev/null)"
    fi
else
    fail "JSONL logging: no log file created under $LOG_DIR"
fi

# ---------------------------------------------------------------------------
# 4. PERFORMED — mock codex that exits 0
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "HIGH: The implementation looks risky."
echo "LOW: Minor style nit."
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_in_repo "$MOCK_BIN:$PATH" --base main --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "PERFORMED case: expected exit 0, got $EXIT_CODE"
else
    pass "PERFORMED case: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Review: PERFORMED"; then
    pass "PERFORMED case: correct status label present"
else
    fail "PERFORMED case: status label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "begin-codex-output"; then
    pass "PERFORMED case: output wrapped in safety comment block"
else
    fail "PERFORMED case: output not wrapped. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 5. FAILED — mock codex exits non-zero
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "some error" >&2
exit 2
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_in_repo "$MOCK_BIN:$PATH" --base main --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "FAILED case: expected exit 0, got $EXIT_CODE"
else
    pass "FAILED case: exits 0 despite codex failure"
fi

if echo "$OUTPUT" | grep -q "## Codex Review: FAILED — codex exec exit code 2"; then
    pass "FAILED case: correct status label present"
else
    fail "FAILED case: status label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "## Codex Review:"; then
    pass "Visibility invariant: status label present in FAILED case"
else
    fail "Visibility invariant: no '## Codex Review:' in FAILED output"
fi

# ---------------------------------------------------------------------------
# 6. FAILED — simulate timeout via a wrapper that makes codex return exit 124
#    (same exit code as `timeout` when it kills a process). Avoids actually
#    waiting 60 seconds which would exceed the outer test timeout.
# ---------------------------------------------------------------------------
TIMEOUT_BIN="$TMPDIR_BASE/timeout-shim-bin"
mkdir -p "$TIMEOUT_BIN"
# Replace system `timeout` with a shim that always runs the command but exits 124
# so the script branch for timeout is exercised without waiting.
cat > "$TIMEOUT_BIN/timeout" << 'MOCK_EOF'
#!/usr/bin/env bash
shift  # drop the timeout duration arg
"$@" >/dev/null 2>&1 || true
exit 124
MOCK_EOF
chmod +x "$TIMEOUT_BIN/timeout"

cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "would run forever"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

OUTPUT=$(cd "$REPO" && PATH="$TIMEOUT_BIN:$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --base main --no-log 2>&1 || true)
EXIT_CODE=0
(cd "$REPO" && PATH="$TIMEOUT_BIN:$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --base main --no-log >/dev/null 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "TIMEOUT case: expected exit 0, got $EXIT_CODE"
else
    pass "TIMEOUT case: exits 0 despite codex timeout"
fi

if echo "$OUTPUT" | grep -q "## Codex Review: FAILED — timeout"; then
    pass "TIMEOUT case: correct status label present"
else
    fail "TIMEOUT case: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 7. Security: malicious diff content does not cause shell injection
# ---------------------------------------------------------------------------
INJECTION_REPO="$TMPDIR_BASE/inject-repo"
mkdir -p "$INJECTION_REPO"
git -C "$INJECTION_REPO" init -q
git -C "$INJECTION_REPO" config user.email "test@example.com"
git -C "$INJECTION_REPO" config user.name "Test"
echo "init" > "$INJECTION_REPO/safe.txt"
git -C "$INJECTION_REPO" add safe.txt
git -C "$INJECTION_REPO" commit -q -m "initial"
git -C "$INJECTION_REPO" checkout -q -b injection-test

printf '%s\n' '$(touch /tmp/codex-injection-marker)' '`touch /tmp/codex-injection-marker2`' > "$INJECTION_REPO/evil.txt"
git -C "$INJECTION_REPO" add evil.txt
git -C "$INJECTION_REPO" commit -q -m "evil commit"

cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "codex ran safely"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

(cd "$INJECTION_REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --no-log >/dev/null 2>&1) || true

if [[ -f /tmp/codex-injection-marker ]] || [[ -f /tmp/codex-injection-marker2 ]]; then
    fail "Security: shell injection succeeded — marker files created"
    rm -f /tmp/codex-injection-marker /tmp/codex-injection-marker2
else
    pass "Security: diff content with shell metacharacters not evaluated"
fi

# ---------------------------------------------------------------------------
# 8. Security: invalid --base ref rejected
# ---------------------------------------------------------------------------
OUTPUT=$(run_in_repo "$PATH" --base "main; rm -rf /" --no-log 2>&1)
if echo "$OUTPUT" | grep -q "FAILED — invalid --base ref"; then
    pass "Security: injected --base ref rejected with FAILED label"
else
    fail "Security: injected --base ref not rejected. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 9. Idempotency: two runs don't mutate git state
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "clean"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

BEFORE=$(git -C "$REPO" status --porcelain)
run_in_repo "$MOCK_BIN:$PATH" --base main --no-log >/dev/null 2>&1 || true
run_in_repo "$MOCK_BIN:$PATH" --base main --no-log >/dev/null 2>&1 || true
AFTER=$(git -C "$REPO" status --porcelain)

if [[ "$BEFORE" == "$AFTER" ]]; then
    pass "Idempotency: git state unchanged after two runs"
else
    fail "Idempotency: git state changed. Before='$BEFORE' After='$AFTER'"
fi

# ---------------------------------------------------------------------------
# 10. JSONL append-only (two runs → two entries)
# ---------------------------------------------------------------------------
rm -rf "$LOG_DIR"
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "findings"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

(cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main >/dev/null 2>&1) || true
(cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main >/dev/null 2>&1) || true

JSONL_COUNT=0
if ls "$LOG_DIR"/*.jsonl >/dev/null 2>&1; then
    JSONL_COUNT=$(cat "$LOG_DIR"/*.jsonl | wc -l)
fi

if (( JSONL_COUNT >= 2 )); then
    pass "JSONL idempotency: two runs produced $JSONL_COUNT entries (append-only)"
else
    fail "JSONL idempotency: expected >=2 entries, got $JSONL_COUNT"
fi

# ---------------------------------------------------------------------------
# 11. FAILED — --base without argument (output contract must hold)
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(cd "$REPO" && HOME="$TMPDIR_BASE" bash "$SCRIPT" --base --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "--base missing arg: expected exit 0, got $EXIT_CODE"
else
    pass "--base missing arg: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Review: FAILED"; then
    pass "--base missing arg: FAILED status label present"
else
    fail "--base missing arg: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 12. FAILED — git diff fails (invalid base ref)
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "should not reach here"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --base nonexistent-branch-xyz --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "git diff fail: expected exit 0, got $EXIT_CODE"
else
    pass "git diff fail: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Review: FAILED — git diff failed"; then
    pass "git diff fail: FAILED status label present"
else
    fail "git diff fail: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
