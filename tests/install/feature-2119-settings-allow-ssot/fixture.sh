# tests/feature-2119-settings-allow-ssot/fixture.sh
# Tests: install/assemble-settings.js, install/lib/settings-assembly.js, install/lib/settings-deploy.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# Shared fixture helpers every later part reuses. Extracted from the retired generator.sh
# (#2264): the generator and its expected-template contract are gone, the helpers stay.

DEPLOYED_SUBPATH="home/.claude/settings.json"

# Fixture isolation in two directions. TREE: the deploy CLI and the pure modules under
# install/lib/ are COPIED into a throwaway tree run with cwd set there, so a
# `__dirname/..`-relative and a cwd-relative implementation both resolve to the fixture.
# HOME: each fixture carries a private home and run_assemble passes HOME + USERPROFILE per
# subprocess, so the suite-wide canary HOME stays untouched (T22 evidence).
mk_fixture() { # <name> -> fixture dir
    local dir="$TMPROOT/$1"
    mkdir -p "$dir/install/lib" "$dir/bin" "$dir/home/.claude"
    if [ -f "$ASSEMBLE" ]; then cp "$ASSEMBLE" "$dir/install/assemble-settings.js"; fi
    cp "$SCRIPT_CHECKOUT_ROOT"/install/lib/*.js "$dir/install/lib/" 2>/dev/null || true
    printf '# fixture PATH-exposed list (never the real one)\n' > "$dir/install/path-exposed-commands.txt"
    printf '%s\n' "$dir"
}

# The deployed file: what the deploy actually produces. Every result assertion reads here.
deployed_file() { # <fixture> -> path
    printf '%s/%s' "$1" "$DEPLOYED_SUBPATH"
}

# A fixture tool whose shebang is chosen by the caller. After #2264 the deploy no longer
# reads shebangs; the tools remain so a fixture still looks like a real checkout.
mk_tool() { # <fixture> <relpath> <env-node|env-bash|bin-bash|env-python3|none>
    local f="$1/$2"
    mkdir -p "$(dirname "$f")"
    case "$3" in
        env-node)    printf '%s\n' '#!/usr/bin/env node' ;;
        env-bash)    printf '%s\n' '#!/usr/bin/env bash' ;;
        bin-bash)    printf '%s\n' '#!/bin/bash' ;;
        env-python3) printf '%s\n' '#!/usr/bin/env python3' ;;
        none)        printf '%s\n' 'echo no shebang here' ;;
    esac > "$f"
    printf '%s\n' 'echo fixture tool' >> "$f"
    chmod +x "$f" 2>/dev/null || true
}

write_ssot() { # <fixture> <entry>...
    local fx="$1"; shift
    printf '%s\n' "$@" > "$fx/install/settings-allow-commands.txt"
}

# The fixture's BASE settings.json -- the repo-tracked input to assembly, not the product.
# Built from a newline-delimited list file, so quotes, `$` and backslashes are escaped by
# JSON.stringify and never by hand.
write_settings() { # <fixture> <list-file|-->
    local fx="$1" list="$2"
    node -e '
      const fs = require("fs");
      const list = process.argv[2];
      const lines = list === "--" ? [] :
        fs.readFileSync(list, "utf8").split("\n").filter((l) => l.length > 0);
      fs.writeFileSync(process.argv[1],
        JSON.stringify({ permissions: { allow: lines, deny: [] } }, null, 2) + "\n");
    ' "$(node_path "$fx/settings.json")" "$([ "$list" = "--" ] && printf -- '--' || node_path "$list")"
}

# The second assembly input. Separate from write_settings because base-then-extension order
# is itself a contract (T12) that a single-file fixture cannot express.
write_ext() { # <fixture> <list-file|-->
    local fx="$1" list="$2"
    node -e '
      const fs = require("fs");
      const list = process.argv[2];
      const lines = list === "--" ? [] :
        fs.readFileSync(list, "utf8").split("\n").filter((l) => l.length > 0);
      fs.writeFileSync(process.argv[1],
        JSON.stringify({ permissions: { allow: lines } }, null, 2) + "\n");
    ' "$(node_path "$fx/settings-extension.json")" "$([ "$list" = "--" ] && printf -- '--' || node_path "$list")"
}

deployed_allow_dump() { # <fixture> <out-file>
    node -e '
      const fs = require("fs");
      let a = [];
      try { a = (JSON.parse(fs.readFileSync(process.argv[1], "utf8")).permissions || {}).allow || []; }
      catch (e) { a = []; }
      fs.writeFileSync(process.argv[2], a.join("\n") + (a.length ? "\n" : ""));
    ' "$(node_path "$(deployed_file "$1")")" "$(node_path "$2")" 2>/dev/null || : > "$2"
}

file_digest() { # <file> -> bytes+checksum, or a marker when unreadable
    cksum < "$1" 2>/dev/null || printf 'UNREADABLE'
}

# A whole-tree manifest for any directory, so a fixture tree and a fixture home can both be
# pinned by the same rows. home-canary.sh keeps its own copy keyed to the canary HOME.
# One cksum over every readable file (not one per file); an unreadable file is still listed.
tree_manifest() { # <dir>
    ( cd "$1" 2>/dev/null || { printf '<NO-DIR:%s>' "$1"; exit 0; }
      files=(); readable=()
      mapfile -d '' -t files < <(find . -type f -print0 2>/dev/null | LC_ALL=C sort -z)
      for f in "${files[@]}"; do
          if [[ -r "$f" ]]; then readable+=("$f"); else printf '%s UNREADABLE\n' "$f"; fi
      done
      [[ "${#readable[@]}" -eq 0 ]] || cksum -- "${readable[@]}" 2>/dev/null )
}

# The repository half of a fixture: everything a stray write could land in that is NOT the
# deployed file, kept apart from the home so the two verdicts never collapse into one.
repo_tree_manifest() { # <fixture>
    tree_manifest "$1/install"
    printf 'settings.json %s\n' "$(file_digest "$1/settings.json")"
    printf 'settings-extension.json %s\n' "$(file_digest "$1/settings-extension.json")"
}

ASM_RC=0
ASM_OUT=""
run_assemble() { # <fixture> <arg>...
    local fx="$1"; shift
    if [ ! -f "$fx/install/assemble-settings.js" ]; then
        ASM_RC=127; ASM_OUT="$(missing_assemble)"; return
    fi
    ASM_RC=0
    ASM_OUT="$( (cd "$fx" && unset CLAUDE_CODE_SESSION_ID && \
        HOME="$fx/home" USERPROFILE="$(node_path "$fx/home")" \
        CLAUDE_CONFIG_DIR="$fx/home/.claude" \
        run_with_timeout 60 node install/assemble-settings.js "$@") 2>&1 )" || ASM_RC=$?
}

# HEALTHY-FIXTURE TEMPLATES. Many cases start from the same deployed-healthy fixture before
# breaking one thing. The deployed bytes do not depend on the fixture path, so the recipe runs
# ONCE per key and each case gets its own private copy (never the template itself). The done
# marker lives on disk, outside the template, so a build inside a `$(...)` case still counts.
# Only a SUCCESSFUL build is cached (builder rc 0 AND ASM_RC 0): a failed one is deleted and the
# case gets an empty dir, so its healthy-baseline rows fail loudly instead of reusing a broken tree.
tpl_copy() { # <dest-dir> <key> <builder-fn> [fixture] -- `fixture` runs mk_fixture first
    local tpl="$TMPROOT/tpl-$2" rc=0
    if [[ ! -f "$tpl.done" ]]; then
        rm -rf "$tpl"
        if [[ "${4:-}" = "fixture" ]]; then mk_fixture "tpl-$2" > /dev/null; fi
        ASM_RC=0
        "$3" "$tpl" || rc=$?
        if [[ "$rc" -ne 0 || "$ASM_RC" -ne 0 ]]; then
            printf 'tpl_copy: template %s build FAILED (builder rc=%s, ASM_RC=%s); not cached, case gets an empty dir\n' \
                "$2" "$rc" "$ASM_RC" >&2
            rm -rf "$tpl"
            mkdir -p "$1"
            return 1
        fi
        : > "$tpl.done"
    fi
    mkdir -p "$1"
    cp -Rp "$tpl/." "$1/"
}

tpl_fixture() { # <name> <key> <builder-fn> -> fresh private copy of the built template
    tpl_copy "$TMPROOT/$1" "$2" "$3" fixture
    printf '%s\n' "$TMPROOT/$1"
}

# The recipe T29, T36 and T41 each used to repeat per case: one tool, empty base, deployed once.
tpl_build_plain() { # <fixture>
    mk_tool "$1" bin/fx-tool env-bash
    write_ssot "$1" bin/fx-tool
    write_settings "$1" --
    run_assemble "$1"
}

# Presence rows, asserted ONCE here: "the CLI is missing" and "the modules it delegates to
# are missing" are different diagnoses. Every later row reports a sentinel instead.
case_begin "fixture-lib-assembly" "install/lib/settings-assembly.js"
fixture_lib_present() {
    local got="absent"
    have_lib && got="present"
    assert_eq "fixture: all of $LIB_REL_LIST exist (absent means MODULE_NOT_FOUND)" "present" "$got"
}
fixture_lib_present # one row checks every file of $LIB_REL_LIST, settings-deploy.js included
case_end
case_begin "fixture-lib-deploy" "install/lib/settings-deploy.js"
case_end
case_begin "fixture-assemble" "install/assemble-settings.js"
fixture_assemble_present() {
    local got="absent"
    [ -f "$ASSEMBLE" ] && got="present"
    assert_eq "fixture: $ASSEMBLE_REL exists (the deploy CLI every fixture copies)" "present" "$got"
}
fixture_assemble_present
case_end
