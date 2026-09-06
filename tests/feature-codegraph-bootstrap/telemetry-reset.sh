# shellcheck shell=bash
# Tests: install/codegraph-mcp.js, install/linux/codegraph.sh, hooks/lib/codegraph-boundary.js
# Tags: codegraph, installer, telemetry, mcp-registration, side-effect-absence, TL2, pwsh-not-required, scope:issue-specific
# M1-M15f (#2215): clearSavedTelemetryChoice() unconditionally deletes a saved
# telemetry.json on every register run while constants ship telemetry on, independent
# of MCP ownership/outcome, no once-per-machine marker (rejected, see plan S5-4/S5-5).
# Sourced after ownership.sh; reuses its $NO_CONSTANTS_JS / $PARTIAL_CONSTANTS_JS.

# telemetry_json: the saved-choice file's exact body, or the literal ABSENT.
telemetry_json() {
    if [ -f "$FAKE_HOME/.codegraph/telemetry.json" ]; then cat "$FAKE_HOME/.codegraph/telemetry.json"
    else printf 'ABSENT'; fi
}
TELEMETRY_OFF_BODY="$(printf '{"enabled":false,%s}' "$TELEMETRY_JSON_TAIL")"

assert_reset_note() { assert_note "$1" "reset the local CodeGraph telemetry choice"; }

assert_no_reset_note() {
    local name="$1" out; out="$(cat "$CASE_DIR/out.log" 2>/dev/null || true)"
    case "$out" in
        *"reset the local CodeGraph telemetry choice"*)
            fail "$name: unexpected telemetry reset line in stdout — got $(printf '%q' "$out")" ;;
        *) pass "$name: no telemetry reset line in stdout" ;;
    esac
}

assert_reset_warn() {
    local name="$1" err; err="$(cat "$CASE_DIR/err.log" 2>/dev/null || true)"
    case "$err" in
        *"could not reset the local CodeGraph telemetry choice"*) pass "$name: stderr explains the reset failure" ;;
        *) fail "$name: stderr missing the reset-failure warning — got $(printf '%q' "$err")" ;;
    esac
}

# assert_reset_before: the reset line is emitted at register()'s entry, strictly
# before its own outcome note (S5-5) — a line-number check, not substring order.
assert_reset_before() {
    local name="$1" needle="$2" out reset_line other_line
    out="$(cat "$CASE_DIR/out.log" 2>/dev/null || true)"
    reset_line="$(printf '%s\n' "$out" | grep -n "reset the local CodeGraph telemetry choice" | head -1 | cut -d: -f1)"
    other_line="$(printf '%s\n' "$out" | grep -n -F "$needle" | head -1 | cut -d: -f1)"
    if [ -n "$reset_line" ] && [ -n "$other_line" ] && [ "$reset_line" -lt "$other_line" ]; then
        pass "$name: the reset line precedes '$needle'"
    else
        fail "$name: the reset line does not precede '$needle' (reset_line=${reset_line:-<none>} other_line=${other_line:-<none>})"
    fi
}

echo "--- M1-M4: register on the ON path (mcp=none) — deletion never inspects the file's content ---"
TELEMETRY_PRE=off
run_case "M1" sh on present none no 0 0 yes file
assert_eq "M1: observable outcome" "rc=0 npmi=1 add=1 rm=0 mcp=1 err=0" "$SUMMARY"
assert_eq "M1: telemetry.json is gone" "ABSENT" "$(telemetry_json)"
assert_reset_note "M1"

TELEMETRY_PRE=on
run_case "M2" sh on present none no 0 0 yes file
assert_eq "M2: observable outcome" "rc=0 npmi=1 add=1 rm=0 mcp=1 err=0" "$SUMMARY"
assert_eq "M2: telemetry.json is gone even though enabled:true (no content inspection)" "ABSENT" "$(telemetry_json)"
assert_reset_note "M2"

