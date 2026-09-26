# tests/feature-2119-settings-allow-ssot/write-and-drift.sh
# Tests: install/gen-settings-allow.js, install/lib/settings-deploy.js, install/lib/settings-assembly.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T6-T7c: what a deploy does to ~/.claude/settings.json, and what `--check` sees. Sourced
# AFTER generator.sh, whose fixture helpers and template contract this part reuses.

T6_FIXTURE=""
T6_PRE_A='Bash(hand-written-one *)'
T6_PRE_B='Bash(hand-written-two *)'
T6_EXT='Bash(extension-written *)'

# T6 -- the deployed file is a BUILD PRODUCT, and the three probes are the three ways a build
# product goes wrong for its reader. The generated rules are injected here, not committed, so
# the failure nobody sees is not a wrong rule but a deployed file whose hand-authored half was
# reordered, reformatted, or quietly rewritten on every session start.
t6_setup() {
    T6_FIXTURE="$(mk_fixture t6)"
    mk_tool "$T6_FIXTURE" bin/fx-tool env-bash
    write_ssot "$T6_FIXTURE" bin/fx-tool
    printf '%s\n%s\n' "$T6_PRE_A" "$T6_PRE_B" > "$T6_FIXTURE/pre.txt"
    write_settings "$T6_FIXTURE" "$T6_FIXTURE/pre.txt"
    printf '%s\n' "$T6_EXT" > "$T6_FIXTURE/ext.txt"
    write_ext "$T6_FIXTURE" "$T6_FIXTURE/ext.txt"
    run_gen "$T6_FIXTURE" --write
    cp "$(deployed_file "$T6_FIXTURE")" "$T6_FIXTURE/after-first.json" 2>/dev/null || true
    run_gen "$T6_FIXTURE" --write
}

t6_probe() { # <a|b|c> -> yes|no|sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local dump head3
    case "$1" in
        a)
            dump="$T6_FIXTURE/allow.txt"
            deployed_allow_dump "$T6_FIXTURE" "$dump"
            head3="$(head -3 "$dump" 2>/dev/null)"
            [ "$head3" = "$(printf '%s\n%s\n%s' "$T6_PRE_A" "$T6_PRE_B" "$T6_EXT")" ] && { printf 'yes'; return; }
            printf 'no'
            ;;
        b)
            cmp -s "$T6_FIXTURE/after-first.json" "$(deployed_file "$T6_FIXTURE")" && { printf 'yes'; return; }
            printf 'no'
            ;;
        c)
            node -e '
              const fs = require("fs");
              const raw = fs.readFileSync(process.argv[1], "utf8");
              const round = JSON.stringify(JSON.parse(raw), null, 2) + "\n";
              console.log(raw === round ? "yes" : "no");
            ' "$(node_path "$(deployed_file "$T6_FIXTURE")")" 2>/dev/null || printf 'no'
            ;;
    esac
}

t6_write_contract() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T6$id: $label" "yes" "$(t6_probe "$id")"
    done <<'T6_CASES'
a|the base and extension allow entries head the deployed array in that order -- the generated block is appended after them, never interleaved
b|a second deploy leaves the deployed file byte-identical (idempotent, so a session start is not a diff)
c|the deployed file equals JSON.parse -> stringify(_, null, 2) + newline (formatting contract)
T6_CASES
}

# T7 is the round trip against the REAL repository, run entirely inside a throwaway HOME:
# deploy the real SSOT there, then ask `--check` about that same HOME. Nothing in the real
# tree is written, and the assertion is the one that matters after this change -- what the
# deploy produces is what the drift check considers in sync.
t7_real_repo_in_sync() {
    if ! have_gen || ! have_lib; then
        fail "T7: cannot round-trip the real SSOT -- $GEN_REL or $LIB_REL_LIST is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local home="$TMPROOT/t7-home" rc=0 out
    mkdir -p "$home/.claude"
    out="$( (cd "$AGENTS_DIR" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$home" USERPROFILE="$(node_path "$home")" CLAUDE_CONFIG_DIR="$home/.claude" \
        run_with_timeout 60 node "$GEN_REL" --write) 2>&1 )" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T7: deploying the real $SSOT_REL into a throwaway HOME failed (rc=$rc)" "$out"
        return
    fi
    rc=0
    out="$( (cd "$AGENTS_DIR" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$home" USERPROFILE="$(node_path "$home")" CLAUDE_CONFIG_DIR="$home/.claude" \
        run_with_timeout 60 node "$GEN_REL" --check) 2>&1 )" || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "T7: what the real deploy writes is exactly what --check calls in sync (no missing, no orphaned entries)"
    else
        fail "T7: $GEN_REL --check reported drift against the file it had just deployed (rc=$rc)" "$out"
    fi
}

