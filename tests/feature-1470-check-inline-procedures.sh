#!/usr/bin/env bash
# tests/feature-1470-check-inline-procedures.sh
# Tests: bin/check-inline-procedures
# Tags: prompt, bin, quality-gate, inline-procedure, adapter, scope:issue-specific, scope:feature-1642, layer:TL2
#
# Detection semantics moved to tests/feature-1642-check-prompt-extraction.sh.
#
# After issue #1642, bin/check-inline-procedures is a THIN ADAPTER over
# bin/check-prompt-extraction (the single decision CLI). It owns no detection
# logic of its own — only the advisory presentation contract that
# skills/review-code-security/scripts/run-quality-gates.sh depends on:
#
#   * header line `## Inline Procedure Review: <STATE>`
#   * advisory `WARN:` prefix (never `HARD:` — the adapter is non-blocking)
#   * always exits 0, whatever the engine reports
#   * degrades to `SKIPPED — engine not found` when the engine is unavailable
#
# Anything about WHICH content counts as an inline procedure belongs in the
# #1642 file, not here (CPR-SSOT: one owner per fact).
#
# TL3 gap (what this test does NOT catch):
# - bin/check-inline-procedures firing from run-quality-gates.sh in a real WF-CODE-6 session
# - run-quality-gates.sh PATH resolution ($AGENTS_CONFIG_DIR/bin on PATH) confirmed live
# Closest-to-action mitigation: bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/check-inline-procedures"
ENGINE="$AGENTS_ROOT/bin/check-prompt-extraction"

if [ ! -f "$SCRIPT" ]; then
    echo "SKIP: bin/check-inline-procedures not present"
    exit 77
fi
if [ ! -f "$ENGINE" ]; then
    echo "SKIP: bin/check-prompt-extraction (adapter engine) not present yet (issue #1642)"
    exit 77
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

make_repo() {
    local repo="$TMPDIR_BASE/$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# 4 numbered steps = one violation under the #1642 threshold (MORE THAN 3).
emit_numbered() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "$i. step $i"; done
}

# add_violation <repo> — commits skills/foo/SKILL.md on a feature branch.
add_violation() {
    local repo="$1"
    git -C "$repo" checkout -q -b feature-adapter
    mkdir -p "$repo/skills/foo"
    { echo "# Foo skill"; echo ""; echo "## Procedure"; echo ""; emit_numbered 4; } \
        > "$repo/skills/foo/SKILL.md"
    git -C "$repo" add skills/foo/SKILL.md
    git -C "$repo" commit -q -m "add SKILL.md with an inline procedure"
}

OUT=""
RC=0
# run_adapter <repo> [args...]
run_adapter() {
    local repo="$1"; shift
    RC=0
    OUT="$( (cd "$repo" && run_with_timeout 60 bash "$SCRIPT" "$@") 2>&1 )" || RC=$?
}

count_warns() { printf '%s\n' "$1" | grep -c "^WARN:" || true; }

assert_exit0() {
    local label="$1"
    if [ "$RC" -eq 0 ]; then
        pass "$label"
    else
        fail "$label: expected exit 0, got $RC" "$OUT"
    fi
}

assert_contains() {
    local label="$1" needle="$2"
    if printf '%s\n' "$OUT" | grep -q -- "$needle"; then
        pass "$label"
    else
        fail "$label: output missing '$needle'" "$OUT"
    fi
}

# ============================================================================
# Adapter contract
# ============================================================================

# T01: diff mode emits the PERFORMED header (header rename from the engine's
#      "## Prompt Extraction Review:" to the adapter's own vocabulary).
t01_performed_header() {
    local repo; repo="$(make_repo r1)"
    add_violation "$repo"
    run_adapter "$repo" --base main
    assert_exit0 "T01: --base <ref> exits 0"
    assert_contains "T01: PERFORMED header present" "## Inline Procedure Review: PERFORMED"
}

# T02: --all emits the all-scan variant of the header.
t02_all_scan_header() {
    local repo; repo="$(make_repo r2)"
    add_violation "$repo"
    run_adapter "$repo" --all
    assert_exit0 "T02: --all exits 0"
    assert_contains "T02: all-scan header present" "## Inline Procedure Review: PERFORMED (all-scan mode)"
}