TELEMETRY_PRE=garbage
run_case "M3" sh on present none no 0 0 yes file
assert_eq "M3: observable outcome" "rc=0 npmi=1 add=1 rm=0 mcp=1 err=0" "$SUMMARY"
assert_eq "M3: telemetry.json is gone even though it is not valid JSON (no JSON.parse)" "ABSENT" "$(telemetry_json)"
assert_reset_note "M3"

TELEMETRY_PRE=absent
run_case "M4" sh on present none no 0 0 yes file
assert_eq "M4: observable outcome" "rc=0 npmi=1 add=1 rm=0 mcp=1 err=0" "$SUMMARY"
assert_eq "M4: telemetry.json stays absent" "ABSENT" "$(telemetry_json)"
assert_eq "M4: ~/.codegraph is not created when there is nothing to reset" "" \
    "$([ -d "$FAKE_HOME/.codegraph" ] && echo present)"
assert_no_reset_note "M4"

echo "--- M5/M6: the OFF path (CODEGRAPH=off) never resets, whether unregister removes or is silent ---"
TELEMETRY_PRE=off
run_case "M5" sh off present present no 0 0 yes file
assert_eq "M5: observable outcome (unregister removes a present entry)" "rc=0 npmi=0 add=0 rm=1 mcp=1 err=0" "$SUMMARY"
assert_eq "M5: telemetry.json is byte-identical (OFF path never resets)" "$TELEMETRY_OFF_BODY" "$(telemetry_json)"
assert_no_reset_note "M5"

run_case "M6" sh off present none no 0 0 yes file
assert_eq "M6: observable outcome (unregister is silent on an absent entry)" "rc=0 npmi=0 add=0 rm=0 mcp=0 err=0" "$SUMMARY"
assert_eq "M6: telemetry.json is byte-identical" "$TELEMETRY_OFF_BODY" "$(telemetry_json)"
assert_no_reset_note "M6"

echo "--- M7-M11: the reset fires on every register outcome regardless of MCP ownership state ---"
TELEMETRY_PRE=off
run_case "M7" sh on present foreigncmd yes 0 0 yes file
assert_eq "M7: observable outcome (a foreign command is left untouched)" "rc=0 npmi=0 add=0 rm=0 mcp=0 err=0" "$SUMMARY"
assert_eq "M7: telemetry.json is gone (reset does not depend on touching the foreign entry)" "ABSENT" "$(telemetry_json)"
assert_reset_note "M7"

run_case "M8" sh on present none yes 0 1 yes file
assert_eq "M8: observable outcome (claude mcp add fails)" "rc=0 npmi=0 add=1 rm=0 mcp=1 err=1" "$SUMMARY"
assert_eq "M8: telemetry.json is gone even though addServer failed" "ABSENT" "$(telemetry_json)"
assert_reset_note "M8"

run_case "M9" sh on present present yes 0 0 yes file
assert_eq "M9: observable outcome (state=current, a no-op)" "rc=0 npmi=0 add=0 rm=0 mcp=0 err=0" "$SUMMARY"
assert_eq "M9: telemetry.json is gone on the current/no-op path too" "ABSENT" "$(telemetry_json)"
assert_reset_note "M9"
assert_reset_before "M9" "already registered."

run_case "M10" sh on present ourenvplus yes 0 0 yes file
assert_eq "M10: observable outcome (current with an unrelated extra env key)" "rc=0 npmi=0 add=0 rm=0 mcp=0 err=0" "$SUMMARY"
assert_eq "M10: telemetry.json is gone regardless of the extra key" "ABSENT" "$(telemetry_json)"
assert_reset_note "M10"
assert_reset_before "M10" "already registered."

run_case "M11" sh on present broken yes 0 0 yes file
assert_eq "M11: observable outcome (an unreadable ~/.claude.json, state=null, early return)" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_eq "M11: telemetry.json is gone even on the state=null early-return path" "ABSENT" "$(telemetry_json)"
assert_reset_note "M11"

