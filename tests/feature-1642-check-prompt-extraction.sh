#!/usr/bin/env bash
# tests/feature-1642-check-prompt-extraction.sh
# Tests: bin/check-prompt-extraction, bin/lib/prompt-extraction/cli.js, bin/lib/prompt-extraction/fence-scanner.js, bin/lib/prompt-extraction/procedure-scanner.js
# Tags: prompt, bin, prompt-extraction, code-fence, inline-procedure, scope:issue-specific, scope:feature-1642, layer:TL2
#
# Issue #1642 — single-decision CLI for prompt-bloat (extraction gate) detection.
# This file owns the DETECTION SEMANTICS contract:
#   * §1.5 code-fence detection (3+ content lines inside a fence)
#   * §1.3 inline-procedure detection (MORE THAN 3 steps per section per prefix)
#   * exit-code contract: 0=clean, 1=blocking violation, 2=usage error, 3=infra error
#
# Split per rules/coding/file-split.md Pattern A (500-line HARD limit). Siblings:
#   tests/feature-1642-check-prompt-extraction/target-set.sh — target enumeration
#                                                              (--all / --base / exclusions)
#   tests/feature-1642-check-prompt-extraction/allowlist.sh  — allowlist parse / match /
#                                                              --allowlist-total / --write-allowlist
# Setup boilerplate is duplicated across the three files deliberately: a shared
# helpers.sh would couple files that must stay independently runnable by the runner.
#
# TL3 gap (what this test does NOT catch):
# - Whether the CLI is reachable on PATH inside a real Claude Code session
#   (install/path-exposed-commands.txt wiring) — covered statically by
#   tests/feature-1642-prompt-extraction-static-guards.sh T03.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$AGENTS_DIR/bin/check-prompt-extraction"

# --- Pre-implementation skip gate -------------------------------------------
if [ ! -f "$CLI" ]; then
    echo "SKIP: bin/check-prompt-extraction not found (issue #1642 not implemented yet)"
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

# make_repo <name> -> prints repo path
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

# write_file <repo> <relpath>  (content on stdin)
write_file() {
    local repo="$1" rel="$2"
    mkdir -p "$repo/$(dirname "$rel")"
    cat > "$repo/$rel"
}

stage() { git -C "$1" add -A -- "$2"; }

OUT=""
RC=0
# run_cli <repo> [args...]
run_cli() {
    local repo="$1"; shift
    RC=0
    OUT="$(cd "$repo" && run_with_timeout 60 bash "$CLI" "$@" 2>&1)" || RC=$?
}

assert_rc() {
    local label="$1" want="$2"
    if [ "$RC" -eq "$want" ]; then
        pass "$label (exit $want)"
    else
        fail "$label: expected exit $want, got $RC" "$OUT"
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

assert_not_contains() {
    local label="$1" needle="$2"
    if printf '%s\n' "$OUT" | grep -q -- "$needle"; then
        fail "$label: output unexpectedly contains '$needle'" "$OUT"
    else
        pass "$label"
    fi
}

# n content lines inside a ```-fence
emit_fence() {
    local n="$1" i
    echo '```bash'
    for ((i = 1; i <= n; i++)); do echo "echo line $i"; done
    echo '```'
}

emit_numbered() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "$i. step $i"; done
}

# ============================================================================
# §1.5 — code-fence detection
# ============================================================================

# T01: fence with exactly 3 content lines -> HARD violation, exit 1.
t01_fence_three_lines() {
    local repo; repo="$(make_repo t01)"
    { echo "# Doc"; echo ""; emit_fence 3; } | write_file "$repo" rules/t01.md
    stage "$repo" rules/t01.md
    run_cli "$repo" --staged --no-allowlist
    assert_rc "T01: 3-line fence" 1
    assert_contains "T01: HARD: line emitted" "^HARD:"
    assert_contains "T01: violation names rules/t01.md" "rules/t01.md"
}

