# tests/feature-2119-settings-allow-ssot/generator.sh
# Tests: install/gen-settings-allow.js, install/settings-allow-commands.txt
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T4-T5 plus the fixture helpers and the expected-template contract that write-and-drift.sh
# reuses. Sourced by tests/feature-2119-settings-allow-ssot.sh, which owns PASS/FAIL/ROWS,
# assert_eq, TMPROOT, run_with_timeout and the sentinel helpers.

# Fixture isolation: the generator is COPIED into a throwaway tree and run with cwd set
# there, so both a `__dirname/..`-relative and a cwd-relative implementation resolve to the
# fixture. Nothing here reads or writes the real settings.json.
mk_fixture() { # <name> -> fixture dir
    local dir="$TMPROOT/$1"
    mkdir -p "$dir/install" "$dir/bin"
    if have_gen; then cp "$GEN" "$dir/install/gen-settings-allow.js"; fi
    printf '# fixture PATH-exposed list (never the real one)\n' > "$dir/install/path-exposed-commands.txt"
    printf '%s\n' "$dir"
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

# settings.json built from a newline-delimited list file, so a rule string carrying quotes,
# `$` or backslashes is escaped by JSON.stringify and never by hand.
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

allow_dump() { # <fixture> <out-file>
    node -e '
      const fs = require("fs");
      let a = [];
      try { a = (JSON.parse(fs.readFileSync(process.argv[1], "utf8")).permissions || {}).allow || []; }
      catch (e) { a = []; }
      fs.writeFileSync(process.argv[2], a.join("\n") + (a.length ? "\n" : ""));
    ' "$(node_path "$1/settings.json")" "$(node_path "$2")" 2>/dev/null || : > "$2"
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
        run_with_timeout 60 node install/gen-settings-allow.js "$@") 2>&1 )" || GEN_RC=$?
}

# THE TEMPLATE CONTRACT, restated independently of the generator (a test that imported the
# generator's own table could only prove it equals itself). Ten path spellings, in the
# generator's own table order: the two CLOSED forms (no trailing wildcard -- the bare,
# argument-less invocation) lead, then the eight wildcard forms. The Windows form converts the
# separators inside the path too, because a Windows spelling carrying forward slashes could
# never match a real command line.
expected_path_rules() { # <interpreter> <relative-path>
    local i="$1" p="$2" w bs
    bs='\'
    w="$(printf '%s' "$p" | tr '/' '\\')"
    printf '%s\n' \
        "Bash($i \"\$AGENTS_CONFIG_DIR/$p\")" \
        "Bash($i $p)" \
        "Bash($i \"\$AGENTS_CONFIG_DIR/$p\" *)" \
        "Bash($i */agents/$p *)" \
        "Bash($i *${bs}agents${bs}$w *)" \
        "Bash($i $p *)" \
        "Bash(\"\$AGENTS_CONFIG_DIR/$p\" *)" \
        "Bash(*/agents/$p *)" \
        "Bash(bash -c '$i \"\$AGENTS_CONFIG_DIR/$p\" *')" \
        "Bash(bash -c 'cd \"\$AGENTS_CONFIG_DIR\" && $i \"\$AGENTS_CONFIG_DIR/$p\" *')"
}

# Three more spellings, added only for a command whose basename is on the PATH-exposed list.
expected_bare_rules() { # <basename>
    local n="$1"
    printf '%s\n' \
        "Bash($n *)" \
        "Bash(bash -c '$n *')" \
        "Bash(bash -c 'cd \"\$AGENTS_CONFIG_DIR\" && $n *')"
}

# The generator's own existence is asserted ONCE, here. Every row below then reports the
# sentinel instead of crashing, so the tables keep executing (and T10 keeps meaning
# something) while the artifact is still missing.
t4_generator_present() {
    local got="absent"
    have_gen && got="present"
    assert_eq "T4/T5/T6/T7: $GEN_REL exists (IMPLEMENTATION MISSING while absent)" "present" "$got"
}

T4_DUMP=""

# T4 expands a three-entry fixture SSOT (one bash tool, one node tool, one PATH-exposed tool)
# and checks both the ARITY per entry (10 / 10 / 13) and the exact spelling of every rule for
# two of them. Counting alone would pass a generator that emitted ten wrong strings.
t4_setup() {
    local fx; fx="$(mk_fixture t4)"
    mk_tool "$fx" bin/fx-bash-tool env-bash
    mk_tool "$fx" bin/fx-node-tool.js env-node
    mk_tool "$fx" bin/fx-path-tool env-bash
    write_ssot "$fx" bin/fx-bash-tool bin/fx-node-tool.js bin/fx-path-tool
    printf '%s\n' 'fx-path-tool' >> "$fx/install/path-exposed-commands.txt"
    write_settings "$fx" --
    run_gen "$fx" --write
    T4_DUMP="$fx/allow.txt"
    allow_dump "$fx" "$T4_DUMP"
}

