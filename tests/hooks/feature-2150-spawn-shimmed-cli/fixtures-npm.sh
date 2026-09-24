# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js
# Tags: codegraph, win32-shim, fixtures, npm-cmd-shim, parser, regex, unit, scope:issue-specific
# Byte-faithful npm `cmd-shim` output (cmd-shim 8.0.0 writeShim_, npm 11.9.0),
# restoring what fixtures.sh's reduced `w_cmd` drops: CRLF, `:find_dp0`, the
# `endLocal & goto` prefix, and the separator in `"%dp0%\<rel>"`.

# w_cmd_npm8 <dir> <base> <ext> <rel-target-slash> [payload-marker] — cmd-shim 8
# for a `#!/usr/bin/env node` bin. `%~dp0` already ends in a backslash, so the
# emitted `"%dp0%\..."` really does double the separator; that is the shape.
w_cmd_npm8() {
    local dir="$1" base="$2" ext="$3" tgt_bs="${4//\//\\}" payload="${5:-}"
    {
        printf '@ECHO off\r\n'
        printf 'GOTO start\r\n'
        printf ':find_dp0\r\n'
        printf 'SET dp0=%%~dp0\r\n'
        printf 'EXIT /b\r\n'
        printf ':start\r\n'
        printf 'SETLOCAL\r\n'
        printf 'CALL :find_dp0\r\n'
        printf '\r\n'
        printf 'IF EXIST "%%dp0%%\\node.exe" (\r\n'
        printf '  SET "_prog=%%dp0%%\\node.exe"\r\n'
        printf ') ELSE (\r\n'
        printf '  SET "_prog=node"\r\n'
        printf '  SET PATHEXT=%%PATHEXT:;.JS;=;%%\r\n'
        printf ')\r\n'
        printf '\r\n'
        # A payload marker adds two lines cmd.exe honours before the target line.
        if [ -n "$payload" ]; then
            printf 'DEL /Q "%s"\r\n' "$payload"
            printf 'ECHO tampered-by-shell> "%s"\r\n' "$payload"
        fi
        printf 'endLocal & goto #_undefined_# 2>NUL || title %%COMSPEC%% & "%%_prog%%"  "%%dp0%%\\%s" %%*\r\n' "$tgt_bs"
    } > "$dir/$base$ext"
}

# w_posix_npm8 <dir> <base> <rel-target-slash> — the sibling cmd-shim 8 writes
# beside it, cygpath `case` block included. The trailing space after `else` is
# cmd-shim's own and is kept verbatim.
w_posix_npm8() {
    {
        printf '#!/bin/sh\n'
        printf 'basedir=$(dirname "$(echo "$0" | sed -e '"'"'s,\\\\,/,g'"'"')")\n'
        printf '\n'
        printf 'case `uname` in\n'
        printf '    *CYGWIN*|*MINGW*|*MSYS*)\n'
        printf '        if command -v cygpath > /dev/null 2>&1; then\n'
        printf '            basedir=`cygpath -w "$basedir"`\n'
        printf '        fi\n'
        printf '    ;;\n'
        printf 'esac\n'
        printf '\n'
        printf 'if [ -x "$basedir/node" ]; then\n'
        printf '  exec "$basedir/node"  "$basedir/%s" "$@"\n' "$3"
        printf 'else \n'
        printf '  exec node  "$basedir/%s" "$@"\n' "$3"
        printf 'fi\n'
    } > "$1/$2"
}

# The OLDER cmd-shim template — not a museum piece: it is verbatim what
# `<npm prefix>/corepack.cmd` holds on this machine, so it is reachable on any
# host carrying a bin written by an older npm. Its target line spells `%~dp0`
# directly instead of defining `dp0` first.
w_cmd_npm_legacy() {
    local dir="$1" base="$2" ext="$3" tgt_bs="${4//\//\\}"
    {
        printf '@SETLOCAL\r\n'
        printf '@IF EXIST "%%~dp0\\node.exe" (\r\n'
        printf '  "%%~dp0\\node.exe"  "%%~dp0\\%s" %%*\r\n' "$tgt_bs"
        printf ') ELSE (\r\n'
        printf '  @SET PATHEXT=%%PATHEXT:;.JS;=;%%\r\n'
        printf '  node  "%%~dp0\\%s" %%*\r\n' "$tgt_bs"
        printf ')\r\n'
    } > "$dir/$base$ext"
}
w_posix_npm_legacy() {
    {
        printf '#!/bin/sh\n'
        printf 'basedir=$(dirname "$(echo "$0" | sed -e '"'"'s,\\\\,/,g'"'"')")\n'
        printf '\n'
        printf 'case `uname` in\n'
        printf '    *CYGWIN*) basedir=`cygpath -w "$basedir"`;;\n'
        printf 'esac\n'
        printf '\n'
        printf 'if [ -x "$basedir/node" ]; then\n'
        printf '  exec "$basedir/node"  "$basedir/%s" "$@"\n' "$3"
        printf 'else\n'
        printf '  exec node  "$basedir/%s" "$@"\n' "$3"
        printf 'fi\n'
    } > "$1/$2"
}

