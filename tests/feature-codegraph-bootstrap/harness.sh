# shellcheck shell=bash
# Tests: install/codegraph-mcp.js, install/linux/codegraph.sh
# Tags: codegraph, installer, harness, TL2, pwsh-not-required, scope:issue-specific, dup-group-keep:size-hard-limit
# Harness for tests/feature-codegraph-bootstrap.sh (ST-19): the os.homedir()
# redirection hard gate, PATH sanitising, the argv-recording stubs and run_case.
# The dispatcher's `# Serial:` justification holds here unchanged.

# node_path converts a POSIX path to the form win32 node understands (identity on
# POSIX). Every var a node child reads must travel in this form — MSYS only
# auto-converts the variables it already knows.
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
posixify() { printf '%s' "$1" | tr '\\' '/'; }

# The parent session exports the session ids; a child that resolves them would mutate
# live workflow state. CODEGRAPH must be unset too — load-env lets process.env win
# over .env, which would pin every case to one branch.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEGRAPH 2>/dev/null || true

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# HOME redirection proof. install/codegraph-mcp.js reads os.homedir()/.claude.json;
# without proof that node honours the redirection this file would read and judge the
# developer's real Claude Code config. Unprovable => fail and stop, never skip.
FAKE_HOME="$BASE/home"
mkdir -p "$FAKE_HOME"
NORM_HOME="$(node_path "$FAKE_HOME")"
RESOLVED="$(HOME="$NORM_HOME" USERPROFILE="$NORM_HOME" node -e "console.log(require('os').homedir())" 2>&1)"
PREFLIGHT_FAIL_BASE="$FAIL"
assert_eq "preflight: os.homedir() resolves to the fixture home, not the real one" \
    "$(posixify "$NORM_HOME")" "$(posixify "$RESOLVED")"
if [ "$FAIL" -ne "$PREFLIGHT_FAIL_BASE" ]; then
    echo "Refusing to run the installer: HOME redirection is unprovable on this host."
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP_ENV env-limited"
    exit 1
fi

# Strip every PATH directory that already carries one of the four binaries this test
# controls, so a machine that really has codegraph/claude installed cannot leak a real
# one into a case that requires absence. Everything else stays: node needs the system
# directories.
sanitize_path() {
    local out="" d
    local OLD_IFS="$IFS"; IFS=":"
    for d in $1; do
        [ -z "$d" ] && continue
        if [ -e "$d/node" ] || [ -e "$d/node.exe" ] || [ -e "$d/npm" ] || [ -e "$d/npm.cmd" ] \
           || [ -e "$d/claude" ] || [ -e "$d/claude.exe" ] || [ -e "$d/claude.cmd" ] \
           || [ -e "$d/claude.bat" ] || [ -e "$d/claude.com" ] \
           || [ -e "$d/codegraph" ] || [ -e "$d/codegraph.cmd" ] || [ -e "$d/codegraph.bat" ] \
           || [ -e "$d/codegraph.exe" ] || [ -e "$d/codegraph.com" ]; then continue; fi
        out="$out:$d"
    done
    IFS="$OLD_IFS"
    printf '%s' "${out#:}"
}
CLEAN_PATH="$(sanitize_path "$PATH")"
REAL_NODE="$(command -v node)"
REAL_NODE_EXE="$(node -e "console.log(process.execPath)")"
if command -v cygpath >/dev/null 2>&1; then REAL_NODE_EXE="$(cygpath -u "$REAL_NODE_EXE")"; fi
MCP_JS_NATIVE="$(node_path "$CODEGRAPH_MCP_JS")"
IS_WIN=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;; esac

# The PATHEXT every child of this suite runs with (C4), defined once so WC-5 can
# assert the pin the suite really applies rather than a copy of it. The hostile
# counterpart is the host shape WC-5 shows the pin protects against.
PINNED_PATHEXT=".COM;.EXE;.BAT;.CMD"
HOSTILE_PATHEXT=".EXE"
SHIM_REF_N="$(node_path "$AGENTS_DIR/tests/lib/shim-resolve-reference.js")"

# write_npm_stub <path> — a recording npm stub: every argv line is appended to
# $NPM_STUB_LOG and the process exits with ${NPM_STUB_RC:-0}. A SUCCESSFUL global
# install of the pinned codegraph package also publishes the staged codegraph stub
# beside itself, because that is what the real command does — and the register verb
# probes `codegraph --version` immediately afterwards, so a fixture that installed
# nothing would warn on stderr in every install case.
write_npm_stub() {
    local path="$1"
    cat > "$path" <<'NPMSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NPM_STUB_LOG"
npm_rc="${NPM_STUB_RC:-0}"
if [ "$npm_rc" = "0" ]; then
    case " $* " in
        *" -g "*"@colbymchenry/codegraph@"*)
            npm_bin="$(dirname "$0")"
            if [ -d "$npm_bin/cg-pending" ]; then
                cp -R "$npm_bin/cg-pending/." "$npm_bin/"
                chmod +x "$npm_bin/codegraph" 2>/dev/null || true
            fi
            ;;
    esac
