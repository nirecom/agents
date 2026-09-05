#!/usr/bin/env bash
# Tests: hooks/block-capture-echo/shape.js, hooks/block-capture-echo/remedy.js
# Tags: mutation-probe, capture-echo-guard, scratchpad-allow, regex, security, scope:issue-specific, pwsh-not-required
# Serial: no

# Round 13, C10 — mutation evidence for the regex constants #2170 introduced or leans
# on. Each row neuters exactly ONE constant in a COPY of its module and asserts the
# probe input flips while a sibling input keeps its verdict, so a row cannot pass by
# breaking the whole module (a MODULE_MISSING / ERROR: verdict fails both halves).
# Harness: tests/feature-2170-regex-mutation/mutate.js.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_DIR
export AGENTS_CONFIG_DIR="$AGENTS_DIR"
MUT="$AGENTS_DIR/tests/feature-2170-regex-mutation/mutate.js"
command -v node >/dev/null 2>&1 || exit 77
[ -f "$MUT" ] || exit 77

PASS=0
FAIL=0
ROWS=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$want got=$got"; FAIL=$((FAIL + 1))
    fi
}

# A real allow-SSOT entry, so remedy.js reaches its matched (argument-rendering) branch.
ENTRY='bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip"'

judge() { # <module> <fragment> <predicate> <input>
    node "$MUT" "$1" "$2" "$3" "$4"
}

# id~module~fragment~predicate~input~baseline~mutated~control-input~control-verdict
while IFS='~' read -r id mod frag pred inp base mutv ctl ctlv; do
    [ -z "$id" ] && continue
    case "$id" in \#*) continue ;; esac
    ROWS=$((ROWS + 1))
    inp="${inp//@E@/$ENTRY}"
    ctl="${ctl//@E@/$ENTRY}"

    # Precondition: the UNMUTATED module gives the baseline verdict. Without it a
    # "flip" could be a probe input that never had the baseline verdict at all.
    assert_eq "$id-0-baseline" "$base" "$(judge "$mod" --none "$pred" "$inp")"
    # The kill: neutering this one constant changes THIS input's verdict.
    assert_eq "$id-1-mutant-flips-probe" "$mutv" "$(judge "$mod" "$frag" "$pred" "$inp")"
    # The survivor: a sibling input is untouched, so the module still works.
    assert_eq "$id-2-mutant-spares-sibling" "$ctlv" "$(judge "$mod" "$frag" "$pred" "$ctl")"
done <<'MUT_CASES'
M01-shape-NAME_RE~hooks/block-capture-echo/shape.js~([A-Za-z_][A-Za-z0-9_]*)=~shape~X=$(a); echo "$X"~true~false~ls~false
M02-shape-subst-paren~hooks/block-capture-echo/shape.js~^\$\(~shape~X=$(a); echo "$X"~true~false~X="$(a)"; echo "$X"~true
M03-shape-subst-quoted~hooks/block-capture-echo/shape.js~^"\$\(~shape~X="$(a)"; echo "$X"~true~false~X=$(a); echo "$X"~true
M04-shape-subst-backtick~hooks/block-capture-echo/shape.js~^`~shape~X=`a`; echo "$X"~true~false~X=$(a); echo "$X"~true
M05-remedy-SAFE_ARG_RE~hooks/block-capture-echo/remedy.js~^[A-Za-z0-9._/=:@,+-]+$~remedy~@E@ --target outline~bare~scratchpad~@E@~bare
M06-remedy-SECRET_NAME_RE~hooks/block-capture-echo/remedy.js~(?:token|secret|password|passwd|api[_-]?key|apikey|credential|private[_-]?key)~remedy~@E@ --token=hunter2~scratchpad~bare~@E@ --target ghp_TESTFIXTUREAAAABBBBCCCCDDDDEEEE1234~scratchpad
M07-remedy-OPAQUE_TOKEN_RE~hooks/block-capture-echo/remedy.js~^[A-Za-z0-9_+-]{20,}$~remedy~@E@ --target ghp_TESTFIXTUREAAAABBBBCCCCDDDDEEEE1234~scratchpad~bare~@E@ --token=hunter2~scratchpad
MUT_CASES

# --- Harness self-checks: the probes must be able to fail --------------------------
assert_eq "MX-1-unknown-fragment-is-reported" "FRAGMENT_NOT_FOUND" \
    "$(judge hooks/block-capture-echo/shape.js 'NO_SUCH_FRAGMENT_XYZ' shape 'ls')"
assert_eq "MX-2-missing-module-is-reported" "MODULE_MISSING" \
    "$(judge hooks/no-such-module.js --none shape 'ls')"
assert_eq "MX-3-every-row-ran" "7" "$ROWS"

echo ""
echo "regex-mutation: PASS=$PASS FAIL=$FAIL ROWS=$ROWS"
exit "$FAIL"
