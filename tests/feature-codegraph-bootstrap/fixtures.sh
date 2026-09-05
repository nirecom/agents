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
# The marker env key is what makes a registration attributable to this installer
# (#2215). An empty value would make every ownership assertion below compare a
# marker against nothing, so it is guarded exactly like the three above.
CG_OWNER_KEY="AGENTS_CODEGRAPH_MCP_OWNER"
CG_OWNER="$(read_constant "$CG_OWNER_KEY")"
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
[ -n "$CG_OWNER" ] && pass "constants: AGENTS_CODEGRAPH_MCP_OWNER has a value ($CG_OWNER)" \
    || fail "constants: AGENTS_CODEGRAPH_MCP_OWNER is missing from install/codegraph-constants.txt"

# Literal, non-derived guards. Every other assertion reads these back out of the
# same file the installer reads, so a shipped change would move expectation and
# implementation together and pass silently. These three pin what #2215 decided:
# telemetry stays upstream's ON default (the installer no longer overrides the
# user's own `codegraph telemetry` choice), DO_NOT_TRACK is decoupled from it
# (a cross-tool convention this installer has no standing to set), and the owner
# marker is STABLE — ownership is decided by that literal, so changing it strands
# every registration an earlier build wrote.
[ "$CG_TELEMETRY" = "1" ] && pass "constants: CODEGRAPH_TELEMETRY ships as 1 (telemetry on by default, #2215)" \
    || fail "constants: CODEGRAPH_TELEMETRY must ship as 1 (telemetry on by default, #2215) — got '${CG_TELEMETRY:-<empty>}'"
[ "$CG_DNT" = "0" ] && pass "constants: DO_NOT_TRACK ships as 0 (decoupled from CODEGRAPH_TELEMETRY, #2215)" \
    || fail "constants: DO_NOT_TRACK must ship as 0 (decoupled from CODEGRAPH_TELEMETRY, #2215) — got '${CG_DNT:-<empty>}'"
[ "$CG_OWNER" = "agents-framework" ] \
    && pass "constants: AGENTS_CODEGRAPH_MCP_OWNER ships as agents-framework (changing it strands existing registrations, #2215)" \
    || fail "constants: AGENTS_CODEGRAPH_MCP_OWNER ships as agents-framework (changing it strands existing registrations, #2215) — got '${CG_OWNER:-<empty>}'"

# The exact argv install/codegraph-mcp.js must hand the CLI, derived from the SSOT.
# The marker flag comes last so a reordered --env list reads as a mismatch too.
WANT_MCP_ADD="mcp add codegraph --scope user --env CODEGRAPH_TELEMETRY=$CG_TELEMETRY --env DO_NOT_TRACK=$CG_DNT --env $CG_OWNER_KEY=$CG_OWNER -- codegraph serve --mcp"
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

# PRE_MARKER_ENV — the env pair the pre-#2215 installer shipped, spelled as
# literals on purpose: it is a historical fact about entries already on disk, so
# it must not track today's SSOT. The literal guards above keep the two distinct,
# which is what stops `staleenv`/`legacyowned` collapsing into `present`.
PRE_MARKER_ENV='"CODEGRAPH_TELEMETRY":"0","DO_NOT_TRACK":"1"'

# TELEMETRY_PRE — the third fixture axis (#2215): what ~/.codegraph/telemetry.json
# looks like before the installer runs. Module-scope rather than a 12th run_case
# parameter, so every existing caller keeps the `absent` default untouched.
#   absent (default) — no ~/.codegraph at all, the brand-new-machine shape
#   off / on         — a saved CLI consent verdict, either way round
#   garbage          — a corrupt body: the reset must never parse the file
#   undeletable      — a non-empty DIRECTORY in its place, so removal must fail
TELEMETRY_PRE=absent
TELEMETRY_JSON_TAIL='"machine_id":"m-2215","consent_source":"cli","first_run_notice_shown":true,"updated_at":"2026-01-01T00:00:00.000Z"'

write_telemetry_pre() {
    local dir="$FAKE_HOME/.codegraph" f="$FAKE_HOME/.codegraph/telemetry.json"
    case "${TELEMETRY_PRE:-absent}" in
        absent)      return 0 ;;
        off)         mkdir -p "$dir"; printf '{"enabled":false,%s}\n' "$TELEMETRY_JSON_TAIL" > "$f" ;;
        on)          mkdir -p "$dir"; printf '{"enabled":true,%s}\n' "$TELEMETRY_JSON_TAIL" > "$f" ;;
        garbage)     mkdir -p "$dir"; printf '{not json\n' > "$f" ;;
        undeletable) mkdir -p "$f"; printf 'keep\n' > "$f/keep" ;;
        *)           fail "harness bug: unknown TELEMETRY_PRE '${TELEMETRY_PRE:-}'" ;;
    esac
}

