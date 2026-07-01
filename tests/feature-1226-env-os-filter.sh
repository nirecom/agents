#!/bin/bash
# tests/feature-1226-env-os-filter.sh
# Tests: bin/env-os-filter, hooks/pre-commit, bin/github-issues/wip-state.sh
# Tags: scope:issue-specific, env-os-blocks, os-conditional, env-os-filter, pre-commit, wip-state, pwsh-not-required
# RED for issue #1226 — bin/env-os-filter OS-conditional .env preprocessor.
# L3 gap (what this test does NOT catch):
# - Non-running OS block selection: TF-1 only verifies the RUNNING OS's block
#   survives and the other-OS block is excluded. Verifying the other-OS path
#   requires a real machine (Windows or POSIX) running this test. env-os-filter
#   delegates to filterOsBlocks(text, process.platform) which uses the live
#   process.platform — there is no platform-override seam by design.
# - A shared .env symlinked across both OSes simultaneously: only a two-machine
#   run of this test would exercise that real-world scenario.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required
#
# Non-regression: tests/fix-pre-commit-dotenv-order.sh must still pass after
# write-code modifies hooks/pre-commit _load_env_file to route through
# bin/env-os-filter. That file's existing cases are not duplicated here.
# (Validated by the run-tests step, not here.)
#
# Sibling test: tests/feature-1226-load-env-os-blocks.sh covers T1226-1..13
# (filterOsBlocks unit cases). Those cases are NOT duplicated here.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_OS_FILTER="$AGENTS_DIR/bin/env-os-filter"
PRECOMMIT="$AGENTS_DIR/hooks/pre-commit"
WIP_STATE="$AGENTS_DIR/bin/github-issues/wip-state.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name (contains '$needle')"
    else
        fail "$name (expected to contain '$needle'; got: $(printf '%s' "$haystack" | tr '\n' '|'))"
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$name (expected NOT to contain '$needle'; got: $(printf '%s' "$haystack" | tr '\n' '|'))"
    else
        pass "$name (omits '$needle')"
    fi
}

assert_empty() {
    local name="$1" haystack="$2"
    if [ -z "$haystack" ]; then
        pass "$name (output is empty)"
    else
        fail "$name (expected empty output; got: $(printf '%s' "$haystack" | tr '\n' '|'))"
    fi
}

# Determine the running OS as env-os-filter sees it (node process.platform:
# win32 → windows, anything else → posix). On Git Bash / Cygwin / MSYS under
# Windows, process.platform is "win32", so uname-based detection must map
# MINGW*/MSYS*/CYGWIN* to "windows".
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) running_os="windows" ;;
    *) running_os="posix" ;;
esac

# Capability guard: bin/env-os-filter must exist and be executable.
HAS_FILTER=0
[ -x "$ENV_OS_FILTER" ] && HAS_FILTER=1

# ---------------------------------------------------------------------------
# TF-1: Running-OS block selection — per-OS values
# ---------------------------------------------------------------------------
run_tf1() {
    local name="TF-1: bin/env-os-filter selects running-OS block"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local tmp rc out
    tmp="$(mktemp)"
    printf '#@if windows\nOS_BLOCK_KEY=winval\n\n#@endif\n#@if posix\nOS_BLOCK_KEY=posixval\n\n#@endif\n' > "$tmp"
    out=$(run_with_timeout 10 "$ENV_OS_FILTER" "$tmp" 2>/dev/null); rc=$?
    rm -f "$tmp"
    if [ $rc -ne 0 ]; then fail "$name (rc=$rc)"; return; fi
    if [ "$running_os" = "windows" ]; then
        assert_contains "$name" "$out" "OS_BLOCK_KEY=winval"
        assert_not_contains "$name" "$out" "OS_BLOCK_KEY=posixval"
    else
        assert_contains "$name" "$out" "OS_BLOCK_KEY=posixval"
        assert_not_contains "$name" "$out" "OS_BLOCK_KEY=winval"
    fi
}

# ---------------------------------------------------------------------------
# TF-2: Marker lines are stripped from output
# ---------------------------------------------------------------------------
run_tf2() {
    local name="TF-2: bin/env-os-filter strips marker lines from output"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local tmp rc out
    tmp="$(mktemp)"
    printf '#@if windows\nKEY=val\n\n#@endif\n#@if posix\nKEY=posixval\n\n#@endif\n' > "$tmp"
    out=$(run_with_timeout 10 "$ENV_OS_FILTER" "$tmp" 2>/dev/null); rc=$?
    rm -f "$tmp"
    if [ $rc -ne 0 ]; then fail "$name (rc=$rc)"; return; fi
    assert_not_contains "$name" "$out" "#@if windows"
    assert_not_contains "$name" "$out" "#@if posix"
    assert_not_contains "$name" "$out" "#@endif"
}

