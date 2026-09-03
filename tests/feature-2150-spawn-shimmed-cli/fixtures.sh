# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js
# Tags: codegraph, win32-shim, fixtures, path-resolution, unit, scope:issue-specific
# lang-check: ignore (CJK path segments below are deliberate Unicode test data, not identifiers)
# Fixture builders for tests/feature-2150-spawn-shimmed-cli.sh. Every `bld_*`
# takes ONE argument — the row's private case dir — and builds a real on-disk
# PATH x PATHEXT search space in it. Nothing here is ever run by a shell.

# w_target <dir> <rel-name.js> — records its own argv, so an exec-mode row can
# prove WHICH target ran and that the arguments arrived literally.
w_target() {
    mkdir -p "$(dirname "$1/$2")"
    {
        printf 'const fs = require("fs");\n'
        printf 'if (process.env.SSC_MARKER) {\n'
        printf '  fs.writeFileSync(process.env.SSC_MARKER, process.argv.slice(2).join(",") + "\\n");\n'
        printf '}\n'
    } > "$1/$2"
}

# w_posix <dir> <base> <rel-target> — npm's extensionless POSIX sibling. Only
# `"$basedir/<target>"` is load-bearing; the rest keeps the fixture realistic.
w_posix() {
    {
        printf '#!/bin/sh\n'
        printf 'basedir=$(dirname "$(echo "$0" | sed -e '"'"'s,\\\\,/,g'"'"')")\n'
        printf 'if [ -x "$basedir/node" ]; then\n'
        printf '  exec "$basedir/node"  "$basedir/%s" "$@"\n' "$3"
        printf 'else\n'
        printf '  exec node  "$basedir/%s" "$@"\n' "$3"
        printf 'fi\n'
    } > "$1/$2"
}

# w_cmd <dir> <base> <ext> <rel-target> [payload-marker] [no-star] — npm's batch
# shim. A payload marker adds two lines a real cmd.exe WOULD run and a text
# parser never does (C4); `no-star` drops the `%*` CMD_TARGET_PATTERN requires,
# which is what keys that row on the regex and nothing else.
w_cmd() {
    local dir="$1" base="$2" ext="$3" tgt="$4" payload="${5:-}" nostar="${6:-}"
    {
        printf '@ECHO off\n'
        printf 'SETLOCAL\n'
        printf 'SET "dp0=%%~dp0"\n'
        printf 'IF EXIST "%%dp0%%\\node.exe" (SET "_prog=%%dp0%%\\node.exe") ELSE (SET "_prog=node")\n'
        if [ -n "$payload" ]; then
            printf 'DEL /Q "%s"\n' "$payload"
            printf 'ECHO tampered-by-shell> "%s"\n' "$payload"
        fi
        if [ -n "$nostar" ]; then
            printf '"%%_prog%%"  "%%dp0%%%s"\n' "$tgt"
        else
            printf '"%%_prog%%"  "%%dp0%%%s" %%*\n' "$tgt"
        fi
    } > "$dir/$base$ext"
}

# mk_trio <dir> <base> <ext> <rel-target> [payload] [no-star] — the complete npm
# install shape: POSIX sibling + batch shim + the real target.
mk_trio() {
    mkdir -p "$1"
    w_target "$1" "$4"
    w_posix "$1" "$2" "$4"
    w_cmd "$1" "$2" "$3" "$4" "${5:-}" "${6:-}"
}

# --- Section R: resolution and classifier shapes ----------------------------
bld_trio() { mk_trio "$1/d1" codegraph .cmd codegraph-target.js; }
bld_bat()  { mk_trio "$1/d1" codegraph .bat codegraph-target.js; }
bld_exe()  { mkdir -p "$1/d1"; printf 'MZ-not-a-real-pe\n' > "$1/d1/codegraph.exe"; }
bld_com()  { mkdir -p "$1/d1"; printf 'MZ-not-a-real-pe\n' > "$1/d1/codegraph.com"; }
bld_vbs()  { mkdir -p "$1/d1"; printf 'WScript.Echo "nope"\n' > "$1/d1/codegraph.vbs"; }

# A direct .exe and a complete delegated trio in ONE directory: only
# pathextList()'s declared order can choose between them.
bld_extprec() {
    mk_trio "$1/d1" codegraph .cmd codegraph-target.js
    printf 'MZ-not-a-real-pe\n' > "$1/d1/codegraph.exe"
}

# Two resolvable directories with DIFFERENT targets, so the reported target
# name names which directory won.
bld_dirprec() {
    mk_trio "$1/d1" codegraph .cmd target-a.js
    mk_trio "$1/d2" codegraph .cmd target-b.js
}

bld_spaces()  { mk_trio "$1/dir one" "my cli" .cmd "my cli-target.js"; }
bld_unicode() { mk_trio "$1/ディレクトリ" コード .cmd コード-target.js; }

