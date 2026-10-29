#!/usr/bin/env bash
# tests/tests/feature-2649-precommit-gate-stub.sh
# Tests: tests/lib/precommit-gate-stub.sh
# Tags: scope:common, shared-lib, pre-commit, gate-stub, fixture, fail-closed, drift, node-precommit
# #2649 review C5: precommit_gate_stub_plant fails closed (rc 1 + DRIFT on stderr) whenever the gate
# list cannot be turned into stubs, and plants one stub per gate otherwise. #2507: the list is the
# Node registry's AGENTS_REPO_GATES; fixture registries plus one control against the real one.

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

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

REAL_REG="$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/registry.js"

# reg_fixture <name> <module>... — a registry.js exporting one AGENTS_REPO_GATES row per module.
reg_fixture() {
    local f="$TMPROOT/$1-registry.js" m rows=""; shift
    for m in "$@"; do rows="$rows{ cliPath: \"bin/x\", module: \"$m\" },"; done
    printf '%s\n' "module.exports = { AGENTS_REPO_GATES: [$rows] };" > "$f"
    printf '%s' "$f"
}

# plant <tag> <registry> [root]: runs the helper in a subshell; leaves rc, stdout and stderr under $TMPROOT.
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

# stub_rc <stub> -> what the stub's run() returns, as the gate runner would call it.
stub_rc() {
    node -e 'Promise.resolve(require(process.argv[1]).run({})).then((r) => console.log(r), () => console.log("throw"));' "$(np "$1")" 2>&1
}

plant good      "$(reg_fixture good bin/fx-one/main.js bin/lib/fx-two.js)"
plant empty     "$(reg_fixture empty)"
plant escape    "$(reg_fixture escape bin/lib/fx-ok.js ../outside.js)"
printf '%s\n' 'module.exports = {' > "$TMPROOT/broken-registry.js"
plant broken    "$TMPROOT/broken-registry.js"
plant no-reg    "$TMPROOT/does-not-exist.js"
plant no-root   "$(reg_fixture no-root bin/fx-one/main.js)" "$TMPROOT/no-such-root"
plant real      "$REAL_REG"

ROWS=0
check() { # <label> <want> <got>
    ROWS=$((ROWS + 1))
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi
}

case_begin "precommit-gate-stub-drift" "tests/lib/precommit-gate-stub.sh"
check "GS1: CONTROL -- two gate rows plant two stubs, no DRIFT" "0/2/no-drift" "$(verdict good)"
check "GS1b: a stub at a nested module path returns 0 from run()" "0" "$(stub_rc "$TMPROOT/good-root/bin/fx-one/main.js")"
check "GS1c: a stub at a lib module path returns 0 from run()" "0" "$(stub_rc "$TMPROOT/good-root/bin/lib/fx-two.js")"
check "GS2: an empty gate list → rc 1 + DRIFT" "1//DRIFT" "$(verdict empty)"
check "GS3: a module path escaping the sandbox → rc 1 + DRIFT" "1//DRIFT" "$(verdict escape)"
check "GS3b: nothing is written outside the sandbox root" "absent" \
    "$( [ -e "$TMPROOT/outside.js" ] && echo present || echo absent )"
check "GS4: a registry that does not load → rc 1 + DRIFT" "1//DRIFT" "$(verdict broken)"
check "GS5: a missing registry → rc 1 + DRIFT" "1//DRIFT" "$(verdict no-reg)"
check "GS6: a missing sandbox root → rc 1 + DRIFT" "1//DRIFT" "$(verdict no-root)"
check "GS7: CONTROL -- the real registry plants without DRIFT" "0/no-drift" \
    "$(cat "$TMPROOT/real.rc")/$(grep -q '^DRIFT:' "$TMPROOT/real.err" && echo DRIFT || echo no-drift)"
_real_want="$(node -e 'console.log(require(process.argv[1]).AGENTS_REPO_GATES.length)' "$(np "$REAL_REG")" | tr -d '\r')"
case "$_real_want" in ''|*[!0-9]*|0) _real_want=BAD ;; esac
check "GS7b: one stub per real gate row ($_real_want)" "$_real_want" "$(cat "$TMPROOT/real.out")"
case_end

ROWS_EXPECTED=11
if [ "$ROWS" -eq "$ROWS_EXPECTED" ]; then pass "TOTAL: all $ROWS_EXPECTED rows ran"
else fail "TOTAL" "rows ran=$ROWS expected=$ROWS_EXPECTED"; fi

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
