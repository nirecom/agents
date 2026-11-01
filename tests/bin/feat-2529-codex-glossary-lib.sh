#!/usr/bin/env bash
# tests/bin/feat-2529-codex-glossary-lib.sh
# Tests: bin/lib/codex-glossary.sh, bin/lib/codex-core.sh, bin/review-plan-codex, bin/review-code-codex
# Tags: scope:issue-specific, TL1, codex, glossary, prompt-injection, dup-group-keep:size-hard-limit, pwsh-not-required
# size-hard-limit: tests/bin/feat-2529-codex-glossary-block.sh would pass 500 lines with these cases (append-vs-new.md condition (b)).
# Issue #2529: the glossary block moves out of codex-core.sh into bin/lib/codex-glossary.sh, which
# both review scripts source. This file pins that library boundary; the `glossary-format.js
# prompt-data` contract is tested in tests/bin/feat-2529-glossary-old-paths.js.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
unset CLAUDE_PROJECT_DIR CODEX_GLOSSARY_MAX_LINES CODEX_GLOSSARY_MAX_BYTES 2>/dev/null || true

# --- helpers ---------------------------------------------------------------

assert_file_has() {
    if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then pass "$1"
    else fail "$1" "'$3' absent from $(basename "$2")"; fi
}

# An absence over an empty file passes for the wrong reason.
assert_file_lacks() {
    if [[ ! -s "$2" ]]; then fail "$1" "$(basename "$2") missing or empty; absence not provable"
    elif grep -qF -- "$3" "$2"; then fail "$1" "'$3' unexpectedly present in $(basename "$2")"
    else pass "$1"; fi
}

# source_line_no <file> <lib-regex> — 1-based line of the first `source`/`.` of bin/lib/<lib>.
source_line_no() {
    grep -nE "^[[:space:]]*(source|\.)[[:space:]].*lib/$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# check_sources_glossary_lib <script> <name> — the script sources codex-glossary.sh right after
# codex-core.sh (a shellcheck directive may sit between) and calls the new function only.
check_sources_glossary_lib() {
    local script="$SCRIPT_CHECKOUT_ROOT/bin/$1" core_no gl_no
    core_no="$(source_line_no "$script" 'codex-core\.sh')"
    gl_no="$(source_line_no "$script" 'codex-glossary\.sh')"
    if [[ -n "$core_no" && -n "$gl_no" ]] && (( gl_no > core_no && gl_no - core_no <= 3 )); then
        pass "$2/sources-codex-glossary-right-after-codex-core"
    else
        fail "$2/sources-codex-glossary-right-after-codex-core" "codex-core line=${core_no:-none} codex-glossary line=${gl_no:-none}"
    fi
    assert_file_has "$2/calls-codex-glossary-block" "$script" "codex_glossary_block"
    assert_file_lacks "$2/no-old-core-function-call" "$script" "codex_core_combined_glossary_block"
}

# --- shared-library boundary ---------------------------------------------------

CORE_SH="$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-core.sh"
GLOSS_SH="$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-glossary.sh"

# ============================================================================
case_begin "codex-core-carries-no-glossary" "bin/lib/codex-core.sh"
# ============================================================================
if [[ -s "$CORE_SH" ]] && ! grep -qi 'glossary' "$CORE_SH"; then pass "L1/codex-core-has-no-glossary-function-cap-or-header"
else fail "L1/codex-core-has-no-glossary-function-cap-or-header" "$(grep -ni 'glossary' "$CORE_SH" 2>/dev/null | head -3 | tr '\n' ' ')"; fi
assert_file_lacks "L1/codex-core-does-not-source-main-worktree" "$CORE_SH" "main-worktree.sh"
assert_file_has "L1/codex-glossary-defines-block" "$GLOSS_SH" "codex_glossary_block()"
assert_file_has "L1/codex-glossary-sources-main-worktree" "$GLOSS_SH" "main-worktree.sh"
case_end

# ============================================================================
case_begin "review-plan-codex-sources-glossary-lib" "bin/review-plan-codex"
# ============================================================================
check_sources_glossary_lib review-plan-codex "L2/review-plan-codex"
case_end

# ============================================================================
case_begin "review-code-codex-sources-glossary-lib" "bin/review-code-codex"
# ============================================================================
check_sources_glossary_lib review-code-codex "L3/review-code-codex"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
