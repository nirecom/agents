#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/o2-positional-argv.sh
# Tests: tests/run-all.sh, bin/worker-dispatch/spawn.js, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, positional-args, argv, quoting, injection, table-driven, TL2, scope:issue-specific

# WHY: `test_args` JSON -> worker argv (shell:false) -> run-all.sh "$@" -> expanded
# scripts. Any hop can silently merge/tear an argument (a spaced path just not
# running looks like "that test passed"). Sibling o-positional-args.sh counts
# executions; this file compares the argv BYTES at the far end of the chain.

# HOW: driver spawns bash with spawnSync + shell:false exactly as
# bin/worker-dispatch/spawn.js does, so nothing can re-quote. Each fixture test
# records its own $#, $0 and every $n; compared byte-for-byte against expected.

# RED BY DESIGN (tests/run-all.sh:51): unquoted `for f in $pattern` tears any
# spaced argument — red until /write-code lands the fix. Metacharacter rows are
# the opposite claim (no command-substitution re-run) and must stay green.

# TL3 gap: dispatcher registry/anchor/env-allowlist plumbing (pinned by
# tests/feature-1643-worker-dispatch-test-runner-behavior.sh) and native-Windows
# shell argv handling. Mitigation: bin/check-verification-gate.sh preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_RUNNER="$AGENTS_DIR/tests/run-all.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-o2-$$")"
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

# WHY: RUN_ALL_JOBS / RUN_ALL_DEADLINE / RUN_ALL_PROGRESS / RUN_ALL_REAP and
# FEATURE_644_PHASE each change what the runner does, so an ambient value in the
# developer's shell could rewrite these verdicts. Every child goes through senv.

# CAVEAT: GNU `env` stops parsing options at the first NAME=VALUE, so all the
# `-u NAME` flags MUST precede any pass-through assignment. senv owns that order.
senv() {
    env -u RUN_ALL_JOBS -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE "$@"
}
AMBIENT_VARS="RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE

ROOT="$TMPD/fx"
LOG="$TMPD/exec.log"
CHILD_OUT="$TMPD/runner-output.txt"
DRIVER="$TMPD/argv-driver.js"
mkdir -p "$ROOT/bin" "$ROOT/tests/dir with space"

if [ ! -f "$REAL_RUNNER" ] || ! command -v node >/dev/null 2>&1; then
    fail "o2/prereq/runner-and-node-present" "runner=$REAL_RUNNER node=$(command -v node || echo missing)"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi
cp "$REAL_RUNNER" "$ROOT/bin/run-all.sh"

# mk_recorder <path> — a fixture test that records its own argv, byte for byte.
mk_recorder() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "argc=%%s\\n" "$#" >> "%s"\n' "$LOG"
        printf 'printf "argv[0]=%%s\\n" "$0" >> "%s"\n' "$LOG"
        printf 'i=1; for a in "$@"; do printf "argv[%%s]=%%s\\n" "$i" "$a" >> "%s"; i=$((i+1)); done\n' "$LOG"
        printf 'printf "=== end\\n" >> "%s"\n' "$LOG"
        printf 'exit 0\n'
    } > "$1"
}
mk_recorder "$ROOT/tests/plain.sh"
mk_recorder "$ROOT/tests/with space.sh"
mk_recorder "$ROOT/tests/multi-a.sh"
mk_recorder "$ROOT/tests/multi-b.sh"
mk_recorder "$ROOT/tests/multi-c.sh"
mk_recorder "$ROOT/tests/dir with space/inner1.sh"
mk_recorder "$ROOT/tests/dir with space/inner2.sh"
mk_recorder "$ROOT/decoy.sh"

# The driver is the production hop, not a re-implementation of it: spawnSync with
# shell:false and an argv ARRAY is precisely what bin/worker-dispatch/spawn.js
# hands to bash, so nothing between the JSON and "$@" can re-quote a thing.
cat > "$DRIVER" <<'DRIVERJS'
"use strict";
const fs = require("fs");
const { spawnSync } = require("child_process");
const args = JSON.parse(process.argv[2]);
const r = spawnSync("bash", [process.argv[3]].concat(args), {
  cwd: process.argv[4], shell: false, encoding: "utf8",
  timeout: 60000, windowsHide: true,
});
fs.writeFileSync(process.argv[5], String(r.stdout || "") + String(r.stderr || ""));
DRIVERJS

# Captured runner output never reaches this file's stdout unmasked: one
# contract-shaped line escaping here would break the exactly-one rule the
# run-tests hook applies over the whole stream.
executed_of() {
    sed -n 's/^[[:space:]]*RUN_CONTRACT: PASS=[0-9]* FAIL=[0-9]* SKIP=[0-9]* EXECUTED=\([0-9]*\).*/\1/p' \
        "$CHILD_OUT" 2>/dev/null | head -1
}

drive() {
    : > "$LOG"; : > "$CHILD_OUT"
    senv bash "$RWT" 90 node "$(nodepath "$DRIVER")" "$1" \
        "$(nodepath "$ROOT/bin/run-all.sh")" "$(nodepath "$ROOT")" \
        "$(nodepath "$CHILD_OUT")" >/dev/null 2>&1
}