fi
exit "$npm_rc"
NPMSTUB
    chmod +x "$path"
}

# write_cg_stub <dir> — a recording codegraph stub at <dir>/codegraph. Every argv
# line is appended to $CG_STUB_LOG and the process exits 0, EXCEPT `--version`,
# which is answered directly from ${CG_STUB_VERSION:-$CG_VERSION} on stdout and
# never touches CG_STUB_LOG — this must stay first so the `^(un)?install( |$)`
# CG_INSTALL count (harness.sh's own regex) never sees a --version invocation.
# On win32 the binary is reached through hooks/lib/spawn-shimmed-cli.js, which only
# ever resolves a PATHEXT extension and then reads the npm cmd-shim trio as text, so
# the same contract is mirrored into codegraph.cmd + codegraph-target.js there — the
# symmetric member of write_win_claude_cmd_shim's class (CPR-ORTH).
write_cg_stub() {
    local dir="$1"
    mkdir -p "$dir"
    if [ "$IS_WIN" = "1" ]; then write_win_cg_cmd_shim "$dir"; return 0; fi
    printf '#!/usr/bin/env bash\nif [ "${1:-}" = "--version" ]; then printf "%%s\\n" "${CG_STUB_VERSION:-%s}"; exit 0; fi\nprintf "%%s\\n" "$*" >> "$CG_STUB_LOG"\nexit 0\n' "$CG_VERSION" > "$dir/codegraph"
    chmod +x "$dir/codegraph"
}

# write_win_cg_cmd_shim <dir> — the win32 codegraph trio (POSIX sibling + .cmd +
# codegraph-target.js), reproducing write_cg_stub's `--version`-from-CG_STUB_VERSION
# / argv-logging contract in the shape spawn-shimmed-cli.js parses.
write_win_cg_cmd_shim() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/codegraph-target.js" <<CGTARGET
const fs = require("fs");
const args = process.argv.slice(2);
if (args[0] === "--version") {
  process.stdout.write((process.env.CG_STUB_VERSION || "$CG_VERSION") + "\n");
  process.exit(0);
}
fs.appendFileSync(process.env.CG_STUB_LOG, args.join(" ") + "\n");
process.exit(0);
CGTARGET
    _win_shim_sibling codegraph > "$dir/codegraph"
    { _win_cmd_shim_head; _win_cmd_shim_tail codegraph; } > "$dir/codegraph.cmd"
}

# make_stubs <dir> <node yes|no> <codegraph yes|no> <npm 0|1|no> <claude 0|1|no>.
# npm and codegraph are only ever resolved by bash, so a shebang script suffices.
# `claude` on win32 now uses the same npm cmd-shim shape spawnShimmedCli resolves in
# production (extensionless POSIX sibling + .cmd + claude-target.js); the old
# node.exe-hardlink exception is retired because spawnShimmedCli never executes the
# .cmd — it only parses it as text — so no real PE needs to sit next to it.
make_stubs() {
    local dir="$1" with_node="$2" with_cg="$3" npm_mode="$4" claude_mode="$5"
    mkdir -p "$dir"
    write_npm_stub "$dir/npm"
    # Staged, not published: `with_cg=no` means the binary is absent NOW, which the
    # npm stub above may still turn into a presence the way a real install does.
    write_cg_stub "$dir/cg-pending"
    rm -f "$dir/codegraph" "$dir/codegraph.cmd" "$dir/codegraph-target.js"
    if [ "$with_cg" = "yes" ]; then
        cp -R "$dir/cg-pending/." "$dir/"
        chmod +x "$dir/codegraph" 2>/dev/null || true
    fi
    [ "$npm_mode" = "no" ] && rm -f "$dir/npm" "$dir/npm.cmd"
    # Absence means absence under every PATHEXT spelling: leaving any spelling of
    # the shim trio behind would turn a "binary missing" case into a silent
    # presence case.
    if [ "$claude_mode" = "no" ]; then
        rm -f "$dir/claude" "$dir/claude.exe" "$dir/claude.cmd" "$dir/claude.bat" \
              "$dir/claude.com" "$dir/claude-target.js" "$dir/claude-target-decoy.js"
    elif [ "$IS_WIN" = "1" ]; then
        write_win_claude_cmd_shim "$dir"
    else
        write_posix_claude_stub "$dir/claude"
        chmod +x "$dir/claude"
    fi
    if [ "$with_node" != "yes" ]; then rm -f "$dir/node" "$dir/node.exe"; return 0; fi
    if [ "$IS_WIN" = "1" ]; then
        ln "$REAL_NODE_EXE" "$dir/node.exe" 2>/dev/null || cp "$REAL_NODE_EXE" "$dir/node.exe"
    else
        ln -s "$REAL_NODE" "$dir/node" 2>/dev/null || cp "$REAL_NODE" "$dir/node"
    fi
}

