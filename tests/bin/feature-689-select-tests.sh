#!/bin/bash
# tests/bin/feature-689-select-tests.sh
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

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELECT_SH="${SCRIPT_CHECKOUT_ROOT}/bin/select-tests.sh"
# shellcheck source=../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"
# shellcheck source=../lib/repo-settings-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/repo-settings-fixture.sh"

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

# The selector lists tests from the target repo's .agents.json (#2473); a fixture without one exits 6.
F689_JSON='{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"bin","covers":["bin","skills"]}],"supportDirs":["lib"],"testHarness":"on","caseMarker":"on"}}'
F689_FLAT_JSON='{"tests":{"dir":"tests","categorization":"flat","testHarness":"on","caseMarker":"on"}}'

# seed_target_tests <repo> [<name>...] — <repo>/.agents.json (F689_JSON) and the empty tests/bin
# files every C/S/C12 row selects from: the stems they assert, two TL3-* for the tier append, <name>s.
seed_target_tests() {
    local repo="$1" n; shift
    mkdir -p "$repo/tests/bin"
    printf '%s\n' "$F689_JSON" > "$repo/.agents.json"
    for n in run-tests.sh feature-689-select-tests.sh feature-1779-zero-commit.sh \
        TL3-fake-alpha.sh TL3-fake-beta.sh "$@"; do
        : > "$repo/tests/bin/$n"
    done
}

