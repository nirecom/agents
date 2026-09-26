# tests/feature-2119-settings-allow-ssot/write-and-drift.sh
# Tests: install/assemble-settings.js, install/lib/settings-deploy.js, install/lib/settings-assembly.js, hooks/lib/settings-drift.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T6-T7: what a deploy does to ~/.claude/settings.json, and what the drift check sees. Sourced
# AFTER fixture.sh. The generator's --check/orphan rows (T7b/T7c) retired with it in #2264.

T6_FIXTURE=""
T6_PRE_A='Bash(hand-written-one *)'
T6_PRE_B='Bash(hand-written-two *)'
T6_EXT='Bash(extension-written *)'

# T6 -- the deployed file is a BUILD PRODUCT, and the three probes are the three ways a build
# product goes wrong for its reader: a hand-authored half that is reordered, reformatted, or
# quietly rewritten on every session start.
t6_setup() {
    T6_FIXTURE="$(mk_fixture t6)"
    mk_tool "$T6_FIXTURE" bin/fx-tool env-bash
    write_ssot "$T6_FIXTURE" bin/fx-tool
    printf '%s\n%s\n' "$T6_PRE_A" "$T6_PRE_B" > "$T6_FIXTURE/pre.txt"
    write_settings "$T6_FIXTURE" "$T6_FIXTURE/pre.txt"
    printf '%s\n' "$T6_EXT" > "$T6_FIXTURE/ext.txt"
    write_ext "$T6_FIXTURE" "$T6_FIXTURE/ext.txt"
    run_assemble "$T6_FIXTURE"
    cp "$(deployed_file "$T6_FIXTURE")" "$T6_FIXTURE/after-first.json" 2>/dev/null || true
    run_assemble "$T6_FIXTURE"
}

t6_probe() { # <a|b|c> -> yes|no|sentinel
    have_lib || { missing_lib; return; }
    local dump
    case "$1" in
        a)
            dump="$T6_FIXTURE/allow.txt"
            deployed_allow_dump "$T6_FIXTURE" "$dump"
            [ "$(cat "$dump" 2>/dev/null)" = "$(printf '%s\n%s\n%s' "$T6_PRE_A" "$T6_PRE_B" "$T6_EXT")" ] && { printf 'yes'; return; }
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
a|the deployed allow array is exactly the base entries then the extension entry -- nothing generated is appended (#2264)
b|a second deploy leaves the deployed file byte-identical (idempotent, so a session start is not a diff)
c|the deployed file equals JSON.parse -> stringify(_, null, 2) + newline (formatting contract)
T6_CASES
}

# T7 is the round trip against the REAL repository, run entirely inside a throwaway HOME:
# deploy with install/assemble-settings.js there, then ask detectDrift about that same HOME.
# Nothing in the real tree is written. `gen=absent` pins that the drift result no longer
# carries a generatorUnavailable key -- the generator it described is gone.
t7_real_repo_in_sync() {
    local home="$TMPROOT/t7-home" rc=0 out
    ROWS=$((ROWS + 1))
    if ! have_lib; then
        fail "T7: cannot round-trip the real repo -- $LIB_REL_LIST is missing (IMPLEMENTATION MISSING)"
        return
    fi
    mkdir -p "$home/.claude"
    out="$( (cd "$AGENTS_DIR" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$home" USERPROFILE="$(node_path "$home")" CLAUDE_CONFIG_DIR="$home/.claude" \
        run_with_timeout 60 node "$ASSEMBLE_REL") 2>&1 )" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T7: deploying the real repo into a throwaway HOME failed (rc=$rc)" "$out"
        return
    fi
    out="$(run_with_timeout 30 node -e '
      const r = require(process.argv[1]).detectDrift({ homeDir: process.argv[2] });
      console.log("drifted=" + r.drifted + ";gen=" + ("generatorUnavailable" in r ? "PRESENT" : "absent"));
    ' "$(node_path "$AGENTS_DIR/hooks/lib/settings-drift.js")" "$(node_path "$home")" 2>&1)"
    assert_eq "T7: what the real deploy writes is what detectDrift calls in sync, with no generatorUnavailable key" \
        "drifted=false;gen=absent" "$out"
}

t6_setup
t6_write_contract
t7_real_repo_in_sync