# T02: fence with exactly 2 content lines -> clean, exit 0.
t02_fence_two_lines() {
    local repo; repo="$(make_repo t02)"
    { echo "# Doc"; echo ""; emit_fence 2; } | write_file "$repo" rules/t02.md
    stage "$repo" rules/t02.md
    run_cli "$repo" --staged --no-allowlist
    assert_rc "T02: 2-line fence is under threshold" 0
    assert_not_contains "T02: no HARD: line" "^HARD:"
}

# T03: 4-backtick outer fence containing a 3-backtick inner fence.
#      The inner fence must NOT close the outer one, and must NOT be reported
#      as a separate violation (fence nesting is decided by backtick count).
t03_nested_fence_by_count() {
    local repo; repo="$(make_repo t03)"
    {
        echo "# Doc"
        echo ""
        echo '````markdown'
        echo '```'
        echo 'x'
        echo '```'
        echo '````'
    } | write_file "$repo" rules/t03.md
    stage "$repo" rules/t03.md
    run_cli "$repo" --staged --no-allowlist --kind code-fence
    # Outer fence holds 4 content lines -> exactly one violation, at the outer start.
    local hits
    hits="$(printf '%s\n' "$OUT" | grep -c "^HARD:" || true)"
    if [ "$hits" -eq 1 ]; then
        pass "T03: nested 3-backtick fence does not close the 4-backtick outer (1 violation)"
    else
        fail "T03: expected exactly 1 HARD: violation, got $hits" "$OUT"
    fi
}

# T04: tilde fence is treated identically to a backtick fence (CPR-8).
t04_tilde_fence() {
    local repo; repo="$(make_repo t04)"
    {
        echo "# Doc"
        echo ""
        echo '~~~bash'
        echo 'a'
        echo 'b'
        echo 'c'
        echo '~~~'
    } | write_file "$repo" rules/t04.md
    stage "$repo" rules/t04.md
    run_cli "$repo" --staged --no-allowlist
    assert_rc "T04: tilde fence with 3 content lines" 1
    assert_contains "T04: tilde fence reported" "rules/t04.md"
}

# ============================================================================
# §1.3 — inline-procedure detection
# ============================================================================

# T05: 4 numbered steps in one section -> violation (threshold is MORE THAN 3).
t05_four_steps() {
    local repo; repo="$(make_repo t05)"
    { echo "# Doc"; echo ""; echo "## Procedure"; echo ""; emit_numbered 4; } \
        | write_file "$repo" rules/t05.md
    stage "$repo" rules/t05.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T05: 4 numbered steps in one section" 1
    assert_contains "T05: violation names rules/t05.md" "rules/t05.md"
}

# T06: exactly 3 numbered steps -> clean (3 is NOT more than 3).
t06_three_steps() {
    local repo; repo="$(make_repo t06)"
    { echo "# Doc"; echo ""; echo "## Procedure"; echo ""; emit_numbered 3; } \
        | write_file "$repo" rules/t06.md
    stage "$repo" rules/t06.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T06: exactly 3 numbered steps is at (not over) threshold" 0
    assert_not_contains "T06: no HARD: line" "^HARD:"
}

# T07: heading boundary resets the per-section step counter.
t07_heading_resets_counter() {
    local repo; repo="$(make_repo t07)"
    {
        echo "# Doc"
        echo ""
        echo "## First"
        echo ""
        emit_numbered 3
        echo ""
        echo "## Second"
        echo ""
        emit_numbered 3
    } | write_file "$repo" rules/t07.md
    stage "$repo" rules/t07.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T07: 3+3 steps split across headings stays clean" 0
    assert_not_contains "T07: steps do not accumulate across headings" "^HARD:"
}

