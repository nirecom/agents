# shellcheck shell=bash
# Tests: install/codegraph-mcp.js, hooks/lib/spawn-shimmed-cli.js
# Tags: codegraph, installer, win32-shim, regression, scope:issue-specific
# ST-19 WC-1..WC-8: #2150 CPR-ORTH counterpart of ST-18 WS — claudeCliPresent /
# runClaude through the real npm cmd-shim shape. WC-1 uses the now-default stub
# shape; WC-2/WC-3/WC-4 cover the fail-closed edges; WC-5 proves the PATHEXT pin
# is load-bearing; WC-6/WC-7 are the shell-payload proof; WC-8 the direct .exe
# verdict. See wc_run below for why these bypass run_case().

# wc_fixture <dir> <shim-builder> — the fixture world WC-1..WC-3 share: fresh case
# dir, fake HOME with no registration, ON .env, no-op nvm stub, node.exe, the shim.
wc_fixture() {
    local d="$1" builder="$2"
    rm -rf "$d"; mkdir -p "$d/cwd" "$d/cfg" "$d/nvm" "$d/bin"
    build_home none ""
    write_env_file "$d/cfg" present on
    printf '# no-op nvm stub\n:\n' > "$d/nvm/nvm.sh"
    write_win_claude_node "$d/bin"
    # The register verb probes `codegraph --version` before it looks at `claude` at
    # all, so without this stub every stderr count below would carry that warning too.
    write_cg_stub "$d/bin"
    "$builder" "$d/bin"
    : > "$d/claude.log"; : > "$d/codegraph.log"; : > "$d/out.log"; : > "$d/err.log"
}

# wc_run <dir> — run `codegraph-mcp.js register` inside that fixture world. These
# cases cannot go through run_case(): its claude_mode parameter is an exit-code
# contract (0|1|no) with no slot for "shim files in a broken/mismatched shape",
# so the fixture is built here instead — which also means run_case()'s own PATHEXT
# export never reaches them, hence the individual pin below (C4).
wc_run() {
    local d="$1"
    (
        cd "$d/cwd" || exit 111
        export HOME="$NORM_HOME" USERPROFILE="$NORM_HOME"
        export PATH="$d/bin:$CLEAN_PATH"
        export PATHEXT="$PINNED_PATHEXT"
        export NVM_DIR="$d/nvm"
        AGENTS_CONFIG_DIR="$(node_path "$d/cfg")"; export AGENTS_CONFIG_DIR
        CLAUDE_STUB_LOG="$(node_path "$d/claude.log")"; export CLAUDE_STUB_LOG
        CG_STUB_LOG="$(node_path "$d/codegraph.log")"; export CG_STUB_LOG
        export CLAUDE_WORKFLOW_DIR="$d/wf" WORKFLOW_PLANS_DIR="$d/plans"
        bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" node "$MCP_JS_NATIVE" register
    ) >"$d/out.log" 2>"$d/err.log" </dev/null
}

# wc_payload_intact <label> <dir> — the C4 measurement. An untouched marker is
# only evidence when the shim was actually reached; a run that resolved nothing
# leaves it untouched for the wrong reason.
wc_payload_intact() {
    if [ "$(grep -c '^mcp add ' "$2/claude.log" 2>/dev/null || true)" -lt 1 ]; then
        fail "$1 — the marker survived only because the shim was never reached (no evidence)"
    else
        assert_eq "$1 — the planted shim body was never shell-executed" \
            "pristine" "$(cat "$2/bin/payload-marker.txt" 2>/dev/null || echo "<destroyed-or-missing>")"
    fi
}

if [ "$IS_WIN" -ne 1 ]; then
    skip_env "WC-1..WC-8 — .cmd-shim delegation is a win32-only code path"