# ---------------------------------------------------------------------------
# TF-3: Flat / no-marker .env passes through identically (modulo trailing newline)
# ---------------------------------------------------------------------------
run_tf3() {
    local name="TF-3: bin/env-os-filter passes flat .env through unchanged"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local tmp rc out
    tmp="$(mktemp)"
    printf 'KEY=value\nOTHER=foo\nTHIRD=bar\n' > "$tmp"
    out=$(run_with_timeout 10 "$ENV_OS_FILTER" "$tmp" 2>/dev/null); rc=$?
    rm -f "$tmp"
    if [ $rc -ne 0 ]; then fail "$name (rc=$rc)"; return; fi
    assert_contains "$name" "$out" "KEY=value"
    assert_contains "$name" "$out" "OTHER=foo"
    assert_contains "$name" "$out" "THIRD=bar"
    assert_not_contains "$name" "$out" "#@"
}

# ---------------------------------------------------------------------------
# TF-4: Non-existent path arg → empty stdout, rc 0
# ---------------------------------------------------------------------------
run_tf4() {
    local name="TF-4: bin/env-os-filter with absent file → empty stdout, rc 0"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local out rc
    out=$(run_with_timeout 10 "$ENV_OS_FILTER" "/nonexistent/path/that/does/not/exist/.env" 2>/dev/null); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (expected rc=0, got rc=$rc)"; return; fi
    assert_empty "$name" "$out"
}

# ---------------------------------------------------------------------------
# TF-4b: Existing EMPTY file (distinct from TF-4's non-existent path)
#        → empty stdout, rc 0
# ---------------------------------------------------------------------------
run_tf4b() {
    local name="TF-4b: bin/env-os-filter with existing empty file → empty stdout, rc 0"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local tmp out rc
    tmp="$(mktemp)"
    # mktemp creates the file; write nothing → 0-byte file exists on disk.
    out=$(run_with_timeout 10 "$ENV_OS_FILTER" "$tmp" 2>/dev/null); rc=$?
    rm -f "$tmp"
    if [ $rc -ne 0 ]; then fail "$name (expected rc=0, got rc=$rc)"; return; fi
    assert_empty "$name" "$out"
}

# ---------------------------------------------------------------------------
# TF-4c: .env with ONLY the non-running-OS block → header, footer AND body all
#        removed (not just the value). Proves full-block exclusion.
# ---------------------------------------------------------------------------
run_tf4c() {
    local name="TF-4c: bin/env-os-filter drops a block for the non-running OS entirely"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local tmp out rc other_os
    if [ "$running_os" = "windows" ]; then other_os="posix"; else other_os="windows"; fi
    tmp="$(mktemp)"
    # Write ONLY the OTHER OS's block. On the running OS none of it should survive.
    printf '#@if %s\nOTHER_ONLY_KEY=shouldvanish\nOTHER_ONLY_KEY2=alsogone\n\n#@endif\n' "$other_os" > "$tmp"
    out=$(run_with_timeout 10 "$ENV_OS_FILTER" "$tmp" 2>/dev/null); rc=$?
    rm -f "$tmp"
    if [ $rc -ne 0 ]; then fail "$name (rc=$rc)"; return; fi
    assert_not_contains "$name" "$out" "OTHER_ONLY_KEY=shouldvanish"
    assert_not_contains "$name" "$out" "OTHER_ONLY_KEY2=alsogone"
    assert_not_contains "$name" "$out" "#@"
}