# expected_block <semicolon-separated-paths> — the exact log a correct run leaves.
expected_block() {
    local list="$1" p out=""
    [ "$list" = "(none)" ] && { printf ''; return; }
    local IFS=';'
    for p in $list; do
        out="${out}argc=0
argv[0]=$p
=== end
"
    done
    printf '%s' "$out"
}

sentinels() { find "$TMPD" "$AGENTS_DIR" -maxdepth 3 -name 'INJ_ARG_*' 2>/dev/null | tr '\n' ' '; }

case_ambient_sanitized() {
    local probe="$TMPD/ambient-probe.sh" got want v
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for v in %s; do printf "%%s=%%s " "$v" "${!v-<unset>}"; done\n' "$AMBIENT_VARS"
    } > "$probe"
    want=""
    for v in $AMBIENT_VARS; do want="$want$v=<unset> "; done
    got="$(RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 senv bash "$probe" 2>/dev/null)"
    assert_eq "o2/ambient/senv-strips-every-hostile-value" "$want" "$got"

    # And the verdict itself must not move under a hostile ambient environment.
    local clean hostile
    drive '["tests/multi-a.sh"]'; clean="$(cat "$LOG")"
    RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 FEATURE_644_PHASE=9 \
        RUN_ALL_PROGRESS=hostile RUN_ALL_REAP=hostile drive '["tests/multi-a.sh"]'
    hostile="$(cat "$LOG")"
    assert_eq "o2/ambient/verdict-unchanged-under-hostile-ambient" "$clean" "$hostile"
}

# ===========================================================================
# The argv-boundary table: JSON test_args -> spawn argv -> "$@" -> child $0
# ===========================================================================

# `want-argv` lists, in execution order, the exact `$0` each child must report;
# `(none)` means nothing may run. `want-sentinel` is the injection verdict.
case_argv_table() {
    local name args want_argv want_sentinel got want
    while IFS='|' read -r name args want_argv want_sentinel; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="${name//[[:space:]]/}"
        want_sentinel="${want_sentinel//[[:space:]]/}"
        args="$(printf '%s' "$args" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        want_argv="$(printf '%s' "$want_argv" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

        drive "$args"
        want="$(expected_block "$want_argv")"
        got="$(cat "$LOG" 2>/dev/null)"
        assert_eq "o2/argv/$name" "$want" "$got"

        case "$want_sentinel" in
            none) assert_eq "o2/sentinel/$name" "" "$(sentinels)" ;;
            *) fail "o2/sentinel/$name" "unknown expected sentinel state '$want_sentinel'" ;;
        esac
    done <<'TABLE'
space-in-filename        | ["tests/with space.sh"]                  | tests/with space.sh                                            | none
space-in-dirname         | ["tests/dir with space/inner1.sh"]       | tests/dir with space/inner1.sh                                 | none
two-patterns-one-each    | ["tests/multi-b.sh","tests/multi-a.sh"]  | tests/multi-b.sh;tests/multi-a.sh                              | none
quoted-pattern-many      | ["tests/multi-*.sh"]                     | tests/multi-a.sh;tests/multi-b.sh;tests/multi-c.sh             | none
glob-inside-spaced-dir   | ["tests/dir with space/*.sh"]            | tests/dir with space/inner1.sh;tests/dir with space/inner2.sh  | none
empty-string-argument    | ["","tests/plain.sh"]                    | tests/plain.sh                                                 | none
bare-star-control        | ["*"]                                    | decoy.sh                                                       | none
metachar-cmdsubst        | ["$(touch INJ_ARG_A)"]                   | (none)                                                         | none
metachar-backtick        | ["`touch INJ_ARG_B`"]                    | (none)                                                         | none
metachar-semicolon-chain | ["tests/plain.sh; touch INJ_ARG_C"]      | (none)                                                         | none
TABLE
}

# ===========================================================================
# Fences — without these the table above could certify a run that never happened
# ===========================================================================
case_fences() {
    # The recorder really does record: a directly-invoked child writes the block.
    : > "$LOG"
    ( cd "$ROOT" && bash "tests/plain.sh" )
    assert_eq "o2/fence/recorder-writes-a-block" "$(expected_block 'tests/plain.sh')" "$(cat "$LOG")"

    # The driver really does reach the runner: a plain single-file run reports
    # EXECUTED=1 through the runner's own contract line.
    drive '["tests/plain.sh"]'
    assert_eq "o2/fence/driver-reaches-the-runner" "1" "$(executed_of)"

    # And run-all.sh must not hand its own argv down to the child: every recorded
    # block above states argc=0, which is only meaningful if a child CAN observe
    # arguments at all.
    : > "$LOG"
    ( cd "$ROOT" && bash "tests/plain.sh" "one arg" two )
    assert_eq "o2/fence/recorder-sees-arguments-when-given" \
        "argc=2
argv[0]=tests/plain.sh
argv[1]=one arg
argv[2]=two
=== end" "$(cat "$LOG")"
}

case_ambient_sanitized
case_argv_table
case_fences

LEFTOVERS="$(sentinels)"
if [ -z "${LEFTOVERS// /}" ]; then
    pass "o2/inject/no-sentinel-anywhere-at-exit"
else
    fail "o2/inject/no-sentinel-anywhere-at-exit" "leftovers: $LEFTOVERS"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
