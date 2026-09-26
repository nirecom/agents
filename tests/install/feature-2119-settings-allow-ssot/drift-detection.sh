# tests/feature-2119-settings-allow-ssot/drift-detection.sh
# Tests: hooks/lib/settings-drift.js, hooks/session-start.js, install/lib/settings-assembly.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T30: the detection path, which is fail-OPEN where the deploy path is fail-closed.

DRIFT_MODULE_REL="hooks/lib/settings-drift.js"
SESSION_START_REL="hooks/session-start.js"
T30_A=""
T30_B=""
T30_C=""
T30_D=""
T30_E=""
T30_SESSION=""

# T30 -- OPPOSITE POLARITY, SAME PROVIDER (CPR-SC: the receiver decides the polarity, not the
# provider). This path runs at every session start, so it must never throw and never block.
# Since #2264 the expected set is base + extension ONLY: the SSOT lists feed bash-guard at
# runtime and no longer reach settings.json, so a broken list is not a drift input at all and
# the generatorUnavailable key the old generator needed is gone with it.
t30_root() { # <name> -> fixture root with a hooks/lib of its own
    local d
    d="$(mk_fixture "t30-$1")"
    mkdir -p "$d/hooks/lib"
    cp "$AGENTS_DIR/$DRIFT_MODULE_REL" "$d/hooks/lib/" 2>/dev/null || true
    mk_tool "$d" bin/fx-tool env-bash
    write_ssot "$d" bin/fx-tool
    printf '%s\n' 'Bash(base-hand-written *)' > "$d/pre.txt"
    write_settings "$d" "$d/pre.txt"
    printf '%s\n' 'Bash(ext-hand-written *)' > "$d/ext.txt"
    write_ext "$d" "$d/ext.txt"
    run_assemble "$d"
    printf '%s\n' "$d"
}

# The deployed file is edited directly, the way a stale machine or a curious user leaves it.
t30_edit_deployed() { # <root> <drop-rule|--> <add-rule|-->
    node -e '
      const fs = require("fs");
      const p = process.argv[1], drop = process.argv[2], add = process.argv[3];
      let o;
      try { o = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { process.exit(0); }
      o.permissions = o.permissions || {};
      let a = o.permissions.allow || [];
      if (drop !== "--") a = a.filter((r) => r !== drop);
      if (add !== "--") a = a.concat([add]);
      o.permissions.allow = a;
      fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
    ' "$(node_path "$(deployed_file "$1")")" "$2" "$3" 2>/dev/null || true
}

t30_detect() { # <root> -> JSON on one line
    run_with_timeout 20 node -e '
      let r;
      try { r = require(process.argv[1]); }
      catch (e) { console.log(JSON.stringify({ THREW: "require: " + String(e.message).split("\n")[0] })); process.exit(0); }
      let o;
      try { o = r.detectDrift({ homeDir: process.argv[2] }); }
      catch (e) { console.log(JSON.stringify({ THREW: String(e.message).split("\n")[0] })); process.exit(0); }
      console.log(JSON.stringify(o));
    ' -- "$(node_path "$1/hooks/lib/settings-drift.js")" "$(node_path "$1/home")" 2>&1
}

t30_ask() { # <json> <mode> [needle] -> token
    printf '%s' "$1" | run_with_timeout 10 node -e '
      let d = "";
      process.stdin.on("data", (c) => (d += c));
      process.stdin.on("end", () => {
        const mode = process.argv[1], needle = process.argv[2];
        let o;
        try { o = JSON.parse(d); } catch (e) { console.log("NOT-JSON:" + d.slice(0, 140)); return; }
        if (o.THREW !== undefined) { console.log("THREW:" + o.THREW); return; }
        if (mode === "drifted") { console.log(String(o.drifted)); return; }
        if (mode === "gen-key") {
          // The key itself must be gone, not merely empty: a reader that still branches on it
          // keeps a dead generator path alive in session-start.js.
          console.log("generatorUnavailable" in o ? "PRESENT:" + JSON.stringify(o.generatorUnavailable) : "absent");
          return;
        }
        if (mode === "source-unreadable") { console.log(o.sourceUnreadable === true ? "yes" : "no"); return; }
        if (mode === "missing-allow") {
          const a = ((o.missingPermissions || {}).allow) || [];
          console.log(a.indexOf(needle) !== -1 ? "listed" : "NOT-LISTED:" + a.length);
          return;
        }
        console.log("UNKNOWN-MODE");
      });
    ' -- "$2" "${3:-}" 2>&1
}

t30_setup() {
    local d
    if ! have_lib || [ ! -f "$ASSEMBLE" ]; then return; fi
    d="$(t30_root missing-ext)"
    t30_edit_deployed "$d" 'Bash(ext-hand-written *)' '--'
    T30_A="$(t30_detect "$d")"

    d="$(t30_root user-added)"
    t30_edit_deployed "$d" '--' 'Bash(user-added-locally *)'
    T30_B="$(t30_detect "$d")"

    # The SSOT is replaced by a DIRECTORY, AND a base rule is deleted: the base finding must
    # still be reported, and the broken list must not surface at all.
    d="$(t30_root list-broken)"
    t30_edit_deployed "$d" 'Bash(base-hand-written *)' '--'
    rm -f "$d/install/settings-allow-commands.txt"
    mkdir -p "$d/install/settings-allow-commands.txt"
    T30_C="$(t30_detect "$d")"

    # The SAME breakage with NOTHING ELSE wrong: a broken list alone is not drift (CPR-ORTH).
    d="$(t30_root list-broken-intact)"
    rm -f "$d/install/settings-allow-commands.txt"
    mkdir -p "$d/install/settings-allow-commands.txt"
    T30_E="$(t30_detect "$d")"

    d="$TMPROOT/t30-fake-root"
    mkdir -p "$d/hooks/lib" "$d/home/.claude"
    cp "$AGENTS_DIR/$DRIFT_MODULE_REL" "$d/hooks/lib/" 2>/dev/null || true
    printf '%s\n' '{}' > "$d/home/.claude/settings.json"
    T30_D="$(t30_detect "$d")"
}

t30_probe() { # <slot> <mode> [needle] -> token | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local v
    case "$1" in
        a) v="$T30_A" ;;
        b) v="$T30_B" ;;
        c) v="$T30_C" ;;
        d) v="$T30_D" ;;
        e) v="$T30_E" ;;
    esac
    [ -n "$v" ] || { printf 'NO-RESULT'; return; }
    t30_ask "$v" "$2" "${3:-}"
}

