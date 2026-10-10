# tests/install/feature-2119-settings-allow-ssot/drift-detection.sh
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
t30_build() { # <fixture> -- the healthy root every slot starts from (see tpl_fixture)
    local d="$1"
    mkdir -p "$d/hooks/lib"
    cp "$SCRIPT_CHECKOUT_ROOT/$DRIFT_MODULE_REL" "$d/hooks/lib/" 2>/dev/null || true
    mk_tool "$d" bin/fx-tool env-bash
    write_ssot "$d" bin/fx-tool
    printf '%s\n' 'Bash(base-hand-written *)' > "$d/pre.txt"
    write_settings "$d" "$d/pre.txt"
    printf '%s\n' 'Bash(ext-hand-written *)' > "$d/ext.txt"
    write_ext "$d" "$d/ext.txt"
    run_assemble "$d"
}

t30_root() { # <name> -> private copy of the healthy root, with a hooks/lib of its own
    tpl_fixture "t30-$1" t30 t30_build
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

# BATCHED: the request file (last argv) holds json\0mode\0needle\0 triples; one node answers
# each triple independently (its own JSON.parse) with one NUL-terminated token, in order.
T30_ASK_JS='
  const fs = require("fs");
  const parts = fs.readFileSync(process.argv[process.argv.length - 1], "utf8").split("\0");
  parts.pop();
  const ask = (d, mode, needle) => {
    let o;
    try { o = JSON.parse(d); } catch (e) { return "NOT-JSON:" + d.slice(0, 140); }
    if (o.THREW !== undefined) return "THREW:" + o.THREW;
    if (mode === "drifted") return String(o.drifted);
    // The key itself must be gone, not merely empty: a reader that still branches on it
    // keeps a dead generator path alive in session-start.js.
    if (mode === "gen-key") return "generatorUnavailable" in o ? "PRESENT:" + JSON.stringify(o.generatorUnavailable) : "absent";
    if (mode === "source-unreadable") return o.sourceUnreadable === true ? "yes" : "no";
    if (mode === "missing-allow") {
      const a = ((o.missingPermissions || {}).allow) || [];
      return a.indexOf(needle) !== -1 ? "listed" : "NOT-LISTED:" + a.length;
    }
    return "UNKNOWN-MODE";
  };
  const out = [];
  for (let i = 0; i + 2 < parts.length; i += 3) {
    let r;
    try { r = ask(parts[i], parts[i + 1], parts[i + 2]); } catch (e) { r = "ERROR:ask-failed"; }
    out.push(r + "\0");
  }
  process.stdout.write(out.join(""));
'

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
    cp "$SCRIPT_CHECKOUT_ROOT/$DRIFT_MODULE_REL" "$d/hooks/lib/" 2>/dev/null || true
    printf '%s\n' '{}' > "$d/home/.claude/settings.json"
    T30_D="$(t30_detect "$d")"
}

T30_NAMES=()
T30_WANTS=()
T30_GOT=()
T30_REQ_IDX=()
T30_REQ_FILE=""

# Queues one row. A sentinel or an empty slot is settled here in bash; every other row becomes
# one json/mode/needle triple in the request file, answered later by t30_run.
t30_row() { # <name> <want> <slot> <mode> [needle]
    local v
    T30_NAMES+=("$1"); T30_WANTS+=("$2")
    if ! have_lib; then T30_GOT+=("$(missing_lib)"); return; fi
    if [[ ! -f "$ASSEMBLE" ]]; then T30_GOT+=("$(missing_assemble)"); return; fi
    case "$3" in
        a) v="$T30_A" ;;
        b) v="$T30_B" ;;
        c) v="$T30_C" ;;
        d) v="$T30_D" ;;
        e) v="$T30_E" ;;
    esac
    if [[ -z "$v" ]]; then T30_GOT+=("NO-RESULT"); return; fi
    T30_GOT+=("")
    T30_REQ_IDX+=("$((${#T30_GOT[@]} - 1))")
    printf '%s\0%s\0%s\0' "$v" "$4" "${5:-}" >> "$T30_REQ_FILE"
}

t30_run() { # answers every queued triple in one node, then asserts every row in table order
    local i k
    if [[ "${#T30_REQ_IDX[@]}" -gt 0 ]]; then
        nul_records "T30 drift ask" "${#T30_REQ_IDX[@]}" \
            run_with_timeout 30 node -e "$T30_ASK_JS" "$(node_path "$T30_REQ_FILE")"
        for k in "${!T30_REQ_IDX[@]}"; do T30_GOT[${T30_REQ_IDX[$k]}]="${NUL_RECS[$k]}"; done
    fi
    for i in "${!T30_NAMES[@]}"; do
        ROWS=$((ROWS + 1))
        assert_eq "${T30_NAMES[$i]}" "${T30_WANTS[$i]}" "${T30_GOT[$i]}"
    done
}

