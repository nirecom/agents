#!/bin/bash
# tests/feature-689-run-all-all-flag.sh
# Tests: tests/run-all.sh
# Tags: bin, tests, scope:issue-specific
#
# Issue #689 — tests/run-all.sh dispatch: `--all`, the default sweep (which
# excludes tests/_archive/), and bare positional file arguments.
# Issue #1836 — every case runs against a throwaway fixture suite under
# mktemp; no case may ever sweep the repository's own tests/ tree.

# RECURSION CONTRACT (#1836): no case in this file may launch the repository's
# own tests/run-all.sh with TESTS_DIR unset or empty AND no positional
# argument. That re-runs the whole suite from inside the suite — and the
# runner's own file is matched by its "$TESTS_DIR"/*.sh glob, so the recursion
# never terminates. Every launch line below pins a non-empty TESTS_DIR= or
# names a positional file; C6(a) enforces that mechanically.

# TL3 gap (what this test does NOT catch):
# - runner behaviour under a non-bash /bin/sh or a shell without `local`
# - real-CI glob/locale differences in "$TESTS_DIR"/*.sh expansion
# Closest-to-action mitigation: the runner is bash-pinned by its shebang, so
# the residual gap is limited to CI shell-image drift.

set -u

SELF="${BASH_SOURCE[0]}"
AGENTS_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
RUN_ALL="$AGENTS_DIR/tests/run-all.sh"

# Belt-and-braces for the recursion contract: if the suite ever re-enters this
# file, stop instead of forking another level.
if [ -n "${FEATURE_689_REENTRY_GUARD:-}" ]; then
    echo "SKIP: feature-689-run-all-all-flag re-entered recursively (recursion contract violated)"
    exit 77
fi
export FEATURE_689_REENTRY_GUARD=1

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

[ -f "$RUN_ALL" ] || { echo "SKIP: tests/run-all.sh not present"; exit 77; }
[ -f "$AGENTS_DIR/bin/run-with-timeout.sh" ] || { echo "SKIP: bin/run-with-timeout.sh not present"; exit 77; }

# --- helpers ---------------------------------------------------------------

# --- ambient sanitization (M-ambient), self-contained ------------------------

# The five RUN_ALL_* / FEATURE_644_PHASE knobs all change what the runner does,
# so a value inherited from the developer's shell would rewrite these verdicts.
# senv() sits OUTERMOST on every child: bin/run-with-timeout.sh execs its argv
# directly, so a shell function placed inside it would die with 127 instead of
# sanitizing. GNU `env` stops parsing options at the first NAME=VALUE, so every
# `-u` flag must come before any pass-through assignment.
senv() {
    env -u RUN_ALL_JOBS -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE "$@"
}
AMBIENT_VARS="RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE

# Canonical portable timeout wrapper (2-tier: timeout -> perl alarm), and the
# single funnel every child launch goes through — so sanitizing it here covers
# every case below without repeating the flag list per call site.
run_with_timeout() { senv bash "$AGENTS_DIR/bin/run-with-timeout.sh" "$@"; }

# Neutralise a captured child contract line. This file's stdout is scanned by
# hooks/workflow-run-tests.js and bin/worker-dispatch/workers/test-runner.js,
# which both require exactly one line-initial contract marker over the whole
# stream; leaking a captured one breaks the run verdict.
mask_contract() { sed 's/^\([[:space:]]*\)RUN_CONTRACT:/\1[masked] RUN_CONTRACT:/'; }

# The single funnel for printing captured runner output: last 20 lines, masked,
# and prefixed so child verdict lines cannot be read as this file's own.
diag() { printf '%s\n' "$1" | tail -20 | mask_contract | sed 's/^/    | /'; }

