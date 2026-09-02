# tests/feature-2119-settings-allow-ssot/merger-contract.sh
# Tests: install/lib/settings-assembly.js, install/assemble-settings.js
# Tags: install, settings, permissions, merge, scope:issue-specific, pwsh-not-required, TL2
# T34: mergeSettings beyond permissions.allow. Sourced by tests/feature-2119-settings-allow-ssot.sh,
# which owns PASS/FAIL/ROWS and assert_eq; the fixture helpers come from generator.sh.

T34_FX=""
T34_RC="unrun"

# WHY A SEPARATE PART. settings-preservation.sh drives the extension through `permissions.allow`
# only -- the one key the generated rules also land in. Extraction into settings-assembly.js moves
# the merge of every OTHER key across a module boundary, and a merge that silently drops `hooks`
# or lets base win over extension is invisible to an allow-only fixture while quietly disarming
# the developer's hooks. Wants below are read off the CURRENT install/assemble-settings.js:
# arrays concatenate base-then-extension, env/attribution are Object.assign(base, ext), and
# everything else is extension-wins.

t34_write_pair() { # <fixture>
    node -e '
      const fs = require("fs");
      fs.writeFileSync(process.argv[1], JSON.stringify({
        model: "base-model",
        cleanupPeriodDays: 7,
        env: { BASE_ONLY: "base", SHARED_ENV: "from-base" },
        attribution: { BASE_ATTR: "base", SHARED_ATTR: "from-base" },
        permissions: {
          allow: ["Bash(base-allow *)"], deny: ["Bash(base-deny *)"],
          ask: ["Bash(base-ask *)"], additionalDirectories: ["/base/dir"],
          defaultMode: "default"
        },
        hooks: { PreToolUse: [{ matcher: "BaseMatcher", hooks: [{ type: "command", command: "base-hook.js" }] }] }
      }, null, 2) + "\n");
      fs.writeFileSync(process.argv[2], JSON.stringify({
        model: "ext-model",
        env: { SHARED_ENV: "from-ext", EXT_ONLY: "ext" },
        attribution: { SHARED_ATTR: "from-ext", EXT_ATTR: "ext" },
        permissions: {
          allow: ["Bash(ext-allow *)"], deny: ["Bash(ext-deny *)"],
          ask: ["Bash(ext-ask *)"], additionalDirectories: ["/ext/dir"],
          defaultMode: "acceptEdits"
        },
        hooks: {
          PreToolUse: [{ matcher: "ExtMatcher", hooks: [{ type: "command", command: "ext-hook.js" }] }],
          SessionStart: [{ matcher: "", hooks: [{ type: "command", command: "ext-start.js" }] }]
        }
      }, null, 2) + "\n");
    ' "$(node_path "$1/settings.json")" "$(node_path "$1/settings-extension.json")"
}

t34_setup() {
    T34_FX="$(mk_fixture t34)"
    mk_tool "$T34_FX" bin/fx-tool env-bash
    write_ssot "$T34_FX" bin/fx-tool
    t34_write_pair "$T34_FX"
    run_assemble "$T34_FX"
    T34_RC="$ASM_RC"
}

