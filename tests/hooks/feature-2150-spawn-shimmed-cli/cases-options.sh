# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js, bin/codegraph-lifecycle.js
# Tags: codegraph, win32-shim, spawn, spawn-options, direct-launch, table-driven, unit, scope:issue-specific
# Section O — the helper as a DELEGATE. Two questions the other sections never
# ask: does a caller's spawnSync options object survive the indirection intact,
# and does the direct .exe/.com branch really launch a real process.

# The one options object every row uses, spelled the way probe.js builds it.
# `timeout` is bin/codegraph-lifecycle.js's own STATUS_TIMEOUT_MS, so a helper
# that dropped it would silently remove the only bound that file has.
O_OPTS="timeout=60000 cwd=. encoding=utf8 env.SSC_CUSTOM=cg-2150-custom stdio=pipe shell=undefined"
O_CHILD="cwd=match env=cg-2150-custom argv=--flag,a b,x&y,\$(id)"

run_O_options() {
# Spy rows: what the underlying spawnSync was HANDED. Both branches of the class
# carry the same expectation (CPR-ORTH) — a helper that rebuilds options on the
# node path and forwards them on the direct path would pass one row and fail the
# other. `shell=undefined` is part of the string, not a separate row: the option
# must be absent, not merely falsy, on every path.
run_table O <<TABLE
O-opts-node   | node d1/codegraph-target.js :: $O_OPTS | opts | optstrio | .COM;.EXE;.BAT;.CMD | d1 | codegraph
O-opts-exe    | direct d1/codegraph.exe :: $O_OPTS     | opts | exe      | .COM;.EXE;.BAT;.CMD | d1 | codegraph
O-opts-com    | direct d1/codegraph.com :: $O_OPTS     | opts | com      | .COM;.EXE;.BAT;.CMD | d1 | codegraph
TABLE

# Real subprocess, no spy: the delegated branch, with the child reporting the
# cwd, env and argv it actually received. A spy can be satisfied by an options
# object that never reaches the OS; this cannot.
run_table O <<TABLE
O-exec-node | status=0 $O_CHILD | execopts | optstrio | .COM;.EXE;.BAT;.CMD | d1 | codegraph
TABLE

# The direct branch through a real process. The fixture is the node binary
# itself, so status, argv and the child's own view of cwd/env are observed and
# `shell` is provably never set — an .exe launched through a shell would not
# receive `x&y` or `$(id)` intact. O-direct-precedence adds a complete .cmd trio
# beside it: PATHEXT puts .EXE first, so the direct branch must still win.
if [ -n "${REAL_NODE_EXE:-}" ] && [ -x "$REAL_NODE_EXE" ]; then
    run_table O <<TABLE
O-direct-exe        | status=0 $O_CHILD | direct | realexe     | .EXE;.CMD | d1 | codegraph
O-direct-com        | status=0 $O_CHILD | direct | realcom     | .COM;.CMD | d1 | codegraph
O-direct-precedence | status=0 $O_CHILD | direct | realexeplus | .EXE;.CMD | d1 | codegraph
TABLE
else
    skip "O O-direct-* — no executable node binary to plant as the direct-launch fixture"
fi
}