# T03: --base and --all are mutually exclusive -> SKIPPED, still exit 0.
t03_mutually_exclusive() {
    local repo; repo="$(make_repo r3)"
    run_adapter "$repo" --base main --all
    assert_exit0 "T03: mutually exclusive flags still exit 0"
    assert_contains "T03: SKIPPED reported" "## Inline Procedure Review: SKIPPED"
}

# T04: --base without an argument -> SKIPPED, still exit 0.
t04_base_without_arg() {
    local repo; repo="$(make_repo r4)"
    run_adapter "$repo" --base
    assert_exit0 "T04: dangling --base still exits 0"
    assert_contains "T04: SKIPPED reported" "## Inline Procedure Review: SKIPPED"
}

# T05: exit 0 is unconditional, even when the engine finds violations.
t05_always_exit_zero() {
    local repo; repo="$(make_repo r5)"
    add_violation "$repo"
    run_adapter "$repo" --base main
    assert_exit0 "T05: violations present, adapter still exits 0"
}

# T06: violations surface as WARN:, never HARD: — the adapter is advisory.
t06_warn_not_hard() {
    local repo; repo="$(make_repo r6)"
    add_violation "$repo"
    run_adapter "$repo" --base main
    if [ "$(count_warns "$OUT")" -ge 1 ]; then
        pass "T06: at least one WARN: line emitted"
    else
        fail "T06: expected >=1 WARN: line, got $(count_warns "$OUT")" "$OUT"
    fi
    if printf '%s\n' "$OUT" | grep -q "^HARD:"; then
        fail "T06: adapter leaked a blocking HARD: prefix" "$OUT"
    else
        pass "T06: no HARD: prefix in adapter output"
    fi
}

# T07: the adapter runs the engine in --advisory mode, so a committed allowlist
#      must NOT suppress the WARN: lines (C4 — advisory implies --no-allowlist).
t07_allowlist_does_not_suppress() {
    local repo; repo="$(make_repo r7)"
    add_violation "$repo"
    printf 'inline-procedure skills/foo/SKILL.md *\n' > "$repo/.prompt-extraction-allowlist"
    git -C "$repo" add .prompt-extraction-allowlist
    git -C "$repo" commit -q -m "add wildcard allowlist entry"
    run_adapter "$repo" --base main
    assert_exit0 "T07: exits 0 with an allowlist present"
    if [ "$(count_warns "$OUT")" -ge 1 ]; then
        pass "T07: wildcard allowlist entry does not suppress advisory WARN: output"
    else
        fail "T07: allowlist suppressed the advisory output (advisory must ignore the allowlist)" "$OUT"
    fi
}

# T08: engine unavailable -> explicit SKIPPED reason, still exit 0.
t08_engine_missing() {
    local fakecfg="$TMPDIR_BASE/fakecfg"
    mkdir -p "$fakecfg/bin" "$fakecfg/hooks"
    echo "// stub marker" > "$fakecfg/hooks/enforce-worktree.js"
    cp "$SCRIPT" "$fakecfg/bin/check-inline-procedures"
    chmod +x "$fakecfg/bin/check-inline-procedures"
    # Deliberately no bin/check-prompt-extraction next to the adapter copy.
    local repo; repo="$(make_repo r8)"
    add_violation "$repo"
    RC=0
    OUT="$( (cd "$repo" && run_with_timeout 60 env "AGENTS_CONFIG_DIR=$fakecfg" \
        bash "$fakecfg/bin/check-inline-procedures" --base main) 2>&1 )" || RC=$?
    assert_exit0 "T08: missing engine still exits 0"
    assert_contains "T08: SKIPPED — engine not found" "SKIPPED — engine not found"
}

t01_performed_header
t02_all_scan_header
t03_mutually_exclusive
t04_base_without_arg
t05_always_exit_zero
t06_warn_not_hard
t07_allowlist_does_not_suppress
t08_engine_missing

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
