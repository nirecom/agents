# tests/feature-2119-settings-allow-ssot/real-spellings-gone.sh
# Tests: install/lib/settings-assembly.js, install/lib/settings-deploy.js
# Tags: install, settings, permissions, assembly, regression, migration, scope:issue-specific, pwsh-not-required, TL2
# T52: MIGRATION PIN over the REAL lists. T51 proves the pin on one synthetic entry; this case
# feeds every real install/settings-allow-commands.txt entry and the real
# install/path-exposed-commands.txt into a fixture deploy, so an entry whose spelling some leftover
# still generates cannot hide behind T51's single row. Base and extension stay EMPTY: the repo's
# own settings.json carries hand-written `Bash(<cmd> *)` rules, which would make the
# generated-shape count below meaningless.

T52_FIXTURE=""
T52_GENERATED_RE='^Bash\(.*[[:space:]]\*\)$'
T52_ENTRIES=""
T52_PATH_ENTRIES=""

t52_setup() {
    T52_FIXTURE="$(mk_fixture t52)"
    T52_ENTRIES="$(ssot_entries "$SSOT")"
    T52_PATH_ENTRIES="$(ssot_entries "$PATH_SSOT")"
    local e
    # The real tools are copied so the fixture carries their real shebangs.
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        mkdir -p "$(dirname "$T52_FIXTURE/$e")"
        cp "$AGENTS_DIR/$e" "$T52_FIXTURE/$e" 2>/dev/null || mk_tool "$T52_FIXTURE" "$e" env-node
    done <<< "$T52_ENTRIES"
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        cp "$AGENTS_DIR/bin/$e" "$T52_FIXTURE/bin/$e" 2>/dev/null || mk_tool "$T52_FIXTURE" "bin/$e" env-bash
    done <<< "$T52_PATH_ENTRIES"
    printf '%s\n' "$T52_ENTRIES" > "$T52_FIXTURE/install/settings-allow-commands.txt"
    printf '%s\n' "$T52_PATH_ENTRIES" > "$T52_FIXTURE/install/path-exposed-commands.txt"
    write_settings "$T52_FIXTURE" --
    write_ext "$T52_FIXTURE" --
}

