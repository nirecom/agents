#!/usr/bin/env bash
# tests/bin-review-bare-python-exemption-scope.sh
# Tests: bin/review-bare-python
# Tags: lint, bare-python, allowlist, exemption-scope, whole-file-exemption, grep-failure, fail-loud, error-path, mutation-probe, security, scope:common, pwsh-not-required, TL2, dup-group-keep:size-hard-limit
# Sibling of tests/bin-review-bare-python-classifier.sh (rules/coding/file-split.md):
# that file sits at the 500-line HARD limit, so these two sections land here.
# Section E  - how far the whole-file EXCLUDED_FILES exemption reaches INSIDE a file.
# Section GF - what scan_file() reports when its own candidate grep fails.
# TL3 gap: a real grep binary breaking on a real host. The shim below fails on argv
# shape alone, so a grep dying for any other reason is out of its reach; the
# closest-to-action mitigation is bin/check-verification-gate.sh, pwsh-required.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-bare-python"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/review-bare-python"
    echo ""
    echo "Results: 0 passed, 1 failed, 0 skipped"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md). The repo builder and the
# placeholder expander are deliberate duplicates of the classifier sibling's:
# each file must stand alone as a runnable suite, and a shared helper would be a
# third place to keep the SELF-EXEMPTION property below in sync.
EMPTY_HOOKS="$TMP/no-hooks"; mkdir -p "$EMPTY_HOOKS"
EMPTY_EXCLUDES="$TMP/empty-excludes"; : > "$EMPTY_EXCLUDES"

make_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS"
    git -C "$repo" config core.excludesFile "$EMPTY_EXCLUDES"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" checkout -q -b main
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
}

# SELF-EXEMPTION NOTE
# This file is deliberately NOT in the script's EXCLUDED_FILES. The interpreter
# spellings exist only as %PY3% tokens, expanded when a fixture file is written,
# so no spelling the lint looks for appears in this file's own bytes. Adding this
# path to the allowlist to make the suite pass is exactly the failure mode
# Section E exists to measure.
expand_placeholders() {
    local s="$1"
    s="${s//%PY3%/pyth""on3}"
    printf '%s' "$s"
}

# write_mixed <repo> <relpath> — one file, two DIFFERENT kinds of candidate:
#   line 2  a documented example, quoted, never executed
#   line 3  a genuinely executable invocation
# Line granularity is the whole point: a per-file verdict cannot tell them apart.
write_mixed() {
    local repo="$1" rel="$2"
    mkdir -p "$repo/$(dirname "$rel")"
    {
        printf '#!/bin/bash\n'
        printf '%s\n' "$(expand_placeholders "echo 'documented example: %PY3% -c \"import sys\"'")"
        printf '%s\n' "$(expand_placeholders '%PY3% -c "import sys"')"
    } > "$repo/$rel"
}

REPO="$TMP/repo"
make_repo "$REPO"
git -C "$REPO" checkout -q -b feature

EXCL="tests/fix-992-bare-python.sh"                 # an EXCLUDED_FILES entry
EXCL_CTRL="tests/feature-enforce-system-ops.sh"     # a different entry, mutation control
PLAIN="src/mixed-not-excluded.sh"                   # identical content, not excluded
write_mixed "$REPO" "$EXCL"
write_mixed "$REPO" "$EXCL_CTRL"
write_mixed "$REPO" "$PLAIN"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m "mixed-context corpus"

ALL_OUT="$TMP/all-out.txt"
ALL_RC=0
( cd "$REPO" && run_with_timeout 120 bash "$SCRIPT" --all ) > "$ALL_OUT" 2>&1 || ALL_RC=$?

# line_verdict <output-file> <path> <lineno> -> HARD | CLEAN
line_verdict() {
    if grep -qF "HARD: $2:$3:" "$1"; then printf 'HARD'; else printf 'CLEAN'; fi
}

# Harness self-check first: a crashed or empty run would report every line CLEAN.
assert_eq "H1 --all exits 0" "0" "$ALL_RC"
if grep -q "^## Bare Python Review: PERFORMED (all-scan mode)$" "$ALL_OUT"; then
    pass "H2 --all emitted the all-scan-mode heading"
