#!/usr/bin/env bash
# tests/lib/precommit-gate-stub.sh
# Tests: hooks/lib/precommit-agents-repo-gates.sh
# Tags: scope:common, shared-lib, pre-commit, gate-stub, fixture, fail-closed
# Sourced helper: one success-exiting stub per agents-repo gate checker in a hook sandbox (#2649).
# WHY: a sandbox that is its own hook-copy repo arms those gates, which fail closed on a missing
# checker (#2589); the list is DERIVED from the gate lib's call lines, never hand-written.

precommit_gate_stub_plant() { # <gate-lib> <sandbox-root> -> stdout: stub count; rc 1 + DRIFT on stderr
    local lib="$1" root="$2" calls derived name runner n=0
    [ -f "$lib" ] || { echo "DRIFT: gate lib not found: $lib" >&2; return 1; }
    [ -d "$root" ] || { echo "DRIFT: sandbox root not found: $root" >&2; return 1; }
    # A call line, not the definition (`name() {`) and not a comment mentioning the name.
    calls="$(grep -cE '^[[:space:]]*_precommit_run_agents_gate[[:space:]]+"' "$lib")" || calls=0
    [ "$calls" -gt 0 ] || { echo "DRIFT: no _precommit_run_agents_gate call line in $lib" >&2; return 1; }
    derived="$(sed -nE 's#^[[:space:]]*_precommit_run_agents_gate[[:space:]]+"[^"]*"[[:space:]]+"\$[A-Za-z_][A-Za-z0-9_]*/bin/([A-Za-z0-9._-]+)"[[:space:]]+(exec|bash|node)([[:space:]].*)?$#\1 \2#p' "$lib")"
    mkdir -p "$root/bin" || return 1
    while read -r name runner; do
        [ -n "$name" ] || continue
        # The charset already excludes `/`; `.`/`..` are the only names left that escape bin/.
        case "$name" in .|..) echo "DRIFT: unsafe checker name: $name" >&2; return 1 ;; esac
        case "$runner" in
            exec|bash) printf '%s\n' '#!/bin/sh' 'exit 0' > "$root/bin/$name" ;;
            node)      printf '%s\n' 'process.exit(0);' > "$root/bin/$name" ;;
        esac
        [ "$runner" = exec ] && chmod +x "$root/bin/$name"
        n=$((n + 1))
    done <<EOF
$derived
EOF
    # One stub per call line: a line the regex missed (new runner, checker outside bin/, reflowed
    # arguments) would otherwise leave that gate failing closed with no stub behind it.
    [ "$n" -eq "$calls" ] || {
        echo "DRIFT: $calls gate call line(s) in $lib but $n stub(s) derived" >&2
        return 1
    }
    printf '%s' "$n"
}