# A disconnected UNC entry in both spellings ahead of a directory that does
# resolve: isUncPath() must drop them and resolution must continue past them.
bld_unc() {
    mk_trio "$1/d1" codegraph .cmd codegraph-target.js
    {
        printf '%s\n' '\\unreachable-host\share'
        printf '%s\n' '//unreachable-host/share'
        node_path "$1/d1"; printf '\n'
    } > "$1/__pathdirs.txt"
}

# _bld_cap <case-dir> <total-dirs> — the resolvable directory is always LAST, so
# total=64 must resolve and total=65 must not: the MAX_PATH_DIRS boundary.
_bld_cap() {
    local cdir="$1" total="$2" i
    : > "$cdir/__pathdirs.txt"
    i=1
    while [ "$i" -lt "$total" ]; do
        mkdir -p "$cdir/pad$i"
        node_path "$cdir/pad$i" >> "$cdir/__pathdirs.txt"; printf '\n' >> "$cdir/__pathdirs.txt"
        i=$((i + 1))
    done
    mk_trio "$cdir/last" codegraph .cmd codegraph-target.js
    node_path "$cdir/last" >> "$cdir/__pathdirs.txt"; printf '\n' >> "$cdir/__pathdirs.txt"
}
bld_cap64() { _bld_cap "$1" 64; }
bld_cap65() { _bld_cap "$1" 65; }

# --- Section V: verifiedShimTarget shapes -----------------------------------
bld_nosibling() { bld_trio "$1"; rm -f "$1/d1/codegraph"; }
bld_nocmd()     { bld_trio "$1"; rm -f "$1/d1/codegraph.cmd"; }

# Both targets exist and both are independently resolvable, so this can only
# fail closed if the two files' embedded targets are really cross-checked.
bld_mismatch() {
    mk_trio "$1/d1" codegraph .cmd target-a.js
    w_target "$1/d1" target-b.js
    w_posix "$1/d1" codegraph target-b.js
}

# One target, two case spellings. The comparison is case-insensitive, so this
# resolves — to the SIBLING's spelling, the one checked for existence.
bld_casediff() {
    mkdir -p "$1/d1"
    w_target "$1/d1" codegraph-target.js
    w_posix "$1/d1" codegraph codegraph-target.js
    w_cmd "$1/d1" codegraph .cmd CodeGraph-Target.js
}

bld_emptycmd()      { bld_trio "$1"; : > "$1/d1/codegraph.cmd"; }
bld_emptysibling()  { bld_trio "$1"; : > "$1/d1/codegraph"; }
bld_malformed()     { bld_trio "$1"; printf 'not a shim at all\n' > "$1/d1/codegraph.cmd"; }
bld_onlycmd()       { bld_trio "$1"; printf 'not a shim at all\n' > "$1/d1/codegraph"; }
bld_onlysibling()   { bld_trio "$1"; printf 'not a shim at all\n' > "$1/d1/codegraph.cmd"; }
bld_targetmissing() { bld_trio "$1"; rm -f "$1/d1/codegraph-target.js"; }
bld_targetdir()     { bld_trio "$1"; rm -f "$1/d1/codegraph-target.js"; mkdir -p "$1/d1/codegraph-target.js"; }
bld_siblingdir()    { bld_trio "$1"; rm -f "$1/d1/codegraph"; mkdir -p "$1/d1/codegraph"; }
bld_nostar()        { mk_trio "$1/d1" codegraph .cmd codegraph-target.js "" nostar; }
bld_mjs()           { mk_trio "$1/d1" codegraph .cmd codegraph-target.mjs; }
bld_cjs()           { mk_trio "$1/d1" codegraph .cmd codegraph-target.cjs; }

# A target one directory down, spelled with a backslash in the .cmd and a slash
# in the sibling — the separator normalisation both extractions must agree on.
bld_subdir() {
    mkdir -p "$1/d1/lib"
    w_target "$1/d1" lib/t.js
    w_posix "$1/d1" codegraph lib/t.js
    w_cmd "$1/d1" codegraph .cmd 'lib\t.js'
}

bld_permdenied() { bld_trio "$1"; chmod 000 "$1/d1/codegraph" 2>/dev/null || true; }

# --- Section A: a shim that is BOTH a valid npm batch shim and a saboteur ----
# The DEL/ECHO pair destroys __payload.txt the instant cmd.exe interprets it.
bld_payload() {
    printf 'pristine\n' > "$1/__payload.txt"
    mk_trio "$1/d1" codegraph .cmd codegraph-target.js "$(node_path "$1/__payload.txt")"
}
bld_batpayload() {
    printf 'pristine\n' > "$1/__payload.txt"
    mk_trio "$1/d1" codegraph .bat codegraph-target.js "$(node_path "$1/__payload.txt")"
}
