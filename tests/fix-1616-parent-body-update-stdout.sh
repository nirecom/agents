#!/bin/bash
# tests/fix-1616-parent-body-update-stdout.sh
# Tests: bin/github-issues/parent-body-update.sh
# Tags: parent-body-update, issue-close, github, stdout-contract, gh-cli, scope:common, pwsh-not-required
#
# Issue #1616 — parent-body-update.sh's final `gh issue edit "$PARENT" --body`
# is a pure side-effect call with NO redirection at all. On success the real gh
# prints the parent issue URL to stdout, so a script whose contract is "no
# stdout, exit code carries the result" starts emitting a URL. Callers that
# branch on "is stdout non-empty" misread that as data.
#
# Fixed state asserted here: the call is wrapped so that stdout+stderr are both
# silenced (`>/dev/null 2>&1`) while failure stays visible (WARN on stderr,
# non-zero exit) — silencing must not swallow the error signal.
#
# TL3 gap (what this test does NOT catch):
# - Whether the REAL `gh issue edit --body` prints the URL on stdout in the
#   installed gh version, and whether it emits anything else (banners, notices).
# - Whether the real GitHub API rejects the edit for reasons the mock cannot
#   reproduce (permissions, body size, concurrent modification).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT_SCRIPT="$AGENTS_DIR/bin/github-issues/parent-body-update.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

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

if [ ! -f "$PARENT_SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/github-issues/parent-body-update.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        export PATH="${PATH#"$MOCK_DIR:"}"
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR GH_MOCK_COMMENT_LOG GH_META_LABEL GH_MOCK_EDIT_RC 2>/dev/null || true
}

# Config-dependent env vars pinned explicitly in EVERY case below
# (rules/test-design.md "Config-dependent branches"):
#   GH_META_LABEL   — parent-body-update.sh:40-44 meta short-circuit.
#                     "false" = non-meta parent, so the script proceeds to the
#                     edit under test. Never rely on the mock's default.
#   GH_MOCK_EDIT_RC — exit code of the mocked `gh issue edit "$PARENT" --body`.
#                     "0" = success. Never rely on the mock's default.

# ---------------------------------------------------------------------------
# T2-1: parent_42 → exit 0, stdout completely empty, side effect preserved.
# Pre-fix RED: the unredirected gh issue edit leaks the parent issue URL.
# ---------------------------------------------------------------------------
setup_tmp
OUT=$(GH_MOCK_SCENARIO=parent_42 GH_META_LABEL=false GH_MOCK_EDIT_RC=0 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 2>/dev/null)
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && echo "$LOG" | grep -q "EDIT_PARENT_99:"; then
    pass "T2-1: parent exists → exit 0, stdout empty, parent body still edited"
else
    fail "T2-1: expected exit 0 + empty stdout + EDIT_PARENT_99 side effect; got rc=$RC stdout='$OUT' log='$LOG'"
fi
teardown_tmp

# ---------------------------------------------------------------------------
# T2-2: parent_empty (no parent) → early return, stdout empty, exit 0.
# Regression guard on an already-correct path (green before and after the fix).
# ---------------------------------------------------------------------------
setup_tmp
OUT=$(GH_MOCK_SCENARIO=parent_empty GH_META_LABEL=false GH_MOCK_EDIT_RC=0 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 2>/dev/null)
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ! echo "$LOG" | grep -q "EDIT_PARENT_"; then
    pass "T2-2: no parent → exit 0, stdout empty, no edit"
else
    fail "T2-2: expected exit 0 + empty stdout + no edit; got rc=$RC stdout='$OUT' log='$LOG'"
fi
teardown_tmp

# ---------------------------------------------------------------------------
# T2-3: gh issue edit fails → exit 1, WARN on stderr, stdout still empty.
# Silencing stdout must NOT hide the failure — the fix has to add an explicit
# `if ! ... ; then echo WARN >&2; exit 1; fi` wrapper.
#
# Non-vacuity: the failing mock emits a distinct canary on BOTH streams
# (GHCANARY_EDIT_STDOUT_LEAK / GHCANARY_EDIT_STDERR_LEAK), so this case proves
# the `>/dev/null 2>&1` at parent-body-update.sh:49 really swallows the raw gh
# output on the FAILURE path — not just the success path. The only stderr the
# caller may see is the script's own WARN line.
# ---------------------------------------------------------------------------
setup_tmp
ERR_FILE="$TMP/stderr.txt"
OUT=$(GH_MOCK_SCENARIO=parent_42 GH_META_LABEL=false GH_MOCK_EDIT_RC=1 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 2>"$ERR_FILE")
RC=$?
ERR=$(cat "$ERR_FILE" 2>/dev/null)
T2_3_ERR_LINES=$(printf '%s' "$ERR" | grep -c . 2>/dev/null || echo 0)
if [ "$RC" -eq 1 ] \
   && [ -z "$OUT" ] \
   && ! printf '%s' "$OUT" | grep -q "GHCANARY_" \
   && echo "$ERR" | grep -q "WARN: parent body update failed for #99" \
   && ! echo "$ERR" | grep -q "GHCANARY_" \
   && [ "$T2_3_ERR_LINES" -eq 1 ]; then
    pass "T2-3: gh issue edit failure → exit 1, only own WARN on stderr, no canary on either stream"
else
    fail "T2-3: expected exit 1 + sole WARN line on stderr + empty stdout + no GHCANARY_ leak; got rc=$RC stdout='$OUT' stderr='$ERR'"
fi
teardown_tmp

# ---------------------------------------------------------------------------
# T2-4 (static): the parent-body write must be fully silenced.
# Permanent regression guard on the FIXED state — RED until #1616 lands.
# ---------------------------------------------------------------------------
MATCHES=$(grep -nE 'gh issue edit "\$PARENT" --body' "$PARENT_SCRIPT" || true)
if [ -z "$MATCHES" ]; then
    fail "T2-4: no 'gh issue edit \"\$PARENT\" --body' line found (call site moved?)"
else
    BAD=""
    while IFS= read -r ln; do
        case "$ln" in
            *'>/dev/null 2>&1'*) ;;
            *) BAD="$BAD$ln"$'\n' ;;
        esac
    done <<< "$MATCHES"
    if [ -z "$BAD" ]; then
        pass "T2-4: parent-body write fully silenced (>/dev/null 2>&1)"
    else
        fail "T2-4: parent-body write still leaks stdout (missing '>/dev/null 2>&1'):
$BAD"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
