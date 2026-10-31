#!/usr/bin/env bash
# tests/lib/precommit-gate-stub.sh
# Tests: hooks/pre-commit
# Tags: scope:common, shared-lib, pre-commit, gate-stub, fixture, fail-closed
# Sourced helper: one success-returning stub per agents-repo gate module in a hook sandbox (#2649).
# WHY: a sandbox that is its own hook-copy repo arms those gates, which fail closed on a missing
# module (#2589). #2507: the list is DERIVED from hooks/pre-commit.d/registry.js AGENTS_REPO_GATES.

precommit_gate_stub_plant() { # <registry.js> <sandbox-root> -> stdout: stub count; rc 1 + DRIFT on stderr
    local reg="$1" root="$2" mods mod gates n=0
    [ -f "$reg" ] || { echo "DRIFT: gate registry not found: $1" >&2; return 1; }
    [ -d "$root" ] || { echo "DRIFT: sandbox root not found: $root" >&2; return 1; }
    command -v cygpath >/dev/null 2>&1 && reg="$(cygpath -m "$reg")"
    mods="$(node -e 'for (const g of require(process.argv[1]).AGENTS_REPO_GATES) console.log(g.module);' "$reg")" \
        || { echo "DRIFT: cannot load the gate registry: $1" >&2; return 1; }
    gates="$(printf '%s\n' "$mods" | grep -c .)" || gates=0
    [ "$gates" -gt 0 ] || { echo "DRIFT: no AGENTS_REPO_GATES entry in $1" >&2; return 1; }
    while read -r mod; do
        mod="${mod%$'\r'}"
        [ -n "$mod" ] || continue
        case "/$mod/" in */../*|*/./*|//*) echo "DRIFT: unsafe gate module path: $mod" >&2; return 1 ;; esac
        mkdir -p "$root/$(dirname "$mod")" || return 1
        printf '%s\n' '"use strict";' 'module.exports = { run: () => 0 };' > "$root/$mod"
        n=$((n + 1))
    done <<EOF
$mods
EOF
    [ "$n" -eq "$gates" ] || { echo "DRIFT: $gates gate(s) in $1 but $n stub(s) planted" >&2; return 1; }
    printf '%s' "$n"
}