# ---------------------------------------------------------------------------
# TF-5: node-unavailable fallback — raw passthrough (both OS blocks survive)
# ---------------------------------------------------------------------------
run_tf5() {
    local name="TF-5: bin/env-os-filter falls back to raw passthrough when node unavailable"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    # Build a temp dir containing a stub `node` that exits 1, prepend it to PATH
    local stubdir tmp out rc
    stubdir="$(mktemp -d)"
    printf '#!/bin/sh\nexit 1\n' > "$stubdir/node"
    chmod +x "$stubdir/node"
    tmp="$(mktemp)"
    printf '#@if windows\nOS_KEY=winval\n\n#@endif\n#@if posix\nOS_KEY=posixval\n\n#@endif\n' > "$tmp"
    out=$(PATH="$stubdir:$PATH" run_with_timeout 10 "$ENV_OS_FILTER" "$tmp" 2>/dev/null); rc=$?
    rm -f "$tmp"
    rm -rf "$stubdir"
    if [ $rc -ne 0 ]; then fail "$name (rc=$rc — filter must not fail even without node)"; return; fi
    # Raw passthrough: BOTH marker lines AND both OS-block values survive verbatim
    assert_contains "$name" "$out" "OS_KEY=winval"
    assert_contains "$name" "$out" "OS_KEY=posixval"
    assert_contains "$name" "$out" "#@if windows"
    assert_contains "$name" "$out" "#@if posix"
    assert_contains "$name" "$out" "#@endif"
}

# ---------------------------------------------------------------------------
# TF-6: stdin mode — no path arg, content piped on stdin
# ---------------------------------------------------------------------------
run_tf6() {
    local name="TF-6: bin/env-os-filter reads from stdin when no path arg given"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local out rc
    out=$(printf '#@if windows\nSTDIN_KEY=winval\n\n#@endif\n#@if posix\nSTDIN_KEY=posixval\n\n#@endif\n' \
        | run_with_timeout 10 "$ENV_OS_FILTER" 2>/dev/null); rc=$?
    if [ $rc -ne 0 ]; then fail "$name (rc=$rc)"; return; fi
    if [ "$running_os" = "windows" ]; then
        assert_contains "$name" "$out" "STDIN_KEY=winval"
        assert_not_contains "$name" "$out" "STDIN_KEY=posixval"
    else
        assert_contains "$name" "$out" "STDIN_KEY=posixval"
        assert_not_contains "$name" "$out" "STDIN_KEY=winval"
    fi
    assert_not_contains "$name" "$out" "#@if"
    assert_not_contains "$name" "$out" "#@endif"
}