t4_count() { # <basename> -> count | sentinel
    have_gen || { missing_gen; return; }
    local n
    n="$(grep -c -F -- "$1" "$T4_DUMP" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

t4_has() { # <rule-string> -> present | absent | sentinel
    have_gen || { missing_gen; return; }
    if grep -Fxq -- "$1" "$T4_DUMP" 2>/dev/null; then printf 'present'; else printf 'absent'; fi
}

t4_expansion() {
    local id want name rule
    while IFS='|' read -r id want name; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4[$id]: $name expands to $want rules" "$want" "$(t4_count "$name")"
    done <<'T4_COUNTS'
count-bash|10|fx-bash-tool
count-node|10|fx-node-tool.js
count-path|13|fx-path-tool
T4_COUNTS
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4[path-template]: $rule" "present" "$(t4_has "$rule")"
    done < <(expected_path_rules bash bin/fx-bash-tool)
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T4[bare-template]: $rule" "present" "$(t4_has "$rule")"
    done < <(expected_bare_rules fx-path-tool)
}

T4_EMPTY_FIXTURE=""
T4_EMPTY_PRE='Bash(hand-written-only *)'

# T4-empty -- an SSOT that exists but lists ZERO entries is a legitimate input state, and
# nothing pins it yet: T2c guards the REAL SSOT against being empty, which is a different
# question from what the generator does when handed an empty one. The detail plan's A-2 is
# silent here, so THIS CASE IS WHAT FIXES THE CONTRACT: an empty list is not an error --
# the generator appends nothing and exits 0, leaving hand-written allow entries untouched.
t4_empty_setup() {
    T4_EMPTY_FIXTURE="$(mk_fixture t4-empty)"
    : > "$T4_EMPTY_FIXTURE/install/settings-allow-commands.txt"
    printf '%s\n' "$T4_EMPTY_PRE" > "$T4_EMPTY_FIXTURE/pre.txt"
    write_settings "$T4_EMPTY_FIXTURE" "$T4_EMPTY_FIXTURE/pre.txt"
    run_gen "$T4_EMPTY_FIXTURE" --write
}

t4_empty_probe() { # <exit|untouched> -> zero|nonzero|unchanged|changed|sentinel
    have_gen || { missing_gen; return; }
    local dump
    case "$1" in
        exit)
            [ "$GEN_RC" -eq 0 ] && { printf 'zero'; return; }
            printf 'nonzero'
            ;;
        untouched)
            dump="$T4_EMPTY_FIXTURE/allow.txt"
            allow_dump "$T4_EMPTY_FIXTURE" "$dump"
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
exit|zero|an SSOT listing zero entries is not an error -- the generator exits 0
untouched|unchanged|nothing is appended: the hand-written allow entry is all that remains
T4_EMPTY_CASES
}

T4_DUP_FIXTURE=""

# T4-dup -- the SAME path listed twice, fed straight to the generator. T2b guards the real
# SSOT text against duplicates; it says nothing about a generator handed one anyway. The
# expectation follows from T6's append-only/idempotent contract: a rule already present is
# never appended a second time, so a doubled entry yields the same 10 rules, not 20.
t4_dup_setup() {
    T4_DUP_FIXTURE="$(mk_fixture t4-dup)"
    mk_tool "$T4_DUP_FIXTURE" bin/fx-dup env-bash
    write_ssot "$T4_DUP_FIXTURE" bin/fx-dup bin/fx-dup
    write_settings "$T4_DUP_FIXTURE" --
    run_gen "$T4_DUP_FIXTURE" --write
    allow_dump "$T4_DUP_FIXTURE" "$T4_DUP_FIXTURE/allow.txt"
}

t4_dup_probe() { # <arity|unique> -> <count>|yes|no|sentinel
    have_gen || { missing_gen; return; }
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
arity|10|the same path listed twice still expands to exactly 10 rules
unique|yes|the written allow list carries no duplicated entry
T4_DUP_CASES
}

# T5 -- the shebang is the only interpreter source, so its resolution is fail-closed: two
# real spellings resolve, and everything else stops the generator with a non-zero exit
# instead of guessing an interpreter into a permission rule.
t5_probe() { # <shebang-kind> -> node|bash|fail-closed|sentinel
    have_gen || { missing_gen; return; }
    local fx dump
    fx="$(mk_fixture "t5-$1")"
    mk_tool "$fx" bin/fx-tool "$1"
    write_ssot "$fx" bin/fx-tool
    write_settings "$fx" --
    run_gen "$fx" --write
    [ "$GEN_RC" -eq 0 ] || { printf 'fail-closed'; return; }
    dump="$fx/allow.txt"
    allow_dump "$fx" "$dump"
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
env-python3|fail-closed|an interpreter outside bash/node stops the generator (non-zero exit)
none|fail-closed|a file with no shebang stops the generator (non-zero exit)
T5_CASES
}


t4_generator_present
t4_setup
t4_expansion
t4_empty_setup
t4_empty_table
t4_dup_setup
t4_dup_table
t5_shebang_table
