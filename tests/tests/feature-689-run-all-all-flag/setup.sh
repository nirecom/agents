#!/bin/bash
# tests/tests/feature-689-run-all-all-flag/setup.sh — sourced by
# tests/tests/feature-689-run-all-all-flag.sh: counters, helpers and the shared fixtures.
# Tests: tests/run-all.sh
# Tags: bin, tests, scope:issue-specific
# Functions and fixture builders; the dispatcher sources it once before any case part.

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# The runner and the wrapper are part of this checkout: a missing one is a broken root, not a skip.
[ -f "$RUN_ALL" ] || { echo "FAIL: tests/run-all.sh not found at $RUN_ALL"; exit 1; }
[ -f "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" ] || { echo "FAIL: bin/run-with-timeout.sh not found under $SCRIPT_CHECKOUT_ROOT"; exit 1; }

# --- helpers ---------------------------------------------------------------

# --- ambient sanitization (M-ambient), self-contained ------------------------

# The five RUN_ALL_* / FEATURE_644_PHASE knobs all change what the runner does,
# so a value inherited from the developer's shell would rewrite these verdicts.
# senv() sits OUTERMOST on every child: bin/run-with-timeout.sh execs its argv
# directly, so a shell function placed inside it would die with 127 instead of
# sanitizing. GNU `env` stops parsing options at the first NAME=VALUE, so every
# `-u` flag must come before any pass-through assignment.
senv() {
    env -u TEST_MAX_JOBS_PER_RUN -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE -u TEST_MAX_JOBS_PER_HOST RUN_ALL_CONFIG_VAR_CMD=/nonexistent/get-config-var "$@"
}
AMBIENT_VARS="TEST_MAX_JOBS_PER_RUN RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
unset TEST_MAX_JOBS_PER_RUN RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE

# Canonical portable timeout wrapper (2-tier: timeout -> perl alarm), and the
# single funnel every child launch goes through — so sanitizing it here covers
# every case below without repeating the flag list per call site.
run_with_timeout() { senv bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$@"; }

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
export WORKFLOW_STATE_DIR="$TMPROOT/workflow"
export WORKFLOW_PLANS_DIR="$TMPROOT/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID
export RUN_ALL_REGISTRY_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh"
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"

# make_fixture_tests <dir> — 4 fixture tests in the bin/ category (2 pass / 1 fail
# / 1 skip; the runner discovers category dirs only) plus an _archive/ sentinel.
# Never writes inside the repository tree.
make_fixture_tests() {
    local dir="$1"
    case "$dir" in
        "$SCRIPT_CHECKOUT_ROOT"|"$SCRIPT_CHECKOUT_ROOT"/*)
            echo "FATAL: refusing to build a fixture inside the repository tree: $dir" >&2
            exit 1 ;;
    esac
    mkdir -p "$dir/tests/bin" "$dir/tests/_archive"
    printf '#!/bin/bash\necho MARKER_T1\nexit 0\n'             > "$dir/tests/bin/t1-pass.sh"
    printf '#!/bin/bash\nexit 0\n'                             > "$dir/tests/bin/t2-pass.sh"
    printf '#!/bin/bash\nexit 3\n'                             > "$dir/tests/bin/t3-fail.sh"
    printf '#!/bin/bash\nexit 77\n'                            > "$dir/tests/bin/t4-skip.sh"
    printf '#!/bin/bash\necho MARKER_ARCHIVE_LEAKED\nexit 0\n' > "$dir/tests/_archive/archive-sentinel.sh"
    chmod +x "$dir/tests/bin"/*.sh "$dir/tests/_archive"/*.sh
}

# make_fixture_repo <dir> — fixture tests plus a copy of the REAL runner placed
# so its SCRIPT_CHECKOUT_ROOT resolves to <dir>. The copy is deliberately extensionless
# (<dir>/tests/run-all): the runner globs "$TESTS_DIR"/*.sh and would otherwise
# match and re-exec itself, recursing until the timeout fires.
make_fixture_repo() {
    local dir="$1"
    make_fixture_tests "$dir"
    cp "$RUN_ALL" "$dir/tests/run-all"
    # #2473: the default sweep reads the categories from the target's .agents.json (exit 6 without one).
    printf '%s\n' '{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"bin","covers":["bin"]}],"supportDirs":["_archive","lib"],"testHarness":"on","caseMarker":"on"}}' > "$dir/.agents.json"
    # #2501 report/classify/timed-exec libs resolve from <dir>/bin/lib; copied when present.
    # run-all-launch.sh is NOT copied: without its sibling registry loader it would return 2.
    local lib
    mkdir -p "$dir/bin/lib"
    for lib in run-all-report.sh run-all-classify.sh timed-exec.sh repo-settings.sh; do
        [ -f "$SCRIPT_CHECKOUT_ROOT/bin/lib/$lib" ] && cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/$lib" "$dir/bin/lib/$lib"
    done
    # #2473: the repo settings CLI and reader the loader above calls, when present.
    mkdir -p "$dir/hooks/lib"
    [ -f "$SCRIPT_CHECKOUT_ROOT/bin/repo-settings" ] && cp "$SCRIPT_CHECKOUT_ROOT/bin/repo-settings" "$dir/bin/repo-settings"
    [ -d "$SCRIPT_CHECKOUT_ROOT/hooks/lib/repo-settings" ] && cp -R "$SCRIPT_CHECKOUT_ROOT/hooks/lib/repo-settings" "$SCRIPT_CHECKOUT_ROOT/hooks/lib/repo-settings.js" "$dir/hooks/lib/"
    return 0
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