# T7b -- NEGATIVE CONTROL for orphan detection. The fixture's BASE settings.json carries the
# full generated-shaped set for a path that is NOT in the SSOT; assembly carries it through to
# the deployed file, where an implementation that only looks for MISSING entries reports
# perfect sync. Both the exit code and the report text are asserted, because a non-zero exit
# that names nothing is not actionable.
t7b_orphan_detection() {
    local fx rc_verdict names_verdict
    if ! have_gen || ! have_lib; then
        rc_verdict="$(missing_lib)"; names_verdict="$(missing_lib)"
    else
        fx="$(mk_fixture t7b)"
        mk_tool "$fx" bin/fx-keep env-bash
        write_ssot "$fx" bin/fx-keep
        expected_path_rules bash bin/fx-dropped "$fx" > "$fx/pre.txt"
        write_settings "$fx" "$fx/pre.txt"
        run_gen "$fx" --write
        run_gen "$fx" --check
        if [ "$GEN_RC" -eq 1 ]; then rc_verdict="finding"; else rc_verdict="rc=$GEN_RC"; fi
        if printf '%s\n' "$GEN_OUT" | grep -q 'fx-dropped'; then names_verdict="named"; else names_verdict="not-named"; fi
    fi
    ROWS=$((ROWS + 1))
    assert_eq "T7b[exit]: a generated-shaped rule for a path that is NOT in the SSOT makes --check exit 1 (a finding, not an outage)" \
        "finding" "$rc_verdict"
    ROWS=$((ROWS + 1))
    assert_eq "T7b[report]: the orphan report names bin/fx-dropped" "named" "$names_verdict"
}

# T7c -- `--check` MUST NOT WRITE, and now there are two places it could. The deployed file is
# the tempting one (drift was just detected there, and repairing it is one call away), but the
# fixture tree is checked too: a check that "helpfully" rewrote the repository's settings.json
# would produce a diff nobody asked for. The drifted fixture is the load-bearing half.
t7c_probe() { # <in-sync|drifted> -> "<tree>/<home>" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx tree_before tree_after home_before home_after tv hv
    fx="$(mk_fixture "t7c-$1")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    if [ "$1" = "drifted" ]; then
        expected_path_rules bash bin/fx-dropped "$fx" > "$fx/pre.txt"
        write_settings "$fx" "$fx/pre.txt"
    else
        write_settings "$fx" --
    fi
    run_gen "$fx" --write
    tree_before="$(repo_tree_manifest "$fx")"
    home_before="$(tree_manifest "$fx/home")"
    run_gen "$fx" --check
    tree_after="$(repo_tree_manifest "$fx")"
    home_after="$(tree_manifest "$fx/home")"
    [ "$tree_before" = "$tree_after" ] && tv="unchanged" || tv="TREE-MODIFIED"
    [ "$home_before" = "$home_after" ] && hv="unchanged" || hv="HOME-MODIFIED"
    printf '%s/%s' "$tv" "$hv"
}

t7c_check_is_read_only() {
    local kind label
    while IFS='|' read -r kind label; do
        [ -n "$kind" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T7c[$kind]: $label" "unchanged/unchanged" "$(t7c_probe "$kind")"
    done <<'T7C_CASES'
in-sync|--check leaves both the repo tree and the deployed file byte-identical when there is nothing to report
drifted|--check reports drift without repairing it: detection reads, only the deploy path writes
T7C_CASES
}

t6_setup
t6_write_contract
t7_real_repo_in_sync
t7b_orphan_detection
t7c_check_is_read_only
