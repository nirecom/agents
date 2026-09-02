# tests/feature-2119-settings-allow-ssot/argless-and-prefix.sh
# Tests: install/lib/settings-allow-rules.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T27: the issue's own acceptance condition, pinned as strings. Sourced AFTER generator.sh.

T27_FX=""

# T27 -- THE FOUR SPELLINGS THAT WERE MEASURED DENIED. T26 proves the table is paired and T4
# proves a fixture command expands; neither says the four command lines that actually got
# denied are now allow-listed. They are asserted here as exact strings, against a deploy whose
# base and extension are EMPTY -- so the deployed allow array is the generated set and nothing
# else, which is what lets the two negative rows below mean something.
t27_setup() {
    T27_FX="$(mk_fixture t27)"
    mk_tool "$T27_FX" bin/resolve-worktree-path env-bash
    mk_tool "$T27_FX" bin/workflow/next-step env-node
    mk_tool "$T27_FX" bin/worker-dispatch-paths env-node
    mk_tool "$T27_FX" bin/confirm-off env-bash
    # The sibling that makes prefix matching unsafe: it exists on disk, it is NOT in the SSOT,
    # and a `Bash(bash bin/confirm-off*)` spelling would allow it without anyone deciding to.
    mk_tool "$T27_FX" bin/confirm-off.ps1 none
    write_ssot "$T27_FX" bin/resolve-worktree-path bin/workflow/next-step bin/worker-dispatch-paths bin/confirm-off
    write_settings "$T27_FX" --
    write_ext "$T27_FX" --
    run_gen "$T27_FX" --write
    deployed_allow_dump "$T27_FX" "$T27_FX/allow.txt"
}

t27_has() { # <rule> -> present|absent|sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    if grep -Fxq -- "$1" "$T27_FX/allow.txt" 2>/dev/null; then printf 'present'; else printf 'absent'; fi
}

t27_measured_table() {
    local id rule label
    while IFS='|' read -r id rule label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T27[$id]: $label -- $rule" "present" "$(t27_has "$rule")"
    done <<'T27_CASES'
wt-interp|Bash(bash "$AGENTS_CONFIG_DIR/bin/resolve-worktree-path")|the interpreter-plus-config-dir form of a bash tool, argument-less
wt-plain|Bash("$AGENTS_CONFIG_DIR/bin/resolve-worktree-path")|the same path with no interpreter prefix, argument-less
next-step|Bash(node bin/workflow/next-step)|the repo-relative node form -- the exact line CLAUDE.md tells the model to run after every skill
dispatch|Bash(node bin/worker-dispatch-paths)|the same form for the second measured node tool
T27_CASES
}

# The matcher is written here rather than borrowed from hooks/lib/glob-match.js on purpose:
# that helper is path-shaped (its `*` does not cross `/`, and it case-folds on win32), while a
# permission rule is matched against a whole COMMAND STRING where `/` is an ordinary character.
# Borrowing it would answer a different question than the engine asks.
t27_negative() { # <mode> -> none|yes|<offending rule>|sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    run_with_timeout 20 node -e '
      const fs = require("fs");
      const mode = process.argv[2];
      const root = process.argv[3];
      let rules = [];
      try {
        rules = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => l.length > 0);
      } catch (e) { console.log("NO-DEPLOYED-RULES"); process.exit(0); }
      if (rules.length === 0) { console.log("NO-DEPLOYED-RULES"); process.exit(0); }
      if (mode === "no-glued-star") {
        for (const r of rules) {
          for (let i = 0; i < r.length; i++) {
            if (r[i] !== "*") continue;
            const p = i === 0 ? "" : r[i - 1];
            if (p !== " " && p !== "(") { console.log("GLUED:" + r); process.exit(0); }
          }
        }
        console.log("yes");
        process.exit(0);
      }
      if (mode === "no-leading-wildcard") {
        const lead = new RegExp("\\*[/\\\\]");
        for (const r of rules) { if (lead.test(r)) { console.log("LEADING:" + r); process.exit(0); } }
        console.log("yes");
        process.exit(0);
      }
      if (mode === "root-literal") {
        const spell = [root, root.split("/").join("\\"), root.split("\\").join("/")];
        const n = rules.filter((r) => spell.some((s) => r.includes(s))).length;
        console.log(n >= 6 ? "yes" : "only:" + n);
        process.exit(0);
      }
      const target = mode === "no-injection-match"
        ? "touch owned # /agents/bin/workflow/next-step"
        : "bash bin/confirm-off.ps1";
      const inner = (r) => {
        const m = /^Bash\((.*)\)$/.exec(r);
        return m ? m[1] : null;
      };
      const toRe = (p) => new RegExp("^" + p.split("*")
        .map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$");
      for (const r of rules) {
        const p = inner(r);
        if (p === null) continue;
        if (toRe(p).test(target)) { console.log("MATCHED:" + r); process.exit(0); }
      }
      console.log("none");
    ' -- "$(node_path "$T27_FX/allow.txt")" "$1" "$(node_path "$T27_FX")" 2>&1
}

t27_negative_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T27[$id]: $label" "$want" "$(t27_negative "$id")"
    done <<'T27_NEG_CASES'
no-ps1-match|none|not one deployed rule matches the command line `bash bin/confirm-off.ps1` -- the sibling file is on disk, is not in the SSOT, and stays un-allowed
no-glued-star|yes|no deployed rule glues a wildcard to a name: every `*` follows a space or an opening paren, so no rule is a prefix match
no-leading-wildcard|yes|SET-WIDE: not one rule in the whole deployed set carries a wildcard glued to a path separator -- asserted over every rule rather than a sampled one, because a single surviving `*/agents/` spelling is a whole allow rule
no-injection-match|none|and the concrete consequence is gone: no deployed rule matches the command line `touch owned # /agents/bin/workflow/next-step`, which a leading `*` admits because a permission wildcard does not stop at a space -- an arbitrary command smuggled in front of an allow-listed path
root-literal|yes|what replaced it is the deploy-time absolute root, present in the deployed rules as a literal substring: the spellings that used to start with a wildcard now start at a path only this checkout has
T27_NEG_CASES
}

t27_setup
t27_measured_table
t27_negative_table
