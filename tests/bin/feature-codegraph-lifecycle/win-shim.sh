# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, hooks/lib/spawn-shimmed-cli.js
# Tags: codegraph, lifecycle, win32-shim, regression, scope:issue-specific
# ST-18 WS-1..WS-10: #2150 reopen — the win32 .cmd-shim delegation path
# (spawnShimmedCli). WS-1/WS-4 exercise the now-default stub shape; WS-2/WS-3/
# WS-5 the fail-closed edges no existing case reaches; WS-6 proves the PATHEXT
# pin WS-1..WS-5 inherit from run_cli() is load-bearing; WS-7/WS-8 are the
# real-subprocess shell-payload proof; WS-9 the direct .exe verdict; WS-10 the
# caller's own spawn options surviving the indirection.

if [ "$IS_WIN32" -ne 1 ]; then
    skip "WS-1..WS-10 — .cmd-shim delegation is a win32-only code path"
else
    echo "--- WS-1: telemetry env reaches the process spawned via the default .cmd-shim path ---"
    # Expected values come from the SSOT (install/codegraph-constants.txt), not
    # a hardcoded literal, so a future flip of the pair cannot silently drift.
    WS1_EXPECTED_TELEMETRY="$(sed -n 's/^CODEGRAPH_TELEMETRY=//p' "$AGENTS_DIR/install/codegraph-constants.txt" | head -1)"
    WS1_EXPECTED_DNT="$(sed -n 's/^DO_NOT_TRACK=//p' "$AGENTS_DIR/install/codegraph-constants.txt" | head -1)"
    reset_env
    root="$(mkroot "ws1")"
    export CG_STUB_MAKEDB=healthy
    env_log="$TMP_BASE/env-log-ws1.txt"; rm -f "$env_log"
    CG_STUB_ENV_LOG="$(to_native "$env_log")"; export CG_STUB_ENV_LOG
    export CG_STUB_ENV_VARS="CODEGRAPH_TELEMETRY,DO_NOT_TRACK"
    run_cli init "$root"
    unset CG_STUB_MAKEDB CG_STUB_ENV_LOG CG_STUB_ENV_VARS
    assert_eq "WS-1 — telemetry env vars reached the .cmd-shim-resolved subprocess" \
        "CODEGRAPH_TELEMETRY=$WS1_EXPECTED_TELEMETRY DO_NOT_TRACK=$WS1_EXPECTED_DNT" "$(head -n1 "$env_log" 2>/dev/null || true)"

    echo "--- WS-2: a .cmd present without its POSIX sibling fails safe (no shell fallback) ---"
    reset_env
    CG_PATH_MODE=missing-sibling
    root="$(mkroot "ws2")"
    run_cli init "$root"
    assert_warned "WS-2 — codegraph command not found (no .cmd fallback attempted)"
    assert_no_spawn "WS-2"

    echo "--- WS-3: a .cmd whose embedded target disagrees with its POSIX sibling's target fails safe ---"
    reset_env
    CG_PATH_MODE=mismatched-shim
    root="$(mkroot "ws3")"
    run_cli init "$root"
    assert_warned "WS-3 — codegraph command not found (mismatched .cmd/POSIX-sibling target rejected, C2)"
    assert_no_spawn "WS-3"

    echo "--- WS-4: codegraphOnPath() correctly reports FOUND via the .cmd-shim path (defect scenario) ---"
    reset_env
    root="$(mkroot "ws4")"
    make_db "$root" healthy
    run_cli sync "$root"
    assert_eq "WS-4 — exit 0" "0" "$RC"
    assert_eq "WS-4 — sync reached the codegraph binary (not silently skipped as 'not found')" "1" "$(verb_count sync)"

    echo "--- WS-5: a POSIX sibling present without its .cmd fails safe (the mirror of WS-2) ---"
    reset_env
    CG_PATH_MODE=missing-cmd
    root="$(mkroot "ws5")"
    run_cli init "$root"
    assert_warned "WS-5 — codegraph command not found (a bare POSIX sibling is never a win32 candidate)"
    assert_no_spawn "WS-5"

    # WS-6 — is the harness's PATHEXT pin doing anything? Every other case in
    # this suite already runs with the pin, so none of them can answer that.
    # The two probes below run the reference resolver (tests/lib/
    # shim-resolve-reference.js — the stand-in for the not-yet-written
    # hooks/lib/spawn-shimmed-cli.js) against the same $SH_BIN fixture, from a
    # calling shell whose PATHEXT is hostile: (a) without the pin the .cmd
    # branch is unreachable, (b) with it, resolution succeeds anyway.
    echo "--- WS-6: the PATHEXT pin run_cli() applies is load-bearing (C4) ---"
    reset_env
    WS6_SAVED_PATHEXT="${PATHEXT-__unset__}"
    export PATHEXT="$HOSTILE_PATHEXT"
    ws6_unpinned="$(env PATH="$SH_BIN" "$NODE_EXE" "$SHIM_REF_N" codegraph 2>/dev/null || true)"
    ws6_pinned="$(env PATHEXT="$PINNED_PATHEXT" PATH="$SH_BIN" "$NODE_EXE" "$SHIM_REF_N" codegraph 2>/dev/null || true)"
    if [ "$WS6_SAVED_PATHEXT" = "__unset__" ]; then unset PATHEXT; else export PATHEXT="$WS6_SAVED_PATHEXT"; fi
    assert_eq "WS-6a — a host PATHEXT without .CMD steers resolution off the .cmd branch entirely (so the pin is not decorative)" \
        "unresolved" "$ws6_unpinned"
    assert_eq "WS-6b — run_cli()'s own PATHEXT value overrides that hostile ambient one and the shim still resolves" \
        "resolved codegraph-target.js" "$ws6_pinned"

    # WS-7/WS-8 — the real-shell half of C4. Sections A of the #2150 unit suite
    # show that THIS code never shells out; only a genuine win32 subprocess can
    # show what a shell would have done, and that is what the marker measures.
    echo "--- WS-7: a .cmd shim carrying a shell payload is parsed, never executed (C4) ---"
    reset_env
    CG_PATH_MODE=payload-cmd
    root="$(mkroot "ws7")"
    run_cli init "$root"
    assert_eq "WS-7 — the verified JavaScript target still ran" "1" "$(verb_count init)"
    assert_payload_intact "WS-7" "$PAYLOAD_MARKER" "$(verb_count init)"

    echo "--- WS-8: the same, through a .bat shim — the other delegated extension (C3/C4) ---"
    reset_env
    CG_PATH_MODE=payload-bat
    root="$(mkroot "ws8")"
    run_cli init "$root"
    assert_eq "WS-8 — a .bat shim is accepted and its target ran" "1" "$(verb_count init)"
    assert_payload_intact "WS-8" "$BATPAYLOAD_MARKER" "$(verb_count init)"

    # WS-9 — the sanctioned direct-launch verdict. Every case above ends in the
    # delegated branch, so without this one nothing distinguishes "classified as
    # direct" from "not resolved at all" (C3).
    echo "--- WS-9: a bare codegraph.exe is classified as a direct launch, not as unresolved (C3) ---"
    reset_env
    ws9="$(env PATHEXT="$PINNED_PATHEXT" PATH="$SH_BIN_EXE" "$NODE_EXE" "$SHIM_REF_N" codegraph 2>/dev/null || true)"
    assert_eq "WS-9 — a .exe on PATH resolves and is launched as-is" "direct codegraph.exe" "$ws9"

    # WS-10 — the caller's OWN options, not the helper's. WS-1 pins the two vars
    # spawnCodegraph() forces; those would survive a helper that rebuilt env from
    # scratch. This pins a var the caller merely inherited, so it only arrives if
    # the whole options object was delegated intact through the .cmd-shim path.
    echo "--- WS-10: caller-supplied spawn options survive delegation unchanged (C3) ---"
    # The forced var's expected value comes from the SSOT, same rationale as WS-1.
    WS10_EXPECTED_TELEMETRY="$(sed -n 's/^CODEGRAPH_TELEMETRY=//p' "$AGENTS_DIR/install/codegraph-constants.txt" | head -1)"
    reset_env
    root="$(mkroot "ws10")"
    env_log="$TMP_BASE/env-log-ws10.txt"; rm -f "$env_log"
    CG_STUB_ENV_LOG="$(to_native "$env_log")"; export CG_STUB_ENV_LOG
    export CG_STUB_ENV_VARS="CG_WS10_CUSTOM,CODEGRAPH_TELEMETRY"
    export CG_WS10_CUSTOM="ws10-inherited"
    make_db "$root" healthy
    run_cli sync "$root"
    unset CG_STUB_ENV_LOG CG_STUB_ENV_VARS CG_WS10_CUSTOM
    assert_eq "WS-10 — an inherited env var reached the spawned target alongside the forced ones" \
        "CG_WS10_CUSTOM=ws10-inherited CODEGRAPH_TELEMETRY=$WS10_EXPECTED_TELEMETRY" "$(head -n1 "$env_log" 2>/dev/null || true)"
fi
