# shellcheck shell=bash
# Tests: hooks/lib/codegraph-boundary.js, install/codegraph-mcp.js
# Tags: codegraph, installer, mcp-registration, cli-version, fail-safe-off, TL2, pwsh-not-required, scope:issue-specific
# M32-M36 (round-5 codex C3 / S5-13): verifyPinnedCliVersion() compares the pin
# against the real `codegraph --version` and reportPinnedVersionMismatch() WARNS
# on stderr only — never blocks rc/add/rm. unregister never checks (S5-4/CPR-ORTH).
# Sourced after ownership.sh. CG_STUB_VERSION drives write_cg_stub's `--version`
# branch (default $CG_VERSION); cases call codegraph-mcp.js directly (entry = verb,
# like ownership.sh) so npm-install logic never runs.

MISMATCH_ACTUAL="1.5.0"
WANT_MISMATCH_LINE="pinned CodeGraph version mismatch: installed $MISMATCH_ACTUAL, install/codegraph-constants.txt pins $CG_VERSION; run: npm install -g --ignore-scripts @colbymchenry/codegraph@$CG_VERSION"
WANT_UNKNOWN_ACTUAL_LINE="could not read the installed CodeGraph version (\`codegraph --version\`); the per-prompt context hook needs the pinned $CG_VERSION build; run: npm install -g --ignore-scripts @colbymchenry/codegraph@$CG_VERSION"

# assert_stderr_line <name> <exact-line|__silent__> — the report is capped at one
# line (S5-13), so exact match is load-bearing: a substring match would pass on a
# line missing the pin, the actual, or the exact remediation command.
assert_stderr_line() {
    local name="$1" want="$2" got; got="$(cat "$CASE_DIR/err.log" 2>/dev/null || true)"
    if [ "$want" = "__silent__" ]; then
        assert_eq "$name: stderr says nothing (match/unknown-pin verdicts are silent)" "" "$got"
    else
        assert_eq "$name: stderr carries exactly the one-line warning" "$want" "$got"
    fi
}

echo "--- M32: the stub answers the pin itself — match is silent, registration proceeds ---"
CG_STUB_VERSION="$CG_VERSION"
run_case "M32" register on present none yes 0 0 yes file
assert_eq "M32 (register, CG_STUB_VERSION=pin): observable outcome" \
    "rc=0 npmi=0 add=1 rm=0 mcp=1 err=0" "$SUMMARY"
assert_stderr_line "M32" "__silent__"
unset CG_STUB_VERSION

echo "--- M33: an older installed CLI mismatches the pin — warns, but still registers ---"
CG_STUB_VERSION="$MISMATCH_ACTUAL"
run_case "M33" register on present none yes 0 0 yes file
assert_eq "M33 (register, CG_STUB_VERSION=$MISMATCH_ACTUAL): observable outcome" \
    "rc=0 npmi=0 add=1 rm=0 mcp=1 err=1" "$SUMMARY"
assert_stderr_line "M33" "$WANT_MISMATCH_LINE"
unset CG_STUB_VERSION

echo "--- M34: a non-numeric --version reply (an unrelated binary) is unknown-actual, not a mismatch ---"
CG_STUB_VERSION="usage-text"
run_case "M34" register on present none yes 0 0 yes file
assert_eq "M34 (register, CG_STUB_VERSION=usage-text): observable outcome" \
    "rc=0 npmi=0 add=1 rm=0 mcp=1 err=1" "$SUMMARY"
assert_stderr_line "M34" "$WANT_UNKNOWN_ACTUAL_LINE"
unset CG_STUB_VERSION

echo "--- M35: codegraph absent from PATH entirely degrades to unknown-actual, registration still proceeds ---"
run_case "M35" register on present none no 0 0 yes file
assert_eq "M35 (register, codegraph absent): observable outcome" \
    "rc=0 npmi=0 add=1 rm=0 mcp=1 err=1" "$SUMMARY"
assert_stderr_line "M35" "$WANT_UNKNOWN_ACTUAL_LINE"

echo "--- M36: unregister never probes the version, even when the stub would mismatch ---"
CG_STUB_VERSION="$MISMATCH_ACTUAL"
run_case "M36" unregister on present present yes 0 0 yes file
assert_eq "M36 (unregister, CG_STUB_VERSION=$MISMATCH_ACTUAL): observable outcome" \
    "rc=0 npmi=0 add=0 rm=1 mcp=1 err=0" "$SUMMARY"
assert_stderr_line "M36" "__silent__"
unset CG_STUB_VERSION
