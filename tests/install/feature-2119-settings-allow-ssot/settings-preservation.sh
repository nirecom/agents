# tests/feature-2119-settings-allow-ssot/settings-preservation.sh
# Tests: install/lib/settings-assembly.js, install/lib/settings-deploy.js, install/assemble-settings.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T11-T12: what a deploy must carry through from the base document, and the order in which
# the sources land in the deployed allow array. Sourced AFTER fixture.sh, whose helpers this
# part reuses. Since #2264 nothing is generated: the allow array is base, then extension.

T11_FIXTURE=""
T11_EXT='Bash(extension-written *)'

# T11 -- DATA PRESERVATION. The cheapest merge builds a fresh document out of the fields it
# happens to care about, dropping `hooks`, `env`, `statusLine` and a non-empty
# `permissions.deny` -- the one field whose loss turns a formatting bug into a permission
# grant. The base fixture carries sentinels in every shape settings.json really uses, and
# the assertion is deep equality of the whole document except the allow array.
rich_settings() { # <fixture>
    node -e '
      const fs = require("fs");
      const o = {
        "$schema": "https://json.schemastore.org/claude-code-settings.json",
        model: "sentinel-model",
        cleanupPeriodDays: 42,
        env: { SENTINEL_ENV: "keep-me", SECOND_ENV: "also-keep-me" },
        permissions: {
          allow: ["Bash(hand-written-one *)", "Bash(hand-written-two *)"],
          deny: ["Bash(rm -rf *)", "Read(./.env)"],
          ask: ["Bash(git push *)"],
          defaultMode: "default",
          additionalDirectories: ["/sentinel/extra/dir"]
        },
        hooks: {
          PreToolUse: [
            { matcher: "Bash", hooks: [{ type: "command", command: "sentinel-hook.js" }] }
          ]
        },
        statusLine: { type: "command", command: "sentinel-status" }
      };
      fs.writeFileSync(process.argv[1], JSON.stringify(o, null, 2) + "\n");
    ' "$(node_path "$1/settings.json")"
}

t11_setup() {
    T11_FIXTURE="$(mk_fixture t11)"
    mk_tool "$T11_FIXTURE" bin/fx-tool env-bash
    write_ssot "$T11_FIXTURE" bin/fx-tool
    rich_settings "$T11_FIXTURE"
    cp "$T11_FIXTURE/settings.json" "$T11_FIXTURE/before.json"
    # The extension contributes ONLY permissions.allow, so any top-level key that reaches the
    # deployed file came from the base.
    printf '%s\n' "$T11_EXT" > "$T11_FIXTURE/ext.txt"
    write_ext "$T11_FIXTURE" "$T11_FIXTURE/ext.txt"
    run_assemble "$T11_FIXTURE"
}

# Comparison is delegated to node, not to `cmp`: a text diff can only say "different", which
# is exactly what the deploy is supposed to make the two files.
t11_probe() { # <deep|keyorder|prefix|grew> -> equal|yes|<diff detail>|sentinel
    have_lib || { missing_lib; return; }
    node -e '
      const fs = require("fs");
      const mode = process.argv[3];
      let before, after;
      try {
        before = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        after = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
      } catch (e) { console.log("UNPARSEABLE:" + e.message); process.exit(0); }
      const strip = (o) => {
        const c = JSON.parse(JSON.stringify(o));
        if (c.permissions) delete c.permissions.allow;
        return c;
      };
      const ba = ((before.permissions || {}).allow) || [];
      const aa = ((after.permissions || {}).allow) || [];
      if (mode === "deep") {
        const b = JSON.stringify(strip(before)), a = JSON.stringify(strip(after));
        console.log(b === a ? "equal" : "LOST-OR-CHANGED: before=" + b + " after=" + a);
      } else if (mode === "keyorder") {
        const b = Object.keys(before).join(",") + "|" + Object.keys(before.permissions || {}).join(",");
        const a = Object.keys(after).join(",") + "|" + Object.keys(after.permissions || {}).join(",");
        console.log(b === a ? "yes" : "REORDERED: before=" + b + " after=" + a);
      } else if (mode === "prefix") {
        console.log(ba.every((v, i) => aa[i] === v) ? "yes" : "PREFIX-BROKEN");
      } else {
        console.log(aa.length === ba.length + 1 ? "yes" : "LENGTH:" + ba.length + "->" + aa.length);
      }
    ' "$(node_path "$T11_FIXTURE/before.json")" "$(node_path "$(deployed_file "$T11_FIXTURE")")" "$1" \
      2>/dev/null || printf 'NODE-ERROR'
}

