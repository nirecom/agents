# shellcheck shell=bash
# Tests: hooks/codegraph-context-inject.js, hooks/lib/codegraph-boundary.js
# Tags: hook-injection, codegraph, prompt-hook, harness, TL2, scope:issue-specific, dup-group-keep:size-hard-limit
# Harness for tests/feature-2215-codegraph-context-inject.sh: fixture isolation
# (rules/test/fixture-isolation.md), the recording codegraph stub, the scope-gate
# fixture roots and the run_hook / json_field helpers every case group shares.

# ---------------------------------------------------------------------------
# Setup / fixture isolation (rules/test/fixture-isolation.md)
# ---------------------------------------------------------------------------

HOOK="$AGENTS_DIR/hooks/codegraph-context-inject.js"
BOUNDARY="$AGENTS_DIR/hooks/lib/codegraph-boundary.js"
SETTINGS_JSON="$AGENTS_DIR/settings.json"
CONSTANTS_FILE="$AGENTS_DIR/install/codegraph-constants.txt"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

IS_WIN32=$(node -e "process.stdout.write(process.platform === 'win32' ? '1' : '0')" 2>/dev/null || echo 0)

_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    TMPDIR_BASE=$(mktemp -d "/${_DRIVE}${_REST}/feature-2215-ctx-inject.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Dual-pin CLAUDE_WORKFLOW_DIR + WORKFLOW_PLANS_DIR; unset inherited session
# ids; redirect HOME/USERPROFILE at a fixture -- never the real HOME.
WF_DIR="$TMPDIR_BASE/wf"; mkdir -p "$WF_DIR"
WF_DIR_N="$(to_node_path "$WF_DIR")"
FAKE_HOME="$TMPDIR_BASE/fakehome"; mkdir -p "$FAKE_HOME"
FAKE_HOME_N="$(to_node_path "$FAKE_HOME")"
CFG_ON="$TMPDIR_BASE/config-on"; mkdir -p "$CFG_ON"
printf 'CODEGRAPH=on\n' > "$CFG_ON/.env"
CFG_ON_N="$(to_node_path "$CFG_ON")"

# $BIN is prepended to PATH in POSIX form, never to_node_path()'s "C:/..." — PATH is
# split on ':' by the shell and by MSYS, so a drive-letter colon silently drops the
# stub directory and a real installed codegraph answers instead (M19b says the same).
BIN="$TMPDIR_BASE/bin"; mkdir -p "$BIN"

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# The hook's config gate mirrors bin/codegraph-lifecycle.js's codegraphEnabled():
# a real environment variable outranks the .env file. Without this unset, an
# ambient CODEGRAPH already set in the invoking shell would leak into every
# "CODEGRAPH unset" case below and make the config-gate assumption non-deterministic.
unset CODEGRAPH 2>/dev/null || true

# ---------------------------------------------------------------------------
# codegraph stub: reads env knobs, records invocation + stdin, on PATH as
# "codegraph" (win32: .cmd + POSIX-sibling shim trio resolvable by
# hooks/lib/spawn-shimmed-cli.js; POSIX: a real #!/usr/bin/env node script).
# ---------------------------------------------------------------------------

STUB_BODY=$(cat <<'JSEOF'
const fs = require("fs");
let stdin = "";
try { stdin = fs.readFileSync(0, "utf8"); } catch (e) {}
if (process.env.CG_STUB_LOG) {
  try { fs.appendFileSync(process.env.CG_STUB_LOG, process.argv.slice(2).join(" ") + "\n"); } catch (e) {}
}
if (process.env.CG_STUB_STDIN_LOG) {
  try { fs.writeFileSync(process.env.CG_STUB_STDIN_LOG, stdin); } catch (e) {}
}
if (process.env.CG_STUB_ENV_LOG) {
  const keys = String(process.env.CG_STUB_ENV_VARS || "").split(",").filter(Boolean);
  const snap = keys.map(function (k) {
    return k + "=" + (process.env[k] === undefined ? "<unset>" : process.env[k]);
  }).join(" ");
  try { fs.appendFileSync(process.env.CG_STUB_ENV_LOG, snap + "\n"); } catch (e) {}
}
if (process.env.CG_STUB_HANG) {
  setInterval(function () {}, 3600000);
} else {
  const out = process.env.CG_STUB_OUT || "";
  if (out) process.stdout.write(out);
  const code = process.env.CG_STUB_EXIT !== undefined ? Number(process.env.CG_STUB_EXIT) : 0;
  process.exit(code);
}
JSEOF
)

if [ "$IS_WIN32" -eq 1 ]; then
    write_posix_sibling() {
        {
            printf '#!/bin/sh\n'
            printf 'basedir=$(dirname "$(echo "$0" | sed -e '"'"'s,\\\\,/,g'"'"')")\n'
            printf 'case `uname` in\n    *CYGWIN*|*MINGW*|*MSYS*)\n        if command -v cygpath > /dev/null 2>&1; then\n            basedir=`cygpath -w "$basedir"`\n        fi\n    ;;\nesac\n'
            printf 'if [ -x "$basedir/node" ]; then\n  exec "$basedir/node"  "$basedir/codegraph-target.js" "$@"\nelse \n  exec node  "$basedir/codegraph-target.js" "$@"\nfi\n'
        } > "$1"
    }
    write_cmd_shim() {
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
            printf 'endLocal & goto #_undefined_# 2>NUL || title %%COMSPEC%% & "%%_prog%%"  "%%dp0%%\\codegraph-target.js" %%*\r\n'
        } > "$1"
    }
    write_posix_sibling "$BIN/codegraph"
    write_cmd_shim "$BIN/codegraph.cmd"
    printf '%s' "$STUB_BODY" > "$BIN/codegraph-target.js"
