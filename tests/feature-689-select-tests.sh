#!/bin/bash
# tests/feature-689-select-tests.sh
# Tests: bin/select-tests.sh
# Tags: test-selection, tests, bin, git, pr, merge-base, docs-only, scope:issue-specific
#
# Issue #689 — PR-scoped test selection.
# bin/select-tests.sh reads a git diff (between merge-base and HEAD) and
# emits the set of tests/*.sh files whose stems match changed source paths.
#
# Tests for features not yet implemented are expected to SKIP (exit 77)
# at the file level until bin/select-tests.sh lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECT_SH="${AGENTS_DIR}/bin/select-tests.sh"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

# Source-absent gate: skip the whole file via exit 77 if bin/select-tests.sh
# does not exist yet. The structural test file is committed now, but the
# behavioral assertions only become meaningful after the source lands.
if [ ! -f "$SELECT_SH" ]; then
    echo "SKIP: bin/select-tests.sh not yet implemented — skipping all cases"
    exit 77
fi

TMPDIR_BASE="$(mktemp -d 2>/dev/null || echo "/tmp/f689-$$")"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a temp git repo with a base commit + a HEAD commit that touches
# given file paths. Echoes the repo path.
make_repo() {
    local repo="$1"; shift
    mkdir -p "$repo/tests/_archive" "$repo/bin" "$repo/skills/run-tests" "$repo/docs"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    # Seed: create empty test files so stem-matching has targets.
    : > "$repo/tests/run-tests.sh"
    : > "$repo/tests/feature-689-select-tests.sh"
    : > "$repo/tests/run-tests-archived.sh"
    mv "$repo/tests/run-tests-archived.sh" "$repo/tests/_archive/run-tests-archived.sh"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "base"
    # Tag base as merge-base reference
    git -C "$repo" branch -f base HEAD
    # Apply HEAD-side modifications
    for f in "$@"; do
        mkdir -p "$repo/$(dirname "$f")"
        echo "change" >> "$repo/$f"
    done
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "head" --allow-empty
}

# C1: skills/run-tests/SKILL.md changed → stem match returns tests/*run-tests*.sh
test_C1_stem_match_skill_md() {
    local repo="$TMPDIR_BASE/c1"
    make_repo "$repo" "skills/run-tests/SKILL.md"
    local out
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    if echo "$out" | grep -qE "tests/.*run-tests"; then
        pass "C1_stem_match_skill_md: SKILL.md change selects a tests/*run-tests* file"
    else
        fail "C1_stem_match_skill_md: expected a tests/*run-tests* file in output
--- output ---
$out"
    fi
}

# C2: bin/select-tests.sh itself changed → selects tests/feature-689-select-tests.sh
test_C2_self_select() {
    local repo="$TMPDIR_BASE/c2"
    make_repo "$repo" "bin/select-tests.sh"
    local out
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    if echo "$out" | grep -q "tests/feature-689-select-tests.sh"; then
        pass "C2_self_select: bin/select-tests.sh change selects tests/feature-689-select-tests.sh"
    else
        fail "C2_self_select: expected tests/feature-689-select-tests.sh in output
--- output ---
$out"
    fi
}

# C3: empty diff → empty stdout, exit 0
test_C3_empty_diff() {
    local repo="$TMPDIR_BASE/c3"
    make_repo "$repo"
    local out code
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" HEAD HEAD 2>/dev/null)"
    code=$?
    if [ "$code" = "0" ] && [ -z "$out" ]; then
        pass "C3_empty_diff: empty diff → empty stdout, exit 0"
    else
        fail "C3_empty_diff: code=$code, out='$out'"
    fi
}

# C4: no args → exit 1
test_C4_no_args() {
    local code
    run_with_timeout 120 bash "$SELECT_SH" >/dev/null 2>&1
    code=$?
    if [ "$code" = "1" ]; then
        pass "C4_no_args: no args → exit 1"
    else
        fail "C4_no_args: expected exit 1, got $code"
    fi
}

# C5: tests/_archive/ entries NEVER returned, even when stem matches.
test_C5_archive_excluded() {
    local repo="$TMPDIR_BASE/c5"
    # Stage a repo where the ONLY stem match would be in _archive.
    mkdir -p "$repo/tests/_archive" "$repo/bin"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    : > "$repo/tests/_archive/run-tests-archived.sh"
    : > "$repo/bin/unrelated.sh"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "base"
    git -C "$repo" branch -f base HEAD
    echo "change" >> "$repo/bin/run-tests-archived.sh"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "head"

    local out
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    if echo "$out" | grep -q "_archive/"; then
        fail "C5_archive_excluded: _archive entry leaked into output
--- output ---
$out"
    else
        pass "C5_archive_excluded: tests/_archive/* never returned"
    fi
}

