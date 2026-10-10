#!/bin/bash
# tests/skills/fix-1616-path-a-label-and-board-stdout.sh
# Tests: skills/workflow-init/scripts/path-a-label-and-board.sh
# Tags: workflow-init, github, issues, stdout-contract, gh-cli, scope:common, pwsh-not-required
# #1616: the one gh call site (site1 `gh issue edit --add-label`) is `>/dev/null 2>&1` so stdout
# stays empty, with fail-closed semantics intact (abort marker + stderr + exit 1). The board call
# (ensure-board-card.sh) is out of scope (#1589); its mock is stdout-SILENT, so T3-1 speaks to site1 only.
# TL3 gap: real gh stdout/banners, real API rejections, real board-card stdout; mitigated at
# WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh category: skill-orchestration).

set -u

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/scripts/path-a-label-and-board.sh"

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

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: precondition missing — skills/workflow-init/scripts/path-a-label-and-board.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

TMP=""

# Dedicated mocks.
#   gh                  — emits the issue URL on stdout for a successful
#                         `issue edit --add-label`, the way the real CLI does,
#                         so the leak under test is observable.
#   MOCK_GH_LABEL_RC=<n> forces the gh label edit failure path.
#   ensure-board-card.sh — stdout-SILENT stub (see header): #1616 does not
#                         redirect this call site.
#   MOCK_BOARD_RC=<n>    forces the ensure-board-card.sh failure path.
setup_mock() {
    TMP="$(mktemp -d)"
    FAKE_AGENTS_ROOT="$TMP/agents-root"
    mkdir -p "$TMP/mock-bin" "$TMP/plans" "$FAKE_AGENTS_ROOT/bin/github-issues"

    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
ARGS="$*"
echo "gh $ARGS" >> "$MOCK_GH_LOG"
case "$ARGS" in
  issue\ edit\ *--add-label*)
    if [ "${MOCK_GH_LABEL_RC:-0}" != "0" ]; then
        # Canary on BOTH streams: the real gh can print to stdout even when it
        # fails, so the failure path must be proven silent too (T3-2), not just
        # the success path (T3-1).
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

    cat > "$FAKE_AGENTS_ROOT/bin/github-issues/ensure-board-card.sh" <<'MOCKBOARD'
#!/usr/bin/env bash
exit "${MOCK_BOARD_RC:-0}"
MOCKBOARD
    chmod +x "$FAKE_AGENTS_ROOT/bin/github-issues/ensure-board-card.sh"

    # #2434: the abort marker is a control file resolved via $AGENTS_MAIN_ROOT/bin/workflow-control-dir;
    # the fake agents root delegates to the real CLI (which resolves hooks/ from its own __dirname).
    local real_cli="$SCRIPT_CHECKOUT_ROOT/bin/workflow-control-dir"
    command -v cygpath >/dev/null 2>&1 && real_cli="$(cygpath -m "$real_cli")"
    printf 'require(%s);\n' "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$real_cli")" \
        > "$FAKE_AGENTS_ROOT/bin/workflow-control-dir"
    mkdir -p "$TMP/workflow"
    export WORKFLOW_STATE_DIR="$TMP/workflow"
    export WORKFLOW_PLANS_DIR="$TMP/plans"

    export MOCK_GH_LOG="$TMP/gh-calls.log"
    : > "$MOCK_GH_LOG"
    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_MAIN_ROOT="$FAKE_AGENTS_ROOT"
    export PLANS_DIR="$TMP/plans"
    export SESSION_ID="test-sid-1616"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        export PATH="${PATH#"$TMP/mock-bin:"}"
        rm -rf "$TMP" 2>/dev/null || true
    fi
    unset MOCK_GH_LOG MOCK_GH_LABEL_RC MOCK_BOARD_RC \
          PLANS_DIR SESSION_ID WORKFLOW_STATE_DIR WORKFLOW_PLANS_DIR 2>/dev/null || true
    TMP=""
}

# ---------------------------------------------------------------------------
# T3-1: one sibling, all calls succeed → exit 0 AND stdout completely empty.
# The gh mock emits on stdout, so this is RED if site1 loses its redirection.
# (The board mock is silent, so this assertion speaks only to site1.)
# ---------------------------------------------------------------------------
setup_mock
OUT=$(run_with_timeout 15 bash "$SCRIPT" 101 102 2>/dev/null)
RC=$?
GH_LOG=$(cat "$MOCK_GH_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && echo "$GH_LOG" | grep -q "issue edit 102 .*add-label"; then
    pass "T3-1: sibling labeled successfully → exit 0, stdout empty, label call made"
else
    fail "T3-1: expected exit 0 + empty stdout + label call for 102; got rc=$RC stdout='$OUT' gh-log='$GH_LOG'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T3-2: gh label edit fails → exit 1, abort marker written, stderr says aborting,
# AND stdout stays empty. Fail-closed regression guard: the fix's redirection
# must not swallow the failure signal, but it must still suppress the raw gh
# output on the failure path (the mock emits GHCANARY_ on both streams).
# ---------------------------------------------------------------------------
setup_mock
export MOCK_GH_LABEL_RC=1
MARKER="$WORKFLOW_STATE_DIR/$SESSION_ID.control/workflow-init-aborted-pathA-multiN-label-failure.md"
ERR_FILE="$TMP/stderr.txt"
OUT=$(run_with_timeout 15 bash "$SCRIPT" 101 102 2>"$ERR_FILE")
RC=$?
ERR=$(cat "$ERR_FILE" 2>/dev/null)
if [ "$RC" -eq 1 ] && [ -f "$MARKER" ] \
   && echo "$ERR" | grep -q "aborting" \
   && [ -z "$OUT" ] \
   && ! echo "$ERR" | grep -q "GHCANARY_"; then
    pass "T3-2: label failure → exit 1, abort marker, 'aborting' on stderr, stdout empty, no canary leak"
else
    fail "T3-2: expected exit 1 + marker + 'aborting' stderr + empty stdout + no GHCANARY_ leak; got rc=$RC marker=$([ -f "$MARKER" ] && echo yes || echo no) stdout='$OUT' stderr='$ERR'"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T3-3 (static): every `gh issue edit ... --add-label` CODE line in the real
# source must silence BOTH streams. Anchored so comment lines (which start with
# '#') never match. Permanent regression guard on the FIXED state.
# ---------------------------------------------------------------------------
T3_3_ERE='^[[:space:]]*(if ! )?gh issue edit .*--add-label'
T3_3_LINES=$(grep -nE "$T3_3_ERE" "$SCRIPT" || true)
if [ -z "$T3_3_LINES" ]; then
    fail "T3-3: no code line matched /$T3_3_ERE/ in $SCRIPT (call site moved or renamed?)"
else
    T3_3_BAD=""
    while IFS= read -r ln; do
        case "$ln" in
            *'>/dev/null 2>&1'*) ;;
            *) T3_3_BAD="$T3_3_BAD$ln"$'\n' ;;
        esac
    done <<< "$T3_3_LINES"
    if [ -z "$T3_3_BAD" ]; then
        pass "T3-3: site1 gh issue edit --add-label fully silenced (>/dev/null 2>&1)"
    else
        fail "T3-3: site1 gh issue edit --add-label still leaks stdout (missing '>/dev/null 2>&1'):
$T3_3_BAD"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