else
    { printf '#!/usr/bin/env node\n'; printf '%s' "$STUB_BODY"; } > "$BIN/codegraph"
    chmod +x "$BIN/codegraph"
fi

# ---------------------------------------------------------------------------
# Fixture roots for the scope-gate cases (M27-M31)
# ---------------------------------------------------------------------------

mkroot() { local d="$TMPDIR_BASE/roots/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$(to_node_path "$d")"; }

# M27: HOME carries a workspace manifest, and a CHILD (not ancestor) of home is
# indexed -- up-walk from HOME itself must NOT see it (down only, never up).
printf '{"name":"home-manifest"}' > "$FAKE_HOME/package.json"
mkdir -p "$FAKE_HOME/proj/.codegraph"
printf '' > "$FAKE_HOME/proj/.codegraph/codegraph.db"

# M28/M29: an indexed root, and a directory 3 levels below it.
INDEXED_ROOT="$(mkroot indexed)"
mkdir -p "$TMPDIR_BASE/roots/indexed/.codegraph"
printf '' > "$TMPDIR_BASE/roots/indexed/.codegraph/codegraph.db"
DEEP_SUB="$(to_node_path "$TMPDIR_BASE/roots/indexed/a/b/c")"
mkdir -p "$TMPDIR_BASE/roots/indexed/a/b/c"

# M30: ordinary directories, neither home nor root nor with an indexed
# ancestor -- one with a workspace manifest (down-scan eligible upstream-side),
# one without.
ORD_MANIFEST="$(mkroot ord-manifest)"
printf '{"name":"ord"}' > "$TMPDIR_BASE/roots/ord-manifest/package.json"
ORD_PLAIN="$(mkroot ord-plain)"

RESET_LOGS() { rm -f "$TMPDIR_BASE"/log-* 2>/dev/null || true; }

# run_hook <payload-json> <cwd-native-dir> [extra "K=V" ...]
# Spawns the hook with the call/stdin/env log trio, PATH containing the stub,
# CODEGRAPH=on config, dual-pinned workflow dirs, and HOME redirected.
#
# The three log paths are fixed and set HERE, at top level, not inside
# run_hook(): half the call sites capture the hook's stdout with
# `raw=$(run_hook ...)`, and a name assigned inside that command substitution
# dies with its subshell, leaving call_count()/last_call_argv() reading a stale
# path. RESET_LOGS (which every case already runs first) is what gives each case
# a clean slate instead.
LOG="$TMPDIR_BASE/log-call"
STDIN_LOG="$TMPDIR_BASE/log-stdin"
ENV_LOG="$TMPDIR_BASE/log-env"
run_hook() {
    local payload="$1" dir="$2"; shift 2
    (
        cd "$dir" || exit 99
        printf '%s' "$payload" | run_with_timeout 15 env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            "$@" \
            AGENTS_CONFIG_DIR="$CFG_ON_N" \
            PATH="$BIN:$PATH" \
            CLAUDE_WORKFLOW_DIR="$WF_DIR_N" WORKFLOW_PLANS_DIR="$WF_DIR_N" \
            HOME="$FAKE_HOME_N" USERPROFILE="$FAKE_HOME_N" \
            CG_STUB_LOG="$(to_node_path "$LOG")" \
            CG_STUB_STDIN_LOG="$(to_node_path "$STDIN_LOG")" \
            CG_STUB_ENV_LOG="$(to_node_path "$ENV_LOG")" \
            CG_STUB_ENV_VARS="CODEGRAPH_TELEMETRY,DO_NOT_TRACK" \
            node "$HOOK"
    )
}
call_count() { [ -f "$LOG" ] && (wc -l < "$LOG" | tr -d ' ') || echo 0; }
# last_call_argv -- the argv the hook actually invoked codegraph with, not just
# how many times. A hook that spawned e.g. `codegraph serve` or `codegraph
# init` instead of `codegraph prompt-hook` would still satisfy every
# call-count-only assertion; this is what closes that gap (S5-1 step 4 pins
# the argv to exactly `["prompt-hook"]`).
last_call_argv() { [ -f "$LOG" ] && tail -n 1 "$LOG" | tr -d '\r' || echo "__MISSING__"; }

json_field() {
    # json_field <raw> <dotted-path, e.g. hookSpecificOutput.hookEventName>
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  const path = process.argv[2].split('.');
  let v = o;
  for (const k of path) { v = (v === null || v === undefined) ? undefined : v[k]; }
  process.stdout.write(v === undefined ? '' : String(v));
} catch (e) { process.stdout.write('__PARSE_ERROR__'); }
" "$1" "$2" 2>/dev/null
}

# json_field_to_file <raw> <dotted-path> <outfile> -- like json_field, but writes
# via `>` redirection instead of `$()`. Command substitution strips trailing
# newlines from its output; a field value that legitimately ends in a newline
# (e.g. verbatim-forwarded stub stdout) would lose it there, making an
# exact-byte-equality comparison against a `$()`-captured value unpassable even
# once the hook is implemented correctly. Redirecting straight to a file avoids
# that stripping entirely.
json_field_to_file() {
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  const path = process.argv[2].split('.');
  let v = o;
  for (const k of path) { v = (v === null || v === undefined) ? undefined : v[k]; }
  process.stdout.write(v === undefined ? '' : String(v));
} catch (e) { process.stdout.write('__PARSE_ERROR__'); }
" "$1" "$2" > "$3" 2>/dev/null
}
