# tests/feature-2119-settings-allow-ssot/provider-purity.sh
# Tests: install/lib/settings-assembly.js, install/lib/settings-allow-rules.js, hooks/lib/settings-drift.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T28: the expectation provider writes nothing, ever. Sourced AFTER generator.sh.

T28_FX=""
T28_TREE=""
T28_HOME=""
T28_DET=""
T28_INJ=""
T28_REQ=""
DRIFT_SRC_REL="hooks/lib/settings-drift.js"

# T28 -- ONE WRITER, AND THE PROVIDER IS NOT IT. The drift check now consumes the same builder
# the deploy consumes, and the drift check runs at EVERY session start. A provider that writes
# would turn a read-only diagnostic into a silent redeploy on every start -- the failure nobody
# would report, because its symptom is that everything looks fine. Two independent guards are
# used: a dynamic one (call it three times; the fixture tree and the fixture home must be
# byte-identical afterwards) and a static one (no fs write API appears in the source at all),
# because the dynamic one only covers the paths this fixture happens to take.
t28_setup() {
    T28_FX="$(mk_fixture t28)"
    mk_tool "$T28_FX" bin/fx-tool env-bash
    write_ssot "$T28_FX" bin/fx-tool
    printf '%s\n' 'Bash(hand-written-only *)' > "$T28_FX/pre.txt"
    write_settings "$T28_FX" "$T28_FX/pre.txt"
    printf '%s\n' 'Bash(extension-only *)' > "$T28_FX/ext.txt"
    write_ext "$T28_FX" "$T28_FX/ext.txt"
    t28_run_build
    t28_run_require
}

# Three calls, one process: a builder that memoises into a file would still be caught, because
# the manifests are taken around the whole run rather than around a single call.
t28_run_build() {
    local tb ta hb ha out
    if ! have_lib; then
        T28_TREE="$(missing_lib)"; T28_HOME="$(missing_lib)"
        T28_DET="$(missing_lib)"; T28_INJ="$(missing_lib)"
        return
    fi
    tb="$(repo_tree_manifest "$T28_FX")"
    hb="$(tree_manifest "$T28_FX/home")"
    out="$( (cd "$T28_FX" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$T28_FX/home" USERPROFILE="$(node_path "$T28_FX/home")" \
        CLAUDE_CONFIG_DIR="$T28_FX/home/.claude" \
        run_with_timeout 30 node -e '
          const root = process.argv[1];
          let M;
          try { M = require(root + "/install/lib/settings-assembly.js"); }
          catch (e) { console.log("REQUIRE-FAILED/REQUIRE-FAILED"); process.exit(0); }
          const build = M.buildAssembledSettings;
          if (typeof build !== "function") { console.log("NOT-EXPORTED/NOT-EXPORTED"); process.exit(0); }
          let a, b, c;
          try { a = build({ agentsRoot: root }); b = build({ agentsRoot: root }); c = build({ agentsRoot: root }); }
          catch (e) { console.log("THREW/THREW:" + String(e.message).split("\n")[0]); process.exit(0); }
          const det = JSON.stringify(a) === JSON.stringify(b) && JSON.stringify(b) === JSON.stringify(c);
          const allow = ((c.settings || {}).permissions || {}).allow || [];
          const inj = allow.indexOf("Bash(bash bin/fx-tool)") !== -1;
          console.log((det ? "yes" : "NON-DETERMINISTIC") + "/" + (inj ? "yes" : "NOTHING-INJECTED"));
        ' -- "$(node_path "$T28_FX")") 2>&1 )"
    ta="$(repo_tree_manifest "$T28_FX")"
    ha="$(tree_manifest "$T28_FX/home")"
    [ "$tb" = "$ta" ] && T28_TREE="unchanged" || T28_TREE="TREE-MODIFIED"
    [ "$hb" = "$ha" ] && T28_HOME="unchanged" || T28_HOME="HOME-MODIFIED"
    T28_DET="${out%%/*}"
    T28_INJ="${out##*/}"
}

