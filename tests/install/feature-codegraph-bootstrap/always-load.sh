# shellcheck shell=bash
# Tests: install/codegraph-mcp.js
# Tags: codegraph, installer, mcp-registration, always-load, atomic-write, idempotency, secret-leakage, TL2, pwsh-not-required, scope:issue-specific
# AL-1..AL-16 (#2254): after a successful `claude mcp add`, ensureAlwaysLoad() sets
# mcpServers.codegraph.alwaysLoad on an entry of ours — and on nothing else. Every
# case runs the register verb against the emulated CLI (claude-cli-emu.js, mode in
# CLAUDE_STUB_EMU) and is judged by JSON_POST (json-post.js). Sourced after ownership.sh.

# Label-only markers (tests/lib/harness.sh is not sourced: its assert_eq/pass/fail
# would replace the dispatcher's): targets are for static grep.
if ! declare -F case_begin >/dev/null; then
    case_begin() { :; }
    case_end() { :; }
fi

AL_POSIX=1
[ "$IS_WIN" = "1" ] && AL_POSIX=0

# al_warn_line <reason> — the one stderr line the helper may print (plan P2-3).
al_warn_line() {
    printf 'codegraph-mcp: registered, but could not set alwaysLoad on the codegraph entry in ~/.claude.json (%s); codegraph_explore stays deferred until the installer is re-run.' "$1"
}

# al_run <id> <mcp-pre> <emu-mode> — one register run against the emulated CLI.
al_run() {
    CURRENT_AL="$1"
    CLAUDE_STUB_EMU="$3"
    run_case "$1" register on present "$2" yes 0 0 yes file
    unset CLAUDE_STUB_EMU
}

# al_check <id> <want-json> <want-summary> <reason|-> — the assertions every AL case
# shares. With a reason, stderr must be exactly the fixed warning line: nothing of
# the file's content and no err.message may ride along (sentinel check included).
al_check() {
    local id="$1" want_json="$2" want="$3" reason="$4"
    assert_eq "$id: observable outcome" "$want" "$SUMMARY"
    assert_eq "$id: JSON_POST" "$want_json" "$JSON_POST"
    assert_eq "$id: no sentinel leak" "" "${SENTINEL_STATE#*leaked=}"
    if [ "$reason" != "-" ]; then
        assert_eq "$id: stderr is exactly the alwaysLoad warning ($reason)" \
            "$(al_warn_line "$reason")" "$(cat "$CASE_DIR/err.log" 2>/dev/null || true)"
    fi
}

# al_mode <file> — permission bits as octal, read by node so GNU/BSD stat differ not.
al_mode() {
    node -e 'try { console.log((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8)); } catch (e) { console.log("none"); }' "$(node_path "$1")"
}

al_hook_mode600() { chmod 600 "$FAKE_HOME/.claude.json"; }

ADD_ONLY="rc=0 npmi=0 add=1 rm=0 mcp=1"
REFRESH="rc=0 npmi=0 add=1 rm=1 mcp=2"

echo "--- AL-1..AL-3: the patch lands on our fresh entry, once ---"
case_begin "AL-1" "install/codegraph-mcp.js"
PRE_RUN_HOOK=al_hook_mode600
al_run "AL-1" none write
PRE_RUN_HOOK=
al_check "AL-1" always "$ADD_ONLY err=0" -
assert_no_tmp "$FAKE_HOME"
if [ "$AL_POSIX" = "1" ]; then
    assert_eq "AL-1: ~/.claude.json keeps mode 600 (the temp file inherits it)" "600" "$(al_mode "$FAKE_HOME/.claude.json")"
else
    skip_env "AL-1: file mode check — MSYS/Cygwin has no POSIX permission bits"
fi
case_end

case_begin "AL-2" "install/codegraph-mcp.js"
al_run "AL-2" crowded write
al_check "AL-2" always "$REFRESH err=0" -
case_end

case_begin "AL-3" "install/codegraph-mcp.js"
al_run "AL-3" none alwaysload
al_check "AL-3" same "$ADD_ONLY err=0" -
case_end

echo "--- AL-4..AL-6, AL-8..AL-13: no entry of ours to patch — nothing is written ---"
while IFS='|' read -r id mode reason; do
    [ -n "$id" ] || continue
    case_begin "$id" "install/codegraph-mcp.js"
    al_run "$id" none "$mode"
    al_check "$id" same "$ADD_ONLY err=1" "$reason"
    case_end
done <<'AL_GUARDS'
AL-4|nowrite|entry missing
AL-5|foreign|entry not ours
AL-6|garbage|unparsable
AL-8|nullservers|mcpServers not an object
AL-9|nullentry|entry not an object
AL-10|noservers|entry missing
AL-11|rootnull|root not an object
AL-12|rootarray|root not an object
AL-13|rootscalar|root not an object
AL_GUARDS

