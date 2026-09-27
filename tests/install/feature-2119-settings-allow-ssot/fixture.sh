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
    cp "$AGENTS_DIR"/install/lib/*.js "$dir/install/lib/" 2>/dev/null || true
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
tree_manifest() { # <dir>
    ( cd "$1" 2>/dev/null || { printf '<NO-DIR:%s>' "$1"; exit 0; }
      find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
          printf '%s %s\n' "$f" "$(cksum < "$f" 2>/dev/null || printf 'UNREADABLE')"
      done )
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
    ASM_OUT="$( (cd "$fx" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$fx/home" USERPROFILE="$(node_path "$fx/home")" \
        CLAUDE_CONFIG_DIR="$fx/home/.claude" \
        run_with_timeout 60 node install/assemble-settings.js "$@") 2>&1 )" || ASM_RC=$?
}

# Presence rows, asserted ONCE here: "the CLI is missing" and "the modules it delegates to
# are missing" are different diagnoses. Every later row reports a sentinel instead.
fixture_lib_present() {
    local got="absent"
    have_lib && got="present"
    assert_eq "fixture: all of $LIB_REL_LIST exist (absent means MODULE_NOT_FOUND)" "present" "$got"
}

fixture_assemble_present() {
    local got="absent"
    [ -f "$ASSEMBLE" ] && got="present"
    assert_eq "fixture: $ASSEMBLE_REL exists (the deploy CLI every fixture copies)" "present" "$got"
}

case_begin "fixture-lib-assembly" "install/lib/settings-assembly.js"
fixture_lib_present # one row checks every file of $LIB_REL_LIST, settings-deploy.js included
case_end
case_begin "fixture-lib-deploy" "install/lib/settings-deploy.js"
case_end
case_begin "fixture-assemble" "install/assemble-settings.js"
fixture_assemble_present
case_end
