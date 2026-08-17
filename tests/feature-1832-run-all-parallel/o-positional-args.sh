#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/o-positional-args.sh
# Tests: tests/run-all.sh
# Tags: tests, bin, parallel, positional-args, globbing, injection, TL2, scope:issue-specific

# WHY: the positional branch (`for pattern in "$@"` / `for f in $pattern`) is the
# surface every skill/hook uses to run a subset of the suite; this file pins it
# before the parallelism rewrite touches it.

# Adversarial reason: `for f in $pattern` is UNQUOTED, so args are word-split and
# glob-expanded before `[ -f ]` — a path with a space breaks, and an
# attacker-shaped filename could be re-interpreted. Both covered below.

# FIXTURE SHAPE: runner copy lives at <root>/bin/run-all.sh, tests at
# <root>/tests — one directory up so it can't glob-match and re-exec itself.

# TL3 gap: real suite's 780+ files under load, and native-Windows shell argument
# splitting. Closest-to-action mitigation: bin/check-verification-gate.sh at
# WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_RUNNER="$AGENTS_DIR/tests/run-all.sh"

PASS=0
FAIL=0
SKIPPED_NAMES=""
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
fx_note() { echo "NOTE: $1"; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-pos-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

# --- ambient sanitization (M-ambient), self-contained ------------------------

# The RUN_ALL_*/FEATURE_644_PHASE knobs change runner behavior, so an inherited
# value would rewrite verdicts. senv() wraps every child (must be outermost —
# run-with-timeout.sh execs argv directly). GNU `env` needs all `-u` flags before
# any pass-through assignment.
senv() {
    env -u RUN_ALL_JOBS -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE "$@"
}
AMBIENT_VARS="RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE

ROOT="$TMPD/fx"
RUNNER="$ROOT/bin/run-all.sh"
LOG="$TMPD/exec.log"
mkdir -p "$ROOT/bin" "$ROOT/tests"

if [ ! -f "$REAL_RUNNER" ]; then
    fail "o-pos/prereq/runner-present" "missing $REAL_RUNNER"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi
cp "$REAL_RUNNER" "$RUNNER"

# mk_test <basename> <id> — a fixture test that records its own id and exits 0.
mk_test() {
    printf '#!/usr/bin/env bash\nprintf %%s\\\\n %s >> "%s"\nexit 0\n' "$2" "$LOG" > "$ROOT/tests/$1" 2>/dev/null
}

# Captured runner output is never printed raw: one contract-shaped line escaping
# into this file's stdout would break the exactly-one rule the run-tests hook
# applies over the whole run.
mask_contract() { sed 's/^\([[:space:]]*\)RUN_CONTRACT:/\1[masked] RUN_CONTRACT:/'; }

OUT=""; RC=0
run_all() {
    : > "$LOG"
    RC=0
    OUT="$(cd "$ROOT" && senv bash "$AGENTS_DIR/bin/run-with-timeout.sh" 60 bash "$RUNNER" "$@" 2>&1)" || RC=$?
}
executed_of() {
    printf '%s\n' "$OUT" \
        | sed -n 's/^[[:space:]]*RUN_CONTRACT: PASS=[0-9]* FAIL=[0-9]* SKIP=[0-9]* EXECUTED=\([0-9]*\).*/\1/p' \
        | head -1
}
order_of() { tr '\n' ' ' < "$LOG" 2>/dev/null | sed 's/[[:space:]]*$//'; }
diag() { printf '%s\n' "$OUT" | mask_contract | tail -5; }

mk_test t1.sh t1
mk_test t2.sh t2
mk_test t3.sh t3

# ===========================================================================
# 1. Normal cases — one file, one glob, several patterns
# ===========================================================================
case_single_file() {
    run_all "tests/t1.sh"
    assert_eq "o-pos/single/executed-is-1" "1" "$(executed_of)"
    assert_eq "o-pos/single/only-that-file-ran" "t1" "$(order_of)"
    assert_eq "o-pos/single/exit-zero" "0" "$RC"
}

case_glob_pattern() {
    run_all "tests/t*.sh"
    # Pathname expansion is sorted, so the order is a fact, not a coincidence.
    assert_eq "o-pos/glob/executed-is-3" "3" "$(executed_of)"
    assert_eq "o-pos/glob/exact-set-and-order" "t1 t2 t3" "$(order_of)"
}

case_multiple_patterns() {
    run_all "tests/t3.sh" "tests/t1.sh"
    assert_eq "o-pos/multi/executed-is-2" "2" "$(executed_of)"
    # Argument order wins over lexical order: the runner walks "$@" in order.
    assert_eq "o-pos/multi/runs-in-argument-order" "t3 t1" "$(order_of)"
}

# OBSERVED, NOT DESIRED: overlapping patterns are not de-duplicated — a file named
# by two patterns runs twice. Pinned so the rewrite can't change it by accident.
case_overlapping_patterns() {
    run_all "tests/t1.sh" "tests/t*.sh"
    assert_eq "o-pos/overlap/duplicate-not-deduped-executed-is-4" "4" "$(executed_of)"
    assert_eq "o-pos/overlap/duplicate-runs-twice" "t1 t1 t2 t3" "$(order_of)"
}

# ===========================================================================
# 2. Error / edge cases — patterns that match nothing
# ===========================================================================

# OBSERVED, MERELY CURRENT: an unmatched pattern is silent (EXECUTED=0, exit 0) —
# a typo looks like a green run. Pinned as-is; a future issue should fix it.
case_unmatched_pattern() {
    run_all "tests/nomatch-zzz-*.sh"
    assert_eq "o-pos/unmatched/executed-is-0" "0" "$(executed_of)"
    assert_eq "o-pos/unmatched/exit-is-zero-not-an-error" "0" "$RC"
    assert_eq "o-pos/unmatched/nothing-ran" "" "$(order_of)"

    # A matched pattern beside an unmatched one still runs: the miss is skipped,
    # not fatal to the rest of the invocation.
    run_all "tests/t2.sh" "tests/nomatch-zzz-*.sh"
    assert_eq "o-pos/unmatched/sibling-still-runs-executed-is-1" "1" "$(executed_of)"
    assert_eq "o-pos/unmatched/sibling-is-the-matched-one" "t2" "$(order_of)"
}

# ===========================================================================
# 3. File/path edge case — a path containing a space
# ===========================================================================

# RED BY DESIGN (tests/run-all.sh:51): unquoted `for f in $pattern` splits
# "tests/with space.sh" into two tokens and the file never runs.
case_path_with_spaces() {
    mk_test "with space.sh" sp
    run_all "tests/with space.sh"
    assert_eq "o-pos/space/executed-is-1" "1" "$(executed_of)"
    assert_eq "o-pos/space/ran-the-spaced-file" "sp" "$(order_of)"
    [ "$(order_of)" = "sp" ] || fx_note "space case diagnostic: $(diag | tr '\n' ' ')"
}

# ===========================================================================
# 4. Shell-metacharacter filenames
# ===========================================================================

# NTFS refuses : ? * | < > " outright, so creatability is probed; rejected
# names are skipped and reported by name.
try_mk() {
    local base="$1" id="$2"
    mk_test "$base" "$id" 2>/dev/null || true
    [ -f "$ROOT/tests/$base" ]
}

meta_case() {
    local label="$1" base="$2" id="$3"
    if ! try_mk "$base" "$id"; then
        SKIPPED_NAMES="$SKIPPED_NAMES $label"
        fx_note "o-pos/meta/$label — filesystem refused the filename, case skipped"
        return
    fi
    run_all "tests/$base"
    assert_eq "o-pos/meta/$label/executed-is-1" "1" "$(executed_of)"
    assert_eq "o-pos/meta/$label/ran-exactly-once" "$id" "$(order_of)"
    rm -f "$ROOT/tests/$base"
}

case_metacharacters() {
    meta_case "semicolon" 'semi;colon.sh' m1
    meta_case "ampersand" 'amp&ersand.sh' m2
    meta_case "pipe" 'pipe|char.sh' m3
    meta_case "star" 'star*x.sh' m4
    meta_case "question" 'quest?x.sh' m5
    meta_case "dollar" 'dollar$var.sh' m6
    meta_case "backtick" 'back`tick.sh' m7
    meta_case "single-quote" "quote'single.sh" m8
    meta_case "double-quote" 'quote"double.sh' m9
    meta_case "newline" "$(printf 'new\nline.sh')" m10
    if [ -n "$SKIPPED_NAMES" ]; then
        fx_note "o-pos/meta/skipped-by-filesystem:$SKIPPED_NAMES"
    else
        fx_note "o-pos/meta/skipped-by-filesystem: (none)"
    fi
}

# ===========================================================================
# 5. Input injection — a filename shaped like a command substitution
# ===========================================================================

# The security claim is the sentinel, not the count: word splitting/globbing must
# not re-run command substitution on an already-expanded value.

# The sentinel is a bare name (filenames can't contain '/'); the sweep below
# looks everywhere under the fixture for it.
sentinel_hits() { find "$TMPD" -name "$1" 2>/dev/null; }

inject_case() {
    local label="$1" base="$2" sentinel="$3" id="$4" hits
    if ! try_mk "$base" "$id"; then
        SKIPPED_NAMES="$SKIPPED_NAMES $label"
        fx_note "o-pos/inject/$label — filesystem refused the filename, case skipped"
        return
    fi
    run_all "tests/$base"
    hits="$(sentinel_hits "$sentinel" | tr '\n' ' ')"
    if [ -n "$hits" ]; then
        fail "o-pos/inject/$label/no-sentinel-side-effect" \
            "the filename was executed as a command; sentinel created at: $hits"
        find "$TMPD" -name "$sentinel" -exec rm -f {} + 2>/dev/null
    else
        pass "o-pos/inject/$label/no-sentinel-side-effect"
    fi
    # RED BY DESIGN where the shaped name contains spaces: the file exists and
    # must run exactly once, which the unquoted `for f in $pattern` prevents.
    assert_eq "o-pos/inject/$label/executed-is-1" "1" "$(executed_of)"
    rm -f "$ROOT/tests/$base"
}

case_injection() {
    inject_case "cmdsubst" '$(touch INJ_SENTINEL_A).sh' INJ_SENTINEL_A inj1
    inject_case "backtick" '`touch INJ_SENTINEL_B`.sh' INJ_SENTINEL_B inj2
}

# ===========================================================================
# 6. The sanitization above is itself asserted, not assumed
# ===========================================================================
case_ambient_sanitized() {
    local probe="$TMPD/ambient-probe.sh" got want v
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for v in %s; do printf "%%s=%%s " "$v" "${!v-<unset>}"; done\n' "$AMBIENT_VARS"
    } > "$probe"
    want=""; for v in $AMBIENT_VARS; do want="$want$v=<unset> "; done
    got="$(RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 senv bash "$probe" 2>/dev/null)"
    assert_eq "o-pos/ambient/senv-strips-every-hostile-value" "$want" "$got"
    # The behavioural half: the glob verdict must not move under a hostile
    # ambient environment. Asserted against the literal expectation, so an
    # invocation that silently ran nothing cannot satisfy it.
    export RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile
    export RUN_ALL_REAP=hostile FEATURE_644_PHASE=9
    run_all "tests/t*.sh"
    unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE
    assert_eq "o-pos/ambient/glob-verdict-unchanged-under-hostile-ambient" \
        "3/t1 t2 t3" "$(executed_of)/$(order_of)"
}

case_ambient_sanitized
case_single_file
case_glob_pattern
case_multiple_patterns
case_overlapping_patterns
case_unmatched_pattern
case_path_with_spaces
case_metacharacters
case_injection

# Last line of defence: no sentinel anywhere under the fixture, and none in the
# two directories an injected `touch` could plausibly have reached.
LEFTOVERS="$( { sentinel_hits INJ_SENTINEL_A; sentinel_hits INJ_SENTINEL_B; \
    ls -d "$AGENTS_DIR"/INJ_SENTINEL_* 2>/dev/null; } | tr '\n' ' ')"
if [ -z "${LEFTOVERS// /}" ]; then
    pass "o-pos/inject/no-sentinel-anywhere-at-exit"
else
    fail "o-pos/inject/no-sentinel-anywhere-at-exit" "leftovers: $LEFTOVERS"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