# write_win_claude_cmd_shim <dir> — the real npm cmd-shim shape for `claude` on
# win32: extensionless POSIX sibling (parsed as text, never executed), .cmd (never
# spawned directly) and claude-target.js, which reproduces the `--version`-is-0 /
# mcp-verb-logs contract write_posix_claude_stub gives POSIX.
write_win_claude_cmd_shim() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/claude-target.js" <<'CLAUDETARGET'
const fs = require("fs");
const args = process.argv.slice(2);
if (args[0] === "--version") { process.exit(0); }
fs.appendFileSync(process.env.CLAUDE_STUB_LOG, args.join(" ") + "\n");
process.exit(Number(process.env.CLAUDE_STUB_RC || 0));
CLAUDETARGET
    _win_shim_sibling claude > "$dir/claude"
    { _win_cmd_shim_head; _win_cmd_shim_tail claude; } > "$dir/claude.cmd"
}

# _win_shim_sibling <name> — npm's POSIX sibling script on stdout, naming
# "$basedir/<name>-target.js" in the dialect spawn-shimmed-cli.js parses.
_win_shim_sibling() {
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
    printf '  exec "$basedir/node"  "$basedir/%s-target.js" "$@"\n' "$1"
    printf 'else \n'
    printf '  exec node  "$basedir/%s-target.js" "$@"\n' "$1"
    printf 'fi\n'
}

# _win_cmd_shim_head / _win_cmd_shim_tail <name> — byte-faithful npm cmd-shim 8.0.0
# output, mirrored from tests/feature-2150-spawn-shimmed-cli/fixtures-npm.sh:
# CRLF, the :find_dp0 subroutine, the `endLocal & goto` prefix and the separator
# in `"%dp0%\...`. Split in two so a payload can be spliced between them.
_win_cmd_shim_head() {
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
}
_win_cmd_shim_tail() {
    printf 'endLocal & goto #_undefined_# 2>NUL || title %%COMSPEC%% & "%%_prog%%"  "%%dp0%%\\%s-target.js" %%*\r\n' "$1"
}

# _write_win_claude_payload <dir> <ext> — a batch half that is a valid npm shim
# AND destroys $dir/payload-marker.txt the instant a shell interprets it. The
# ext argument makes .bat the symmetric member of .cmd (CPR-ORTH): both are
# PATHEXT-delegated and both must be read as text, never run (WC-6/WC-7, C4).
_write_win_claude_payload() {
    local dir="$1" ext="$2" marker
    write_win_claude_cmd_shim "$dir"
    rm -f "$dir/claude.cmd"
    printf 'pristine\n' > "$dir/payload-marker.txt"
    marker="$(node_path "$dir/payload-marker.txt")"
    {
        _win_cmd_shim_head
        printf 'DEL /Q "%s"\r\n' "$marker"
        printf 'ECHO tampered-by-shell> "%s"\r\n' "$marker"
        _win_cmd_shim_tail claude
    } > "$dir/claude$ext"
}
write_win_claude_cmd_payload() { _write_win_claude_payload "$1" .cmd; }
write_win_claude_bat_payload() { _write_win_claude_payload "$1" .bat; }

# write_win_claude_exe <dir> — the sanctioned DIRECT-launch shape: no shim, no
# sibling, content never read. WC-8 asserts only how resolution classifies it.
write_win_claude_exe() {
    mkdir -p "$1"
    rm -f "$1/claude" "$1/claude.cmd" "$1/claude.bat"
    printf 'not-a-real-pe\n' > "$1/claude.exe"
}

# write_win_claude_cmd_shim_broken <dir> — .cmd present, POSIX sibling absent
# (WC-2 fail-closed case).
write_win_claude_cmd_shim_broken() {
    write_win_claude_cmd_shim "$1"
    rm -f "$1/claude"
}