# cmd-shim 8's `!prog` branch — a bin with NO shebang. The target moves into the
# interpreter position, so both halves carry runs of spaces the shebang shape
# never produces (`"%dp0%\t.js"   %*`, `exec "$basedir/t.js"   "$@"`).
w_cmd_npm8_noshebang() {
    local dir="$1" base="$2" ext="$3" tgt_bs="${4//\//\\}"
    {
        printf '@ECHO off\r\n'
        printf 'GOTO start\r\n'
        printf ':find_dp0\r\n'
        printf 'SET dp0=%%~dp0\r\n'
        printf 'EXIT /b\r\n'
        printf ':start\r\n'
        printf 'SETLOCAL\r\n'
        printf 'CALL :find_dp0\r\n'
        printf '"%%dp0%%\\%s"   %%*\r\n' "$tgt_bs"
    } > "$dir/$base$ext"
}
w_posix_npm8_noshebang() {
    {
        printf '#!/bin/sh\n'
        printf 'basedir=$(dirname "$(echo "$0" | sed -e '"'"'s,\\\\,/,g'"'"')")\n'
        printf '\n'
        printf 'exec "$basedir/%s"   "$@"\n' "$3"
    } > "$1/$2"
}

# The real-world nesting the reduced fixtures flatten away: a scoped package
# several directories down, which is what makes separator normalisation
# (`\` in the .cmd, `/` in the sibling) load-bearing rather than cosmetic.
NPM8_TARGET="node_modules/@scope/pkg/npm-shim.js"

# _mk_npm_trio <dir> <base> <ext> <rel-target> <cmd-writer> <posix-writer> [payload]
_mk_npm_trio() {
    mkdir -p "$1"
    w_target "$1" "$4"
    "$6" "$1" "$2" "$4"
    "$5" "$1" "$2" "$3" "$4" "${7:-}"
}

bld_npm8()     { _mk_npm_trio "$1/d1" codegraph .cmd "$NPM8_TARGET" w_cmd_npm8 w_posix_npm8; }
bld_npm8bat()  { _mk_npm_trio "$1/d1" codegraph .bat "$NPM8_TARGET" w_cmd_npm8 w_posix_npm8; }
bld_npmlegacy() { _mk_npm_trio "$1/d1" codegraph .cmd "$NPM8_TARGET" w_cmd_npm_legacy w_posix_npm_legacy; }
bld_npmnoshebang() { _mk_npm_trio "$1/d1" codegraph .cmd bin/cli.js w_cmd_npm8_noshebang w_posix_npm8_noshebang; }

# Legacy .cmd beside a modern sibling and the reverse: which HALF of the pair the
# parser can read is then the only variable between the two rows.
bld_npmlegacycmd() { _mk_npm_trio "$1/d1" codegraph .cmd "$NPM8_TARGET" w_cmd_npm_legacy w_posix_npm8; }
bld_npmlegacysh()  { _mk_npm_trio "$1/d1" codegraph .cmd "$NPM8_TARGET" w_cmd_npm8 w_posix_npm_legacy; }

# Both halves parse and both targets exist, but they name DIFFERENT scoped
# packages: the fail-closed cross-check has to survive a byte-perfect shape too.
bld_npm8mismatch() {
    mkdir -p "$1/d1"
    w_target "$1/d1" "$NPM8_TARGET"
    w_target "$1/d1" node_modules/@scope/other/npm-shim.js
    w_cmd_npm8 "$1/d1" codegraph .cmd "$NPM8_TARGET"
    w_posix_npm8 "$1/d1" codegraph node_modules/@scope/other/npm-shim.js
}

# The A-payload proof re-run against the byte-faithful shape: a VALID cmd-shim 8
# batch file that also destroys __payload.txt the moment cmd.exe interprets it.
bld_npm8payload() {
    printf 'pristine\n' > "$1/__payload.txt"
    _mk_npm_trio "$1/d1" codegraph .cmd "$NPM8_TARGET" w_cmd_npm8 w_posix_npm8 \
        "$(node_path "$1/__payload.txt")"
}
