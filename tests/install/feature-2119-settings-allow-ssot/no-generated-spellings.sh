# tests/feature-2119-settings-allow-ssot/no-generated-spellings.sh
# Tests: install/lib/settings-assembly.js, install/lib/settings-deploy.js
# Tags: install, settings, permissions, assembly, regression, scope:issue-specific, pwsh-not-required, TL2
# T51: MIGRATION PIN. The retired generator wrote spellings such as `Bash(bin/workflow/next-step *)`
# into the assembled allow list. With an SSOT entry present but an EMPTY base and extension, the
# assembled and the deployed allow lists must carry no `Bash(<...> *)` entry -- any survivor
# means the generator (or a leftover of it) still writes the rules bash-guard now owns.

T51_FIXTURE=""
T51_GENERATED_RE='^Bash\(.*[[:space:]]\*\)$'

t51_setup() {
    T51_FIXTURE="$(mk_fixture t51)"
    mk_tool "$T51_FIXTURE" bin/workflow/next-step env-node
    write_ssot "$T51_FIXTURE" bin/workflow/next-step
    write_settings "$T51_FIXTURE" --
    write_ext "$T51_FIXTURE" --
    : > "$T51_FIXTURE/install/path-exposed-commands.txt"
}

# <list-file> -> none | the offending entries, space-joined
t51_generated_in() {
    local hits
    hits="$(grep -E -- "$T51_GENERATED_RE" "$1" 2>/dev/null | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
    [ -n "$hits" ] && printf '%s' "$hits" || printf 'none'
}

t51_assembly() {
    have_lib || { assert_eq "T51[assembly]: assembled allow list has no generated spelling" "none" "$(missing_lib)"; return; }
    local out="$T51_FIXTURE/assembled-allow.txt" rc=0
    run_with_timeout 30 node -e '
      const path = require("path"), fs = require("fs");
      const [root, out] = process.argv.slice(1);
      const a = require(path.join(root, "install", "lib", "settings-assembly.js"));
      const r = a.buildAssembledSettings({ agentsRoot: root });
      const allow = (((r && r.settings) || {}).permissions || {}).allow || [];
      fs.writeFileSync(out, allow.join("\n") + (allow.length ? "\n" : ""));
    ' "$(node_path "$T51_FIXTURE")" "$(node_path "$out")" >/dev/null 2>&1 || rc=$?
    assert_eq "T51[assembly]: buildAssembledSettings ran on an empty base + extension" "0" "$rc"
    assert_eq "T51[assembly]: assembled allow list has no generated \`Bash(<cmd> *)\` spelling" \
        "none" "$(t51_generated_in "$out")"
}

t51_deploy() {
    run_assemble "$T51_FIXTURE"
    assert_eq "T51[deploy]: the deploy CLI exits 0 on an empty base + extension (out: $ASM_OUT)" "0" "$ASM_RC"
    local deployed="absent"
    [ -f "$(deployed_file "$T51_FIXTURE")" ] && deployed="present"
    assert_eq "T51[deploy]: a deployed settings.json exists, so the next row is not vacuous" "present" "$deployed"
    deployed_allow_dump "$T51_FIXTURE" "$T51_FIXTURE/deployed-allow.txt"
    assert_eq "T51[deploy]: deployed allow list has no generated \`Bash(<cmd> *)\` spelling" \
        "none" "$(t51_generated_in "$T51_FIXTURE/deployed-allow.txt")"
}

t51_setup
case_begin "t51-assembly" "install/lib/settings-assembly.js"
t51_assembly
case_end
case_begin "t51-deploy" "install/lib/settings-deploy.js"
t51_deploy
case_end