# write_win_claude_cmd_shim_nocmd <dir> — the mirror image: POSIX sibling
# present, .cmd absent (WC-4). Resolution only ever considers PATHEXT
# extensions, so the bare sibling is not a candidate and this must fail closed
# exactly like the _broken shape — the symmetric member of the class (CPR-ORTH).
write_win_claude_cmd_shim_nocmd() {
    write_win_claude_cmd_shim "$1"
    rm -f "$1/claude.cmd"
}

# write_win_claude_cmd_shim_mismatch <dir> — the .cmd names claude-target.js, the
# POSIX sibling names a different (also real, also resolvable) decoy, so this
# fixture only fails closed if the two files are cross-checked (WC-3, C2).
write_win_claude_cmd_shim_mismatch() {
    write_win_claude_cmd_shim "$1"
    cp "$1/claude-target.js" "$1/claude-target-decoy.js"
    sed 's/claude-target\.js/claude-target-decoy.js/' "$1/claude" > "$1/claude.tmp"
    mv "$1/claude.tmp" "$1/claude"
}

# write_win_claude_node <dir> — the node.exe every claude shim shape needs beside
# it. run_case gets this from make_stubs; the WC-* subshells build their bin dir
# directly, so they call this instead.
write_win_claude_node() {
    ln "$REAL_NODE_EXE" "$1/node.exe" 2>/dev/null || cp "$REAL_NODE_EXE" "$1/node.exe"
}

# `claude --version` is the presence probe (install/codegraph-mcp.js only inspects
# error.code === "ENOENT"), so it answers 0 even when CLAUDE_STUB_RC pins the `mcp`
# verbs to a failure. claude-target.js (win32, write_win_claude_cmd_shim) reproduces
# the same split; every assertion counts `^mcp ` lines, so the two differ only in
# whether the probe itself is echoed to the log.
write_posix_claude_stub() {
    cat > "$1" <<'CLAUDESTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_STUB_LOG"
if [ "${1:-}" = "--version" ]; then exit 0; fi
exit "${CLAUDE_STUB_RC:-0}"
CLAUDESTUB
}

file_kind() { if [ -L "$1" ]; then printf 'symlink'; elif [ -f "$1" ]; then printf 'regular'; else printf 'absent'; fi; }
digest() { if [ -e "$1" ]; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1; else printf 'ABSENT'; fi; }

