#!/usr/bin/env bash
# tests/tests/feature-2649-precommit-gate-stub.sh
# Tests: tests/lib/precommit-gate-stub.sh
# Tags: scope:common, shared-lib, pre-commit, gate-stub, fixture, fail-closed, drift
# #2649 review C5: precommit_gate_stub_plant fails closed (rc 1 + DRIFT on stderr) whenever a gate
# call line cannot be turned into a stub -- a malformed line, an unknown runner, no call line at
# all, or a missing input -- and plants one stub per call line otherwise. Fixture gate libs only,
# plus one control against the real hooks/lib/precommit-agents-repo-gates.sh.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/precommit-gate-stub.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/precommit-gate-stub.sh"

readonly TMPROOT="$(make_tmp)"
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
unset CLAUDE_CODE_SESSION_ID

REAL_LIB="$SCRIPT_CHECKOUT_ROOT/hooks/lib/precommit-agents-repo-gates.sh"
GOOD_CALL_EXEC='    _precommit_run_agents_gate "gate one" "$AGENTS_ROOT/bin/fx-gate-one" exec --staged'
GOOD_CALL_NODE='    _precommit_run_agents_gate "gate two" "$AGENTS_ROOT/bin/fx-gate-two" node'

# lib_fixture <name> <line>...: a gate lib holding the given lines plus the function definition
# and a comment naming the function, neither of which may count as a call line.
lib_fixture() {
    local f="$TMPROOT/$1.sh"; shift
    printf '%s\n' '_precommit_run_agents_gate() { :; }' \
        '# _precommit_run_agents_gate is mentioned here in a comment only' "$@" > "$f"
    printf '%s' "$f"
}

# plant <tag> <lib> [root]: runs the helper in a subshell; leaves rc, stdout and stderr under $TMPROOT.
plant() {
    local root="${3:-$TMPROOT/$1-root}" rc=0
    [ -n "${3:-}" ] || mkdir -p "$root"
    ( precommit_gate_stub_plant "$2" "$root" ) > "$TMPROOT/$1.out" 2> "$TMPROOT/$1.err" || rc=$?
    printf '%s' "$rc" > "$TMPROOT/$1.rc"
}

verdict() { # <tag> -> "<rc>/<stdout>/<DRIFT|no-drift>"
    local d=no-drift
    grep -q '^DRIFT:' "$TMPROOT/$1.err" 2>/dev/null && d=DRIFT
    printf '%s/%s/%s' "$(cat "$TMPROOT/$1.rc")" "$(cat "$TMPROOT/$1.out")" "$d"
}

plant good       "$(lib_fixture good "$GOOD_CALL_EXEC" "$GOOD_CALL_NODE")"
plant malformed  "$(lib_fixture malformed "$GOOD_CALL_EXEC" \
    '    _precommit_run_agents_gate "gate three" "$AGENTS_ROOT/hooks/fx-gate-three" exec')"
plant unquoted   "$(lib_fixture unquoted "$GOOD_CALL_EXEC" \
    '    _precommit_run_agents_gate "gate four" $AGENTS_ROOT/bin/fx-gate-four exec')"
plant runner     "$(lib_fixture runner "$GOOD_CALL_EXEC" \
    '    _precommit_run_agents_gate "gate five" "$AGENTS_ROOT/bin/fx-gate-five" python')"
plant no-calls   "$(lib_fixture no-calls)"
plant no-lib     "$TMPROOT/does-not-exist.sh"
plant no-root    "$(lib_fixture no-root "$GOOD_CALL_EXEC")" "$TMPROOT/no-such-root"
plant real       "$REAL_LIB"

ROWS=0
check() { # <label> <want> <got>
    ROWS=$((ROWS + 1))
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi
}

case_begin "precommit-gate-stub-drift" "tests/lib/precommit-gate-stub.sh"
check "GS1: CONTROL -- two well-formed call lines plant two stubs, no DRIFT" "0/2/no-drift" "$(verdict good)"
check "GS1b: the exec stub is executable and exits 0" "0" \
    "$( [ -x "$TMPROOT/good-root/bin/fx-gate-one" ] && "$TMPROOT/good-root/bin/fx-gate-one"; echo $? )"
check "GS1c: the node stub exists" "present" \
    "$( [ -f "$TMPROOT/good-root/bin/fx-gate-two" ] && echo present || echo missing )"