# T08: sub-bullets / prose between steps do NOT reset the counter.
t08_subbullets_do_not_reset() {
    local repo; repo="$(make_repo t08)"
    {
        echo "# Doc"
        echo ""
        echo "## Procedure"
        echo ""
        echo "1. first"
        echo "   - detail a"
        echo "2. second"
        echo ""
        echo "some prose between the steps"
        echo ""
        echo "3. third"
        echo "   - detail b"
        echo "4. fourth"
    } | write_file "$repo" rules/t08.md
    stage "$repo" rules/t08.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T08: interleaved sub-bullets/prose still reach 4 steps" 1
    assert_contains "T08: violation names rules/t08.md" "rules/t08.md"
}

# T09: numbered lines INSIDE a fence are not steps.
t09_fence_interior_not_steps() {
    local repo; repo="$(make_repo t09)"
    {
        echo "# Doc"
        echo ""
        echo "## Procedure"
        echo ""
        echo '```text'
        emit_numbered 6
        echo '```'
    } | write_file "$repo" rules/t09.md
    stage "$repo" rules/t09.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T09: fence interior lines are not counted as steps" 0
    assert_not_contains "T09: no inline-procedure violation from fenced text" "^HARD:"
}

# T10: WF-CODE-N style labels are recognised as step markers.
t10_label_steps() {
    local repo; repo="$(make_repo t10)"
    {
        echo "# Doc"
        echo ""
        echo "## Steps"
        echo ""
        echo "- **WF-CODE-1** do a thing"
        echo "- **WF-CODE-2** do another"
        echo "- **WF-CODE-2a** the sub-variant"
        echo "- **WF-CODE-3** finish"
    } | write_file "$repo" rules/t10.md
    stage "$repo" rules/t10.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T10: 4 distinct WF-CODE-N labels trigger the gate" 1
    assert_contains "T10: violation names rules/t10.md" "rules/t10.md"
}

# T11: duplicate labels within one section are counted once.
t11_duplicate_labels_deduped() {
    local repo; repo="$(make_repo t11)"
    {
        echo "# Doc"
        echo ""
        echo "## Steps"
        echo ""
        echo "- **WE-1** first"
        echo "- **WE-2** second"
        echo "- **WE-3** third"
        echo "- **WE-3** third again (cross-reference)"
        echo "- **WE-3** and once more"
    } | write_file "$repo" rules/t11.md
    stage "$repo" rules/t11.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T11: repeated WE-3 label counted once -> 3 distinct steps, clean" 0
    assert_not_contains "T11: dedup prevents a false positive" "^HARD:"
}

# T12: distinct label prefixes are counted as independent series.
t12_prefix_series_independent() {
    local repo; repo="$(make_repo t12)"
    {
        echo "# Doc"
        echo ""
        echo "## Steps"
        echo ""
        echo "- **WE-1** a"
        echo "- **SC-1** b"
        echo "- **WE-2** c"
        echo "- **SC-2** d"
        echo "- **WE-3** e"
        echo "- **SC-3** f"
    } | write_file "$repo" rules/t12.md
    stage "$repo" rules/t12.md
    run_cli "$repo" --staged --no-allowlist --kind inline-procedure
    assert_rc "T12: 3 WE- + 3 SC- markers are two separate series, both at threshold" 0
    assert_not_contains "T12: prefixes do not merge into one 6-step series" "^HARD:"
}

# ============================================================================
# Mode / exit-code contract
# ============================================================================

# T22: --staged reads the INDEX blob, not the working tree.
t22_staged_reads_index() {
    local repo; repo="$(make_repo t22)"
    { echo "# Doc"; echo ""; echo "clean content, no fence"; } | write_file "$repo" rules/a.md
    stage "$repo" rules/a.md
    # Dirty the working tree AFTER staging the clean version.
    { echo "# Doc"; echo ""; emit_fence 9; } | write_file "$repo" rules/a.md
    run_cli "$repo" --staged --no-allowlist
    assert_rc "T22: --staged ignores the dirty working tree" 0
    assert_not_contains "T22: working-tree-only violation not reported" "^HARD:"
}

