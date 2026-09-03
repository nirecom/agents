# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js, tests/lib/shim-resolve-reference.js
# Tags: codegraph, win32-shim, parser, regex, npm-cmd-shim, table-driven, unit, scope:issue-specific
# Section N — the same parser Section V exercises, fed npm's REAL shim bytes
# instead of the reduced fixture shape. Section V can only show the extraction is
# self-consistent; N shows it survives what `npm install -g` actually writes.

run_N_npm_shapes() {
# Every row shares one resolvable directory and one pinned PATHEXT, so the only
# variable is which generator wrote the pair. N-npm8 / N-npm8-bat are cmd-shim 8
# as shipped with npm 11.9.0; N-noshebang is its `!prog` branch; N-mismatch is
# the fail-closed cross-check re-proved against the byte-faithful shape.
run_table N <<'TABLE'
N-npm8        | node d1/node_modules/@scope/pkg/npm-shim.js | verdict | npm8        | .COM;.EXE;.BAT;.CMD | d1 | codegraph
N-npm8-bat    | node d1/node_modules/@scope/pkg/npm-shim.js | verdict | npm8bat     | .COM;.EXE;.BAT;.CMD | d1 | codegraph
N-noshebang   | node d1/bin/cli.js                          | verdict | npmnoshebang| .COM;.EXE;.BAT;.CMD | d1 | codegraph
N-mismatch    | enoent                                      | verdict | npm8mismatch| .COM;.EXE;.BAT;.CMD | d1 | codegraph
N-npm8-exec   | status=0 argv=--flag,a b,x&y,$(id)          | exec    | npm8        | .COM;.EXE;.BAT;.CMD | d1 | codegraph
TABLE

# The older cmd-shim template. This is NOT a hypothetical: it is verbatim what
# `<npm prefix>/corepack.cmd` holds on the development host, so any machine
# carrying a bin written by an older npm hits it. Its target line spells
# `"%~dp0\...`, which CMD_TARGET_PATTERN (anchored on the literal `"%dp0%`)
# cannot match — so the .cmd half yields nothing and the cross-check fails
# closed. `enoent` is therefore the CURRENT contract, pinned here deliberately:
# the failure is safe (no wrong file is launched) but it is a false negative.
# N-legacy-sh-only isolates which half is responsible — a legacy SIBLING parses
# fine, because SHIM_TARGET_PATTERN's `"$basedir/...` is unchanged across
# generator versions. See the suite's TL3-gap note.
run_table N <<'TABLE'
N-legacy-both  | enoent                                      | verdict | npmlegacy    | .COM;.EXE;.BAT;.CMD | d1 | codegraph
N-legacy-cmd   | enoent                                      | verdict | npmlegacycmd | .COM;.EXE;.BAT;.CMD | d1 | codegraph
N-legacy-sh-only | node d1/node_modules/@scope/pkg/npm-shim.js | verdict | npmlegacysh | .COM;.EXE;.BAT;.CMD | d1 | codegraph
TABLE

# Section A's planted-payload proof, re-run against a byte-faithful cmd-shim 8
# file. A parser tolerant enough to read the real shape must still not be a
# shell: the DEL/ECHO pair sits between the SETLOCAL block and the target line,
# exactly where a real npm shim would carry more batch statements.
run_row N N-npm8-payload "status=0 argv=--flag,a b,x&y,\$(id)" exec npm8payload ".COM;.EXE;.BAT;.CMD" d1 codegraph
if [ "${LAST_GOT#load-failed}" != "$LAST_GOT" ]; then
    fail "N N-npm8-payload — the marker survived only because the module never ran (no evidence)"
else
    assert_eq "N N-npm8-payload — the real-shape shim body was never shell-executed" \
        "pristine" "$(cat "$LAST_CASE_DIR/__payload.txt" 2>/dev/null || echo "<destroyed-or-missing>")"
fi
}