echo "--- M12: re-running the installer clears a re-created opt-out again — accepted, not a bug ---"
TELEMETRY_PRE=off
run_case "M12-1" sh on present present yes 0 0 yes file
assert_eq "M12-1: observable outcome" "rc=0 npmi=0 add=0 rm=0 mcp=0 err=0" "$SUMMARY"
assert_eq "M12-1: telemetry.json is gone" "ABSENT" "$(telemetry_json)"
assert_reset_note "M12-1"

# Re-invoke the same OS script against the SAME $FAKE_HOME (no build_home call in
# between, unlike a second run_case). build_home wipes $FAKE_HOME on every call, so a
# once-per-machine marker under ~/.claude would be wiped along with it and this
# regression would go undetected if written as two ordinary run_case invocations.
mkdir -p "$FAKE_HOME/.codegraph"
printf '{"enabled":false,%s}\n' "$TELEMETRY_JSON_TAIL" > "$FAKE_HOME/.codegraph/telemetry.json"
M12_DIR="$CASE_DIR"
(
    cd "$M12_DIR/cwd" || exit 111
    export HOME="$NORM_HOME" USERPROFILE="$NORM_HOME"
    export PATH="$M12_DIR/bin:$CLEAN_PATH"
    export PATHEXT="$PINNED_PATHEXT"
    export NVM_DIR="$M12_DIR/nvm"
    export NPM_STUB_RC=0 CLAUDE_STUB_RC=0
    AGENTS_CONFIG_DIR="$(node_path "$M12_DIR/cfg")"; export AGENTS_CONFIG_DIR
    NPM_STUB_LOG="$(node_path "$M12_DIR/npm.log")"; export NPM_STUB_LOG
    CG_STUB_LOG="$(node_path "$M12_DIR/codegraph.log")"; export CG_STUB_LOG
    CLAUDE_STUB_LOG="$(node_path "$M12_DIR/claude.log")"; export CLAUDE_STUB_LOG
    export CLAUDE_WORKFLOW_DIR="$M12_DIR/wf" WORKFLOW_PLANS_DIR="$M12_DIR/plans"
    bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" bash "$CODEGRAPH_SH"
) >"$M12_DIR/out2.log" 2>"$M12_DIR/err2.log" </dev/null
M12_RC2=$?
assert_eq "M12-2: the second run also exits clean" "0" "$M12_RC2"
assert_eq "M12-2: the re-created opt-out is cleared again" "ABSENT" "$(telemetry_json)"
case "$(cat "$M12_DIR/out2.log" 2>/dev/null || true)" in
    *"reset the local CodeGraph telemetry choice"*) pass "M12-2: the reset line fires again on the second run" ;;
    *) fail "M12-2: expected the reset line on the second run too — got $(printf '%q' "$(cat "$M12_DIR/out2.log" 2>/dev/null)")" ;;
esac

echo "--- M13: a deletion failure (EPERM/EISDIR) warns, keeps exit 0, and does not block registration ---"
TELEMETRY_PRE=undeletable
run_case "M13" sh on present none no 0 0 yes file
assert_eq "M13: observable outcome (registration completes normally)" "rc=0 npmi=1 add=1 rm=0 mcp=1 err=1" "$SUMMARY"
assert_eq "M13: the undeletable telemetry.json directory survives" "directory" \
    "$([ -d "$FAKE_HOME/.codegraph/telemetry.json" ] && echo directory || echo other)"
assert_reset_warn "M13"

echo "--- M14: an unreadable/partial codegraph-constants.txt fails closed on telemetry too (reuses ownership.sh's mini trees) ---"
TELEMETRY_PRE=off
run_case "M14a" register on present none no 0 0 yes file "$NO_CONSTANTS_JS"
assert_eq "M14a: telemetry.json untouched (constants file absent)" "$TELEMETRY_OFF_BODY" "$(telemetry_json)"
assert_no_reset_note "M14a"

run_case "M14b" register on present none no 0 0 yes file "$PARTIAL_CONSTANTS_JS"
assert_eq "M14b: telemetry.json untouched (constants file partial)" "$TELEMETRY_OFF_BODY" "$(telemetry_json)"
assert_no_reset_note "M14b"