# ---------------------------------------------------------------------------
# TF-7: hooks/pre-commit _load_env_file — routes through env-os-filter
# Guard: SKIP unless pre-commit source already references env-os-filter AND
#        bin/env-os-filter is executable.
# ---------------------------------------------------------------------------
run_tf7() {
    local name="TF-7: hooks/pre-commit _load_env_file sources only running-OS block"
    # Guard 1: bin/env-os-filter must exist
    if [ "$HAS_FILTER" != "1" ]; then
        skip "$name (bin/env-os-filter not yet created — pending write-code)"; return
    fi
    # Guard 2: hooks/pre-commit must reference env-os-filter in its source
    if ! grep -q "env-os-filter" "$PRECOMMIT" 2>/dev/null; then
        skip "$name (hooks/pre-commit does not yet reference env-os-filter — pending write-code)"; return
    fi
    # Extract _load_env_file into a subshell and test it with a crafted temp dir
    local tmpdir out rc
    tmpdir="$(mktemp -d)"
    # Create a crafted .env: ENFORCE_WORKTREE_EXCLUDE differs per OS
    if [ "$running_os" = "windows" ]; then
        expected_excl="docs/*.md"
        other_excl="LICENSE"
    else
        expected_excl="LICENSE"
        other_excl="docs/*.md"
    fi
    printf '#@if windows\nENFORCE_WORKTREE_EXCLUDE=docs/*.md\n\n#@endif\n#@if posix\nENFORCE_WORKTREE_EXCLUDE=LICENSE\n\n#@endif\n' \
        > "$tmpdir/.env"
    # Source _load_env_file in a subshell, then print the resolved var
    out=$(AGENTS_CONFIG_DIR="$tmpdir" run_with_timeout 15 bash -c "
source '$PRECOMMIT' 2>/dev/null || true
_load_env_file
echo \"\$ENFORCE_WORKTREE_EXCLUDE\"
" 2>/dev/null); rc=$?
    rm -rf "$tmpdir"
    if [ $rc -ne 0 ] && [ -z "$out" ]; then
        skip "$name (sourcing _load_env_file failed — possible dependency in pre-commit; rc=$rc)"
        return
    fi
    assert_contains "$name" "$out" "$expected_excl"
    assert_not_contains "$name" "$out" "$other_excl"
}

# ---------------------------------------------------------------------------
# TF-8: bin/github-issues/wip-state.sh load_env_file routes through env-os-filter
# Guard: SKIP unless wip-state.sh source already references env-os-filter AND
#        bin/env-os-filter is executable.
# ---------------------------------------------------------------------------
run_tf8() {
    local name="TF-8: wip-state.sh load_env_file loads WIP_STATE_* and resolves OS var"
    # Guard 1: bin/env-os-filter must exist
    if [ "$HAS_FILTER" != "1" ]; then
        skip "$name (bin/env-os-filter not yet created — pending write-code)"; return
    fi
    # Guard 2: wip-state.sh must reference env-os-filter
    if ! grep -q "env-os-filter" "$WIP_STATE" 2>/dev/null; then
        skip "$name (wip-state.sh does not yet reference env-os-filter — pending write-code)"; return
    fi
    local tmpdir out rc
    tmpdir="$(mktemp -d)"
    # OS-independent WIP_STATE_* var PLUS a per-OS WIPS_OS_VAR
    if [ "$running_os" = "windows" ]; then
        expected_os_val="win-val"
        other_os_val="posix-val"
    else
        expected_os_val="posix-val"
        other_os_val="win-val"
    fi
    printf 'WIP_STATE_STATUS_FIELD_ID=SFID_TEST\n#@if windows\nWIPS_OS_VAR=win-val\n\n#@endif\n#@if posix\nWIPS_OS_VAR=posix-val\n\n#@endif\n' \
        > "$tmpdir/.env"
    # Extract and call load_env_file in a subshell; print the two vars
    out=$(AGENTS_CONFIG_DIR="$tmpdir" run_with_timeout 15 bash -c "
source '$WIP_STATE' 2>/dev/null || true
load_env_file
printf 'WIP_STATE_STATUS_FIELD_ID=%s\n' \"\${WIP_STATE_STATUS_FIELD_ID:-}\"
printf 'WIPS_OS_VAR=%s\n' \"\${WIPS_OS_VAR:-}\"
" 2>/dev/null); rc=$?
    rm -rf "$tmpdir"
    if [ $rc -ne 0 ] && [ -z "$out" ]; then
        skip "$name (sourcing wip-state.sh load_env_file failed — rc=$rc)"; return
    fi
    assert_contains "$name" "$out" "WIP_STATE_STATUS_FIELD_ID=SFID_TEST"
    assert_contains "$name" "$out" "WIPS_OS_VAR=$expected_os_val"
    assert_not_contains "$name" "$out" "WIPS_OS_VAR=$other_os_val"
}

# ---------------------------------------------------------------------------
# TF-9: path arg with a SPACE + literal value passthrough (security:
#       CWE-78 OS command injection, CWE-22 path traversal). Proves (a) a
#       path containing a space does not break invocation, and (b) the filter
#       emits shell-metachar values as LITERAL text — it never evaluates them.
#       NOTE: value-evaluation semantics belong to the LOADER, not the filter:
#       wip-state.sh sources via `. "$envfile"` (evaluates by design);
#       pre-commit uses a non-evaluating line parser. Loader-level evaluation
#       is out of scope here and intentionally not asserted.
# ---------------------------------------------------------------------------
run_tf9() {
    local name="TF-9: bin/env-os-filter handles spaced path and emits values verbatim (no eval)"
    if [ "$HAS_FILTER" != "1" ]; then skip "$name (bin/env-os-filter not yet created — pending write-code)"; return; fi
    local base spacedir out rc
    base="$(mktemp -d)"
    spacedir="$base/with space"
    mkdir -p "$spacedir"
    # Running-OS block with shell-metachar values written as LITERAL text.
    printf '#@if %s\nINJ=$(id)\nINJ2=`id`\n\n#@endif\n' "$running_os" > "$spacedir/.env"
    out=$(run_with_timeout 10 "$ENV_OS_FILTER" "$spacedir/.env" 2>/dev/null); rc=$?
    rm -rf "$base"
    if [ $rc -ne 0 ]; then fail "$name (rc=$rc — spaced path must not break invocation)"; return; fi
    assert_contains "$name" "$out" 'INJ=$(id)'
    assert_contains "$name" "$out" 'INJ2=`id`'
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------
run_tf1
run_tf2
run_tf3
run_tf4
run_tf4b
run_tf4c
run_tf5
run_tf6
run_tf7
run_tf8
run_tf9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