t11_preservation_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T11[$id]: $label" "$want" "$(t11_probe "$id")"
    done <<'T11_CASES'
deep|equal|every base field except permissions.allow reaches the deployed file unchanged (env, hooks, statusLine, deny, ask, additionalDirectories, $schema, model)
keyorder|yes|the top-level and permissions key order is unchanged (a rebuilt object reorders them)
prefix|yes|the base allow entries remain the leading prefix of the deployed array
grew|yes|the deployed allow array grew by exactly the one extension entry -- positive control, and nothing generated rode along
T11_CASES
}

T12_FIXTURE=""
T12_PRE='Bash(hand-written-only *)'
T12_EXT='Bash(extension-only *)'

# T12 -- SOURCE ORDER. The deployed array is base then extension, and since #2264 NOTHING
# else: the SSOT list feeds bash-guard at runtime, not settings.json. A fixture SSOT that
# lists tools (one of them PATH-exposed) is still present so a leftover injection path would
# have something to inject and show up here.
t12_setup() {
    local fx
    fx="$(mk_fixture t12)"
    T12_FIXTURE="$fx"
    mk_tool "$fx" bin/zz-bash-tool env-bash
    mk_tool "$fx" bin/aa-node-tool.js env-node
    mk_tool "$fx" bin/mm-path-tool env-bash
    write_ssot "$fx" bin/zz-bash-tool bin/aa-node-tool.js bin/mm-path-tool
    printf '%s\n' 'mm-path-tool' >> "$fx/install/path-exposed-commands.txt"
    printf '%s\n' "$T12_PRE" > "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    printf '%s\n' "$T12_EXT" > "$fx/ext.txt"
    write_ext "$fx" "$fx/ext.txt"
    cat "$fx/pre.txt" "$fx/ext.txt" > "$fx/want.txt"
    run_assemble "$fx"
    deployed_allow_dump "$fx" "$fx/allow.txt"
}

t12_probe() { # <full-order|no-generated|rc> -> equal|absent|0|<detail>|sentinel
    have_lib || { missing_lib; return; }
    local fx="$T12_FIXTURE"
    case "$1" in
        rc) printf '%s' "$ASM_RC_T12" ;;
        no-generated)
            if grep -Eq 'zz-bash-tool|aa-node-tool|mm-path-tool' "$fx/allow.txt" 2>/dev/null; then
                printf 'PRESENT:%s' "$(grep -E 'zz-bash-tool|aa-node-tool|mm-path-tool' "$fx/allow.txt" | head -3 | tr '\n' ' ')"
            else
                printf 'absent'
            fi
            ;;
        full-order)
            if cmp -s "$fx/want.txt" "$fx/allow.txt"; then printf 'equal'; return; fi
            printf 'DIFF:%s' "$(diff "$fx/want.txt" "$fx/allow.txt" 2>/dev/null | head -6 | tr '\n' ' ')"
            ;;
    esac
}

t12_order_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T12[$id]: $label" "$want" "$(t12_probe "$id")"
    done <<'T12_CASES'
rc|0|a base + extension deploy with a populated SSOT list exits 0
full-order|equal|the deployed allow array is exactly base, then extension -- nothing appended after them
no-generated|absent|no rule naming an SSOT-listed tool reaches the deployed file (#2264: the list feeds bash-guard, not settings.json)
T12_CASES
}

t11_setup
t11_preservation_table
t12_setup
ASM_RC_T12="$ASM_RC"
t12_order_table