check "GS2: a call line whose checker is outside bin/ → rc 1 + DRIFT" "1//DRIFT" "$(verdict malformed)"
check "GS3: a call line with an unquoted checker path → rc 1 + DRIFT" "1//DRIFT" "$(verdict unquoted)"
check "GS4: a call line with an unknown runner (python) → rc 1 + DRIFT" "1//DRIFT" "$(verdict runner)"
check "GS5: a lib with only the definition and a comment (no call line) → rc 1 + DRIFT" "1//DRIFT" "$(verdict no-calls)"
check "GS6: a missing gate lib → rc 1 + DRIFT" "1//DRIFT" "$(verdict no-lib)"
check "GS7: a missing sandbox root → rc 1 + DRIFT" "1//DRIFT" "$(verdict no-root)"
check "GS8: CONTROL -- the real gate lib plants without DRIFT" "0/no-drift" \
    "$(cat "$TMPROOT/real.rc")/$(grep -q '^DRIFT:' "$TMPROOT/real.err" && echo DRIFT || echo no-drift)"
case "$(cat "$TMPROOT/real.out")" in ''|*[!0-9]*|0) _real_n=BAD ;; *) _real_n=positive ;; esac
check "GS8b: and its stub count is a positive number" "positive" "$_real_n"
case_end

# stub_shape <stub> <want_x> -> "<first line>/<x|nox|->"; `-` skips the bit (MSYS reports any
# shebang file as executable, so only the chmod'ed exec stub's bit is portable to assert).
stub_shape() {
    local x=nox
    if [ "$2" = - ]; then x=-; elif [ -x "$1" ]; then x=x; fi
    printf '%s/%s' "$(head -n 1 "$1" 2>/dev/null | tr -d '\r')" "$x"
}
# stub_run <runner> <stub> -> exit code of running the stub the way the gate lib's runner would
stub_run() {
    case "$1" in
        exec) "$2" ;;
        bash) bash "$2" ;;
        node) node "$(np "$2")" ;;
    esac
    echo $?
}

case_begin "precommit-gate-stub-runners" "tests/lib/precommit-gate-stub.sh"
# Columns: id | runner | trailing args on the call line | want first line of the stub | want exec bit (x, or - = not asserted)
while IFS='|' read -r -u 3 id runner args want_head want_x; do
    [[ -z "$id" || "$id" =~ ^[[:space:]]*# ]] && continue
    id="${id//[[:space:]]/}"; runner="${runner//[[:space:]]/}"
    args="${args#"${args%%[![:space:]]*}"}"; args="${args%"${args##*[![:space:]]}"}"
    want_head="${want_head#"${want_head%%[![:space:]]*}"}"; want_head="${want_head%"${want_head##*[![:space:]]}"}"
    want_x="${want_x//[[:space:]]/}"
    line="    _precommit_run_agents_gate \"gate $id\" \"\$AGENTS_ROOT/bin/fx-$id\" $runner${args:+ $args}"
    plant "rt-$id" "$(lib_fixture "rt-$id" "$line")"
    stub="$TMPROOT/rt-$id-root/bin/fx-$id"
    check "$id: a $runner call line plants one stub, no DRIFT" "0/1/no-drift" "$(verdict "rt-$id")"
    check "$id: the $runner stub has the runner's shape" "$want_head/$want_x" "$(stub_shape "$stub" "$want_x")"
    check "$id: the $runner stub, run as $runner, exits 0" "0" "$(stub_run "$runner" "$stub")"
done 3<<'TABLE'
RT1-exec-args | exec | --staged      | #!/bin/sh        | x
RT2-exec-bare | exec |               | #!/bin/sh        | x
RT3-bash      | bash |               | #!/bin/sh        | -
RT4-bash-args | bash | --staged --q  | #!/bin/sh        | -
RT5-node      | node |               | process.exit(0); | -
RT6-node-args | node | --staged      | process.exit(0); | -
TABLE
case_end

ROWS_EXPECTED=29
if [ "$ROWS" -eq "$ROWS_EXPECTED" ]; then pass "TOTAL: all $ROWS_EXPECTED rows ran"
else fail "TOTAL" "rows ran=$ROWS expected=$ROWS_EXPECTED"; fi

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
