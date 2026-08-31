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
           || [ -e "$d/claude" ] || [ -e "$d/claude.exe" ] \
           || [ -e "$d/codegraph" ] || [ -e "$d/codegraph.cmd" ]; then continue; fi
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

# make_stubs <dir> <node yes|no> <codegraph yes|no> <npm 0|1|no> <claude 0|1|no>.
# npm and codegraph are only ever resolved by bash, so a shebang script suffices.
# `claude` is resolved by win32 node's spawnSync, which refuses extensionless files and
# .cmd wrappers alike — on Windows the stub must be a real PE, so it is a hardlink to
# node.exe running the `mcp` recorder in the case CWD (bounded exception, CPR-UNV).
make_stubs() {
    local dir="$1" with_node="$2" with_cg="$3" npm_mode="$4" claude_mode="$5"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$NPM_STUB_LOG"\nexit "${NPM_STUB_RC:-0}"\n' > "$dir/npm"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CG_STUB_LOG"\nexit 0\n' > "$dir/codegraph"
    write_posix_claude_stub "$dir/claude"
    chmod +x "$dir/npm" "$dir/codegraph" "$dir/claude"
    [ "$with_cg" = "yes" ] || rm -f "$dir/codegraph" "$dir/codegraph.cmd"
    [ "$npm_mode" = "no" ] && rm -f "$dir/npm" "$dir/npm.cmd"
    # Absence means absence under every PATHEXT spelling: win32 spawnSync resolves
    # claude.exe, bash resolves the extensionless script, and leaving either behind
    # would turn a "binary missing" case into a silent presence case.
    if [ "$claude_mode" = "no" ]; then rm -f "$dir/claude" "$dir/claude.exe"
    elif [ "$IS_WIN" = "1" ]; then
        ln "$REAL_NODE_EXE" "$dir/claude.exe" 2>/dev/null || cp "$REAL_NODE_EXE" "$dir/claude.exe"
    fi
    if [ "$with_node" != "yes" ]; then rm -f "$dir/node" "$dir/node.exe"; return 0; fi
    if [ "$IS_WIN" = "1" ]; then
        ln "$REAL_NODE_EXE" "$dir/node.exe" 2>/dev/null || cp "$REAL_NODE_EXE" "$dir/node.exe"
    else
        ln -s "$REAL_NODE" "$dir/node" 2>/dev/null || cp "$REAL_NODE" "$dir/node"
    fi
}

# `claude --version` is the presence probe (install/codegraph-mcp.js only inspects
# error.code === "ENOENT"), so it answers 0 even when CLAUDE_STUB_RC pins the `mcp`
# verbs to a failure. Windows gets that split for free: node.exe answers --version
# itself and only `claude mcp ...` reaches the recorder below.
write_posix_claude_stub() {
    cat > "$1" <<'CLAUDESTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_STUB_LOG"
if [ "${1:-}" = "--version" ]; then exit 0; fi
exit "${CLAUDE_STUB_RC:-0}"
CLAUDESTUB
}

write_win_mcp_recorder() {
    cat > "$1/mcp" <<'MCPREC'
const fs = require("fs");
fs.appendFileSync(process.env.CLAUDE_STUB_LOG, ["mcp", ...process.argv.slice(2)].join(" ") + "\n");
process.exit(Number(process.env.CLAUDE_STUB_RC || 0));
MCPREC
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
    [ "$IS_WIN" = "1" ] && write_win_mcp_recorder "$dir/cwd"

    : > "$dir/npm.log"; : > "$dir/codegraph.log"; : > "$dir/claude.log"

    local rc=0
    (
        cd "$dir/cwd" || exit 111
        export HOME="$NORM_HOME" USERPROFILE="$NORM_HOME"
        export PATH="$dir/bin:$CLEAN_PATH"
        export NVM_DIR="$dir/nvm"
        export NPM_STUB_RC="$npm_rc" CLAUDE_STUB_RC="$claude_rc"
        AGENTS_CONFIG_DIR="$(node_path "$dir/cfg")"; export AGENTS_CONFIG_DIR
        NPM_STUB_LOG="$(node_path "$dir/npm.log")"; export NPM_STUB_LOG
        CG_STUB_LOG="$(node_path "$dir/codegraph.log")"; export CG_STUB_LOG
        CLAUDE_STUB_LOG="$(node_path "$dir/claude.log")"; export CLAUDE_STUB_LOG
        # Dual-pinned so no child resolves the live workflow state store.
        export CLAUDE_WORKFLOW_DIR="$dir/wf" WORKFLOW_PLANS_DIR="$dir/plans"
        case "$entry" in
            sh)     bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" bash "$CODEGRAPH_SH" ;;
            noverb) bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" node "$MCP_JS_NATIVE" ;;
            *)      bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" node "$MCP_JS_NATIVE" "$entry" ;;
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