# Build a temp git repo with a base commit + a HEAD commit that touches
# given file paths. Echoes the repo path.
make_repo() {
    local repo="$1"; shift
    mkdir -p "$repo/tests/_archive" "$repo/tests/bin" "$repo/bin" "$repo/skills/run-tests" "$repo/docs"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    seed_target_tests "$repo"
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

# C2: bin/select-tests.sh itself changed → selects tests/bin/feature-689-select-tests.sh
test_C2_self_select() {
    local repo="$TMPDIR_BASE/c2"
    make_repo "$repo" "bin/select-tests.sh"
    local out
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    if echo "$out" | grep -q "tests/bin/feature-689-select-tests.sh"; then
        pass "C2_self_select: bin/select-tests.sh change selects tests/bin/feature-689-select-tests.sh"
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

# C5: tests/_archive/ entries NEVER returned, even when stem matches. A flat target makes tests/
# itself the test dir, so _archive sits right under it; the same-stem live test is the control.
test_C5_archive_excluded() {
    local repo="$TMPDIR_BASE/c5" out code=0
    make_target "$repo" "$F689_FLAT_JSON" bin/run-tests-archived.sh \
        tests/_archive/run-tests-archived.sh tests/run-tests-archived-live.sh
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)" || code=$?
    if [ "$code" = "0" ] && ! echo "$out" | grep -q "_archive/" && has_suffix_line "$out" "/tests/run-tests-archived-live.sh"; then
        pass "C5_archive_excluded: tests/_archive/* never returned, same-stem live test is"
    else
        fail "C5_archive_excluded: code=$code
--- output ---
$out"
    fi
}

# make_target <repo> <agents-json> <changed-path> [<test-rel>...] — a target repo carrying
# <agents-json> and the empty <test-rel> files at base, then a HEAD commit touching <changed-path>.
make_target() {
    local repo="$1" json="$2" changed="$3" rel
    shift 3
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    printf '%s\n' "$json" > "$repo/.agents.json"
    for rel in "$@"; do
        mkdir -p "$repo/$(dirname "$rel")"
        : > "$repo/$rel"
    done
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "base"
    git -C "$repo" branch -f base HEAD
    mkdir -p "$repo/$(dirname "$changed")"
    echo "change" > "$repo/$changed"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "head"
}

# sel_fake <fake> <repo> — <fake>'s selector run in <repo>; sets SEL_OUT (stdout) and SEL_RC.
sel_fake() {
    SEL_RC=0
    SEL_OUT="$(cd "$2" && run_with_timeout 120 bash "$1/bin/select-tests.sh" base HEAD 2>/dev/null)" || SEL_RC=$?
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

# make_fake_selector <dir> — the selector plus the test-language registry (#2500) and the repo
# settings reader (#2473); both libs resolve their CLI from their own location. Tests and settings
# come from the target repo (make_target); <dir>/tests/bin holds only checkout decoys.
# bin/get-config-var is not copied, so the TL3 append cannot add noise.
make_fake_selector() {
    local fake="$1"
    mkdir -p "$fake/bin/lib" "$fake/hooks/lib" "$fake/tests/bin"
    cp "$SELECT_SH" "$fake/bin/select-tests.sh"
    cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/select-tests-stem.sh" "$fake/bin/lib/select-tests-stem.sh"
    install_repo_settings "$fake" "$SCRIPT_CHECKOUT_ROOT"
    install_test_language_registry "$fake" "$SCRIPT_CHECKOUT_ROOT"
}

# has_suffix_line <text> <suffix> — rc 0 when some line of <text> ends with <suffix> (literal).
has_suffix_line() {
    local l
    while IFS= read -r l; do
        case "$l" in *"$2") return 0 ;; esac
    done <<< "$1"
    return 1
}

native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

# supported_names <table.json> <stem> — one test filename per supported-entry pattern.
supported_names() {
    node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      for (const e of t.entries) if (e.status === "supported")
        for (const p of e.patterns) console.log(p.split("*").join(process.argv[2]));' \
        "$(native_path "$1")" "$2"
}

# C7 (#2392, #2500, #2473): every supported registry pattern is stem-matched in the TARGET repo's
# category dir — names come from the registry, not a literal extension list; a sub-folder file stays
# out (maxdepth 1); a same-stem test in the selector's own checkout is never listed.
test_C7_nonsh_stem_match() {
    local fake="$TMPDIR_BASE/c7-agents" repo="$TMPDIR_BASE/c7-repo" miss="" names n
    local -a rels=()
    make_fake_selector "$fake"
    names="$(supported_names "$fake/hooks/lib/test-language-registry.json" widget-probe)"
    if [ -z "$names" ]; then fail "C7_nonsh_stem_match: registry yielded no supported patterns"; return; fi
    while IFS= read -r n; do rels+=("tests/bin/$n" "tests/bin/sub/$n"); done <<< "$names"
    : > "$fake/tests/bin/widget-probe-checkout-decoy.sh"
    make_target "$repo" "$F689_JSON" bin/widget-probe.sh "${rels[@]}"
    sel_fake "$fake" "$repo"
    [ "$SEL_RC" = "0" ] || miss="$miss rc=$SEL_RC"
    while IFS= read -r n; do
        has_suffix_line "$SEL_OUT" "/tests/bin/$n" || miss="$miss $n"
    done <<< "$names"
    echo "$SEL_OUT" | grep -q "tests/bin/sub/" && miss="$miss sub-folder-leaked"
    has_suffix_line "$SEL_OUT" "/widget-probe-checkout-decoy.sh" && miss="$miss checkout-test-listed"
    if [ -z "$miss" ]; then
        pass "C7_nonsh_stem_match: tests/bin/<stem> for every supported pattern selected ($(echo $names)), sub/ and checkout excluded"
    else
        fail "C7_nonsh_stem_match: problems:$miss
--- output ---
$SEL_OUT"
    fi
}

# C8 (#2392): non-matching stems for .Tests.ps1 and test_*.py are NOT selected.
# Changed path has stem "foo"; test tree has "bar.*" — those files must not appear.
test_C8_nonsh_stem_no_match() {
    local fake="$TMPDIR_BASE/c8-agents" repo="$TMPDIR_BASE/c8-repo" extra=""
    make_fake_selector "$fake"
    make_target "$repo" "$F689_JSON" bin/foo.sh tests/bin/bar.Tests.ps1 tests/bin/test_bar.py
    sel_fake "$fake" "$repo"
    [ "$SEL_RC" = "0" ] || extra="$extra rc=$SEL_RC"
    echo "$SEL_OUT" | grep -q "tests/bin/bar\.Tests\.ps1" && extra="$extra bar.Tests.ps1"
    echo "$SEL_OUT" | grep -q "tests/bin/test_bar\.py"    && extra="$extra test_bar.py"
    if [ -z "$extra" ]; then
        pass "C8_nonsh_stem_no_match: non-matching .Tests.ps1 and test_*.py not selected (exit 0)"
    else
        fail "C8_nonsh_stem_no_match: unexpected result:$extra
--- output ---
$SEL_OUT"
    fi
}

# C9 (#2392): non-test entrypoint files (helper.ps1, helper.py) are never selected.
# tests/bin/helper.ps1 does not match *.Tests.ps1, and tests/bin/helper.py does not
# match test_*.py — neither must appear in output even when the changed stem matches.
test_C9_non_entrypoint_ignored() {
    local fake="$TMPDIR_BASE/c9-agents" repo="$TMPDIR_BASE/c9-repo" extra=""
    make_fake_selector "$fake"
    make_target "$repo" "$F689_JSON" bin/helper.sh tests/bin/helper.ps1 tests/bin/helper.py
    sel_fake "$fake" "$repo"
    [ "$SEL_RC" = "0" ] || extra="$extra rc=$SEL_RC"
    echo "$SEL_OUT" | grep -q "tests/bin/helper\.ps1" && extra="$extra helper.ps1"
    echo "$SEL_OUT" | grep -q "tests/bin/helper\.py"  && extra="$extra helper.py"
    if [ -z "$extra" ]; then
        pass "C9_non_entrypoint_ignored: helper.ps1 and helper.py not selected (not *.Tests.ps1 / test_*.py), exit 0"
    else
        fail "C9_non_entrypoint_ignored: non-entrypoint files leaked into selection or bad exit:$extra
--- output ---
$SEL_OUT"
    fi
}

# C10 (#2500): the selector's test patterns come from the registry. The fake tree's pester entry
# is re-patterned to *.Pester.ps1: <stem>.Pester.ps1 is then selected, <stem>.Tests.ps1 is not.
test_C10_registry_patterns_drive_selection() {
    local fake="$TMPDIR_BASE/c10-agents" repo="$TMPDIR_BASE/c10-repo" problems="" tbl
    make_fake_selector "$fake"
    tbl="$fake/hooks/lib/test-language-registry.json"
    node -e 'const f=require("fs");const t=JSON.parse(f.readFileSync(process.argv[1],"utf8"));
      const e=t.entries.find((x)=>x.patterns.includes("*.Tests.ps1"));
      e.patterns=["*.Pester.ps1"];e.nameStrip.suffix=".Pester.ps1";
      if(e.diagnostics&&e.diagnostics.nameLabel)e.diagnostics.nameLabel=".Pester.ps1";
      f.writeFileSync(process.argv[1],JSON.stringify(t,null,2));' "$(native_path "$tbl")"
    if ! node "$(native_path "$fake/bin/test-language-registry")" --format shell >/dev/null 2>&1; then
        fail "C10_registry_patterns_drive_selection: re-patterned fixture registry does not validate"
        return
    fi
    make_target "$repo" "$F689_JSON" bin/widget-probe.sh tests/bin/widget-probe.Pester.ps1 tests/bin/widget-probe.Tests.ps1
    sel_fake "$fake" "$repo"
    has_suffix_line "$SEL_OUT" "/tests/bin/widget-probe.Pester.ps1" || problems="$problems registry-pattern-not-selected(rc=$SEL_RC)"
    has_suffix_line "$SEL_OUT" "/tests/bin/widget-probe.Tests.ps1" && problems="$problems literal-pattern-still-selected"
    if [ -z "$problems" ]; then
        pass "C10_registry_patterns_drive_selection: a re-patterned registry entry changes what is selected"
    else
        fail "C10_registry_patterns_drive_selection:$problems
--- output ---
$SEL_OUT"
    fi
}

# C11 (#2500): recognized-only test files (registry status recognized-only, e.g. *.test.* and
# *_test.*; js is supported since #2501) are never selected; the same-stem supported
# widget-probe.sh is, so the run is not vacuous.
test_C11_recognized_only_not_selected() {
    local fake="$TMPDIR_BASE/c11-agents" repo="$TMPDIR_BASE/c11-repo" problems="" n
    make_fake_selector "$fake"
    make_target "$repo" "$F689_JSON" bin/widget-probe.sh \
        tests/bin/widget-probe.sh tests/bin/widget-probe.test.ts tests/bin/widget-probe_test.rb
    sel_fake "$fake" "$repo"
    has_suffix_line "$SEL_OUT" "/tests/bin/widget-probe.sh" || problems="$problems supported-control-not-selected(rc=$SEL_RC)"
    for n in widget-probe.test.ts widget-probe_test.rb; do
        has_suffix_line "$SEL_OUT" "/tests/bin/$n" && problems="$problems $n-selected"
    done
    if [ -z "$problems" ]; then
        pass "C11_recognized_only_not_selected: widget-probe.test.ts / widget-probe_test.rb not selected, widget-probe.sh is"
    else
        fail "C11_recognized_only_not_selected:$problems
--- output ---
$SEL_OUT"
    fi
}

# shellcheck source=./feature-689-select-tests/auto-merge-base.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/auto-merge-base.sh"
# shellcheck source=./feature-689-select-tests/docs-only-table.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/docs-only-table.sh"
# shellcheck source=./feature-689-select-tests/zero-commit.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/zero-commit.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-boundaries.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/zero-commit-boundaries.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-real-resolver.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/zero-commit-real-resolver.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-trust-and-faults.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/zero-commit-trust-and-faults.sh"
# shellcheck source=./feature-689-select-tests/zero-commit-hostile-paths.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/zero-commit-hostile-paths.sh"
# shellcheck source=./feature-689-select-tests/registry-unreadable.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-689-select-tests/registry-unreadable.sh"


test_C1_stem_match_skill_md
test_C2_self_select
test_C3_empty_diff
test_C4_no_args
test_C5_archive_excluded
test_C6_docs_only_empty
test_C7_nonsh_stem_match
test_C8_nonsh_stem_no_match
test_C9_non_entrypoint_ignored
test_C10_registry_patterns_drive_selection
test_C11_recognized_only_not_selected
test_C12_registry_unreadable_aborts

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
test_S27b_zero_commit_untracked_hostile_filename

# S28 (#1779): the RECORDED trust state with NOTHING stubbed — the recovery RNT-1 documents,
# replayed through the real baseline CLI, the real resolver and the real selector.
test_S28_real_resolver_recorded_state_end_to_end

test_D_is_docs_only

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
