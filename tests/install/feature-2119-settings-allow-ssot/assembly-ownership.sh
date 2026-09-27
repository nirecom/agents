# tests/feature-2119-settings-allow-ssot/assembly-ownership.sh
# Tests: install/lib/settings-assembly.js, install/lib/settings-deploy.js
# Tags: install, settings, permissions, assembly, scope:issue-specific, pwsh-not-required, TL2
# T50: settings-assembly.js OWNS GenError and DEFAULT_ROOT after #2264. Sourced AFTER fixture.sh.

T50_DIR=""

# WHY OWNERSHIP IS ITS OWN TABLE. Both modules borrowed GenError and DEFAULT_ROOT from the
# deleted settings-allow-rules.js; a surviving require() throws at load time, on the next
# post-merge rather than in review. So the modules run in a fixture install/lib WITHOUT that
# file, and the default agentsRoot is pinned to still resolve (the C4 regression).
t50_setup() {
    have_lib || return 0
    T50_DIR="$TMPROOT/t50"
    mkdir -p "$T50_DIR/install/lib" "$T50_DIR/home/.claude"
    cp "$LIB_DIR/settings-assembly.js" "$LIB_DIR/settings-deploy.js" "$T50_DIR/install/lib/"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(t50-base *)"], "deny": [] } }' > "$T50_DIR/settings.json"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(t50-ext *)"] } }' > "$T50_DIR/settings-extension.json"
}

# One node process per row, so a throw in one probe cannot mask another. Errors are reported
# as THREW:<first line>, never folded into a "no".
t50_probe() { # <id> -> verdict | sentinel
    have_lib || { missing_lib; return; }
    case "$1" in
        assembly-no-ref|deploy-no-ref)
            local f="$LIB_DIR/settings-assembly.js"
            [ "$1" = "deploy-no-ref" ] && f="$LIB_DIR/settings-deploy.js"
            if grep -q -- 'settings-allow-rules' "$f"; then printf 'STILL-REFERENCED'; else printf 'unreferenced'; fi
            return ;;
    esac
    run_with_timeout 30 node -e '
      const path = require("path"), fs = require("fs");
      const [id, root, home] = process.argv.slice(1);
      const lib = path.join(root, "install", "lib");
      (function () { try {
        if (id === "generror") {
          const a = require(path.join(lib, "settings-assembly.js"));
          console.log(typeof a.GenError === "function" ? "function" : "NOT-FUNCTION:" + typeof a.GenError);
        } else if (id === "default-root") {
          const a = require(path.join(lib, "settings-assembly.js"));
          if (typeof a.DEFAULT_ROOT !== "string") { console.log("NOT-STRING:" + typeof a.DEFAULT_ROOT); return; }
          console.log(path.resolve(a.DEFAULT_ROOT) === path.resolve(root) ? "fixture-root" : "OTHER:" + a.DEFAULT_ROOT);
        } else if (id === "deploy-shares-generror") {
          const a = require(path.join(lib, "settings-assembly.js"));
          const d = require(path.join(lib, "settings-deploy.js"));
          console.log(d.GenError === a.GenError ? "same" : "DIFFERENT");
        } else if (id === "build-keys") {
          const a = require(path.join(lib, "settings-assembly.js"));
          console.log(Object.keys(a.buildAssembledSettings({ agentsRoot: root })).sort().join(","));
        } else if (id === "deploy-default-root") {
          const d = require(path.join(lib, "settings-deploy.js"));
          d.deployAssembledSettings({ homeDir: home });
          const out = JSON.parse(fs.readFileSync(path.join(home, ".claude", "settings.json"), "utf8"));
          console.log(((out.permissions || {}).allow || []).join(","));
        } else {
          console.log("UNKNOWN-ID");
        }
      } catch (e) {
        console.log("THREW:" + String(e.message).split("\n")[0]);
      } })();
    ' "$1" "$(node_path "$T50_DIR")" "$(node_path "$T50_DIR/home")" 2>&1
}

t50_run_rows() { # reads id|want|label rows from stdin
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T50[$id]: $label" "$want" "$(t50_probe "$id")"
    done
}

t50_assembly_rows() {
    t50_run_rows <<'T50_ASSEMBLY_CASES'
assembly-no-ref|unreferenced|install/lib/settings-assembly.js no longer names settings-allow-rules -- the module it borrowed from is deleted
generror|function|settings-assembly.js loads in an install/lib WITHOUT settings-allow-rules.js and exports GenError as its own class
default-root|fixture-root|and exports DEFAULT_ROOT as a string resolving to the checkout that holds the module, so a copied install layer targets itself
build-keys|settings|buildAssembledSettings returns exactly {settings}: the generatorError half of the result went with the generator
T50_ASSEMBLY_CASES
}

t50_deploy_rows() {
    t50_run_rows <<'T50_DEPLOY_CASES'
deploy-no-ref|unreferenced|CPR-ORTH: install/lib/settings-deploy.js no longer names it either
deploy-shares-generror|same|settings-deploy.js loads in the same stripped lib and re-exports the ONE GenError, so an instanceof check at the CLI still recognises the assembler's errors
deploy-default-root|Bash(t50-base *),Bash(t50-ext *)|deployAssembledSettings with NO agentsRoot deploys from DEFAULT_ROOT, base then extension and nothing else (the C4 regression: a default borrowed from a deleted module would throw here)
T50_DEPLOY_CASES
}

t50_setup
case_begin "t50-assembly" "install/lib/settings-assembly.js"
t50_assembly_rows
case_end
case_begin "t50-deploy" "install/lib/settings-deploy.js"
t50_deploy_rows
case_end