echo "--- M15a-e: the shipped-posture gate copies upstream's own truthiness for both env keys ---"
TELEMETRY_PRE=off
M15A_JS="$(make_constants_tree "m15a-optout" "$(constants_body 0 1)")"
run_case "M15a" register on present none no 0 0 yes file "$M15A_JS"
assert_eq "M15a: byte-identical (CODEGRAPH_TELEMETRY=0, DO_NOT_TRACK=1 — numeric off side)" \
    "$TELEMETRY_OFF_BODY" "$(telemetry_json)"
assert_no_reset_note "M15a"

M15B_JS="$(make_constants_tree "m15b-false-telemetry" "$(constants_body false 0)")"
run_case "M15b" register on present none no 0 0 yes file "$M15B_JS"
assert_eq "M15b: byte-identical (CODEGRAPH_TELEMETRY=false is the OFF side, not on)" \
    "$TELEMETRY_OFF_BODY" "$(telemetry_json)"
assert_no_reset_note "M15b"

M15C_JS="$(make_constants_tree "m15c-false-dnt" "$(constants_body 1 false)")"
run_case "M15c" register on present none no 0 0 yes file "$M15C_JS"
assert_eq "M15c: cleared (DO_NOT_TRACK=false is not an opt-out)" "ABSENT" "$(telemetry_json)"
assert_reset_note "M15c"

M15D_JS="$(make_constants_tree "m15d-false-dnt-upper" "$(constants_body 1 FALSE)")"
run_case "M15d" register on present none no 0 0 yes file "$M15D_JS"
assert_eq "M15d: cleared (DO_NOT_TRACK=FALSE, case-insensitive)" "ABSENT" "$(telemetry_json)"
assert_reset_note "M15d"

M15E_JS="$(make_constants_tree "m15e-empty-telemetry" "$(constants_body "" 0)")"
run_case "M15e" register on present none no 0 0 yes file "$M15E_JS"
assert_eq "M15e: byte-identical (an empty CODEGRAPH_TELEMETRY decides nothing, S5-5's asymmetry)" \
    "$TELEMETRY_OFF_BODY" "$(telemetry_json)"
assert_no_reset_note "M15e"

echo "--- M15f: turning the constants off afterwards does not un-delete an already-reset choice ---"
TELEMETRY_PRE=off
M15F_ON_JS="$(make_constants_tree "m15f-on" "$(constants_body "$CG_TELEMETRY" "$CG_DNT")")"
run_case "M15f-1" register on present none no 0 0 yes file "$M15F_ON_JS"
assert_eq "M15f-1: the first register clears the saved opt-out" "ABSENT" "$(telemetry_json)"
assert_reset_note "M15f-1"

# Same $FAKE_HOME as M15f-1 (no build_home in between): the two-stage, order-dependent
# recovery (constants to 0, re-run, THEN `codegraph telemetry off`) exists precisely
# because this step alone does not restore the file (round-7 codex C3).
M15F_OFF_JS="$(make_constants_tree "m15f-off" "$(constants_body 0 1)")"
M15F_DIR="$CASE_DIR"
(
    export HOME="$NORM_HOME" USERPROFILE="$NORM_HOME"
    export PATH="$M15F_DIR/bin:$CLEAN_PATH"
    export PATHEXT="$PINNED_PATHEXT"
    export CLAUDE_WORKFLOW_DIR="$M15F_DIR/wf" WORKFLOW_PLANS_DIR="$M15F_DIR/plans"
    bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" node "$M15F_OFF_JS" register
) >"$M15F_DIR/out2.log" 2>"$M15F_DIR/err2.log" </dev/null
assert_eq "M15f-2: turning the constants off does not restore the deleted file" "ABSENT" "$(telemetry_json)"

# Restore the shared fixture axis: win-shim.sh (sourced after this file) calls
# build_home directly and must not inherit whatever value this file last set.
TELEMETRY_PRE=absent
