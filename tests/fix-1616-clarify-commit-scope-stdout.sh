#!/bin/bash
# tests/fix-1616-clarify-commit-scope-stdout.sh
# Tests: bin/github-issues/clarify-commit-scope.sh
# Tags: clarify-intent, github, issues, stdout-contract, gh-cli, scope:common, pwsh-not-required
#
# Issue #1616 — `gh` side-effect call sites suppress only stderr (`2>/dev/null`).
# On success `gh issue edit` prints the issue URL to stdout, so that URL leaks
# into clarify-commit-scope.sh's OWN stdout, whose documented contract is
# exactly one of: CREATED:<N> | CLOSED:<N> | RC2 | SCAN_BLOCKED (or nothing).
# Callers branch on "is stdout non-empty" / parse it as a token, so the leak is
# a behavioral defect, not cosmetic.
#
# Fixed state asserted here: the two loop-body side-effect calls
#   site1: gh issue edit <N> --add-label "intent:clarified"   (~line 158)
#   site2: ensure-board-card.sh <N>                            (~line 166)
# are fully silenced with `>/dev/null 2>&1`.
#
# TL3 gap (what this test does NOT catch):
# - Whether the REAL `gh` binary prints the issue URL on stdout for
#   `issue edit --add-label` in the installed gh version (the mock asserts the
#   documented behavior, not the binary's).
# - Whether the real GitHub API path emits additional stdout (rate-limit
#   notices, upgrade banners) that would leak past the same redirection.
# - Whether the real ensure-board-card.sh is stdout-silent in production.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCS="$AGENTS_DIR/bin/github-issues/clarify-commit-scope.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$CCS" ]; then
    echo "FAIL: precondition missing — bin/github-issues/clarify-commit-scope.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

TMP=""

# Mock harness mirrors tests/fix-issue-513-clarify-commit-scope.sh, with one
# deliberate fidelity upgrade: the `issue edit --add-label` arm and the
# ensure-board-card.sh mock each emit a line on STDOUT on success, the way the
# real tools do. Without that emission the leak is unobservable and every
# stdout assertion below would pass vacuously.
setup_mock() {
    TMP="$(mktemp -d)"
    FAKE_ACD="$TMP/agents-root"
    mkdir -p "$TMP/mock-bin" "$TMP/plans" "$FAKE_ACD/bin/github-issues"
    export MOCK_LOG_DIR="$TMP"

    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
ARGS="$*"
echo "gh $ARGS" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$ARGS" in
  issue\ create*)
    echo "https://github.com/nirecom/agents/issues/999"
    exit 0
    ;;
  issue\ edit\ *--add-label*)
    # MOCK_GH_LABEL_RC != 0 forces the site1 FAILURE path. The real gh can
    # write to stdout even when it fails, so the failing arm emits a distinct
    # canary on BOTH streams — that is what makes T1-5 non-vacuous.
    if [ "${MOCK_GH_LABEL_RC:-0}" != "0" ]; then
        echo "GHCANARY_LABEL_STDOUT_LEAK"
        echo "gh: mock label edit failed GHCANARY_LABEL_STDERR_LEAK" >&2
        exit "${MOCK_GH_LABEL_RC}"
    fi
    # Real `gh issue edit` prints the edited issue's URL to stdout on success.
    echo "https://github.com/nirecom/agents/issues/LABELED"
    exit 0
    ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    cat > "$TMP/mock-bin/issue-state-check.sh" <<'MOCKSTATE'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) shift 2 ;;
        --repo=*) shift ;;
        *) break ;;
    esac
done
N="${1:-}"
STVAR="GH_MOCK_STATE_${N}"
ST="${!STVAR:-${GH_MOCK_STATE:-OPEN}}"
case "$ST" in
    OPEN|open)     echo "open";   exit 0 ;;
    CLOSED|closed) echo "closed"; exit 0 ;;
    *)             echo "error";  exit 1 ;;
esac
MOCKSTATE
    chmod +x "$TMP/mock-bin/issue-state-check.sh"

    cat > "$TMP/mock-bin/wip-set-single.sh" <<'MOCKWIP'
#!/usr/bin/env bash
rc="${MOCK_WIP_RC:-0}"
case "$rc" in
    0) echo "SET_OK" ;;
    2) echo "RC2" ;;
