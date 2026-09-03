# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js
# Tags: codegraph, win32-shim, fixtures, spawn-options, direct-launch, unit, scope:issue-specific
# Fixtures for Section O: what the CHILD saw. The targets here report their own
# cwd, env and argv into $SSC_MARKER, so caller-supplied spawnSync options are
# observed through a real process instead of inferred from a spy.

# w_target_opts <dir> <rel-name.js> — same role as w_target, but records the
# three fields Section O pins. Output format matches probe.js's DIRECT_SCRIPT so
# the delegated and direct branches share one expectation string (CPR-ORTH).
w_target_opts() {
    mkdir -p "$(dirname "$1/$2")"
    {
        printf 'const fs = require("fs");\n'
        printf 'const n = (p) => String(p).replace(/\\\\/g, "/").toLowerCase();\n'
        printf 'const cwdOk = n(process.cwd()) === n(process.env.SSC_EXPECT_CWD || "");\n'
        printf 'fs.writeFileSync(process.env.SSC_MARKER, [\n'
        printf '  "cwd=" + (cwdOk ? "match" : "MISMATCH:" + process.cwd()),\n'
        printf '  "env=" + (process.env.SSC_CUSTOM || "<unset>"),\n'
        printf '  "argv=" + process.argv.slice(2).join(","),\n'
        printf '].join(" ") + "\\n");\n'
    } > "$1/$2"
}

# The delegated branch under a full caller options object: a normal npm trio
# whose target is the reporting one.
bld_optstrio() {
    mkdir -p "$1/d1"
    w_target_opts "$1/d1" codegraph-target.js
    w_posix "$1/d1" codegraph codegraph-target.js
    w_cmd "$1/d1" codegraph .cmd codegraph-target.js
}

# _bld_realbin <case-dir> <ext> — the direct branch needs a file the OS can
# really execute, so the fixture is a byte copy of the running node binary.
# probe.js then drives it with `-e <report script>`, and the report is the
# child's own, not the parent spy's (C2).
_bld_realbin() {
    mkdir -p "$1/d1"
    _link_real_node "$1/d1/codegraph$2"
}

# A hard link where the filesystem allows one: the node binary is ~100 MB and
# Section O plants it four times per run. MSYS/Cygwin's `ln`/`cp` silently
# creates PE content under a `.exe`-suffixed name even when told to write a
# non-`.exe` target (e.g. a `.com` fixture) — and its own exe-lookup magic
# then makes `[ -e "$1" ]` report the unsuffixed name present too, so testing
# for the file cannot detect the mismatch. Route around it instead: always
# land the link/copy at the `.exe`-suffixed name (where the quirk is a
# no-op), then `mv` that real file onto the intended name — a plain rename
# of an already-existing source, which does not trigger the append.
_link_real_node() {
    case "$1" in
        *.exe)
            ln "$REAL_NODE_EXE" "$1" 2>/dev/null || cp "$REAL_NODE_EXE" "$1"
            ;;
        *)
            ln "$REAL_NODE_EXE" "$1.exe" 2>/dev/null || cp "$REAL_NODE_EXE" "$1.exe"
            mv "$1.exe" "$1"
            ;;
    esac
    chmod +x "$1" 2>/dev/null || true
}
bld_realexe() { _bld_realbin "$1" .exe; }
bld_realcom() { _bld_realbin "$1" .com; }

# A real direct binary and a complete delegated trio in one directory. PATHEXT
# is pinned so .EXE wins: the row proves the direct branch is reached even when
# a .cmd of the same basename sits beside it.
bld_realexeplus() {
    bld_optstrio "$1"
    _link_real_node "$1/d1/codegraph.exe"
}