# <allow-list-file> -> none | every retired spelling of a real entry found in the list. Spellings
# are compared as whole strings in node, so no entry is ever interpreted as a regex.
t52_retired_spellings_in() {
    run_with_timeout 30 node -e '
      const fs = require("fs");
      const [allowFile, ssotFile, pathFile] = process.argv.slice(1);
      const read = (f) => { try { return fs.readFileSync(f, "utf8").split("\n").filter(Boolean); } catch (_e) { return []; } };
      const allow = new Set(read(allowFile));
      const bare = new Set(read(pathFile));
      const hits = [];
      for (const e of read(ssotFile)) {
        const names = [e];
        const base = e.replace(/^bin\//, "");
        if (e.startsWith("bin/") && bare.has(base)) names.push(base);
        for (const n of names) for (const pre of ["", "bash ", "node "]) {
          for (const r of ["Bash(" + pre + n + " *)", "Bash(" + pre + n + ")"]) if (allow.has(r)) hits.push(r);
        }
      }
      process.stdout.write(hits.length ? hits.join(" ") : "none");
    ' "$(node_path "$1")" "$(node_path "$T52_FIXTURE/install/settings-allow-commands.txt")" \
      "$(node_path "$T52_FIXTURE/install/path-exposed-commands.txt")" 2>/dev/null || printf '<PROBE-FAILED>'
}

t52_generated_count() { # <allow-list-file> -> count of `Bash(<...> *)` entries
    grep -c -E -- "$T52_GENERATED_RE" "$1" 2>/dev/null || true
}

t52_assembly() {
    local n
    n="$(printf '%s\n' "$T52_ENTRIES" | grep -c .)"
    assert_eq "T52[assembly]: the real SSOT yields entries, so the rows below are not vacuous" \
        "nonzero" "$([ "$n" -gt 0 ] && printf nonzero || printf 'zero')"
    have_lib || { assert_eq "T52[assembly]: assembled allow list carries no retired spelling" "none" "$(missing_lib)"; return; }
    local out="$T52_FIXTURE/assembled-allow.txt" rc=0
    run_with_timeout 30 node -e '
      const path = require("path"), fs = require("fs");
      const [root, out] = process.argv.slice(1);
      const a = require(path.join(root, "install", "lib", "settings-assembly.js"));
      const r = a.buildAssembledSettings({ agentsRoot: root });
      const allow = (((r && r.settings) || {}).permissions || {}).allow || [];
      fs.writeFileSync(out, allow.join("\n") + (allow.length ? "\n" : ""));
    ' "$(node_path "$T52_FIXTURE")" "$(node_path "$out")" >/dev/null 2>&1 || rc=$?
    assert_eq "T52[assembly]: buildAssembledSettings ran over the real SSOT lists" "0" "$rc"
    assert_eq "T52[assembly]: assembled allow list carries no retired spelling of a real SSOT entry" \
        "none" "$(t52_retired_spellings_in "$out")"
    assert_eq "T52[assembly]: assembled allow list has zero \`Bash(<cmd> *)\` entries" \
        "0" "$(t52_generated_count "$out")"
}

t52_deploy() {
    run_assemble "$T52_FIXTURE"
    assert_eq "T52[deploy]: the deploy CLI exits 0 over the real SSOT lists (out: $ASM_OUT)" "0" "$ASM_RC"
    local deployed="absent"
    [ -f "$(deployed_file "$T52_FIXTURE")" ] && deployed="present"
    assert_eq "T52[deploy]: a deployed settings.json exists, so the next rows are not vacuous" "present" "$deployed"
    deployed_allow_dump "$T52_FIXTURE" "$T52_FIXTURE/deployed-allow.txt"
    assert_eq "T52[deploy]: deployed allow list carries no retired spelling of a real SSOT entry" \
        "none" "$(t52_retired_spellings_in "$T52_FIXTURE/deployed-allow.txt")"
    assert_eq "T52[deploy]: deployed allow list has zero \`Bash(<cmd> *)\` entries" \
        "0" "$(t52_generated_count "$T52_FIXTURE/deployed-allow.txt")"
}

# T53: the developer's REAL deployed settings.json, located by the module's own
# deployedSettingsPath() under the home the canary replaced, and READ only. The real deployment
# is built from the $AGENTS_CONFIG_DIR checkout, so from any other checkout (a worktree before
# merge) its contents say nothing about this revision and the case skips. Hand-written
# `Bash(<cmd> *)` rules from base/extension are legitimate; only ones the checkout does not own
# count. Prints: absent | foreign-checkout | present <count>.
t53_probe_real_deploy() { # <dump-file>
    run_with_timeout 30 node -e '
      const fs = require("fs"), path = require("path");
      const [realHome, realProfile, root, dump] = process.argv.slice(1);
      if (realHome) process.env.HOME = realHome;
      if (realProfile) process.env.USERPROFILE = realProfile;
      const a = require(path.join(root, "install", "lib", "settings-assembly.js"));
      const deployed = a.deployedSettingsPath();
      if (!fs.existsSync(deployed)) { process.stdout.write("absent"); process.exit(0); }
      const real = (p) => { try { return fs.realpathSync(p); } catch (_e) { return null; } };
      const norm = (p) => (p && process.platform === "win32" ? p.toLowerCase() : p);
      const owner = norm(real(process.env.AGENTS_CONFIG_DIR || ""));
      if (!owner || owner !== norm(real(root))) { process.stdout.write("foreign-checkout"); process.exit(0); }
      const allow = (JSON.parse(fs.readFileSync(deployed, "utf8")).permissions || {}).allow || [];
      fs.writeFileSync(dump, allow.join("\n") + (allow.length ? "\n" : ""));
      const own = new Set(((a.buildAssembledSettings({ agentsRoot: root }).settings || {}).permissions || {}).allow || []);
      const extra = allow.filter((e) => /^Bash\(.*\s\*\)$/.test(e) && !own.has(e));
      process.stdout.write("present " + extra.length);
    ' "$(node_path "$CANARY_REAL_HOME")" "$CANARY_REAL_USERPROFILE" "$(node_path "$AGENTS_DIR")" \
      "$(node_path "$1")" 2>/dev/null || printf '<PROBE-FAILED>'
}

t53_real_deploy() {
    local dump="$T52_FIXTURE/real-deployed-allow.txt" got
    got="$(t53_probe_real_deploy "$dump")"
    case "$got" in
        absent)
            assert_eq "T53[real-deploy]: real settings.json not found — skipping" "skip" "skip"
            return ;;
        foreign-checkout)
            assert_eq "T53[real-deploy]: real settings.json was deployed from \$AGENTS_CONFIG_DIR, not this checkout — skipping" "skip" "skip"
            return ;;
    esac
    assert_eq "T53[real-deploy]: real deployed allow list has zero \`Bash(<cmd> *)\` entries the checkout's base/extension do not own" \
        "present 0" "$got"
    assert_eq "T53[real-deploy]: real deployed allow list carries no retired spelling of a real SSOT entry" \
        "none" "$(t52_retired_spellings_in "$dump")"
}

t52_setup
case_begin "real-spellings-gone-assembly" "install/lib/settings-assembly.js"
t52_assembly
case_end
case_begin "real-spellings-gone-deploy" "install/lib/settings-deploy.js"
t52_deploy
case_end
case_begin "real-installed-spellings-gone" "install/lib/settings-deploy.js"
t53_real_deploy
case_end