t34_probe() { # <field> -> value | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    node -e '
      const fs = require("fs");
      let d = null;
      try { d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
      catch (e) { d = null; }
      if (d === null) {
        process.stdout.write("UNPARSEABLE");
      } else {
        const p = d.permissions || {}, h = d.hooks || {};
        const pick = (o, ks) => ks.map((k) => String((o || {})[k])).join("~");
        const evt = (n) => ((h[n] || [])[0] || { hooks: [] }).hooks.map((x) => x.command).join(",");
        const out = {
          "hooks-concat": (h.PreToolUse || []).map((x) => x.matcher).join(","),
          "hooks-new-event": evt("SessionStart"),
          "deny-concat": (p.deny || []).join(","),
          "ask-concat": (p.ask || []).join(","),
          "adddirs-concat": (p.additionalDirectories || []).join(","),
          "perm-scalar": String(p.defaultMode),
          "env-merge": pick(d.env, ["BASE_ONLY", "SHARED_ENV", "EXT_ONLY"]),
          "attribution-merge": pick(d.attribution, ["BASE_ATTR", "SHARED_ATTR", "EXT_ATTR"]),
          "top-scalar": String(d.model),
          "top-base-only": String(d.cleanupPeriodDays)
        };
        const v = out[process.argv[2]];
        process.stdout.write(v === undefined ? "NO-SUCH-FIELD" : v);
      }
    ' "$(node_path "$(deployed_file "$T34_FX")")" "$1" 2>/dev/null || printf 'PROBE-FAILED'
}

# The table is `!`-delimited: two of the wants are themselves `~`-joined triples and several
# carry a literal `|`-free rule string, so the usual pipe would split a want in half.
t34_merge_table() {
    local id want label
    ROWS=$((ROWS + 1))
    assert_eq "T34[healthy-rc]: base + extension assemble and deploy cleanly (every row below reads that deployment)" \
        "0" "$T34_RC"
    while IFS='!' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T34[$id]: $label" "$want" "$(t34_probe "$id")"
    done <<'T34_CASES'
hooks-concat!BaseMatcher,ExtMatcher!an event present in BOTH files concatenates base-then-extension -- an extension hook must never REPLACE the repository's own
hooks-new-event!ext-start.js!an event the base does not declare at all arrives from the extension intact
deny-concat!Bash(base-deny *),Bash(ext-deny *)!permissions.deny concatenates too: a personal deny rule may only ADD to the repository's denials
ask-concat!Bash(base-ask *),Bash(ext-ask *)!permissions.ask concatenates (CPR-ORTH: allow is not the only permissions array)
adddirs-concat!/base/dir,/ext/dir!permissions.additionalDirectories concatenates
perm-scalar!acceptEdits!a SCALAR under permissions is extension-wins, not concatenated -- the array rule must not leak onto non-array keys
env-merge!base~from-ext~ext!env is an object merge: the base-only key survives, the shared key takes the extension value, the extension-only key is added
attribution-merge!base~from-ext~ext!attribution merges by the same rule (CPR-ORTH: the two object-merged keys are treated alike)
top-scalar!ext-model!a top-level scalar is extension-wins
top-base-only!7!a top-level key the extension never mentions survives the merge untouched
T34_CASES
}

# The error half. A malformed extension must not be partially applied: the previous deployment is
# what the developer's live session is running on, so a half-merged file is worse than no merge.
t34_bad_case() { # <bad-json|non-object|perm-array> -> "rc/state" | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local fx target before after rcv state
    fx="$(mk_fixture "t34-$1")"
    mk_tool "$fx" bin/fx-tool env-bash
    write_ssot "$fx" bin/fx-tool
    t34_write_pair "$fx"
    run_assemble "$fx"
    target="$(deployed_file "$fx")"
    before="$(file_digest "$target")"
    case "$1" in
        bad-json)   printf '%s\n' '{ "permissions": { "allow": [ }' > "$fx/settings-extension.json" ;;
        non-object) printf '%s\n' '"an extension that is a bare JSON string"' > "$fx/settings-extension.json" ;;
        perm-array) printf '%s\n' '{ "permissions": ["Bash(array-where-object-expected *)"] }' > "$fx/settings-extension.json" ;;
    esac
    run_assemble "$fx"
    rcv="nonzero"; [ "$ASM_RC" -eq 0 ] && rcv="ZERO"
    after="$(file_digest "$target")"
    state="MODIFIED"; [ "$before" = "$after" ] && state="unchanged"
    printf '%s/%s' "$rcv" "$state"
}

t34_bad_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T34[$id]: $label" "$want" "$(t34_bad_case "$id")"
    done <<'T34_BAD_CASES'
bad-json|nonzero/unchanged|an extension that is not valid JSON stops the deploy and leaves the prior deployed file byte-identical
non-object|nonzero/unchanged|an extension that parses to a non-object is rejected rather than merged key-by-key over a string
perm-array|nonzero/unchanged|an extension whose permissions is an ARRAY where an object is expected is rejected, not index-merged into nonsense keys
T34_BAD_CASES
}

t34_setup
t34_merge_table
t34_bad_table