# Each span below is its own batch: reset the queue, queue rows, then t30_run.
t30_batch_begin() { # <batch-id>
    T30_NAMES=(); T30_WANTS=(); T30_GOT=(); T30_REQ_IDX=()
    T30_REQ_FILE="$TMPROOT/t30-ask-req-$1.bin"
    : > "$T30_REQ_FILE"
}

t30_queue_rows() { # stdin: id|slot|mode|want|label
    local id slot mode want label
    while IFS='|' read -r id slot mode want label; do
        [ -n "$id" ] || continue
        t30_row "T30[$id]: $label" "$want" "$slot" "$mode"
    done
}

t30_setup

# Target: the expected set is base + extension, which is the assembly module's merge.
case_begin "t30-expected-set-includes-extension" "install/lib/settings-assembly.js"
t30_batch_begin expected-set
t30_queue_rows <<'T30_EXT_CASES'
ext-missing-drifted|a|drifted|true|deleting the extension rule from the deployed file is drift -- the expected set is base + extension
T30_EXT_CASES
t30_row "T30[ext-missing-named]: the deleted extension rule is named in missingPermissions.allow, so the warning can say which rule went" \
    "listed" a missing-allow 'Bash(ext-hand-written *)'
t30_run
case_end

case_begin "t30-detect-drift" "hooks/lib/settings-drift.js"
t30_batch_begin detect
t30_queue_rows <<'T30_CASES'
user-added-ok|b|drifted|false|a rule the user added to the deployed file is NOT drift: the check is one-directional containment, so a local addition is not reported as damage
broken-list-still-judges|c|drifted|true|with the SSOT list unreadable the check still judges base and extension, and catches the base rule that went missing
broken-list-no-key|c|gen-key|absent|#2264: no generatorUnavailable key is reported -- the list no longer feeds settings.json, so its breakage is not this detector's business
intact-broken-not-drifted|e|drifted|false|a broken list with base and extension INTACT is not drift
intact-broken-no-key|e|gen-key|absent|and carries no generatorUnavailable key either, so session-start has nothing generator-shaped left to print
healthy-no-key|a|gen-key|absent|CONTROL: the healthy fixture carries no such key, so the retirement is total rather than conditional
fake-root-quiet|d|drifted|false|a tree with no install layer at all does not throw -- the session-start path must survive a repo the module was merely copied into
fake-root-flag|d|source-unreadable|yes|and reports sourceUnreadable, the existing shape the fix-846 suite already pins
T30_CASES
t30_row "T30[broken-named]: and with the list unreadable the base finding is still named" \
    "listed" c missing-allow 'Bash(base-hand-written *)'
# The other direction of the same pair: slot e must name NOTHING. A classifier that
# reported the list failure as a missing permission would fail only this row.
t30_row "T30[intact-broken-nothing-named]: with base and extension intact the broken list adds no entry to missingPermissions.allow" \
    "NOT-LISTED:0" e missing-allow 'Bash(base-hand-written *)'
t30_run
case_end

# The last row follows the whole path rather than the module: hooks/session-start.js is where
# the user would see a warning. The hooks tree is copied into a fixture root so agentsRoot
# resolves there, never at the real repo. With the list broken and nothing drifted, the
# session start must say NOTHING about a generator (#2264: there is none to fail).
case_begin "t30-session-start-quiet" "hooks/session-start.js"
t30_session_setup() {
    local d="$TMPROOT/t30-session"
    mkdir -p "$d/home/.claude" "$d/install"
    cp -R "$SCRIPT_CHECKOUT_ROOT/hooks" "$d/" 2>/dev/null || true
    cp -R "$SCRIPT_CHECKOUT_ROOT/install" "$d/" 2>/dev/null || true
    rm -rf "$d/install/settings-allow-commands.txt"
    mkdir -p "$d/install/settings-allow-commands.txt"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(base-hand-written *)"] } }' > "$d/settings.json"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(ext-hand-written *)"] } }' > "$d/settings-extension.json"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(base-hand-written *)", "Bash(ext-hand-written *)"] } }' \
        > "$d/home/.claude/settings.json"
    T30_SESSION="$( (unset CLAUDE_CODE_SESSION_ID && \
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

t30_session_setup
t30_session_table
case_end