# build_home <mcp-pre> <claude-md: file|symlink>. mcp-pre names the ownership input
# install/codegraph-mcp.js classifies; #2215 made the owner marker the ONLY evidence
# of authorship, so an unmarked entry is foreign whatever its shape or env holds:
#   current     — present, ourenvplus (an unrelated extra var must not matter)
#   ours-stale  — staleenv (marker present, telemetry env stale)
#   foreign     — foreigncmd, foreignargs, plus every unmarked entry: legacy,
#                 nomarker, legacyowned, legacyplus, legacyhttp, customenv
#   absent      — none, nokey, missing
#   null        — broken, nonobject (unreadable; must change nothing)
build_home() {
    local mcp_pre="$1" md_kind="$2"
    rm -rf "$FAKE_HOME"
    mkdir -p "$FAKE_HOME/.claude"
    local head="{\"numStartups\":3,\"sentinelSecret\":\"$JSON_SENTINEL\""
    local marker="\"$CG_OWNER_KEY\":\"$CG_OWNER\""
    local ourenv="\"env\":{\"CODEGRAPH_TELEMETRY\":\"$CG_TELEMETRY\",\"DO_NOT_TRACK\":\"$CG_DNT\",$marker}"
    local base='"type":"stdio","command":"codegraph","args":["serve","--mcp"]'
    local server="{$base,$ourenv}"
    local j="$FAKE_HOME/.claude.json"
    case "$mcp_pre" in
        none)    printf '%s\n' "$head,\"mcpServers\":{}}" > "$j" ;;
        nokey)   printf '%s\n' "$head}" > "$j" ;;
        present) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":$server}}" > "$j" ;;
        ourenvplus) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base,\"env\":{\"CODEGRAPH_TELEMETRY\":\"$CG_TELEMETRY\",\"DO_NOT_TRACK\":\"$CG_DNT\",$marker,\"CODEGRAPH_MCP_DEBUG\":\"1\"}}}}" > "$j" ;;
        staleenv) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base,\"env\":{$PRE_MARKER_ENV,$marker}}}}" > "$j" ;;
        legacyowned) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base,\"env\":{$PRE_MARKER_ENV}}}}" > "$j" ;;
        legacyplus)  printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base,\"env\":{$PRE_MARKER_ENV,\"SOME_OTHER_TOOL_VAR\":\"x\"}}}}" > "$j" ;;
        legacyhttp)  printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{\"type\":\"http\",\"command\":\"codegraph\",\"args\":[\"serve\",\"--mcp\"],\"env\":{$PRE_MARKER_ENV}}}}" > "$j" ;;
        legacy)  printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base}}}" > "$j" ;;
        nomarker) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base,\"env\":{\"CODEGRAPH_TELEMETRY\":\"1\",\"DO_NOT_TRACK\":\"1\"}}}}" > "$j" ;;
        customenv) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{$base,\"env\":{\"MY_TOOL_PROFILE\":\"fast\",\"MY_TOOL_LOG\":\"debug\"}}}}" > "$j" ;;
        foreigncmd)  printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{\"type\":\"stdio\",\"command\":\"codegraph-wrapper\",\"args\":[\"serve\",\"--mcp\"],$ourenv}}}" > "$j" ;;
        foreignargs) printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":{\"type\":\"stdio\",\"command\":\"codegraph\",\"args\":[\"serve\",\"--http\",\"--port\",\"9999\"],$ourenv}}}" > "$j" ;;
        nonobject)   printf '%s\n' "$head,\"mcpServers\":{\"codegraph\":\"codegraph serve --mcp\"}}" > "$j" ;;
        broken)  printf '%s\n' "$head,\"mcpServers\":{" > "$j" ;;
        missing) rm -f "$j" ;;
        *)       fail "harness bug: unknown mcp-pre '$mcp_pre'" ;;
    esac
    write_telemetry_pre
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

# make_constants_tree <name> <constants-body|none> — a standalone installer tree
# at $BASE/<name>/ whose install/codegraph-constants.txt carries exactly <body>
# (or is absent for `none`), echoing the node-form path of its codegraph-mcp.js
# for run_case's 11th argument. Each tree gets its OWN hooks/lib copy because
# hooks/lib/codegraph-boundary.js resolves the constants file relative to itself:
# a shared lib directory would make every tree read the same constants file and
# the whole "unreadable constants" input class would vanish. Shared by
# ownership.sh, telemetry-reset.sh and cli-version.sh (CPR-SSOT).
make_constants_tree() {
    # Two statements, not one: `local a=$1 b=$BASE/$a` expands every word BEFORE the
    # builtin assigns, so `$a` would resolve to whatever a caller's loop left behind
    # and every tree would collide on one directory.
    local name="$1" body="$2"
    local root="$BASE/$name"
    rm -rf "$root"
    mkdir -p "$root/hooks/lib" "$root/install"
    cp -R "$AGENTS_DIR/hooks/lib/." "$root/hooks/lib/"
    cp "$CODEGRAPH_MCP_JS" "$root/install/codegraph-mcp.js"
    if [ "$body" = "none" ]; then
        rm -f "$root/install/codegraph-constants.txt"
    else
        printf '%s\n' "$body" > "$root/install/codegraph-constants.txt"
    fi
    node_path "$root/install/codegraph-mcp.js"
}

# constants_body <telemetry> <do-not-track> — a COMPLETE constants file that
# differs from the shipped one only in the telemetry pair, so a case built on it
# isolates the telemetry axis instead of also losing the version pin and the
# owner marker (which would change the verdict for unrelated reasons).
constants_body() {
    printf 'CODEGRAPH_VERSION=%s\nCODEGRAPH_TELEMETRY=%s\nDO_NOT_TRACK=%s\n%s=%s' \
        "$CG_VERSION" "$1" "$2" "$CG_OWNER_KEY" "$CG_OWNER"
}
