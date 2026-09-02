# tests/feature-2119-settings-allow-ssot/input-validation.sh
# Tests: install/gen-settings-allow.js, install/settings-allow-commands.txt
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T13 -- THE SSOT IS AN INPUT, NOT A CONSTANT. Sourced AFTER generator.sh, whose fixture
# helpers this reuses. ssot-structure.sh T2a inspects the entries in the file today, so it can
# only say "the current list is clean"; it cannot fail for a generator that never validates.
# Each entry is interpolated into twenty-two permission rules, so an unvalidated `..`,
# absolute path, drive letter, space, backslash, shell metacharacter or glob metacharacter
# does not merely name the wrong file -- it WIDENS a rule, and the widened rule now lands
# straight in the deployed permission set with no commit and no review in between.

T13_OUTSIDE=""
T13_PROBE=""
T13_ABS=""
T13_DRIVE=""
T13_BACKSLASH=""
T13_PRE='Bash(hand-written-only *)'

# EVERY HOSTILE ROW MUST FAIL FOR THE CHARSET REASON. An entry naming a file that does not
# exist, or one with no shebang, is rejected by the existence check and the shebang check long
# before any charset rule runs -- so such a row passes against a generator that validates
# nothing, and the table reports green while testing the wrong gate. Each name below is
# therefore created as a REAL executable file carrying a REAL bash shebang, and the absolute
# and drive-qualified spellings are computed from $TMPROOT at run time so they point at a file
# that genuinely exists on this host.
try_mk_tool() { # <dir> <relpath> -> 0 when the GENERATOR's runtime can open the name, else 1
    local f="$1/$2"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo hostile fixture' > "$f" 2>/dev/null || return 1
    [ -f "$f" ] || return 1
    chmod +x "$f" 2>/dev/null || true
    # Existence is confirmed the way the GENERATOR will confirm it -- a node process joining
    # the raw SSOT entry onto the tree root -- not the way bash sees it. On Windows the MSYS
    # layer happily creates names carrying `*`, `?` or `"` by mapping them into a private
    # Unicode range, so bash finds a file that node, given the literal entry, never can. Such a
    # row would fail on the existence check, which is the precise false-green this table exists
    # to remove, so it is skipped with its reason stated instead.
    [ "$(node -e 'const p=require("path"),fs=require("fs");process.stdout.write(fs.existsSync(p.join(process.argv[1],process.argv[2]))?"y":"n")' \
        "$(node_path "$1")" "$2" 2>/dev/null)" = "y" ]
}