# run_case builds one fixture world, runs the chosen entry point inside it under a
# timeout with stdin closed (an interactive prompt then surfaces as a non-zero exit,
# not a hang), and publishes the observable summary plus the per-case log paths.
# `entry` is `sh` (install/linux/codegraph.sh), `noverb` (codegraph-mcp.js with no
# argument) or any other token, passed to codegraph-mcp.js verbatim as its verb —
# that is how the usage-error cases reach the helper directly.
run_case() {
    local name="$1" entry="$2" flag="$3" envfile="$4" mcp_pre="$5"
    local with_cg="$6" npm_mode="$7" claude_mode="$8" with_node="$9" md_kind="${10}"
    # $11 lets a case swap in a codegraph-mcp.js copy from a directory of the
    # caller's choosing (e.g. one with no sibling codegraph-constants.txt) —
    # every other fixture stays the shared, byte-identical installer script.
    local mcp_js="${11:-$MCP_JS_NATIVE}"

    local dir="$BASE/case-$name"
    rm -rf "$dir"; mkdir -p "$dir/cwd" "$dir/cfg" "$dir/nvm" "$dir/bin"
    local npm_rc=0 claude_rc=0
    case "$npm_mode" in 0|1) npm_rc="$npm_mode" ;; esac
    case "$claude_mode" in 0|1) claude_rc="$claude_mode" ;; esac

    build_home "$mcp_pre" "$md_kind"
    PRE_SETTINGS_SHA="$(digest "$FAKE_HOME/.claude/settings.json")"
    PRE_MD_SHA="$(digest "$FAKE_HOME/.claude/CLAUDE.md")"
    PRE_MD_KIND="$(file_kind "$FAKE_HOME/.claude/CLAUDE.md")"
    # C10: ~/.claude.json is read-only to install/codegraph-mcp.js — every write is
    # delegated to the `claude` CLI, which is a recording stub here. Byte identity
    # therefore holds for EVERY case; a changed digest means the helper wrote the
    # file itself, the destructive regression R-14 / B9 forbid.
    PRE_JSON_SHA="$(digest "$FAKE_HOME/.claude.json")"

    write_env_file "$dir/cfg" "$envfile" "$flag"
    # A no-op nvm.sh proves the `[ -s ]` guard sources it without pulling a real node
    # onto PATH — B8 depends on node staying absent through that line.
    printf '# no-op nvm stub\n:\n' > "$dir/nvm/nvm.sh"

    make_stubs "$dir/bin" "$with_node" "$with_cg" "$npm_mode" "$claude_mode"

    : > "$dir/npm.log"; : > "$dir/codegraph.log"; : > "$dir/claude.log"

    local rc=0
    (
        cd "$dir/cwd" || exit 111
        export HOME="$NORM_HOME" USERPROFILE="$NORM_HOME"
        export PATH="$dir/bin:$CLEAN_PATH"
        # Pinned so a custom host PATHEXT cannot steer the win32 shim resolution
        # away from the .cmd branch these fixtures are shaped for (C4).
        export PATHEXT="$PINNED_PATHEXT"
        export NVM_DIR="$dir/nvm"
        export NPM_STUB_RC="$npm_rc" CLAUDE_STUB_RC="$claude_rc"
        # The codegraph stub reads it, so it has to cross the process boundary; the
        # empty default keeps the stub's own `${CG_STUB_VERSION:-$CG_VERSION}` in force.
        export CG_STUB_VERSION="${CG_STUB_VERSION-}"
        AGENTS_CONFIG_DIR="$(node_path "$dir/cfg")"; export AGENTS_CONFIG_DIR
        NPM_STUB_LOG="$(node_path "$dir/npm.log")"; export NPM_STUB_LOG
        CG_STUB_LOG="$(node_path "$dir/codegraph.log")"; export CG_STUB_LOG
        CLAUDE_STUB_LOG="$(node_path "$dir/claude.log")"; export CLAUDE_STUB_LOG
        # Dual-pinned so no child resolves the live workflow state store.
        export CLAUDE_WORKFLOW_DIR="$dir/wf" WORKFLOW_PLANS_DIR="$dir/plans"
        case "$entry" in
            sh)     bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" bash "$CODEGRAPH_SH" ;;
            noverb) bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" node "$mcp_js" ;;
            *)      bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" node "$mcp_js" "$entry" ;;
        esac
    ) >"$dir/out.log" 2>"$dir/err.log" </dev/null || rc=$?

    # The npm argv is pinned to the SSOT-derived string, so a floating tag or a
    # dropped --ignore-scripts (both #2150 review findings) reads as npmi=0.
    NPM_INSTALL="$(grep -cF -x "$WANT_NPM_INSTALL" "$dir/npm.log" 2>/dev/null || true)"
    MCP_ADD="$(grep -c '^mcp add ' "$dir/claude.log" 2>/dev/null || true)"
    MCP_REMOVE="$(grep -c '^mcp remove ' "$dir/claude.log" 2>/dev/null || true)"
    MCP_ANY="$(grep -c '^mcp ' "$dir/claude.log" 2>/dev/null || true)"
    ERR_LINES="$(grep -c . "$dir/err.log" 2>/dev/null || true)"
    CG_INSTALL="$(grep -cE '^(un)?install( |$)' "$dir/codegraph.log" 2>/dev/null || true)"
    CASE_DIR="$dir"
    # Pattern 1 (negative assertion) support. `rm=0` is the load-bearing half — the
    # CLI is a stub, so it never rewrites the file — and this post-state read is the
    # backstop that the helper did not delete the entry behind the CLI's back.
    MCP_ENTRY_POST="$(grep -cF '"codegraph":' "$FAKE_HOME/.claude.json" 2>/dev/null || true)"
    MCP_ENTRY_POST="${MCP_ENTRY_POST:-0}"
    SUMMARY="rc=$rc npmi=$NPM_INSTALL add=$MCP_ADD rm=$MCP_REMOVE mcp=$MCP_ANY err=$ERR_LINES"
    scan_sentinels "$dir"
}

# C16: prove the two sentinels were really planted in this case's fixtures BEFORE
# reporting that they did not leak — a "no leak" verdict over an unplanted secret is
# exactly the vacuous pass this suite must not ship. SENTINEL_STATE carries both
# halves so a single assert_eq settles them together.
scan_sentinels() {
    local dir="$1" planted=0 leaked=""
    grep -qF "$ENV_SENTINEL" "$dir/cfg/.env" 2>/dev/null && planted=$((planted + 1))
    grep -qF "$JSON_SENTINEL" "$FAKE_HOME/.claude.json" 2>/dev/null && planted=$((planted + 1))
    leaked="$(grep -l -F -e "$ENV_SENTINEL" -e "$JSON_SENTINEL" \
        "$dir/out.log" "$dir/err.log" "$dir/npm.log" "$dir/codegraph.log" "$dir/claude.log" \
        2>/dev/null | sed "s|^$dir/||" | tr '\n' ' ')"
    SENTINEL_STATE="planted=$planted leaked=${leaked% }"
}
