# tests/feature-2119-settings-allow-ssot/settings-preservation.sh
# Tests: install/gen-settings-allow.js, settings.json
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T11-T12: what --write must leave alone, and the order in which it appends. Sourced AFTER
# generator.sh, whose fixture helpers this part reuses.

T11_FIXTURE=""

# T11 -- DATA PRESERVATION. The cheapest way to implement "append to permissions.allow" is to
# rebuild the document from the fields you happen to care about; that passes every case in
# write-and-drift.sh while deleting `hooks`, `env`, `statusLine` and a non-empty
# `permissions.deny` -- the one field whose loss turns a formatting bug into a permission
# grant. The fixture therefore carries sentinels in every shape settings.json really uses, and
# the assertion is deep equality of the WHOLE document except the appended allow tail.
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
    run_gen "$T11_FIXTURE" --write
}

# Comparison is delegated to node, not to `cmp`: a text diff can only say "different", which
# is exactly what --write is supposed to make the two files.
t11_probe() { # <deep|keyorder|prefix|grew> -> equal|yes|<diff detail>|sentinel
    have_gen || { missing_gen; return; }
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
        console.log(aa.length > ba.length ? "yes" : "NO-APPEND");
      }
    ' "$(node_path "$T11_FIXTURE/before.json")" "$(node_path "$T11_FIXTURE/settings.json")" "$1" \
      2>/dev/null || printf 'NODE-ERROR'
}

t11_preservation_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T11[$id]: $label" "$want" "$(t11_probe "$id")"
    done <<'T11_CASES'
deep|equal|every field except permissions.allow survives --write unchanged (env, hooks, statusLine, deny, ask, additionalDirectories, $schema, model)
keyorder|yes|the top-level and permissions key order is unchanged (a rebuilt object reorders them)
prefix|yes|the pre-existing allow entries remain the leading prefix of the new array
grew|yes|the allow array actually grew, so the three rows above are not passing on a no-op
T11_CASES
}

T12_FIXTURE=""
T12_PARTIAL=""
T12_PRE='Bash(hand-written-only *)'

# T12 -- APPEND ORDER. T6 proves a tail is appended and T4 proves the right rules exist;
# neither pins WHERE each one lands. Order is its own contract: a 143-entry diff is reviewable
# only in one predictable sequence -- SSOT file order, then template-table order, then that
# entry's bare forms. Rebuilt here from the template contract, not from the generator, and
# with a deliberately non-alphabetical SSOT so a generator that sorts its input reads
# differently from one that preserves it.
t12_expected() { # <out-file>
    {
        printf '%s\n' "$T12_PRE"
        expected_path_rules bash bin/zz-bash-tool
        expected_path_rules node bin/aa-node-tool.js
        expected_path_rules bash bin/mm-path-tool
        expected_bare_rules mm-path-tool
    } > "$1"
}

t12_make() { # <name> -> fixture dir
    local fx
    fx="$(mk_fixture "$1")"
    mk_tool "$fx" bin/zz-bash-tool env-bash
    mk_tool "$fx" bin/aa-node-tool.js env-node
    mk_tool "$fx" bin/mm-path-tool env-bash
    write_ssot "$fx" bin/zz-bash-tool bin/aa-node-tool.js bin/mm-path-tool
    printf '%s\n' 'mm-path-tool' >> "$fx/install/path-exposed-commands.txt"
    printf '%s\n' "$fx"
}

# The partial fixture is the state the real repository is actually in: a few of the generated
# spellings already exist by hand, scattered through the array rather than at its end.
t12_setup() {
    T12_FIXTURE="$(t12_make t12)"
    printf '%s\n' "$T12_PRE" > "$T12_FIXTURE/pre.txt"
    write_settings "$T12_FIXTURE" "$T12_FIXTURE/pre.txt"
    run_gen "$T12_FIXTURE" --write
    allow_dump "$T12_FIXTURE" "$T12_FIXTURE/allow.txt"
    t12_expected "$T12_FIXTURE/want.txt"

    T12_PARTIAL="$(t12_make t12-partial)"
    t12_expected "$T12_PARTIAL/full.txt"
    {
        printf '%s\n' "$T12_PRE"
        sed -n '4p;7p' "$T12_PARTIAL/full.txt"
        sed -n '12,21p' "$T12_PARTIAL/full.txt"
    } > "$T12_PARTIAL/pre.txt"
    write_settings "$T12_PARTIAL" "$T12_PARTIAL/pre.txt"
    grep -Fxv -f "$T12_PARTIAL/pre.txt" "$T12_PARTIAL/full.txt" > "$T12_PARTIAL/tail.txt"
    cat "$T12_PARTIAL/pre.txt" "$T12_PARTIAL/tail.txt" > "$T12_PARTIAL/want.txt"
    run_gen "$T12_PARTIAL" --write
    allow_dump "$T12_PARTIAL" "$T12_PARTIAL/allow.txt"
}

t12_probe() { # <full-order|partial-order|partial-no-dup> -> equal|yes|<detail>|sentinel
    have_gen || { missing_gen; return; }
    local fx n
    case "$1" in
        full-order) fx="$T12_FIXTURE" ;;
        *)          fx="$T12_PARTIAL" ;;
    esac
    if [ "$1" = "partial-no-dup" ]; then
        n="$(sort "$fx/allow.txt" 2>/dev/null | uniq -d | grep -c . )" || n=0
        [ "${n:-1}" = "0" ] && { printf 'yes'; return; }
        printf 'DUPLICATED:%s' "$(sort "$fx/allow.txt" | uniq -d | tr '\n' ' ')"
        return
    fi
    if cmp -s "$fx/want.txt" "$fx/allow.txt"; then printf 'equal'; return; fi
    printf 'DIFF:%s' "$(diff "$fx/want.txt" "$fx/allow.txt" 2>/dev/null | head -6 | tr '\n' ' ')"
}

t12_order_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T12[$id]: $label" "$want" "$(t12_probe "$id")"
    done <<'T12_CASES'
full-order|equal|the whole allow array equals SSOT order, then template order, then the bare forms
partial-order|equal|an already half-populated array keeps its own order and gains only the absent rules
partial-no-dup|yes|nothing already present is appended a second time
T12_CASES
}

t11_setup
t11_preservation_table
t12_setup
t12_order_table
