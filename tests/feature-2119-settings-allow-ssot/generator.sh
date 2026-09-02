# tests/feature-2119-settings-allow-ssot/generator.sh
# Tests: install/lib/settings-allow-rules.js, install/lib/settings-assembly.js, install/lib/settings-deploy.js, install/assemble-settings.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T4-T5 plus the fixture helpers and the expected-template contract every later part reuses.

DEPLOYED_SUBPATH="home/.claude/settings.json"

# Fixture isolation in two directions. TREE: the whole install layer -- CLIs and the pure
# modules under install/lib/ -- is COPIED into a throwaway tree run with cwd set there, so a
# `__dirname/..`-relative and a cwd-relative implementation both resolve to the fixture.
# Copying only the CLI (what this helper did while the spelling logic still lived inside it)
# makes every success case die of MODULE_NOT_FOUND and every rc=2 case pass FOR THE WRONG
# REASON. HOME: rules are now INJECTED AT DEPLOY TIME into ~/.claude/settings.json, so each
# fixture carries a private home and run_gen/run_assemble pass HOME + USERPROFILE per
# subprocess (the pattern at tests/fix-846-settings-drift.sh). The suite-wide canary HOME
# stays untouched even though these cases really deploy -- which is what makes T22 evidence.
mk_fixture() { # <name> -> fixture dir
    local dir="$TMPROOT/$1"
    mkdir -p "$dir/install/lib" "$dir/bin" "$dir/home/.claude"
    if have_gen; then cp "$GEN" "$dir/install/gen-settings-allow.js"; fi
    if [ -f "$ASSEMBLE" ]; then cp "$ASSEMBLE" "$dir/install/assemble-settings.js"; fi
    cp "$AGENTS_DIR"/install/lib/*.js "$dir/install/lib/" 2>/dev/null || true
    printf '# fixture PATH-exposed list (never the real one)\n' > "$dir/install/path-exposed-commands.txt"
    printf '%s\n' "$dir"
}

# The deployed file: what this feature actually produces. Nothing under the fixture tree is
# the product any more, so every result assertion reads from here.
deployed_file() { # <fixture> -> path
    printf '%s/%s' "$1" "$DEPLOYED_SUBPATH"
}

# A fixture tool whose shebang decides the interpreter. `none` writes a file with no shebang
# at all, which the generator must treat as unresolvable rather than guessing.
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
# Built from a newline-delimited list file, so a rule string carrying quotes, `$` or
# backslashes is escaped by JSON.stringify and never by hand.
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

# A whole-tree manifest for any directory. home-canary.sh keeps its own copy keyed to the
# canary HOME; this one takes the directory as an argument, so a fixture tree and a fixture
# home can both be pinned by the same rows.
tree_manifest() { # <dir>
    ( cd "$1" 2>/dev/null || { printf '<NO-DIR:%s>' "$1"; exit 0; }
      find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
          printf '%s %s\n' "$f" "$(cksum < "$f" 2>/dev/null || printf 'UNREADABLE')"
      done )
}

# The repository half of a fixture: everything a stray write could land in that is NOT the
# deployed file. Paired with tree_manifest "<fixture>/home", it separates "wrote into the
# repo" from "wrote into the home" instead of collapsing both into one verdict.
repo_tree_manifest() { # <fixture>
    tree_manifest "$1/install"
    printf 'settings.json %s\n' "$(file_digest "$1/settings.json")"
    printf 'settings-extension.json %s\n' "$(file_digest "$1/settings-extension.json")"
}

GEN_RC=0
GEN_OUT=""
run_gen() { # <fixture> <arg>...
    local fx="$1"; shift
    if [ ! -f "$fx/install/gen-settings-allow.js" ]; then
        GEN_RC=127; GEN_OUT="$(missing_gen)"; return
    fi
    GEN_RC=0
    GEN_OUT="$( (cd "$fx" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$fx/home" USERPROFILE="$(node_path "$fx/home")" \
        CLAUDE_CONFIG_DIR="$fx/home/.claude" \
        run_with_timeout 60 node install/gen-settings-allow.js "$@") 2>&1 )" || GEN_RC=$?
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

# Three of the eight families spell the checkout by its ABSOLUTE root rather than by a
# leading `*`, so the expected string is no longer a constant -- it differs between a fixture
# tree and the real one. Node owns the resolution (the generator's own normalization runs
# there), so it is asked once per root and cached instead of rebuilt in shell.
declare -A _ROOT_POSIX=()
declare -A _ROOT_WIN=()

resolve_root() { # <dir> -- populates the caches for <dir>
    local d="$1" out
    [ -n "${_ROOT_POSIX[$d]:-}" ] && return 0
    out="$(node -e '
      const path = require("path");
      const posix = path.resolve(process.argv[1]).split("\\").join("/").replace(/\/+$/, "");
      process.stdout.write(posix + "\n" + posix.split("/").join("\\") + "\n");
    ' "$(node_path "$d")")" || return 1
    _ROOT_POSIX[$d]="$(printf '%s' "$out" | sed -n 1p)"
    _ROOT_WIN[$d]="$(printf '%s' "$out" | sed -n 2p)"
}

# A case table cannot spell a fixture root it does not yet know, so rows that need one write
# <R>/<R2W> and this resolves them against the fixture the row just built. <R2W> is consumed
# first: <R> is a prefix of it, and the other order would leave a stray `2W`.
expand_root_placeholders() { # <string> <agents-root> -> <string>
    local s="$1" d="$2"
    resolve_root "$d" || return 1
    s="${s//<R2W>/${_ROOT_WIN[$d]}}"
    printf '%s' "${s//<R>/${_ROOT_POSIX[$d]}}"
}

# THE TEMPLATE CONTRACT, restated independently of the generator (a test importing the
# generator's own table could only prove it equals itself). SIXTEEN path spellings: eight
# families, each in an argument-bearing and an argument-less form, listed as adjacent pairs.
# The pair is the whole point -- a trailing ` *` demands the space before it, so
# `Bash(node bin/next-step *)` never matches the bare `node bin/next-step` the model issues.
# The Windows form converts the separators inside the path too, because a Windows spelling
# carrying forward slashes could never match a real command line.
expected_path_rules() { # <interpreter> <relative-path> [<agents-root>]
    local i="$1" p="$2" root="${3:-$AGENTS_DIR}" w bs r rw
    bs='\'
    w="$(printf '%s' "$p" | tr '/' '\\')"
    resolve_root "$root" || return 1
    r="${_ROOT_POSIX[$root]}"
    rw="${_ROOT_WIN[$root]}"
    printf '%s\n' \
        "Bash($i \"\$AGENTS_CONFIG_DIR/$p\" *)" \
        "Bash($i \"\$AGENTS_CONFIG_DIR/$p\")" \
        "Bash($i $r/$p *)" \
        "Bash($i $r/$p)" \
        "Bash($i $rw${bs}$w *)" \
        "Bash($i $rw${bs}$w)" \
        "Bash($i $p *)" \
        "Bash($i $p)" \
        "Bash(\"\$AGENTS_CONFIG_DIR/$p\" *)" \
        "Bash(\"\$AGENTS_CONFIG_DIR/$p\")" \
        "Bash($r/$p *)" \
        "Bash($r/$p)" \
        "Bash(bash -c '$i \"\$AGENTS_CONFIG_DIR/$p\" *')" \
        "Bash(bash -c '$i \"\$AGENTS_CONFIG_DIR/$p\"')" \
        "Bash(bash -c 'cd \"\$AGENTS_CONFIG_DIR\" && $i \"\$AGENTS_CONFIG_DIR/$p\" *')" \
        "Bash(bash -c 'cd \"\$AGENTS_CONFIG_DIR\" && $i \"\$AGENTS_CONFIG_DIR/$p\"')"
}

# Six more spellings -- three families in the same paired form -- added only for a command
# whose basename is on the PATH-exposed list.
expected_bare_rules() { # <basename>
    local n="$1"
    printf '%s\n' \
        "Bash($n *)" \
        "Bash($n)" \
        "Bash(bash -c '$n *')" \
        "Bash(bash -c '$n')" \
        "Bash(bash -c 'cd \"\$AGENTS_CONFIG_DIR\" && $n *')" \
        "Bash(bash -c 'cd \"\$AGENTS_CONFIG_DIR\" && $n')"
}

# The artifacts' existence is asserted ONCE, here, in three rows. "The CLI is not written
# yet" and "the CLI is there but the pure modules it delegates to are not" are different
# diagnoses, and one presence row would report the second as the first. Every row below then
# reports a sentinel instead of crashing, so the tables keep executing and T10 keeps meaning
# something while an artifact is still missing.
t4_generator_present() {
    local got="absent"
    have_gen && got="present"
    assert_eq "T4/T5/T6/T7: $GEN_REL exists (IMPLEMENTATION MISSING while absent)" "present" "$got"
}

t4_lib_present() {
    local got="absent"
    have_lib && got="present"
    assert_eq "T4/T5/T6/T7: all three of $LIB_REL_LIST exist (absent means MODULE_NOT_FOUND, which every rc=2 row would misread as validation)" \
        "present" "$got"
}

t4_assemble_present() {
    local got="absent"
    [ -f "$ASSEMBLE" ] && got="present"
    assert_eq "T4/T5/T6/T7: $ASSEMBLE_REL exists (the deploy CLI every fixture copies)" "present" "$got"
}

T4_DUMP=""
T4_FX=""

# T4 expands a three-entry fixture SSOT (one bash tool, one node tool, one PATH-exposed tool)
# and checks both the ARITY per entry (16 / 16 / 22) and the exact spelling of every rule for
# two of them. Counting alone would pass a generator that emitted sixteen wrong strings.
t4_setup() {
    local fx; fx="$(mk_fixture t4)"
    T4_FX="$fx"
    mk_tool "$fx" bin/fx-bash-tool env-bash
    mk_tool "$fx" bin/fx-node-tool.js env-node
    mk_tool "$fx" bin/fx-path-tool env-bash
    write_ssot "$fx" bin/fx-bash-tool bin/fx-node-tool.js bin/fx-path-tool
    printf '%s\n' 'fx-path-tool' >> "$fx/install/path-exposed-commands.txt"
    write_settings "$fx" --
    run_gen "$fx" --write
    T4_DUMP="$fx/allow.txt"
    deployed_allow_dump "$fx" "$T4_DUMP"
}

t4_count() { # <basename> -> count | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local n
    n="$(grep -c -F -- "$1" "$T4_DUMP" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

t4_has() { # <rule-string> -> present | absent | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    if grep -Fxq -- "$1" "$T4_DUMP" 2>/dev/null; then printf 'present'; else printf 'absent'; fi
}

t4_expansion() {
    local id want name rule
    while IFS='|' read -r id want name; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4[$id]: $name expands to $want deployed rules" "$want" "$(t4_count "$name")"
    done <<'T4_COUNTS'
count-bash|16|fx-bash-tool
count-node|16|fx-node-tool.js
count-path|22|fx-path-tool
T4_COUNTS
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4[path-template]: $rule" "present" "$(t4_has "$rule")"
    done < <(expected_path_rules bash bin/fx-bash-tool "$T4_FX")
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4[bare-template]: $rule" "present" "$(t4_has "$rule")"
    done < <(expected_bare_rules fx-path-tool)
}

T4_EMPTY_FIXTURE=""
T4_EMPTY_PRE='Bash(hand-written-only *)'

# T4-empty -- an SSOT that exists but lists ZERO entries is a legitimate input state, and
# nothing else pins it: T2c guards the REAL SSOT against being empty, a different question
# from what the deploy path does when handed an empty one. An empty list is not an error --
# nothing is injected, the deploy still happens, and the hand-written base rule arrives in
# the deployed file untouched.
t4_empty_setup() {
    T4_EMPTY_FIXTURE="$(mk_fixture t4-empty)"
    : > "$T4_EMPTY_FIXTURE/install/settings-allow-commands.txt"
    printf '%s\n' "$T4_EMPTY_PRE" > "$T4_EMPTY_FIXTURE/pre.txt"
    write_settings "$T4_EMPTY_FIXTURE" "$T4_EMPTY_FIXTURE/pre.txt"
    run_gen "$T4_EMPTY_FIXTURE" --write
}

t4_empty_probe() { # <exit|untouched> -> zero|nonzero|unchanged|changed|sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local dump
    case "$1" in
        exit)
            [ "$GEN_RC" -eq 0 ] && { printf 'zero'; return; }
            printf 'nonzero'
            ;;
        untouched)
            dump="$T4_EMPTY_FIXTURE/allow.txt"
            deployed_allow_dump "$T4_EMPTY_FIXTURE" "$dump"
            [ "$(cat "$dump" 2>/dev/null)" = "$T4_EMPTY_PRE" ] && { printf 'unchanged'; return; }
            printf 'changed'
            ;;
    esac
}

t4_empty_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4-empty[$id]: $label" "$want" "$(t4_empty_probe "$id")"
    done <<'T4_EMPTY_CASES'
exit|zero|an SSOT listing zero entries is not an error -- the deploy exits 0
untouched|unchanged|nothing is injected: the hand-written base allow entry is all the deployed file carries
T4_EMPTY_CASES
}

T4_DUP_FIXTURE=""

# T4-dup -- the SAME path listed twice, fed straight through. T2b guards the real SSOT text
# against duplicates; it says nothing about a deploy handed one anyway. A rule already
# present is never emitted twice, so a doubled entry yields the same 16 rules, not 32.
t4_dup_setup() {
    T4_DUP_FIXTURE="$(mk_fixture t4-dup)"
    mk_tool "$T4_DUP_FIXTURE" bin/fx-dup env-bash
    write_ssot "$T4_DUP_FIXTURE" bin/fx-dup bin/fx-dup
    write_settings "$T4_DUP_FIXTURE" --
    run_gen "$T4_DUP_FIXTURE" --write
    deployed_allow_dump "$T4_DUP_FIXTURE" "$T4_DUP_FIXTURE/allow.txt"
}

t4_dup_probe() { # <arity|unique> -> <count>|yes|no|sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local dump n
    dump="$T4_DUP_FIXTURE/allow.txt"
    case "$1" in
        arity)
            n="$(grep -c -F -- 'fx-dup' "$dump" 2>/dev/null)" || n=0
            printf '%s' "${n:-0}"
            ;;
        unique)
            n="$(sort "$dump" 2>/dev/null | uniq -d | grep -c . )" || n=0
            [ "${n:-1}" = "0" ] && { printf 'yes'; return; }
            printf 'no'
            ;;
    esac
}

t4_dup_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4-dup[$id]: $label" "$want" "$(t4_dup_probe "$id")"
    done <<'T4_DUP_CASES'
arity|16|the same path listed twice still expands to exactly 16 deployed rules
unique|yes|the deployed allow list carries no duplicated entry
T4_DUP_CASES
}

# T5 -- the shebang is the only interpreter source, so its resolution is fail-closed: two
# real spellings resolve, and everything else stops the deploy with a non-zero exit instead
# of guessing an interpreter into a permission rule.
t5_probe() { # <shebang-kind> -> node|bash|fail-closed|sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx dump
    fx="$(mk_fixture "t5-$1")"
    mk_tool "$fx" bin/fx-tool "$1"
    write_ssot "$fx" bin/fx-tool
    write_settings "$fx" --
    run_gen "$fx" --write
    [ "$GEN_RC" -eq 0 ] || { printf 'fail-closed'; return; }
    dump="$fx/allow.txt"
    deployed_allow_dump "$fx" "$dump"
    if grep -Fxq -- 'Bash(node bin/fx-tool *)' "$dump" 2>/dev/null; then printf 'node'; return; fi
    if grep -Fxq -- 'Bash(bash bin/fx-tool *)' "$dump" 2>/dev/null; then printf 'bash'; return; fi
    printf 'unresolved-but-exit-0'
}

t5_shebang_table() {
    local kind want label
    while IFS='|' read -r kind want label; do
        [ -n "$kind" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T5[$kind]: $label" "$want" "$(t5_probe "$kind")"
    done <<'T5_CASES'
env-node|node|env-style node shebang resolves to node
bin-bash|bash|absolute /bin/bash shebang resolves to bash
env-python3|fail-closed|an interpreter outside bash/node stops the deploy (non-zero exit)
none|fail-closed|a file with no shebang stops the deploy (non-zero exit)
T5_CASES
}


t4_generator_present
t4_lib_present
t4_assemble_present
t4_setup
t4_expansion
t4_empty_setup
t4_empty_table
t4_dup_setup
t4_dup_table
t5_shebang_table