# Requiring a module must not be an action. A top-level side effect would fire once per hook
# process -- and the drift path requires this module from a session-start hook.
t28_run_require() {
    local tb ta hb ha
    if ! have_lib; then T28_REQ="$(missing_lib)"; return; fi
    tb="$(repo_tree_manifest "$T28_FX")"
    hb="$(tree_manifest "$T28_FX/home")"
    ( cd "$T28_FX" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$T28_FX/home" USERPROFILE="$(node_path "$T28_FX/home")" \
        CLAUDE_CONFIG_DIR="$T28_FX/home/.claude" \
        run_with_timeout 30 node -e '
          const root = process.argv[1];
          try { require(root + "/install/lib/settings-assembly.js"); } catch (e) {}
          try { require(root + "/install/lib/settings-allow-rules.js"); } catch (e) {}
        ' -- "$(node_path "$T28_FX")" ) >/dev/null 2>&1
    ta="$(repo_tree_manifest "$T28_FX")"
    ha="$(tree_manifest "$T28_FX/home")"
    if [ "$tb" = "$ta" ] && [ "$hb" = "$ha" ]; then T28_REQ="unchanged"; else T28_REQ="MODIFIED"; fi
}

t28_dynamic_table() {
    local id want got label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        case "$id" in
            tree)        got="$T28_TREE" ;;
            home)        got="$T28_HOME" ;;
            determinism) got="$T28_DET" ;;
            injected)    got="$T28_INJ" ;;
            require)     got="$T28_REQ" ;;
        esac
        assert_eq "T28[$id]: $label" "$want" "$got"
    done <<'T28_DYN_CASES'
tree|unchanged|three buildAssembledSettings calls leave the fixture repo tree byte-identical
home|unchanged|and leave the fixture HOME byte-identical, so nothing was deployed as a side effect of asking for the expectation
determinism|yes|the same input returns the same document three times, so a caller can compare two runs and mean it
injected|yes|POSITIVE CONTROL: the returned document really does carry the generated rules, so the three rows above are not passing on a builder that does nothing
require|unchanged|requiring both provider modules, with no call at all, writes nothing -- a top-level side effect would fire once per session-start hook
T28_DYN_CASES
}

# The static canary covers what the fixture cannot reach: a write on a branch this input never
# takes. Absence of the API in the source is a stronger claim than absence of an observed write.
t28_src_probe() { # <relpath> <api> -> absent|PRESENT|<missing sentinel>
    local f="$AGENTS_DIR/$1"
    [ -f "$f" ] || { printf '<MISSING:%s>' "$1"; return; }
    if grep -Fq -- "$2" "$f"; then printf 'PRESENT'; else printf 'absent'; fi
}

t28_static_table() {
    local id rel api label
    while IFS='|' read -r id rel api label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T28[$id]: $rel carries no $api -- $label" "absent" "$(t28_src_probe "$rel" "$api")"
    done <<'T28_STATIC_CASES'
asm-write|install/lib/settings-assembly.js|writeFileSync|the provider returns a document, it never persists one
asm-mkdir|install/lib/settings-assembly.js|mkdirSync|creating the deploy directory belongs to the writer, not the provider
asm-append|install/lib/settings-assembly.js|appendFileSync|and neither does appending to anything
asm-rm|install/lib/settings-assembly.js|rmSync|nor removing anything
rules-write|install/lib/settings-allow-rules.js|writeFileSync|the spelling layer is pure string work
rules-mkdir|install/lib/settings-allow-rules.js|mkdirSync|with no filesystem of its own to prepare
rules-append|install/lib/settings-allow-rules.js|appendFileSync|CPR-ORTH: the same four APIs are checked on both provider modules
rules-rm|install/lib/settings-allow-rules.js|rmSync|so a write added to either one is caught by the same rule
T28_STATIC_CASES
    ROWS=$((ROWS + 1))
    assert_eq "T28[drift-edge]: $DRIFT_SRC_REL does not reference settings-deploy -- the detection path must not acquire an edge to the writing layer, in either direction" \
        "absent" "$(t28_src_probe "$DRIFT_SRC_REL" "settings-deploy")"
}

t28_setup
t28_dynamic_table
t28_static_table
