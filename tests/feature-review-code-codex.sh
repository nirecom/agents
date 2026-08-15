#!/bin/bash
# Tests: bin/review-code-codex
# Tags: codex, review, labels, github, bin, scope:common, pwsh-not-required, TL2
# Tests for bin/review-code-codex
# Verifies: SKIPPED/PERFORMED/FAILED status labels, JSONL logging,
# exit-0 guarantee, security (no shell injection from diff content),
# and idempotency.
#
# TL3 gap (what this suite does NOT catch):
# - The real codex CLI: every case here substitutes a shell mock on PATH, so the script's
#   actual argument, stdin and exit-code contract with the installed binary is unverified,
#   as is whether a prompt inside the line budget fits the live model's context window.
# - The installed environment's own config: cases pin AGENTS_CONFIG_DIR at fixtures, so a
#   precedence or lookup bug that only appears against the real ~/.claude .env is invisible.
# - The host filesystem's path rules: fixtures with hostile or non-ASCII filenames are created
#   by whatever filesystem the runner is on, and names it refuses are reported SKIP, not run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: merge-base-suspect.
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
git -C "$REPO" config core.hooksPath "$REPO/.git/no-such-hooks"
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

# Status-preserving twin of run_in_repo, for the rows that assert the exit-0 contract.
#
# run_in_repo ends in `|| true`, so every caller sees status 0 no matter what the script did.
# The three cases below were written as `OUTPUT=$(run_in_repo …) || EXIT_CODE=$?` — an
# assertion that can only ever observe 0, and would keep passing if the script started exiting
# 2 on every run. The exit-0 guarantee is the reason this script can be wired into a
# quality-gate chain at all, so it is the one contract that must not be checked through a
# runner that discards the status.
#
# The status also cannot be returned through a command substitution: the assignment would land
# in the subshell and be thrown away. So stdout and stderr go to a file, and the real
# subprocess status is left in RUN_STATUS for the caller.
RUN_STATUS=0
RUN_OUTPUT_FILE="$TMPDIR_BASE/run-output.txt"
run_in_repo_status() { # <path> [args...] ; sets RUN_STATUS and OUTPUT
    local _path="${1}"; shift
    RUN_STATUS=0
    (cd "$REPO" && PATH="$_path" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" "$@") \
        >"$RUN_OUTPUT_FILE" 2>&1 || RUN_STATUS=$?
    OUTPUT="$(cat "$RUN_OUTPUT_FILE")"
}

# ---------------------------------------------------------------------------
# 1. SKIPPED — codex CLI not installed
# Use only minimal system paths so codex (in fnm/nvm/npm dirs) is not found,
# while bash, git, date, mktemp etc. remain accessible.
# ---------------------------------------------------------------------------
MINIMAL_PATH="/usr/local/bin:/usr/bin:/bin"
run_in_repo_status "$MINIMAL_PATH" --base main --no-log
EXIT_CODE=$RUN_STATUS

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

run_in_repo_status "$MOCK_BIN:$PATH" --base main --no-log
EXIT_CODE=$RUN_STATUS

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

run_in_repo_status "$MOCK_BIN:$PATH" --base main --no-log
EXIT_CODE=$RUN_STATUS

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
git -C "$INJECTION_REPO" config core.hooksPath "$INJECTION_REPO/.git/no-such-hooks"
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
# 13. Adversarial preamble: assert "authored by Claude" in prompt sent to codex
# ---------------------------------------------------------------------------
CAPTURE_FILE="$TMPDIR_BASE/captured-code-prompt.txt"
cat > "$MOCK_BIN/codex" << MOCK_EOF
#!/usr/bin/env bash
cat > "$CAPTURE_FILE"
echo "HIGH: Something looks risky."
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

(cd "$REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --no-log >/dev/null 2>&1) || true

if [[ -f "$CAPTURE_FILE" ]] && grep -q "authored by Claude" "$CAPTURE_FILE"; then
    pass "Adversarial preamble: 'authored by Claude' present in prompt sent to codex"
else
    fail "Adversarial preamble: 'authored by Claude' not found in captured prompt. File exists: $([ -f "$CAPTURE_FILE" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# 14. Uncommitted-fallback: unstaged-only changes on a fresh branch are reviewed
#     (regression guard — earlier fallback used `git diff --cached` and missed
#     unstaged working tree, the common state at workflow Step 6).
# ---------------------------------------------------------------------------
FRESH_REPO="$TMPDIR_BASE/fresh-repo"
mkdir -p "$FRESH_REPO"
git -C "$FRESH_REPO" init -q
git -C "$FRESH_REPO" config core.hooksPath "$FRESH_REPO/.git/no-such-hooks"
git -C "$FRESH_REPO" config user.email "test@example.com"
git -C "$FRESH_REPO" config user.name "Test"
echo "init" > "$FRESH_REPO/README.md"
git -C "$FRESH_REPO" add README.md
git -C "$FRESH_REPO" commit -q -m "initial"
git -C "$FRESH_REPO" checkout -q -b fresh-branch
# Unstaged change only — no commits past main, nothing staged.
echo "unstaged edit" >> "$FRESH_REPO/README.md"

cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "HIGH: noted"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

OUTPUT=$(cd "$FRESH_REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --no-log 2>&1) || true

if echo "$OUTPUT" | grep -q "## Codex Review: PERFORMED"; then
    pass "Uncommitted-fallback: unstaged-only changes reviewed (PERFORMED)"
else
    fail "Uncommitted-fallback: unstaged-only changes not reviewed. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "reviewing uncommitted changes"; then
    pass "Uncommitted-fallback: note message present"
else
    fail "Uncommitted-fallback: note message missing. Output: $OUTPUT"
fi

# Cases 15-17 (uncommitted / untracked collection) live in a sourced part: this file is past
# the 500-line hard split limit, and they reuse TMPDIR_BASE, MOCK_BIN and _timeout above.
# shellcheck source=./feature-review-code-codex/uncommitted-and-untracked.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/uncommitted-and-untracked.sh"

# The X-series truncation/base-state scope rows (#1638) live in a sourced part for the same
# reason, and must run after the cases above to preserve the original execution order.
# shellcheck source=./feature-review-code-codex/truncation-scope.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/truncation-scope.sh"

# The remaining merge-base scope rows live in a sourced part: this file is already past the
# 500-line hard split limit, and they reuse REPO, MOCK_BIN and _timeout above.
# shellcheck source=./feature-review-code-codex/base-state-scope.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/base-state-scope.sh"

# The #1976/#1750 path-priority rows come last: they reuse the exact-size fixtures the
# boundary rows above built (Y_AT_REPO / Y_OVER_REPO) rather than rebuilding them.
# shellcheck source=./feature-review-code-codex/path-priority.sh
. "$AGENTS_ROOT/tests/feature-review-code-codex/path-priority.sh"

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