esac
exit "$rc"
MOCKWIP
    chmod +x "$TMP/mock-bin/wip-set-single.sh"

    # Emits a stdout line on success so the site2 leak is observable.
    cat > "$TMP/mock-bin/ensure-board-card.sh" <<'MOCKBOARD'
#!/usr/bin/env bash
if [ "${MOCK_BOARD_RC:-0}" != "0" ]; then
    # Failure path canary on BOTH streams (see gh mock above).
    echo "BOARDCANARY_STDOUT_LEAK"
    echo "ensure-board-card: mock failure BOARDCANARY_STDERR_LEAK" >&2
    exit "${MOCK_BOARD_RC}"
fi
echo "board-card ensured for $*"
exit 0
MOCKBOARD
    chmod +x "$TMP/mock-bin/ensure-board-card.sh"

    cp "$TMP/mock-bin/issue-state-check.sh" \
       "$TMP/mock-bin/wip-set-single.sh" \
       "$TMP/mock-bin/ensure-board-card.sh" \
       "$FAKE_ACD/bin/github-issues/"

    cat > "$TMP/plans/test-sid-intent.md" <<'INTENTMD'
# Agreed Requirements — test-sid
**Title:** Placeholder tracking issue title

## Background / Motivation
Placeholder background text.

## Scope
Placeholder scope text.
INTENTMD

    mkdir -p "$FAKE_ACD/bin"
    cp "$AGENTS_DIR/bin/scan-outbound.sh" "$FAKE_ACD/bin/scan-outbound.sh"
    chmod +x "$FAKE_ACD/bin/scan-outbound.sh"
    : > "$FAKE_ACD/.private-info-allowlist"
    : > "$FAKE_ACD/.private-info-blocklist"

    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_CONFIG_DIR="$FAKE_ACD"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        export PATH="${PATH#"$TMP/mock-bin:"}"
        rm -rf "$TMP" 2>/dev/null || true
    fi
    unset GH_MOCK_STATE GH_MOCK_STATE_101 MOCK_WIP_RC MOCK_BOARD_RC \
          MOCK_GH_LABEL_RC MOCK_LOG_DIR WORKFLOW_PLANS_DIR 2>/dev/null || true
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    TMP=""
}

# Fixed-state static guard: the given line must silence BOTH streams.
# $1 file, $2 ERE selecting the call site line, $3 case label
assert_line_fully_redirected() {
    local file="$1" ere="$2" label="$3"
    local lines
    lines=$(grep -nE "$ere" "$file" || true)
    if [ -z "$lines" ]; then
        fail "$label: no line matched /$ere/ in $file (call site moved or renamed?)"
        return
    fi
    local bad=""
    while IFS= read -r ln; do
        case "$ln" in
            *'>/dev/null 2>&1'*) ;;
            *) bad="$bad$ln"$'\n' ;;
        esac
    done <<< "$lines"
    if [ -z "$bad" ]; then
        pass "$label: call site fully silenced (>/dev/null 2>&1)"
    else
        fail "$label: call site still leaks stdout (missing '>/dev/null 2>&1'):
$bad"
    fi
}

