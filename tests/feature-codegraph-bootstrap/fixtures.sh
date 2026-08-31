# shellcheck shell=bash
# Tests: install/codegraph-mcp.js, install/linux/codegraph.sh
# Tags: codegraph, installer, fixtures, secret-leakage, TL2, pwsh-not-required, scope:issue-specific, dup-group-keep:size-hard-limit
# Fixture builders for tests/feature-codegraph-bootstrap.sh (ST-19): the fake
# HOME tree, the synthetic .env and the two secret sentinels C16 tracks.
# The dispatcher's `# Serial:` justification holds here unchanged.

# The sentinels stand in for the credentials these two files really carry — an API
# token in .env, the oauth/account block in ~/.claude.json. Neither installer path
# has any reason to echo either file, so any appearance in stdout, stderr or a stub
# argv log is a leak, not a formatting accident.
ENV_SENTINEL='cg-env-secret-a1b2c3d4e5'
JSON_SENTINEL='cg-json-secret-f6a7b8c9d0'

# install/codegraph-constants.txt is the SSOT the installer itself reads; these
# tests read the same file rather than restating the values, so a version bump or
# a telemetry-key change moves the expectation and the implementation together.
# A missing or empty value would make every derived assertion compare "" with ""
# — the false green this block refuses to ship.
CONSTANTS_FILE="$AGENTS_DIR/install/codegraph-constants.txt"
read_constant() { sed -n "s/^$1=//p" "$CONSTANTS_FILE" 2>/dev/null | head -1; }
CG_VERSION="$(read_constant CODEGRAPH_VERSION)"
CG_TELEMETRY="$(read_constant CODEGRAPH_TELEMETRY)"
CG_DNT="$(read_constant DO_NOT_TRACK)"
if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "constants: install/codegraph-constants.txt is absent — every version and telemetry expectation below would be vacuous"
fi
case "$CG_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) pass "constants: CODEGRAPH_VERSION is a pinned x.y.z value ($CG_VERSION)" ;;
    *) fail "constants: CODEGRAPH_VERSION is not a pinned x.y.z value — got '${CG_VERSION:-<empty>}'" ;;
esac
[ -n "$CG_TELEMETRY" ] && pass "constants: CODEGRAPH_TELEMETRY has a value ($CG_TELEMETRY)" \
    || fail "constants: CODEGRAPH_TELEMETRY is missing from install/codegraph-constants.txt"
[ -n "$CG_DNT" ] && pass "constants: DO_NOT_TRACK has a value ($CG_DNT)" \
    || fail "constants: DO_NOT_TRACK is missing from install/codegraph-constants.txt"

# The exact argv install/codegraph-mcp.js must hand the CLI, derived from the SSOT.
WANT_MCP_ADD="mcp add codegraph --scope user --env CODEGRAPH_TELEMETRY=$CG_TELEMETRY --env DO_NOT_TRACK=$CG_DNT -- codegraph serve --mcp"
WANT_MCP_REMOVE="mcp remove codegraph -s user"
WANT_NPM_INSTALL="install -g --ignore-scripts @colbymchenry/codegraph@$CG_VERSION"

CLAUDE_MD_BODY="# fixture CLAUDE.md — must survive the installer untouched"
SETTINGS_BODY='{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{}}'

# make_symlink <target> <link> — echoes what it actually produced. Git Bash needs
# winsymlinks:nativestrict for a real reparse point; the copy fallback keeps the
# byte-identity assertion alive on hosts that refuse both.
make_symlink() {
    local target="$1" link="$2"
    MSYS=winsymlinks:nativestrict ln -s "$target" "$link" 2>/dev/null \
        || ln -s "$target" "$link" 2>/dev/null || cp "$target" "$link"
    if [ -L "$link" ]; then printf 'symlink'; else printf 'regular'; fi
}

# build_home <mcp-pre> <claude-md: file|symlink>. The mcp-pre kinds are the
# ownership inputs install/codegraph-mcp.js classifies:
#   present    — this installer's exact registration (state "current")
#   legacy     — our command/args but no telemetry env (state "replaceable")
#   badenv     — our shape, telemetry opted IN (state "replaceable")
#   foreigncmd — someone else's command under our key (state "foreign")
#   foreignargs— our command, someone else's args (state "foreign")
#   none / nokey / missing — nothing registered (state "absent")
#   broken / nonobject — unreadable (state unknown; must change nothing)
build_home() {
    local mcp_pre="$1" md_kind="$2"
    rm -rf "$FAKE_HOME"
    mkdir -p "$FAKE_HOME/.claude"
    local head="{\"numStartups\":3,\"sentinelSecret\":\"$JSON_SENTINEL\""
    local ourenv="\"env\":{\"CODEGRAPH_TELEMETRY\":\"$CG_TELEMETRY\",\"DO_NOT_TRACK\":\"$CG_DNT\"}"
    local base='"type":"stdio","command":"codegraph","args":["serve","--mcp"]'
    local server="{$base,$ourenv}"
    case "$mcp_pre" in
        none)    printf '%s\n' "$head,\"mcpServers\":{}}" > "$FAKE_HOME/.claude.json" ;;
        nokey)   printf '%s\n' "$head}" > "$FAKE_HOME/.claude.json" ;;
        present) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":$server}}" > "$FAKE_HOME/.claude.json" ;;
        legacy)  printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base}}}" > "$FAKE_HOME/.claude.json" ;;
        badenv)  printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base,\"env\":{\"CODEGRAPH_TELEMETRY\":\"1\",\"DO_NOT_TRACK\":\"$CG_DNT\"}}}}" > "$FAKE_HOME/.claude.json" ;;
        foreigncmd)  printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{\"type\":\"stdio\",\"command\":\"codegraph-wrapper\",\"args\":[\"serve\",\"--mcp\"],$ourenv}}}" > "$FAKE_HOME/.claude.json" ;;
        foreignargs) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{\"type\":\"stdio\",\"command\":\"codegraph\",\"args\":[\"serve\",\"--http\",\"--port\",\"9999\"],$ourenv}}}" > "$FAKE_HOME/.claude.json" ;;
        nonobject)   printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":\"codegraph serve --mcp\"}}" > "$FAKE_HOME/.claude.json" ;;
        broken)  printf '%s\n' "$head,\"mcpServers\":{" > "$FAKE_HOME/.claude.json" ;;
        missing) rm -f "$FAKE_HOME/.claude.json" ;;
        *)       fail "harness bug: unknown mcp-pre '$mcp_pre'" ;;
    esac
    printf '%s\n' "$SETTINGS_BODY" > "$FAKE_HOME/.claude/settings.json"
    if [ "$md_kind" = "symlink" ]; then
        printf '%s\n' "$CLAUDE_MD_BODY" > "$BASE/claude-md-target.md"
        make_symlink "$BASE/claude-md-target.md" "$FAKE_HOME/.claude/CLAUDE.md" >/dev/null
    else
        printf '%s\n' "$CLAUDE_MD_BODY" > "$FAKE_HOME/.claude/CLAUDE.md"
    fi
}

# write_env_file <cfg-dir> <envfile: absent|present> <flag>. "absent" is the
# brand-new-machine shape: no .env file at all, which is what B1 pins.
write_env_file() {
    local cfg="$1" envfile="$2" flag="$3"
    if [ "$envfile" = "absent" ]; then rm -f "$cfg/.env"; return 0; fi
    printf 'SESSION_SYNC=off\nCODEGRAPH=%s\nSENTINEL_SECRET=%s\n' "$flag" "$ENV_SENTINEL" > "$cfg/.env"
}