# C6: docs-only change (docs/history.md) → empty stems → empty stdout
test_C6_docs_only_empty() {
    local repo="$TMPDIR_BASE/c6"
    make_repo "$repo" "docs/history.md"
    local out code
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    code=$?
    if [ "$code" = "0" ] && [ -z "$out" ]; then
        pass "C6_docs_only_empty: docs-only change → empty stdout, exit 0"
    else
        fail "C6_docs_only_empty: code=$code, out='$out'"
    fi
}

# shellcheck source=./feature-689-select-tests/auto-merge-base.sh
. "$AGENTS_DIR/tests/feature-689-select-tests/auto-merge-base.sh"
# shellcheck source=./feature-689-select-tests/docs-only-table.sh
. "$AGENTS_DIR/tests/feature-689-select-tests/docs-only-table.sh"
# shellcheck source=./feature-689-select-tests/zero-commit.sh
. "$AGENTS_DIR/tests/feature-689-select-tests/zero-commit.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-boundaries.sh
. "$AGENTS_DIR/tests/feature-689-select-tests/zero-commit-boundaries.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-real-resolver.sh
. "$AGENTS_DIR/tests/feature-689-select-tests/zero-commit-real-resolver.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-trust-and-faults.sh
. "$AGENTS_DIR/tests/feature-689-select-tests/zero-commit-trust-and-faults.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-hostile-paths.sh
. "$AGENTS_DIR/tests/feature-689-select-tests/zero-commit-hostile-paths.sh"


test_C1_stem_match_skill_md
test_C2_self_select
test_C3_empty_diff
test_C4_no_args
test_C5_archive_excluded
test_C6_docs_only_empty

make_fake_agents
test_S1_positional_form_unchanged
test_S2_resolved_proceeds
test_S3_recorded_proceeds
test_S4_suspect_aborts
test_S5_suspect_explains_recovery
test_S6_fallback_aborts
test_S7_unresolved_is_empty_not_abort
test_S8_resolver_arg_error_aborts
test_S9_resolver_absent_aborts
test_S10_auto_docs_only_skips_tl3
test_S11_auto_empty_diff_skips_tl3
test_S12_docs_only_helper_absent_appends
test_S13_post_session_head_notes_and_proceeds

# S14-S19 (#1779): the branch with zero commits, where merge-base == HEAD makes the diff range
# structurally empty while the whole change sits in the working tree.
test_S14_zero_commit_unstaged_selects
test_S14b_zero_commit_staged_selects_both
test_S15_zero_commit_untracked_selects
test_S16_zero_commit_field_absent_still_falls_back
test_S17_zero_commit_tl3_appends
test_S18_zero_commit_docs_only_skips_tl3
test_S19_zero_commit_git_failure_is_exit_1

# S20: the same scenario with NOTHING stubbed — the real selector against the real resolver, so
# a field the two scripts disagree about cannot pass both suites unnoticed.
test_S20_real_resolver_end_to_end

# S21-S24 (#1779): the edges of the fallback — where it must NOT reach, and what the kv parser
# does with every value of base_is_head it can be handed.
test_S21_normal_branch_field_absent_ignores_worktree
test_S22_gitignored_file_is_not_a_change
test_S23_gitignored_excluded_from_a_live_fallback
test_S23b_clean_zero_commit_branch_is_empty_not_an_error
test_S24_base_is_head_parser_table

# S25-S27 (#1779): the trust state the fallback fires under, what it does when one half of the
# working-tree union fails, and the filenames it has to survive.
test_S25_zero_commit_recorded_state_degrades
test_S26a_zero_commit_untracked_half_failure_is_exit_1
test_S26b_zero_commit_tracked_half_failure_is_exit_1
test_S27_zero_commit_hostile_filenames

# S28 (#1779): the RECORDED trust state with NOTHING stubbed — the recovery RNT-1 documents,
# replayed through the real baseline CLI, the real resolver and the real selector.
test_S28_real_resolver_recorded_state_end_to_end

test_D_is_docs_only

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
