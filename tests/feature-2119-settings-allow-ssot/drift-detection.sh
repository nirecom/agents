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
# provider). This path runs at every session start, so it must never throw and never block:
# a generator it cannot use degrades to "judge what base and extension still let me judge, and
# say so", not to silence and not to a crash. The rows below separate the five situations that
# a single "it didn't blow up" check would blur into one.
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
        if (mode === "generator-unavailable") {
          // The plan carries the REASON, not a boolean: settings-drift.js adds
          // `generatorUnavailable: generatorError` and session-start.js prints
          // `"  reason: " + d.generatorUnavailable`. A bare `true` would satisfy the flag
          // and render an empty reason line, so the wrong shape reports as itself.
          const g = o.generatorUnavailable;
          if (g === undefined) { console.log("no"); return; }
          console.log(typeof g === "string" && g.length > 0 ? "yes" : "BAD-SHAPE:" + JSON.stringify(g));
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
    d="$(t30_root missing-generated)"
    t30_edit_deployed "$d" 'Bash(bash bin/fx-tool)' '--'
    T30_A="$(t30_detect "$d")"

    d="$(t30_root user-added)"
    t30_edit_deployed "$d" '--' 'Bash(user-added-locally *)'
    T30_B="$(t30_detect "$d")"

    # The SSOT is replaced by a DIRECTORY: unreadable at the OS level, so the failure happens
    # inside the provider rather than being something the fixture could have spelled as data.
    d="$(t30_root generator-broken)"
    t30_edit_deployed "$d" 'Bash(base-hand-written *)' '--'
    rm -f "$d/install/settings-allow-commands.txt"
    mkdir -p "$d/install/settings-allow-commands.txt"
    T30_C="$(t30_detect "$d")"

    # The SAME breakage with NOTHING ELSE wrong. Slot c breaks the generator AND deletes a base
    # rule, so `drifted:true` there is equally explained by either cause; only the pair of
    # fixtures makes the two independently observable (CPR-ORTH, protection-fix-tests Pattern 4).
    # Base and extension reached the deployed file before the break, so one-directional
    # containment finds nothing missing while the generator is still unusable.
    d="$(t30_root generator-broken-intact)"
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
gen-missing-drifted|a|drifted|true|deleting ONE generated rule from the deployed file is drift -- the detector now judges the generated half, not just base and extension
user-added-ok|b|drifted|false|a rule the user added to the deployed file is NOT drift: the check is one-directional containment, so a local addition is not reported as damage
broken-still-judges|c|drifted|true|with the generator unusable the check carries on from base and extension alone, and still catches the base rule that went missing
broken-flag|c|generator-unavailable|yes|and says so: generatorUnavailable carries the REASON string session-start.js prints, so "no findings" is never confused with "could not look"
intact-broken-not-drifted|e|drifted|false|a broken generator with base and extension INTACT is not drift -- the expected set shrinks to what base and extension still supply, and the deployed file already contains all of it
intact-broken-flag|e|generator-unavailable|yes|yet the same run still flags the unusable generator: the flag tracks the generator, not the verdict, so `drifted:false` plus the flag is a reachable state
healthy-flag-absent|a|generator-unavailable|no|CONTROL: a usable generator sets no flag at all, so the two rows above cannot be passing on a field that is simply always present
fake-root-quiet|d|drifted|false|a tree with no install layer at all does not throw -- the session-start path must survive a repo the module was merely copied into
fake-root-flag|d|source-unreadable|yes|and reports sourceUnreadable, the existing shape the fix-846 suite already pins
T30_CASES
    ROWS=$((ROWS + 1))
    assert_eq "T30[gen-missing-named]: the deleted generated rule is named in missingPermissions.allow, so the warning can say which rule went" \
        "listed" "$(t30_probe a missing-allow 'Bash(bash bin/fx-tool)')"
    ROWS=$((ROWS + 1))
    assert_eq "T30[broken-named]: and with the generator unusable the surviving base finding is still named" \
        "listed" "$(t30_probe c missing-allow 'Bash(base-hand-written *)')"
    # The other direction of the same pair: slot c names the base rule because the fixture
    # removed it, slot e must name NOTHING. A classifier that reported the generator failure
    # itself as a missing permission would pass every row above and fail only this one.
    ROWS=$((ROWS + 1))
    assert_eq "T30[intact-broken-nothing-named]: with base and extension intact the unusable generator adds no entry to missingPermissions.allow -- the failure is reported as generatorUnavailable, never as a phantom missing rule" \
        "NOT-LISTED:0" "$(t30_probe e missing-allow 'Bash(base-hand-written *)')"
}

# The last row follows the whole path rather than the module: a flag nothing reads is the same
# as no flag at all, and hooks/session-start.js is where the user would ever see it. The hooks
# tree is copied into a fixture root so agentsRoot resolves there, never at the real repo.
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

t30_session_probe() { # -> warned|NOT-WARNED|sentinel
    have_lib || { missing_lib; return; }
    printf '%s' "$T30_SESSION" | run_with_timeout 10 node -e '
      let d = "";
      process.stdin.on("data", (c) => (d += c));
      process.stdin.on("end", () => {
        let o;
        try { o = JSON.parse(d); } catch (e) { console.log("NOT-JSON:" + d.slice(0, 140)); return; }
        const ctx = String(o.additionalContext || (o.hookSpecificOutput || {}).additionalContext || "");
        const names = /allow[- ]?rule|gen-settings-allow|settings-allow-commands|generat/i.test(ctx);
        const says = /fail|unavailable|could not|cannot|error/i.test(ctx);
        console.log(names && says ? "warned" : "NOT-WARNED:" + ctx.slice(0, 160));
      });
    ' 2>&1
}

t30_session_table() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T30[$id]: $label" "warned" "$(t30_session_probe)"
    done <<'T30_SESSION_CASES'
session-warning|hooks/session-start.js surfaces the unusable generator in additionalContext, so a machine whose allow rules cannot be rebuilt tells its user instead of degrading quietly
T30_SESSION_CASES
}

t30_setup
t30_detect_table
t30_session_setup
t30_session_table