else
    echo "--- WC-1: register through the default (now .cmd-shim-shaped) claude stub ---"
    WC_DIR="$BASE/case-wc1"
    wc_fixture "$WC_DIR" write_win_claude_cmd_shim
    wc_run "$WC_DIR"; wc_rc=$?
    assert_eq "WC-1 — exit 0" "0" "$wc_rc"
    assert_eq "WC-1 — mcp add reached via the .cmd-shim path" "1" \
        "$(grep -c '^mcp add ' "$WC_DIR/claude.log" 2>/dev/null || true)"
    assert_eq "WC-1 — the argv the CLI received is the SSOT-derived one" "1" \
        "$(grep -cF -x "$WANT_MCP_ADD" "$WC_DIR/claude.log" 2>/dev/null || true)"
    assert_eq "WC-1 — no stderr warning (the CLI resolved)" "0" \
        "$(grep -c . "$WC_DIR/err.log" 2>/dev/null || true)"

    echo "--- WC-2: a claude.cmd without its POSIX sibling is reported as absent (fail safe) ---"
    WC_DIR2="$BASE/case-wc2"
    wc_fixture "$WC_DIR2" write_win_claude_cmd_shim_broken
    wc_run "$WC_DIR2"; wc_rc2=$?
    assert_eq "WC-2 — exit 0 (never halts the installer)" "0" "$wc_rc2"
    assert_eq "WC-2 — exactly 1 stderr warning (claude CLI not found)" "1" \
        "$(grep -c . "$WC_DIR2/err.log" 2>/dev/null || true)"
    assert_eq "WC-2 — the CLI was never invoked (no .cmd fallback attempted)" "0" \
        "$(grep -c . "$WC_DIR2/claude.log" 2>/dev/null || true)"

    echo "--- WC-3: a claude.cmd whose embedded target disagrees with its POSIX sibling's target is reported as absent ---"
    WC_DIR3="$BASE/case-wc3"
    wc_fixture "$WC_DIR3" write_win_claude_cmd_shim_mismatch
    wc_run "$WC_DIR3"; wc_rc3=$?
    assert_eq "WC-3 — exit 0 (never halts the installer)" "0" "$wc_rc3"
    assert_eq "WC-3 — exactly 1 stderr warning (mismatched target rejected, C2)" "1" \
        "$(grep -c . "$WC_DIR3/err.log" 2>/dev/null || true)"
    assert_eq "WC-3 — neither shim target was executed" "0" \
        "$(grep -c . "$WC_DIR3/claude.log" 2>/dev/null || true)"

    echo "--- WC-4: a claude POSIX sibling without its .cmd is reported as absent (the mirror of WC-2) ---"
    WC_DIR4="$BASE/case-wc4"
    wc_fixture "$WC_DIR4" write_win_claude_cmd_shim_nocmd
    wc_run "$WC_DIR4"; wc_rc4=$?
    assert_eq "WC-4 — exit 0 (never halts the installer)" "0" "$wc_rc4"
    assert_eq "WC-4 — exactly 1 stderr warning (claude CLI not found)" "1" \
        "$(grep -c . "$WC_DIR4/err.log" 2>/dev/null || true)"
    assert_eq "WC-4 — the bare POSIX sibling was never executed" "0" \
        "$(grep -c . "$WC_DIR4/claude.log" 2>/dev/null || true)"

    # WC-5 — the CPR-ORTH counterpart of ST-18 WS-6. Every other case here runs
    # with the pin already applied, so none can show the pin matters. The
    # reference resolver (tests/lib/shim-resolve-reference.js, the stand-in for
    # the not-yet-written hooks/lib/spawn-shimmed-cli.js) is run twice against
    # WC-1's own fixture shape from a hostile calling shell: unpinned it cannot
    # reach the .cmd branch at all, pinned it resolves regardless.
    echo "--- WC-5: the PATHEXT pin wc_run()/run_case() apply is load-bearing (C4) ---"
    WC_DIR5="$BASE/case-wc5"
    wc_fixture "$WC_DIR5" write_win_claude_cmd_shim
    WC5_SAVED_PATHEXT="${PATHEXT-__unset__}"
    export PATHEXT="$HOSTILE_PATHEXT"
    wc5_unpinned="$(env PATH="$WC_DIR5/bin" "$REAL_NODE_EXE" "$SHIM_REF_N" claude 2>/dev/null || true)"
    wc5_pinned="$(env PATHEXT="$PINNED_PATHEXT" PATH="$WC_DIR5/bin" "$REAL_NODE_EXE" "$SHIM_REF_N" claude 2>/dev/null || true)"
    if [ "$WC5_SAVED_PATHEXT" = "__unset__" ]; then unset PATHEXT; else export PATHEXT="$WC5_SAVED_PATHEXT"; fi
    assert_eq "WC-5a — a host PATHEXT without .CMD steers resolution off the .cmd branch entirely (so the pin is not decorative)" \
        "unresolved" "$wc5_unpinned"
    assert_eq "WC-5b — the pinned PATHEXT overrides that hostile ambient one and the shim still resolves" \
        "resolved claude-target.js" "$wc5_pinned"

    # WC-6/WC-7 — the installer-side half of C4, and the CPR-ORTH counterpart of
    # ST-18 WS-7/WS-8. install/codegraph-mcp.js reaches `claude` twice
    # (claudeCliPresent, runClaude); a single surviving marker covers both,
    # because either one shelling out would already have destroyed it.
    echo "--- WC-6: a claude.cmd carrying a shell payload is parsed, never executed (C4) ---"
    WC_DIR6="$BASE/case-wc6"
    wc_fixture "$WC_DIR6" write_win_claude_cmd_payload
    wc_run "$WC_DIR6"; wc_rc6=$?
    assert_eq "WC-6 — exit 0" "0" "$wc_rc6"
    assert_eq "WC-6 — the verified JavaScript target still received the mcp add" "1" \
        "$(grep -c '^mcp add ' "$WC_DIR6/claude.log" 2>/dev/null || true)"
    wc_payload_intact "WC-6" "$WC_DIR6"

    echo "--- WC-7: the same through a claude.bat — the other delegated extension (C3/C4) ---"
    WC_DIR7="$BASE/case-wc7"
    wc_fixture "$WC_DIR7" write_win_claude_bat_payload
    wc_run "$WC_DIR7"; wc_rc7=$?
    assert_eq "WC-7 — exit 0" "0" "$wc_rc7"
    assert_eq "WC-7 — a .bat shim is accepted and its target received the mcp add" "1" \
        "$(grep -c '^mcp add ' "$WC_DIR7/claude.log" 2>/dev/null || true)"
    wc_payload_intact "WC-7" "$WC_DIR7"

    # WC-8 — the direct-launch verdict. Every case above ends in the delegated
    # branch, so nothing else here separates "classified as direct" from "not
    # resolved at all" (C3).
    echo "--- WC-8: a bare claude.exe is classified as a direct launch, not as unresolved (C3) ---"
    WC_DIR8="$BASE/case-wc8"
    rm -rf "$WC_DIR8"; mkdir -p "$WC_DIR8/bin"
    write_win_claude_exe "$WC_DIR8/bin"
    wc8="$(env PATHEXT="$PINNED_PATHEXT" PATH="$WC_DIR8/bin" "$REAL_NODE_EXE" "$SHIM_REF_N" claude 2>/dev/null || true)"
    assert_eq "WC-8 — a .exe on PATH resolves and is launched as-is" "direct claude.exe" "$wc8"
fi