# ---------------------------------------------------------------------------
# T1-1: Path B, one OPEN issue → exit 0 AND stdout completely empty.
# Pre-fix RED: site1 leaks the gh issue URL and site2 leaks the board line.
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_STATE_101="OPEN"
OUT=$(run_with_timeout 15 bash "$CCS" \
    --session-id "test-sid" \
    --plans-dir "$TMP/plans" \
    --issues "101" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "T1-1: Path B success → exit 0, stdout empty"
else
    fail "T1-1: expected exit 0 with empty stdout; got rc=$RC stdout='$OUT'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T1-2: Path B, wip-set-single.sh exits 2 → stdout is exactly "RC2".
# Pre-fix RED: the site1 issue URL is printed before RC2.
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_STATE_101="OPEN"
export MOCK_WIP_RC=2
OUT=$(run_with_timeout 15 bash "$CCS" \
    --session-id "test-sid" \
    --plans-dir "$TMP/plans" \
    --issues "101" 2>/dev/null)
RC=$?
if [ "$RC" -eq 2 ] && [ "$OUT" = "RC2" ]; then
    pass "T1-2: wip rc=2 → exit 2, stdout is exactly 'RC2'"
else
    fail "T1-2: expected exit 2 with stdout exactly 'RC2'; got rc=$RC stdout='$OUT'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T1-3: Path C (--issues "") → stdout is exactly "CREATED:999".
# Regression guard: Path C already captures gh stdout via $( ), so this must
# stay green before AND after the fix.
# ---------------------------------------------------------------------------
setup_mock
OUT=$(run_with_timeout 15 bash "$CCS" \
    --session-id "test-sid" \
    --plans-dir "$TMP/plans" \
    --issues "" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "CREATED:999" ]; then
    pass "T1-3: Path C → exit 0, stdout is exactly 'CREATED:999'"
else
    fail "T1-3: expected exit 0 with stdout exactly 'CREATED:999'; got rc=$RC stdout='$OUT'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T1-5: FAILURE path of both loop-body side-effect call sites.
# Both are best-effort (`|| true`), so a non-zero exit must not change the
# script's contract — but the raw tool output must still be suppressed. The two
# mocks emit distinct canaries on BOTH streams when they fail, so this case
# proves `>/dev/null 2>&1` covers the failure path, not just the happy path.
# Without it, T1-1..T1-3 only ever exercise the success arms.
#
# T1-5a: site1 (gh issue edit --add-label) fails.
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_STATE_101="OPEN"
export MOCK_GH_LABEL_RC=1
export MOCK_BOARD_RC=0
ERR_FILE="$TMP/stderr-5a.txt"
OUT=$(run_with_timeout 15 bash "$CCS" \
    --session-id "test-sid" \
    --plans-dir "$TMP/plans" \
    --issues "101" 2>"$ERR_FILE")
RC=$?
ERR=$(cat "$ERR_FILE" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
   && ! printf '%s' "$OUT" | grep -q "GHCANARY_" \
   && ! printf '%s' "$ERR" | grep -q "GHCANARY_"; then
    pass "T1-5a: site1 label failure → exit 0, stdout empty, no canary on either stream"
else
    fail "T1-5a: expected exit 0 + empty stdout + no GHCANARY_ leak; got rc=$RC stdout='$OUT' stderr='$ERR'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T1-5b: site2 (ensure-board-card.sh) fails.
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_STATE_101="OPEN"
export MOCK_GH_LABEL_RC=0
export MOCK_BOARD_RC=1
ERR_FILE="$TMP/stderr-5b.txt"
OUT=$(run_with_timeout 15 bash "$CCS" \
    --session-id "test-sid" \
    --plans-dir "$TMP/plans" \
    --issues "101" 2>"$ERR_FILE")
RC=$?
ERR=$(cat "$ERR_FILE" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
   && ! printf '%s' "$OUT" | grep -q "BOARDCANARY_" \
   && ! printf '%s' "$ERR" | grep -q "BOARDCANARY_"; then
    pass "T1-5b: site2 board failure → exit 0, stdout empty, no canary on either stream"
else
    fail "T1-5b: expected exit 0 + empty stdout + no BOARDCANARY_ leak; got rc=$RC stdout='$OUT' stderr='$ERR'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T1-5c: BOTH sites fail at once — the combined best-effort path still yields
# the empty-stdout contract and leaks neither canary.
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_STATE_101="OPEN"
export MOCK_GH_LABEL_RC=1
export MOCK_BOARD_RC=1
ERR_FILE="$TMP/stderr-5c.txt"
OUT=$(run_with_timeout 15 bash "$CCS" \
    --session-id "test-sid" \
    --plans-dir "$TMP/plans" \
    --issues "101" 2>"$ERR_FILE")
RC=$?
ERR=$(cat "$ERR_FILE" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
   && ! printf '%s' "$OUT" | grep -qE "GHCANARY_|BOARDCANARY_" \
   && ! printf '%s' "$ERR" | grep -qE "GHCANARY_|BOARDCANARY_"; then
    pass "T1-5c: both sites fail → exit 0, stdout empty, no canary on either stream"
else
    fail "T1-5c: expected exit 0 + empty stdout + no canary leak; got rc=$RC stdout='$OUT' stderr='$ERR'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T1-4 (static): both loop-body side-effect call sites must be fully silenced.
# Permanent regression guard on the FIXED state — RED until #1616 lands.
# ---------------------------------------------------------------------------
assert_line_fully_redirected "$CCS" '^[[:space:]]*gh issue edit .*--add-label' \
    "T1-4a: site1 gh issue edit --add-label"
assert_line_fully_redirected "$CCS" '^[[:space:]]*ensure-board-card\.sh ' \
    "T1-4b: site2 ensure-board-card.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