# T23: mutually exclusive modes -> usage error, exit 2.
#      Table-driven: every pairing of the three modes must be rejected the same
#      way (CPR-5 — the three modes are symmetric members of one family).
t23_usage_error() {
    local repo; repo="$(make_repo t23)"
    local name args
    while IFS='|' read -r name args; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="${name//[[:space:]]/}"
        # shellcheck disable=SC2086
        run_cli "$repo" $args
        assert_rc "T23/$name: '$args' rejected as a usage error" 2
    done <<'TABLE'
all-and-staged   | --all --staged
all-and-base     | --all --base HEAD
staged-and-base  | --staged --base HEAD
unknown-flag     | --staged --bogus-flag
bad-kind         | --staged --kind nonsense
TABLE
}

# T24: --staged outside a git repository -> infra error, exit 3.
t24_infra_error() {
    local nongit="$TMPDIR_BASE/nongit"
    mkdir -p "$nongit"
    run_cli "$nongit" --staged --no-allowlist
    assert_rc "T24: --staged in a non-git directory" 3
}

# T25: indented (4-space) code blocks are advisory NOTE: only.
t25_indented_block_note_only() {
    local repo; repo="$(make_repo t25)"
    {
        echo "# Doc"
        echo ""
        echo "    indented line 1"
        echo "    indented line 2"
        echo "    indented line 3"
        echo "    indented line 4"
    } | write_file "$repo" rules/a.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "add indented block"
    run_cli "$repo" --all --no-allowlist
    assert_rc "T25: --all exits 0" 0
    assert_contains "T25: indented block surfaces as NOTE: in --all" "NOTE:"

    git -C "$repo" checkout -q -b t25-branch
    echo "" >> "$repo/rules/a.md"
    echo "    indented line 5" >> "$repo/rules/a.md"
    stage "$repo" rules/a.md
    run_cli "$repo" --staged --no-allowlist
    assert_rc "T25: indented block never blocks --staged" 0
    assert_not_contains "T25: NOTE: absent from --staged output" "NOTE:"
}

# T26: --kind code-fence restricts reporting to that kind only.
t26_kind_filter() {
    local repo; repo="$(make_repo t26)"
    { echo "# Doc"; echo ""; emit_fence 4; } | write_file "$repo" rules/fence.md
    { echo "# Doc"; echo ""; echo "## Procedure"; echo ""; emit_numbered 5; } \
        | write_file "$repo" rules/proc.md
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "add both kinds"
    run_cli "$repo" --all --no-allowlist --kind code-fence
    assert_rc "T26: --all exits 0" 0
    assert_contains "T26: code-fence violation present under --kind code-fence" "rules/fence.md"
    assert_not_contains "T26: inline-procedure violation filtered out" "rules/proc.md"
}

# T27: the header line is always emitted (output-format contract).
t27_header_line() {
    local repo; repo="$(make_repo t27)"
    { echo "# Doc"; echo ""; echo "lean."; } | write_file "$repo" rules/a.md
    stage "$repo" rules/a.md
    run_cli "$repo" --staged --no-allowlist
    assert_rc "T27: clean staged tree exits 0" 0
    assert_contains "T27: '## Prompt Extraction Review:' header emitted" "^## Prompt Extraction Review:"
}

run_all() {
    t01_fence_three_lines
    t02_fence_two_lines
    t03_nested_fence_by_count
    t04_tilde_fence
    t05_four_steps
    t06_three_steps
    t07_heading_resets_counter
    t08_subbullets_do_not_reset
    t09_fence_interior_not_steps
    t10_label_steps
    t11_duplicate_labels_deduped
    t12_prefix_series_independent
    t22_staged_reads_index
    t23_usage_error
    t24_infra_error
    t25_indented_block_note_only
    t26_kind_filter
    t27_header_line
}

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
