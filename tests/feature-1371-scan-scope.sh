#!/bin/bash
# tests/feature-1371-scan-scope.sh
# Tests: skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: review-tests, scan-scope, changed-files, context-injection, scope:issue-specific
#
# Issue #1371 — /review-tests must inject a changed-file scope context so the
# codex reviewer only evaluates test coverage for files actually changed in this
# branch (not the entire codebase). Without scope injection, the reviewer may
# flag coverage gaps for files not touched by the PR, producing false-positive
# NEEDS_REVISION verdicts.
#
# Expected behavior (after fix):
#   skills/review-tests/scripts/run-codex-review-loop.sh generates a tempfile
#   containing `git diff <merge-base>...HEAD --name-only` output and passes it
#   to bin/run-codex-review-loop via --context.
#
# Opt-out (REVIEW_TESTS_FULL_SCAN=1):
#   When REVIEW_TESTS_FULL_SCAN=1 is set, the changed-file context is NOT
#   injected — reviewer evaluates all staged tests against the full codebase.
#
# EXPECTED:
#   Case C1a (changed-file context injected) — FAIL before fix (no --context
#     with changed-files is passed by the current script).
#   Case C1b (REVIEW_TESTS_FULL_SCAN=1 skips injection) — PASS before and
#     after fix only if the opt-in is respected (regression guard).
#
# L3 gap (what this L2 test does NOT catch):
# - Whether the injected context actually changes codex's verdict (only a live
#   codex session with real changed-files output can verify that).
# - Whether the merge-base computation is correct for detached-HEAD states or
#   force-pushed branches (only reproducible in a real git environment with the
#   branch history set up exactly).
# Closest-to-action mitigation: the changed-file tempfile is human-readable;
# the reviewer output can be inspected in a live /review-tests run.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP_SH="$AGENTS_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# ---------------------------------------------------------------------------
# Precondition gate
# ---------------------------------------------------------------------------
if [[ ! -f "$LOOP_SH" ]]; then
    echo "FAIL: precondition missing — skills/review-tests/scripts/run-codex-review-loop.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/sc1371.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Build a git fixture repo with a feature branch containing changed files.
# main branch: README.md
# feature branch: adds src/app.js and hooks/foo.js
# ---------------------------------------------------------------------------
FIXTURE_REPO="$TMPDIR_BASE/fixture-repo"
mkdir -p "$FIXTURE_REPO/src" "$FIXTURE_REPO/hooks"
(
    cd "$FIXTURE_REPO"
    git init -q
    git config user.email test@example.com
    git config user.name Test
    git config commit.gpgsign false
    echo "initial" > README.md
    git -c core.hooksPath="" add README.md
    git -c core.hooksPath="" commit -q -m initial
    git -c core.hooksPath="" switch -q -c feature/scope-test
    echo "// app code" > src/app.js
    echo "// hook code" > hooks/foo.js
    git -c core.hooksPath="" add src/app.js hooks/foo.js
    git -c core.hooksPath="" commit -q -m "add scope files"
)

SID="test-sid-1371"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_DIR"
echo "# Test review draft"  > "$PLANS_DIR/$SID-test-review.md"
echo "# Outline"            > "$PLANS_DIR/$SID-outline.md"

# ---------------------------------------------------------------------------
# Stub bin/run-codex-review-loop to record every --context arg passed.
# The loop script calls "$AGENTS_CONFIG_DIR/bin/run-codex-review-loop".
# We create a fake AGENTS_CONFIG_DIR that intercepts the call.
# ---------------------------------------------------------------------------
FAKE_ACD="$TMPDIR_BASE/fake-acd"
mkdir -p "$FAKE_ACD/bin" "$FAKE_ACD/rules"
[[ -d "$AGENTS_DIR/rules" ]] && cp -r "$AGENTS_DIR/rules" "$FAKE_ACD/" 2>/dev/null || true

CONTEXT_LOG="$TMPDIR_BASE/context-args.log"

cat > "$FAKE_ACD/bin/run-codex-review-loop" <<STUBEOF
#!/bin/bash
# Stub: log every --context argument value, then exit 3 (SKIPPED).
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--context" && -n "\${2:-}" ]]; then
        printf '%s\n' "\$2" >> "${CONTEXT_LOG}"
    fi
    shift
done
echo "## Codex Plan Review: SKIPPED -- stub"
exit 3
STUBEOF
chmod +x "$FAKE_ACD/bin/run-codex-review-loop"

cat > "$FAKE_ACD/bin/build-codex-context" <<'BSTUB'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" && -n "${2:-}" ]]; then
        echo "stub-context" > "$2"; break; fi
    shift; done; exit 0
BSTUB
chmod +x "$FAKE_ACD/bin/build-codex-context"

# ---------------------------------------------------------------------------
# Helper: read the context log and find a file whose content matches expected
# git diff output (contains the committed changed files).
# ---------------------------------------------------------------------------
context_contains_changed_files() {
    local expected_file="$1"
    [[ -f "$CONTEXT_LOG" ]] || return 1
    while IFS= read -r ctx_path; do
        [[ -f "$ctx_path" ]] || continue
        if grep -qF "$expected_file" "$ctx_path" 2>/dev/null; then
            return 0
        fi
    done < "$CONTEXT_LOG"
    return 1
}

# ===========================================================================
# Case C1a — script passes a --context file containing changed-file names.
#   Run from feature branch; expect stub to receive a --context with a file
#   listing src/app.js and/or hooks/foo.js (the branch-committed changes).
# EXPECTED: FAIL before fix (current script does not inject changed-file context).
# ===========================================================================
rm -f "$CONTEXT_LOG"