count_lines() { printf '%s\n' "$2" | grep -cE "$1" || true; }
has_line() { printf '%s\n' "$2" | grep -qE "$1"; }
has_fixed() { printf '%s\n' "$2" | grep -qF "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): pin the workflow dir and
# the plans dir as a pair, and drop inherited session ids.
export CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow"
export WORKFLOW_PLANS_DIR="$TMPROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID

# make_fixture_tests <dir> — 4 top-level fixture tests (2 pass / 1 fail / 1
# skip) plus an _archive/ sentinel. Never writes inside the repository tree.
make_fixture_tests() {
    local dir="$1"
    case "$dir" in
        "$AGENTS_DIR"|"$AGENTS_DIR"/*)
            echo "FATAL: refusing to build a fixture inside the repository tree: $dir" >&2
            exit 1 ;;
    esac
    mkdir -p "$dir/tests/_archive"
    printf '#!/bin/bash\necho MARKER_T1\nexit 0\n'             > "$dir/tests/t1-pass.sh"
    printf '#!/bin/bash\nexit 0\n'                             > "$dir/tests/t2-pass.sh"
    printf '#!/bin/bash\nexit 3\n'                             > "$dir/tests/t3-fail.sh"
    printf '#!/bin/bash\nexit 77\n'                            > "$dir/tests/t4-skip.sh"
    printf '#!/bin/bash\necho MARKER_ARCHIVE_LEAKED\nexit 0\n' > "$dir/tests/_archive/archive-sentinel.sh"
    chmod +x "$dir/tests"/*.sh "$dir/tests/_archive"/*.sh
}

# make_fixture_repo <dir> — fixture tests plus a copy of the REAL runner placed
# so its AGENTS_DIR resolves to <dir>. The copy is deliberately extensionless
# (<dir>/tests/run-all): the runner globs "$TESTS_DIR"/*.sh and would otherwise
# match and re-exec itself, recursing until the timeout fires.
make_fixture_repo() {
    local dir="$1"
    make_fixture_tests "$dir"
    cp "$RUN_ALL" "$dir/tests/run-all"
}

# tests/run-all.sh honours an inherited TESTS_DIR only once /write-code lands
# the ${TESTS_DIR:-...} assignment. Until then a TESTS_DIR pin is silently
# ignored and the runner would sweep the REAL tests/ tree, so the cases that
# depend on the override fail fast instead of launching it.
tests_dir_override_supported() {
    grep -qE '^[[:space:]]*(:|TESTS_DIR=)[^#]*\$\{TESTS_DIR:[-=]' "$RUN_ALL"
}
MISSING_OVERRIDE='tests/run-all.sh has no ${TESTS_DIR:-...} override yet — refusing to launch it with a TESTS_DIR pin, which would sweep the real tests/ tree'

FX="$TMPROOT/fx"
make_fixture_tests "$FX"
make_fixture_repo "$TMPROOT/repo"
FIXTURE_RUNNER="$TMPROOT/repo/tests/run-all"

# --- cases -----------------------------------------------------------------

# C1: `--all` sweeps exactly the fixture suite pointed at by TESTS_DIR.
test_C1_all_flag_iterates() {
    if ! tests_dir_override_supported; then
        fail "C1_all_flag_iterates: $MISSING_OVERRIDE"
        return
    fi
    local out rc dispatch contract
    out="$(TESTS_DIR="$FX/tests" run_with_timeout 60 bash "$RUN_ALL" --all 2>&1)"
    rc=$?
    dispatch="$(count_lines '^(PASS|FAIL|SKIP): ' "$out")"
    contract="$(count_lines '^RUN_CONTRACT: PASS=2 FAIL=1 SKIP=1 EXECUTED=4$' "$out")"
    if [ "$dispatch" = "4" ] && [ "$contract" = "1" ] && [ "$rc" = "1" ]; then
        pass "C1_all_flag_iterates: --all swept exactly the 4 fixture tests (rc=$rc)"
    else
        fail "C1_all_flag_iterates: dispatch=$dispatch contract=$contract rc=$rc (want 4 verdict lines, one contract line PASS=2 FAIL=1 SKIP=1 EXECUTED=4, rc=1)"
        diag "$out"
    fi
}

# C2: a single positional file argument runs exactly that file.
test_C2_positional_single_file() {
    local target="$TMPROOT/lone/only-this.sh"
    mkdir -p "$TMPROOT/lone"
    printf '#!/bin/bash\necho MARKER_LONE\nexit 0\n' > "$target"
    chmod +x "$target"
    local out rc dispatch marker
    out="$(run_with_timeout 60 bash "$RUN_ALL" "$target" 2>&1)"
    rc=$?
    dispatch="$(count_lines '^(PASS|FAIL|SKIP): ' "$out")"
    marker="$(count_lines 'MARKER_LONE' "$out")"
    if [ "$dispatch" = "1" ] && [ "$marker" -ge 1 ] && [ "$rc" = "0" ]; then
        pass "C2_positional_single_file: only the named file ran (dispatch=$dispatch marker=$marker)"
    else
        fail "C2_positional_single_file: dispatch=$dispatch marker=$marker rc=$rc (want 1 verdict line, marker>=1, rc=0)"
        diag "$out"
    fi
}

# C3: the default (no-argument) sweep excludes <tests>/_archive/.
test_C3_default_excludes_archive() {
    if ! tests_dir_override_supported; then
        fail "C3_default_excludes_archive: $MISSING_OVERRIDE"
        return
    fi
    local out rc
    out="$(TESTS_DIR="$FX/tests" run_with_timeout 60 bash "$RUN_ALL" 2>&1)"
    rc=$?
    if ! has_line 'MARKER_ARCHIVE_LEAKED' "$out" && has_line 'EXECUTED=4$' "$out"; then
        pass "C3_default_excludes_archive: default sweep ran the 4 top-level fixture tests and skipped _archive/"
    else
        fail "C3_default_excludes_archive: archive sentinel leaked or EXECUTED was not 4 (rc=$rc)"
        diag "$out"
    fi
}

# C4(a): a TESTS_DIR pointing at a non-existent directory sweeps nothing.
test_C4a_missing_tests_dir() {
    if ! tests_dir_override_supported; then
        fail "C4a_missing_tests_dir: $MISSING_OVERRIDE"
        return
    fi
    local out rc
    out="$(TESTS_DIR="$TMPROOT/does-not-exist" run_with_timeout 60 bash "$RUN_ALL" --all 2>&1)"
    rc=$?
    if has_line 'EXECUTED=0$' "$out" && [ "$rc" = "0" ]; then
        pass "C4a_missing_tests_dir: non-existent TESTS_DIR executes nothing and exits 0"
    else
        fail "C4a_missing_tests_dir: rc=$rc (want an EXECUTED=0 contract line and rc=0)"
        diag "$out"
    fi
}

# C4(b): default resolution — with TESTS_DIR empty and with it unset, the
# copied runner must resolve its tests dir from its own AGENTS_DIR. Exercised
# only against the fixture copy; the real tests/ tree is never launched.
test_C4b_default_from_agents_dir() {
    local out rc unset_out unset_rc ok=1
    out="$(TESTS_DIR="" run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    rc=$?
    unset_out="$(unset TESTS_DIR; run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    unset_rc=$?
    has_line 'EXECUTED=4$' "$out" || ok=0
    has_line 'MARKER_T1' "$out" || ok=0
    [ "$rc" = "1" ] || ok=0
    has_line 'EXECUTED=4$' "$unset_out" || ok=0
    has_line 'MARKER_T1' "$unset_out" || ok=0
    [ "$unset_rc" = "1" ] || ok=0
    # Mechanical proof that the repository's own suite was not swept.
    ! has_fixed "$AGENTS_DIR/tests/" "$out" || ok=0
    ! has_fixed "$AGENTS_DIR/tests/" "$unset_out" || ok=0
    if [ "$ok" = "1" ]; then
        pass "C4b_default_from_agents_dir: empty and unset TESTS_DIR both fall back to the fixture repo's own tests dir"
    else
        fail "C4b_default_from_agents_dir: empty-rc=$rc unset-rc=$unset_rc (want EXECUTED=4 + MARKER_T1 + rc=1 for both, and no real tests/ path in the output)"
        diag "$out"
        diag "$unset_out"
    fi
}

# C4(c): a positional argument wins over TESTS_DIR.
test_C4c_positional_beats_tests_dir() {
    local target="$TMPROOT/pos/named-only.sh"
    mkdir -p "$TMPROOT/pos"
    printf '#!/bin/bash\necho MARKER_NAMED\nexit 0\n' > "$target"
    chmod +x "$target"
    local out rc dispatch ok=1
    out="$(TESTS_DIR="$FX/tests" run_with_timeout 60 bash "$RUN_ALL" "$target" 2>&1)"
    rc=$?
    dispatch="$(count_lines '^(PASS|FAIL|SKIP): ' "$out")"
    [ "$dispatch" = "1" ] || ok=0
    has_line 'MARKER_NAMED' "$out" || ok=0
    ! has_line 'MARKER_T1' "$out" || ok=0
    [ "$rc" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "C4c_positional_beats_tests_dir: only the named file ran despite a TESTS_DIR pin (dispatch=$dispatch)"
    else
        fail "C4c_positional_beats_tests_dir: dispatch=$dispatch rc=$rc (want only the named file to run)"
        diag "$out"
    fi
}

# C5(a): the timeout helper delegates to the canonical wrapper — no private
# perl tier, no unbounded bare-exec fallback.
test_C5a_timeout_helper_delegates() {
    local alarm_word="alarm"
    local shift_word="shift"
    local ok=1
    ! grep -qE "$alarm_word[[:space:]]+$shift_word" "$SELF" || ok=0
    ! grep -qE '^[[:space:]]*"\$@"[[:space:]]*$' "$SELF" || ok=0
    grep -qF 'bin/run-with-timeout.sh' "$SELF" || ok=0
    if [ "$ok" = "1" ]; then
        pass "C5a_timeout_helper_delegates: no private perl tier, no unbounded bare-exec tier, canonical wrapper referenced"
    else
        fail "C5a_timeout_helper_delegates: this file still carries a private timeout ladder or does not reference bin/run-with-timeout.sh"
    fi
}

# C5(b): the helper actually bounds a long-running command.
test_C5b_timeout_helper_bounds() {
    local start end elapsed rc
    start=$(date +%s)
    run_with_timeout 2 sleep 20 >/dev/null 2>&1
    rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    if [ "$rc" != "0" ] && [ "$elapsed" -lt 10 ]; then
        pass "C5b_timeout_helper_bounds: run_with_timeout 2 sleep 20 aborted after ${elapsed}s (rc=$rc)"
    else
        fail "C5b_timeout_helper_bounds: rc=$rc elapsed=${elapsed}s (want non-zero rc within 10s)"
    fi
}

# C6(a): static recursion guard — every launch of the repository runner pins a
# non-empty TESTS_DIR or names a positional file.
test_C6a_no_unpinned_launch() {
    local launch_lines total bad=0 line
    launch_lines="$(grep -nE 'bash "\$RUN_ALL"' "$SELF" || true)"
    total="$(printf '%s\n' "$launch_lines" | grep -c '.' || true)"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '%s\n' "$line" | grep -qE 'TESTS_DIR="[^"]+"' && continue
        printf '%s\n' "$line" | grep -qE 'bash "\$RUN_ALL" "' && continue
        bad=$((bad + 1))
        echo "    ! unpinned launch: $line"
    done <<< "$launch_lines"
    if [ "$total" -ge 4 ] && [ "$bad" = "0" ]; then
        pass "C6a_no_unpinned_launch: all $total repository-runner launches pin TESTS_DIR or name a file"
    else
        fail "C6a_no_unpinned_launch: total=$total unpinned=$bad (want at least 4 launches and 0 unpinned)"
    fi
}

# C6(b): static contract-pollution guard — captured runner output only ever
# reaches stdout through diag(), which masks and truncates it.
test_C6b_captured_output_masked() {
    local refs total bad=0 line diag_calls body_ok=0
    refs="$(grep -nE '"\$[a-z_]*out"' "$SELF" || true)"
    total="$(printf '%s\n' "$refs" | grep -c '.' || true)"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            *'="$('*) continue ;;
            *'count_lines '*) continue ;;
            *'has_line '*) continue ;;
            *'has_fixed '*) continue ;;
            *'diag "$'*) continue ;;
        esac
        bad=$((bad + 1))
        echo "    ! unmasked output reference: $line"
    done <<< "$refs"
    diag_calls="$(grep -cE '^[[:space:]]+diag "\$' "$SELF" || true)"
    if grep -E '^diag\(\)' "$SELF" | grep -q 'mask_contract' \
       && grep -E '^diag\(\)' "$SELF" | grep -q 'tail -20'; then
        body_ok=1
    fi
    if [ "$total" -ge 5 ] && [ "$bad" = "0" ] && [ "$diag_calls" -ge 1 ] && [ "$body_ok" = "1" ]; then
        pass "C6b_captured_output_masked: $total captured-output references, none unmasked; diag() truncates and masks"
    else
        fail "C6b_captured_output_masked: refs=$total unmasked=$bad diag_calls=$diag_calls diag_body_ok=$body_ok"
    fi
}

# C6(c): behavioural contract-pollution guard — mask_contract removes every
# line-initial contract marker from real captured runner output.
test_C6c_mask_contract_strips_marker() {
    local raw_out masked_out
    raw_out="$(run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    if ! has_line '^[[:space:]]*RUN_CONTRACT:' "$raw_out"; then
        fail "C6c_mask_contract_strips_marker: fixture run emitted no contract line, so the mask assertion would be vacuous"
        diag "$raw_out"
        return
    fi
    masked_out="$(printf '%s\n' "$raw_out" | mask_contract)"
    if has_line '^[[:space:]]*RUN_CONTRACT:' "$masked_out"; then
        fail "C6c_mask_contract_strips_marker: masked output still carries a line-initial contract marker"
        diag "$raw_out"
    else
        pass "C6c_mask_contract_strips_marker: every line-initial contract marker is neutralised"
    fi
}

# C7: the ambient sanitization is asserted, not assumed — a hostile value for
# any of the five runner knobs must reach neither the child env nor the verdict.
test_C7_ambient_sanitized() {
    local probe="$TMPROOT/ambient-probe.sh" got want v ok=1 hostile_out
    {
        printf '#!/bin/bash\n'
        printf 'for v in %s; do printf "%%s=%%s " "$v" "${!v-<unset>}"; done\n' "$AMBIENT_VARS"
    } > "$probe"
    want=""; for v in $AMBIENT_VARS; do want="$want$v=<unset> "; done
    got="$(RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 senv bash "$probe" 2>/dev/null)"
    [ "$got" = "$want" ] || ok=0
    # Behavioural half: the fixture sweep's verdict must not move under a
    # hostile ambient environment. Pinned to the literal EXECUTED=4 / rc=1, so a
    # launch that silently ran nothing cannot satisfy it either.
    export RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile
    export RUN_ALL_REAP=hostile FEATURE_644_PHASE=9
    hostile_out="$(run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    local hostile_rc=$?
    unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE
    has_line 'EXECUTED=4$' "$hostile_out" || ok=0
    has_line 'MARKER_T1' "$hostile_out" || ok=0
    [ "$hostile_rc" = "1" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "C7_ambient_sanitized: hostile RUN_ALL_*/FEATURE_644_PHASE values reach neither the child env nor the verdict"
    else
        fail "C7_ambient_sanitized: child env='$got' (want '$want'), hostile-run rc=$hostile_rc (want EXECUTED=4 + MARKER_T1 + rc=1)"
        diag "$hostile_out"
    fi
}

test_C1_all_flag_iterates
test_C2_positional_single_file
test_C3_default_excludes_archive
test_C4a_missing_tests_dir
test_C4b_default_from_agents_dir
test_C4c_positional_beats_tests_dir
test_C5a_timeout_helper_delegates
test_C5b_timeout_helper_bounds
test_C6a_no_unpinned_launch
test_C6b_captured_output_masked
test_C6c_mask_contract_strips_marker
test_C7_ambient_sanitized

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