t13_setup() {
    T13_OUTSIDE="$TMPROOT/outside"
    mkdir -p "$T13_OUTSIDE"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo outside' > "$T13_OUTSIDE/fx-out"
    chmod +x "$T13_OUTSIDE/fx-out" 2>/dev/null || true
    T13_PROBE="$TMPROOT/t13-namecheck"
    mkdir -p "$T13_PROBE"
    T13_ABS="$T13_OUTSIDE/fx-out"
    if command -v cygpath >/dev/null 2>&1; then
        T13_DRIVE="$(cygpath -m "$T13_OUTSIDE/fx-out" 2>/dev/null)"
        case "$T13_DRIVE" in [A-Za-z]:/*) : ;; *) T13_DRIVE="" ;; esac
    fi
    # Windows reaches the same real file through its own separator, so `bin\fx-ok` exists there
    # without a second file; POSIX needs a file whose NAME carries the backslash byte.
    if [ -n "$T13_DRIVE" ]; then
        T13_BACKSLASH='bin\fx-ok'
    elif try_mk_tool "$T13_PROBE" 'bin/fx\ok'; then
        T13_BACKSLASH='bin/fx\ok'
    fi
}

# The entry is resolved, not read literally, for the three rows whose spelling depends on the
# host: an empty result means this filesystem cannot represent the name and the row is SKIPped
# with its reason stated rather than dropped, so the T10 row budget stays exact either way.
t13_entry() { # <id> <mkfile:yes|no> <table-entry> -> resolved entry, or "" when unrepresentable
    case "$1" in
        absolute)     printf '%s' "$T13_ABS"; return ;;
        drive-letter) printf '%s' "$T13_DRIVE"; return ;;
        backslash)    printf '%s' "$T13_BACKSLASH"; return ;;
    esac
    [ "$2" = "yes" ] || { printf '%s' "$3"; return; }
    try_mk_tool "$T13_PROBE" "$3" || return 0
    printf '%s' "$3"
}

# Each fixture is DEPLOYED HEALTHY FIRST, from an SSOT carrying only the clean entry, and the
# hostile entry is added afterwards. Without that step a hostile row would exit non-zero for
# the wrong reason -- "there is no deployed file to check" -- and the table would report green
# against a generator that validates nothing. It also makes the positive control meaningful:
# the same fixture, left clean, is in sync and exits 0.
t13_fixture() { # <name> <hostile-entry-or-EMPTY> <mkfile:yes|no> -> fixture dir
    local fx="$1" entry="$2" dir
    dir="$(mk_fixture "$fx")"
    mk_tool "$dir" bin/fx-ok env-bash
    mk_tool "$dir" 'bin/fx ok' env-bash
    printf '%s\n' "$T13_PRE" > "$dir/pre.txt"
    write_settings "$dir" "$dir/pre.txt"
    write_ssot "$dir" bin/fx-ok
    run_gen "$dir" --write
    if [ "$entry" != "EMPTY" ]; then
        [ "$3" = "yes" ] && try_mk_tool "$dir" "$entry"
        write_ssot "$dir" bin/fx-ok "$entry"
    fi
    printf '%s\n' "$dir"
}

# Pattern 1 of protection-fix-tests.md: the exit code alone is not the assertion. A generator
# that rejects the entry AFTER emitting the other sixteen rules has still built a
# half-generated permission set, so both protected resources are checked -- the repository
# tree AND the deployed file, which is now the one the engine reads. The exit code is reported
# EXACTLY (2 = usage/IO/validation per the plan's contract), not as "non-zero": a crash, a
# timeout and a deliberate rejection are three different outcomes.
t13_probe() { # <id> <entry> <mkfile> -> "<rc>/<tree>/<home>" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local dir tb ta hb ha tv hv
    dir="$(t13_fixture "t13-$1" "$2" "$3")"
    tb="$(repo_tree_manifest "$dir")"
    hb="$(tree_manifest "$dir/home")"
    run_gen "$dir" --check
    ta="$(repo_tree_manifest "$dir")"
    ha="$(tree_manifest "$dir/home")"
    [ "$tb" = "$ta" ] && tv="unchanged" || tv="TREE-MODIFIED"
    [ "$hb" = "$ha" ] && hv="unchanged" || hv="HOME-MODIFIED"
    printf '%s/%s/%s' "$GEN_RC" "$tv" "$hv"
}

t13_hostile_entries() {
    local id mkfile entry want label resolved
    while IFS='|' read -r id mkfile entry want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        resolved="$(t13_entry "$id" "$mkfile" "$entry")"
        if [ -z "$resolved" ]; then
            skip "T13[$id]: $label -- SKIPPED: this host's filesystem cannot represent that name, so the row could only re-test the existence check"
            continue
        fi
        assert_eq "T13[$id]: $label" "$want" "$(t13_probe "$id" "$resolved" "$mkfile")"
    done <<'T13_CASES'
traversal|no|../outside/fx-out|2/unchanged/unchanged|a `..` segment escapes the agents root -- and its target really exists with a real shebang, so existence checking alone cannot reject it
traversal-deep|no|bin/../../outside/fx-out|2/unchanged/unchanged|the `..` is buried mid-path rather than leading, and resolves to that same real file
absolute|no|@dynamic@|2/unchanged/unchanged|a leading slash names a file outside the repository -- computed from $TMPROOT so it exists and carries a shebang
drive-letter|no|@dynamic@|2/unchanged/unchanged|the drive-qualified spelling of that same existing file: an absolute path in the other notation
backslash|no|@dynamic@|2/unchanged/unchanged|backslashes are the Windows template's own separator, and this spelling resolves to a real file on both hosts
whitespace|yes|bin/fx ok|2/unchanged/unchanged|an embedded space splits the generated `Bash(... *)` rule at the wrong place -- and this target exists too
semicolon|yes|bin/fx;ok|2/unchanged/unchanged|`;` ends a command in every shell the generated rule is matched against
dollar|yes|bin/fx$ok|2/unchanged/unchanged|`$` starts an expansion inside the `"$AGENTS_CONFIG_DIR/<P>"` template's own quotes
single-quote|yes|bin/fx'ok|2/unchanged/unchanged|`'` closes the quoting of the `bash -c '...'` templates and leaves the rest of the rule unquoted
double-quote|yes|bin/fx"ok|2/unchanged/unchanged|`"` closes the quoting of the `$AGENTS_CONFIG_DIR` templates in the same way
hash|yes|bin/fx#ok|2/unchanged/unchanged|`#` starts a comment in the SSOT's own line syntax, so an entry carrying one is ambiguous at the parser as well as at the rule
glob-star|yes|bin/fx*ok|2/unchanged/unchanged|a `*` in the entry widens the rule from one file to every sibling
glob-question|yes|bin/fx?ok|2/unchanged/unchanged|`?` is a single-character wildcard in the same matcher
glob-bracket|yes|bin/[f]x-ok|2/unchanged/unchanged|a character class is the third metacharacter the matcher honours
control|no|EMPTY|0/unchanged/unchanged|POSITIVE CONTROL: the same fixture left clean is in sync and exits 0, so the fourteen rows above are rejections and not one shared outage
T13_CASES
}

t13_setup
t13_hostile_entries