else
    fail "H2 --all heading missing — output: $(head -5 "$ALL_OUT")"
fi

# ===========================================================================
# Section E — EXCLUDED_FILES is a WHOLE-FILE exemption. The non-excluded twin
# fixes the reference: both lines of this content are candidates, so a CLEAN on
# an excluded copy is the allowlist speaking, never a regex that failed to match.
# ===========================================================================
assert_eq "E1 non-excluded file: the documented-example line is a finding" \
    "HARD" "$(line_verdict "$ALL_OUT" "$PLAIN" 2)"
assert_eq "E2 non-excluded file: the executable line is a finding" \
    "HARD" "$(line_verdict "$ALL_OUT" "$PLAIN" 3)"
assert_eq "E3 excluded file: the documented-example line is exempt (intended)" \
    "CLEAN" "$(line_verdict "$ALL_OUT" "$EXCL" 2)"
assert_eq "E4 excluded file: the EXECUTABLE line is exempt too (measured, not endorsed)" \
    "CLEAN" "$(line_verdict "$ALL_OUT" "$EXCL" 3)"

# E5/E6 — mutation evidence. Renaming the one entry must expose BOTH lines of
# that file while the other entry stays exempt: that is what makes E3/E4 an
# allowlist verdict rather than a DETECT_RE miss, and what turns E4 red the day
# is_excluded() learns to tell fixture text from executable text.
MUTANT="$TMP/mutant-lint"
MUT_OUT="$TMP/mutant-out.txt"
sed 's|^  "tests/fix-992-bare-python.sh"|  "tests/zzz-not-a-real-entry.sh"|' "$SCRIPT" > "$MUTANT"
( cd "$REPO" && run_with_timeout 120 bash "$MUTANT" --all ) > "$MUT_OUT" 2>&1
assert_eq "E5 allowlist mutation exposes the documented-example line" \
    "HARD" "$(line_verdict "$MUT_OUT" "$EXCL" 2)"
assert_eq "E5 allowlist mutation exposes the executable line" \
    "HARD" "$(line_verdict "$MUT_OUT" "$EXCL" 3)"
assert_eq "E6 control: a different allowlist entry is unaffected by that mutation" \
    "CLEAN" "$(line_verdict "$MUT_OUT" "$EXCL_CTRL" 3)"

# SKIPPED: HARD for the genuinely executable line inside an excluded file, while
# the documented-example line in that same file stays CLEAN — /review-tests C2.
# Because: is_excluded() returns before scan_file() reads a single line, so no
# per-line expectation can pass without a source change, and this file is
# test-only.
# L3 gap: none — E4 names the exposure, E1/E2 prove the regex would have caught
# both lines, E5 keeps the CLEAN attributable to the allowlist. Narrowing the
# exemption to fixture context therefore reddens E4 first.

REAL_GREP="$(command -v grep 2>/dev/null || true)"

# ===========================================================================
# Section GF — scan_file()'s candidate grep failing mid-scan. The shim fails ONLY
# the `grep -nE` candidate scan and delegates every other invocation (the
# sanctioned-form filter, git's own helpers) to the real binary, so the injected
# failure is exactly the one scan_file() classifies by grep exit code.
# ===========================================================================
SHIM_DIR="$TMP/shim"
MARKER="$TMP/shim-reached"
mkdir -p "$SHIM_DIR"
{
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "-nE" ]; then\n'
    printf '  echo reached >> "${BP_SHIM_MARKER:?}"\n'
    printf '  echo "simulated grep failure" >&2\n'
    printf '  exit 2\n'
    printf 'fi\n'
    printf 'exec "${BP_SHIM_REAL_GREP:?}" "$@"\n'
} > "$SHIM_DIR/grep"
chmod +x "$SHIM_DIR/grep"

if [ -z "$REAL_GREP" ]; then
    skip "GF grep not on PATH — the shim has nothing to delegate to"