echo "--- AL-7: a non-canonical baseline is normalized, meaning unchanged but alwaysLoad ---"
case_begin "AL-7a" "install/codegraph-mcp.js"
al_run "AL-7a" crowded noncanon
al_check "AL-7a" always "$REFRESH err=0" -
assert_eq "AL-7a: the post file carries no CR" "0" "$(grep -c $'\r' "$FAKE_HOME/.claude.json" 2>/dev/null || true)"
case_end

case_begin "AL-7b" "install/codegraph-mcp.js"
al_run "AL-7b" crowded compact
al_check "AL-7b" always "$REFRESH err=0" -
assert_eq "AL-7b: the post file is multi-line canonical JSON" "yes" \
    "$([ "$(grep -c . "$FAKE_HOME/.claude.json" 2>/dev/null || echo 0)" -gt 1 ] && echo yes || echo no)"
case_end

echo "--- AL-14: a temp file that cannot be created leaves the original intact ---"
case_begin "AL-14" "install/codegraph-mcp.js"
if [ "$AL_POSIX" != "1" ]; then
    skip_env "AL-14 — MSYS/Cygwin cannot enforce a read-only directory with POSIX semantics"
elif [ "$(id -u)" = "0" ]; then
    skip_env "AL-14 — running as root ignores directory permissions"
else
    al_run "AL-14" none lockdir
    chmod u+w "$FAKE_HOME"
    al_check "AL-14" same "$ADD_ONLY err=1" "write failed: EACCES"
    assert_no_tmp "$FAKE_HOME"
fi
case_end

echo "--- AL-15: a symlinked ~/.claude.json keeps its link; the target is replaced ---"
al_hook_symlink() {
    mkdir -p "$FAKE_HOME/real"
    mv "$FAKE_HOME/.claude.json" "$FAKE_HOME/real/claude.json"
    AL15_FIXTURE="$(make_symlink "$FAKE_HOME/real/claude.json" "$FAKE_HOME/.claude.json")"
}
case_begin "AL-15" "install/codegraph-mcp.js"
if [ "$AL_POSIX" != "1" ]; then
    skip_env "AL-15 — MSYS/Cygwin ln -s may produce a copy, not a symlink"
else
    PRE_RUN_HOOK=al_hook_symlink
    al_run "AL-15" none write
    PRE_RUN_HOOK=
    if [ "${AL15_FIXTURE:-}" != "symlink" ]; then
        skip_env "AL-15 — this host could not create the symlink fixture"
    else
        al_check "AL-15" always "$ADD_ONLY err=0" -
        assert_eq "AL-15: ~/.claude.json is still a symlink" "symlink" "$(file_kind "$FAKE_HOME/.claude.json")"
        assert_eq "AL-15: the link still points at real/claude.json" "$FAKE_HOME/real/claude.json" \
            "$(readlink "$FAKE_HOME/.claude.json" 2>/dev/null || true)"
        assert_eq "AL-15: the link target holds the patched content" "always" \
            "$(node "$JSON_POST_JS" "$(node_path "$CASE_DIR/claude.json.snap")" "$(node_path "$FAKE_HOME/real/claude.json")" 2>&1)"
        assert_no_tmp "$FAKE_HOME"
        assert_no_tmp "$FAKE_HOME/real"
    fi
fi
case_end

echo "--- AL-16: debris at temp-file names neither blocks the write nor gets touched ---"
al_hook_debris() {
    printf 'untouched\n' > "$FAKE_HOME/victim.txt"
    if [ "$AL_POSIX" = "1" ]; then ln -s "$FAKE_HOME/victim.txt" "$FAKE_HOME/.claude.json.tmp" 2>/dev/null || true; fi
    mkdir -p "$FAKE_HOME/.claude.json.1.1.tmp"
    printf 'stale\n' > "$FAKE_HOME/.claude.json.2.2.tmp"
}
case_begin "AL-16" "install/codegraph-mcp.js"
PRE_RUN_HOOK=al_hook_debris
al_run "AL-16" none write
PRE_RUN_HOOK=
al_check "AL-16" always "$ADD_ONLY err=0" -
assert_eq "AL-16: victim.txt is untouched" "untouched" "$(cat "$FAKE_HOME/victim.txt" 2>/dev/null || true)"
if [ -L "$FAKE_HOME/.claude.json.tmp" ]; then
    assert_eq "AL-16 (i): the legacy .claude.json.tmp symlink is left as it was" "symlink" "$(file_kind "$FAKE_HOME/.claude.json.tmp")"
else
    skip_env "AL-16 (i): legacy symlink debris — no POSIX symlink on this host"
fi
assert_eq "AL-16 (ii): the directory debris is left in place" "directory" \
    "$([ -d "$FAKE_HOME/.claude.json.1.1.tmp" ] && echo directory || echo other)"
assert_eq "AL-16 (iii): the stale-file debris keeps its content" "stale" "$(cat "$FAKE_HOME/.claude.json.2.2.tmp" 2>/dev/null || true)"
assert_no_tmp "$FAKE_HOME" .claude.json.1.1.tmp .claude.json.2.2.tmp
case_end

unset CLAUDE_STUB_EMU CURRENT_AL PRE_RUN_HOOK AL15_FIXTURE
