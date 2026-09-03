# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js
# Tags: codegraph, win32-shim, path-resolution, pathext, classifier, allowlist, boundary, table-driven, unit, scope:issue-specific
# lang-check: ignore (CJK path segments below are deliberate Unicode test data, not identifiers)
# Sections R and P of tests/feature-2150-spawn-shimmed-cli.sh — resolveOnPath()
# and pathextList(), reached through the exported spawnShimmedCli() and read off
# the file it decided to launch. Verdicts: `direct …` the resolved file was
# launched as-is; `node …` the batch shim was parsed and its verified JavaScript
# target launched instead; `enoent` the fail-closed answer.

run_R_resolve_on_path() {
# Section R — every classifier verdict plus the two precedence axes. Each allow
# row is paired with a reject row differing by one property: R-cmd/R-bat vs
# R-vbs (allow-list in/out), R-exe/R-com vs R-absent (sanctioned direct launch
# vs nothing on PATH), R-extprec-exe vs R-extprec-cmd (ONE directory, two
# PATHEXT orders — only pathextList()'s order can differ), R-dirprec-1 vs
# R-dirprec-2 (ONE fixture, two PATH orders: directory-major), R-cap64 vs
# R-cap65 (the MAX_PATH_DIRS off-by-one boundary).
run_table R <<'TABLE'
R-cmd          | node d1/codegraph-target.js       | verdict | trio     | .COM;.EXE;.BAT;.CMD      | d1        | codegraph
R-bat          | node d1/codegraph-target.js       | verdict | bat      | .COM;.EXE;.BAT;.CMD      | d1        | codegraph
R-exe          | direct d1/codegraph.exe           | verdict | exe      | .COM;.EXE;.BAT;.CMD      | d1        | codegraph
R-com          | direct d1/codegraph.com           | verdict | com      | .COM;.EXE;.BAT;.CMD      | d1        | codegraph
R-vbs          | enoent                            | verdict | vbs      | .COM;.EXE;.BAT;.CMD;.VBS | d1        | codegraph
R-absent       | enoent                            | verdict | trio     | .COM;.EXE;.BAT;.CMD      | d1        | nosuchcli
R-extprec-exe  | direct d1/codegraph.exe           | verdict | extprec  | .COM;.EXE;.BAT;.CMD      | d1        | codegraph
R-extprec-cmd  | node d1/codegraph-target.js       | verdict | extprec  | .CMD;.EXE                | d1        | codegraph
R-dirprec-1    | node d1/target-a.js               | verdict | dirprec  | .COM;.EXE;.BAT;.CMD      | d1,d2     | codegraph
R-dirprec-2    | node d2/target-b.js               | verdict | dirprec  | .COM;.EXE;.BAT;.CMD      | d2,d1     | codegraph
R-spaces       | node dir one/my cli-target.js     | verdict | spaces   | .COM;.EXE;.BAT;.CMD      | dir one   | my cli
R-unicode      | node ディレクトリ/コード-target.js | verdict | unicode  | .COM;.EXE;.BAT;.CMD      | ディレクトリ | コード
R-unc-skip     | node d1/codegraph-target.js       | verdict | unc      | .COM;.EXE;.BAT;.CMD      | @file     | codegraph
R-cap64        | node last/codegraph-target.js     | verdict | cap64    | .COM;.EXE;.BAT;.CMD      | @file     | codegraph
R-cap65        | enoent                            | verdict | cap65    | .COM;.EXE;.BAT;.CMD      | @file     | codegraph
TABLE
}

run_P_pathext_config() {
# Section P — pathextList() / pathDirs() as CONFIG-DEPENDENT branches: every
# variant is pinned explicitly, never inherited, since an unpinned PATHEXT
# silently decides which branch is reachable at all. Pairs: P-unset/P-empty both
# fall back to DEFAULT_PATHEXT; the spelling variants (P-mixedcase, P-dupes,
# P-emptyfields, P-mixedlist) must not change the verdict, against the two
# legitimate ways to lose .cmd (P-exeonly absent, P-allfiltered present but
# outside the allow-list); P-nopath / P-emptypath / P-emptycommand are the three
# empty-input shapes.
run_table P <<'TABLE'
P-unset        | node d1/codegraph-target.js | verdict | trio | @unset              | d1     | codegraph
P-empty        | node d1/codegraph-target.js | verdict | trio | @empty              | d1     | codegraph
P-mixedcase    | node d1/codegraph-target.js | verdict | trio | .Cmd                | d1     | codegraph
P-dupes        | node d1/codegraph-target.js | verdict | trio | .CMD;.CMD;.CMD      | d1     | codegraph
P-emptyfields  | node d1/codegraph-target.js | verdict | trio | ;;.CMD;;            | d1     | codegraph
P-mixedlist    | node d1/codegraph-target.js | verdict | trio | .VBS;.CMD           | d1     | codegraph
P-exeonly      | enoent                      | verdict | trio | .EXE                | d1     | codegraph
P-allfiltered  | enoent                      | verdict | trio | .VBS;.PS1           | d1     | codegraph
P-nopath       | enoent                      | verdict | trio | .COM;.EXE;.BAT;.CMD | @none  | codegraph
P-emptypath    | enoent                      | verdict | trio | .COM;.EXE;.BAT;.CMD | @empty | codegraph
P-emptycommand | enoent                      | verdict | trio | .COM;.EXE;.BAT;.CMD | d1     | @empty
TABLE
}