else
    export BP_SHIM_MARKER="$MARKER" BP_SHIM_REAL_GREP="$REAL_GREP"
    GF_OUT="$TMP/gf-out.txt"
    GF_RC=0
    ( cd "$REPO" && PATH="$SHIM_DIR:$PATH" run_with_timeout 120 bash "$SCRIPT" --all ) > "$GF_OUT" 2>&1 || GF_RC=$?

    # Control first: with a working grep the same corpus DOES report the
    # executable line, so the silence below cannot be an empty target set.
    assert_eq "GF0 control: the finding exists when grep works" \
        "HARD" "$(line_verdict "$ALL_OUT" "$PLAIN" 3)"
    if [ -s "$MARKER" ]; then
        pass "GF1 the shim was actually reached (the candidate scan ran through it)"
    else
        fail "GF1 the shim was never invoked — GF2..GF4 below would be vacuous"
    fi
    assert_eq "GF2 --all still exits 0 — that mode never blocks, findings or not" "0" "$GF_RC"
    if grep -q "^HARD:" "$GF_OUT"; then
        fail "GF3 per-line findings survived a failing candidate grep — re-derive this section"
    else
        pass "GF3 a failing candidate grep yields no per-line finding (there were no lines to read)"
    fi
    if grep -qF "ERROR: $PLAIN: candidate scan failed (grep exit 2)" "$GF_OUT"; then
        pass "GF4 the failure is reported verbatim, naming the file and the grep exit code"
    else
        fail "GF4 want an ERROR line for $PLAIN, got: $(tr '\n' ' ' < "$GF_OUT")"
    fi
    if grep -qF "No bare python3/python invocations found in .sh files." "$GF_OUT"; then
        fail "GF5 the run still claimed a clean tree — a failed scan is being read as clean"
    else
        pass "GF5 the affirmative clean line is withheld when the scan itself never ran"
    fi
    # is_excluded() returns before the candidate grep, so an allowlisted file must
    # produce neither a finding nor a scan error under the same broken grep.
    if grep -qF "ERROR: $EXCL:" "$GF_OUT"; then
        fail "GF6 an excluded file reported a scan error — is_excluded() no longer short-circuits"
    else
        pass "GF6 an excluded file never reaches the candidate grep, so it reports no error"
    fi

    # Diff mode is the blocking mode, and its exit code is the only signal a caller
    # acts on. The corpus here is CLEAN on purpose: with a working grep the run
    # exits 0, so exit 1 below can only come from the injected scan failure.
    GF_REPO="$TMP/repo-gf"
    make_repo "$GF_REPO"
    git -C "$GF_REPO" checkout -q -b feature
    mkdir -p "$GF_REPO/src"
    printf '#!/bin/bash\necho clean\n' > "$GF_REPO/src/clean.sh"
    git -C "$GF_REPO" add -A >/dev/null 2>&1
    git -C "$GF_REPO" commit -q -m "clean corpus"

    GF_CTRL_OUT="$TMP/gf-diff-ctrl.txt"
    GF_CTRL_RC=0
    ( cd "$GF_REPO" && run_with_timeout 120 bash "$SCRIPT" --base main ) > "$GF_CTRL_OUT" 2>&1 || GF_CTRL_RC=$?
    assert_eq "GF7 control: diff mode over the same clean corpus exits 0 with a working grep" \
        "0" "$GF_CTRL_RC"

    GF_DIFF_OUT="$TMP/gf-diff-out.txt"
    GF_DIFF_RC=0
    ( cd "$GF_REPO" && PATH="$SHIM_DIR:$PATH" run_with_timeout 120 bash "$SCRIPT" --base main ) > "$GF_DIFF_OUT" 2>&1 || GF_DIFF_RC=$?
    assert_eq "GF8 diff mode exits 1 when the candidate scan fails" "1" "$GF_DIFF_RC"
    if grep -qF "ERROR: src/clean.sh: candidate scan failed (grep exit 2)" "$GF_DIFF_OUT"; then
        pass "GF9 diff mode names the file whose candidate scan failed"
    else
        fail "GF9 want a diff-mode ERROR line for src/clean.sh, got: $(tr '\n' ' ' < "$GF_DIFF_OUT")"
    fi
    unset BP_SHIM_MARKER BP_SHIM_REAL_GREP
fi

# Residual L3 gap: a grep that fails for a reason other than the argv shape this
# shim keys on. GF2..GF9 pin the fail-LOUD contract — an ERROR line naming the
# file and the grep exit code, no affirmative clean line, and exit 1 in diff mode
# — so a regression to `|| true` reddens all of them at once.

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