( cd "$FIXTURE_REPO" && \
    AGENTS_CONFIG_DIR="$FAKE_ACD" SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
    PLANS_DIR="$PLANS_DIR" EXTENSIONS_USED=0 \
    "$RWT" 120 bash "$LOOP_SH" >/dev/null 2>&1 || true )

if context_contains_changed_files "src/app.js"; then
    pass "C1a: run-codex-review-loop.sh injects --context with changed-file list (src/app.js present)"
elif context_contains_changed_files "hooks/foo.js"; then
    pass "C1a: run-codex-review-loop.sh injects --context with changed-file list (hooks/foo.js present)"
else
    fail "C1a: REGRESSION — no --context containing changed files was passed to run-codex-review-loop"
fi

# ===========================================================================
# Case C1b — REVIEW_TESTS_FULL_SCAN=1 opt-out: changed-file context NOT injected.
#   Even after the fix, REVIEW_TESTS_FULL_SCAN=1 must suppress the scope injection.
#   Before fix: no injection anyway, so this test PASSES regardless.
#   After fix: it verifies the opt-out is respected.
# ===========================================================================
rm -f "$CONTEXT_LOG"
CHANGED_FILE_LOG="$TMPDIR_BASE/changed-files.txt"

( cd "$FIXTURE_REPO" && \
    AGENTS_CONFIG_DIR="$FAKE_ACD" SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
    PLANS_DIR="$PLANS_DIR" EXTENSIONS_USED=0 \
    REVIEW_TESTS_FULL_SCAN=1 \
    "$RWT" 120 bash "$LOOP_SH" >/dev/null 2>&1 || true )

# When full scan: changed-file context MUST NOT be injected as a separate scope file.
# (Normal context files like survey-code.md are allowed — we only check changed-file scope.)
# Heuristic: no context file contains src/app.js (the branch-specific file).
if ! context_contains_changed_files "src/app.js"; then
    pass "C1b: REVIEW_TESTS_FULL_SCAN=1 suppresses changed-file scope injection"
else
    fail "C1b: REGRESSION — changed-file context injected even with REVIEW_TESTS_FULL_SCAN=1"
fi

# ===========================================================================
# Case C2 — Multiple changed files → ALL should appear in the context file.
#   The fixture branch changed both src/app.js and hooks/foo.js.
#   After fix: the context file passed via --context must list both files.
# EXPECTED: FAIL before fix (no --context with changed-files is injected).
# ===========================================================================
rm -f "$CONTEXT_LOG"

( cd "$FIXTURE_REPO" && \
    AGENTS_CONFIG_DIR="$FAKE_ACD" SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
    PLANS_DIR="$PLANS_DIR" EXTENSIONS_USED=0 \
    "$RWT" 120 bash "$LOOP_SH" >/dev/null 2>&1 || true )

both_present=0
if context_contains_changed_files "src/app.js" && context_contains_changed_files "hooks/foo.js"; then
    both_present=1
fi
if [[ "$both_present" -eq 1 ]]; then
    pass "C2: multiple changed files (src/app.js + hooks/foo.js) all appear in --context"
else
    fail "C2: not all changed files appeared in --context (src/app.js=$(context_contains_changed_files "src/app.js" && echo yes || echo no) hooks/foo.js=$(context_contains_changed_files "hooks/foo.js" && echo yes || echo no))"
fi

# ===========================================================================
# Case C3 — File NOT in the PR diff must NOT appear in the context.
#   The fixture branch never touched README.md (it was committed on main before
#   the feature branch diverged). The --context file must not list README.md.
# EXPECTED: FAIL before fix (no --context injected at all; after fix, scope is
#   correct and README.md is absent).
# ===========================================================================
rm -f "$CONTEXT_LOG"

( cd "$FIXTURE_REPO" && \
    AGENTS_CONFIG_DIR="$FAKE_ACD" SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
    PLANS_DIR="$PLANS_DIR" EXTENSIONS_USED=0 \
    "$RWT" 120 bash "$LOOP_SH" >/dev/null 2>&1 || true )

# Before fix: CONTEXT_LOG is empty (no --context passed) → test passes vacuously → FALSE GREEN.
# After fix: --context is passed and must not contain README.md.
# Precondition: a context file must have been injected (CONTEXT_LOG must be non-empty with
# at least one resolvable file path). Without this guard the test passes vacuously whenever
# no --context is injected at all, masking the missing scope-injection behaviour.
c3_precondition_ok=0
if [[ -f "$CONTEXT_LOG" ]]; then
    while IFS= read -r ctx_path; do
        [[ -f "$ctx_path" ]] && c3_precondition_ok=1 && break
    done < "$CONTEXT_LOG"
fi
if [[ "$c3_precondition_ok" -eq 0 ]]; then
    fail "C3: precondition failed — no --context file was injected; cannot verify README.md exclusion (scope injection missing)"
else
    readme_leaked=0
    while IFS= read -r ctx_path; do
        [[ -f "$ctx_path" ]] || continue
        if grep -qF "README.md" "$ctx_path" 2>/dev/null; then
            readme_leaked=1
            break
        fi
    done < "$CONTEXT_LOG"
    if [[ "$readme_leaked" -eq 0 ]]; then
        pass "C3: file not in PR diff (README.md) does NOT appear in --context (exclusion verified)"
    else
        fail "C3: README.md (not in branch diff) leaked into the --context file (scope too broad)"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