t30_detect_table() {
    local id slot mode want label
    while IFS='|' read -r id slot mode want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T30[$id]: $label" "$want" "$(t30_probe "$slot" "$mode")"
    done <<'T30_CASES'
ext-missing-drifted|a|drifted|true|deleting the extension rule from the deployed file is drift -- the expected set is base + extension
user-added-ok|b|drifted|false|a rule the user added to the deployed file is NOT drift: the check is one-directional containment, so a local addition is not reported as damage
broken-list-still-judges|c|drifted|true|with the SSOT list unreadable the check still judges base and extension, and catches the base rule that went missing
broken-list-no-key|c|gen-key|absent|#2264: no generatorUnavailable key is reported -- the list no longer feeds settings.json, so its breakage is not this detector's business
intact-broken-not-drifted|e|drifted|false|a broken list with base and extension INTACT is not drift
intact-broken-no-key|e|gen-key|absent|and carries no generatorUnavailable key either, so session-start has nothing generator-shaped left to print
healthy-no-key|a|gen-key|absent|CONTROL: the healthy fixture carries no such key, so the retirement is total rather than conditional
fake-root-quiet|d|drifted|false|a tree with no install layer at all does not throw -- the session-start path must survive a repo the module was merely copied into
fake-root-flag|d|source-unreadable|yes|and reports sourceUnreadable, the existing shape the fix-846 suite already pins
T30_CASES
    ROWS=$((ROWS + 1))
    assert_eq "T30[ext-missing-named]: the deleted extension rule is named in missingPermissions.allow, so the warning can say which rule went" \
        "listed" "$(t30_probe a missing-allow 'Bash(ext-hand-written *)')"
    ROWS=$((ROWS + 1))
    assert_eq "T30[broken-named]: and with the list unreadable the base finding is still named" \
        "listed" "$(t30_probe c missing-allow 'Bash(base-hand-written *)')"
    # The other direction of the same pair: slot e must name NOTHING. A classifier that
    # reported the list failure as a missing permission would fail only this row.
    ROWS=$((ROWS + 1))
    assert_eq "T30[intact-broken-nothing-named]: with base and extension intact the broken list adds no entry to missingPermissions.allow" \
        "NOT-LISTED:0" "$(t30_probe e missing-allow 'Bash(base-hand-written *)')"
}

# The last row follows the whole path rather than the module: hooks/session-start.js is where
# the user would see a warning. The hooks tree is copied into a fixture root so agentsRoot
# resolves there, never at the real repo. With the list broken and nothing drifted, the
# session start must say NOTHING about a generator (#2264: there is none to fail).
t30_session_setup() {
    local d="$TMPROOT/t30-session"
    mkdir -p "$d/home/.claude" "$d/install"
    cp -R "$AGENTS_DIR/hooks" "$d/" 2>/dev/null || true
    cp -R "$AGENTS_DIR/install" "$d/" 2>/dev/null || true
    rm -rf "$d/install/settings-allow-commands.txt"
    mkdir -p "$d/install/settings-allow-commands.txt"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(base-hand-written *)"] } }' > "$d/settings.json"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(ext-hand-written *)"] } }' > "$d/settings-extension.json"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(base-hand-written *)", "Bash(ext-hand-written *)"] } }' \
        > "$d/home/.claude/settings.json"
    T30_SESSION="$( (unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        printf '%s' '{"session_id":"test-2119-t30"}' | \
        HOME="$d/home" USERPROFILE="$(node_path "$d/home")" CLAUDE_CONFIG_DIR="$d/home/.claude" \
        run_with_timeout 30 node "$(node_path "$d/$SESSION_START_REL")") 2>&1 )"
}

t30_session_probe() { # -> quiet|GENERATOR-WARNED|sentinel
    have_lib || { missing_lib; return; }
    printf '%s' "$T30_SESSION" | run_with_timeout 10 node -e '
      let d = "";
      process.stdin.on("data", (c) => (d += c));
      process.stdin.on("end", () => {
        let o;
        try { o = JSON.parse(d); } catch (e) { o = {}; }
        const ctx = String(o.additionalContext || (o.hookSpecificOutput || {}).additionalContext || "");
        const gen = /gen-settings-allow|generator/i.test(ctx);
        console.log(gen ? "GENERATOR-WARNED:" + ctx.slice(0, 160) : "quiet");
      });
    ' 2>&1
}

t30_session_table() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T30[$id]: $label" "quiet" "$(t30_session_probe)"
    done <<'T30_SESSION_CASES'
session-no-generator-warning|hooks/session-start.js prints no generator warning when the SSOT list is broken -- the list feeds bash-guard, not the deployed settings, so there is nothing for session start to rebuild
T30_SESSION_CASES
}

t30_setup
t30_detect_table
t30_session_setup
t30_session_table
