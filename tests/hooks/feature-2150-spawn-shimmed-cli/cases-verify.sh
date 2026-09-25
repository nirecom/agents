# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js
# Tags: codegraph, win32-shim, parser, regex, boundary, table-driven, unit, scope:issue-specific
# Section V of tests/feature-2150-spawn-shimmed-cli.sh — verifiedShimTarget():
# the two target-extraction regexes, their cross-check, and the file/path error
# boundary. Every row shares ONE resolvable directory and one pinned PATHEXT, so
# resolution is never the variable; only the on-disk shim shape is.

run_V_verified_shim_target() {
# V-happy is the single accept; everything else removes or corrupts exactly one
# property of it. Fail-closed pairs: V-nosibling/V-nocmd (either half missing),
# V-onlycmd/V-onlysibling (either half present but unparseable — only ONE regex
# matches), V-emptycmd/V-emptysibling (zero-byte), V-mismatch (both parse, they
# disagree), V-nostar (the `%*` CMD_TARGET_PATTERN requires), V-targetmissing /
# V-targetdir / V-siblingdir (the stat answers a regex cannot give). Accepts
# that must NOT over-restrict: V-casediff (case-insensitive compare), V-mjs /
# V-cjs (the [cm]?js alternation), V-subdir (backslash vs slash spelling).
run_table V <<'TABLE'
V-happy         | node d1/codegraph-target.js  | verdict | trio          | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-nosibling     | enoent                       | verdict | nosibling     | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-nocmd         | enoent                       | verdict | nocmd         | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-mismatch      | enoent                       | verdict | mismatch      | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-emptycmd      | enoent                       | verdict | emptycmd      | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-emptysibling  | enoent                       | verdict | emptysibling  | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-malformed     | enoent                       | verdict | malformed     | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-onlycmd       | enoent                       | verdict | onlycmd       | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-onlysibling   | enoent                       | verdict | onlysibling   | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-targetmissing | enoent                       | verdict | targetmissing | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-targetdir     | enoent                       | verdict | targetdir     | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-siblingdir    | enoent                       | verdict | siblingdir    | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-nostar        | enoent                       | verdict | nostar        | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-casediff      | node d1/codegraph-target.js  | verdict | casediff      | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-mjs           | node d1/codegraph-target.mjs | verdict | mjs           | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-cjs           | node d1/codegraph-target.cjs | verdict | cjs           | .COM;.EXE;.BAT;.CMD | d1 | codegraph
V-subdir        | node d1/lib/t.js             | verdict | subdir        | .COM;.EXE;.BAT;.CMD | d1 | codegraph
TABLE

# A read that FAILS is a distinct branch from a file that is absent or garbage,
# and it is the one an exception would escape from. Only run it where chmod 000
# is actually enforced — under Windows, or as root, the row would pass for the
# wrong reason and stop being evidence.
if [ "$PERM_ENFORCED" = "1" ]; then
    run_row V V-perm enoent verdict permdenied ".COM;.EXE;.BAT;.CMD" d1 codegraph
else
    skip "V V-perm — this host does not enforce chmod 000 (Windows or root)"
fi
}
