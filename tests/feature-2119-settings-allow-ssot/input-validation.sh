# tests/feature-2119-settings-allow-ssot/input-validation.sh
# Tests: install/gen-settings-allow.js, install/settings-allow-commands.txt
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T13 -- THE SSOT IS AN INPUT, NOT A CONSTANT. Sourced AFTER generator.sh, whose fixture
# helpers this reuses. ssot-structure.sh T2a inspects the entries in the file today, so it can
# only say "the current list is clean"; it cannot fail for a generator that never validates.
# Each entry is interpolated into eleven permission rules, so an unvalidated `..`, absolute
# path, drive letter, space, backslash, shell metacharacter or glob metacharacter does not
# merely name the wrong file -- it WIDENS a rule.

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

t13_fixture() { # <name> <hostile-entry-or-EMPTY> <mkfile:yes|no> -> fixture dir
    local fx="$1" entry="$2" dir
    dir="$(mk_fixture "$fx")"
    mk_tool "$dir" bin/fx-ok env-bash
    mk_tool "$dir" 'bin/fx ok' env-bash
    if [ "$entry" = "EMPTY" ]; then
        write_ssot "$dir" bin/fx-ok
    else
        [ "$3" = "yes" ] && try_mk_tool "$dir" "$entry"
        write_ssot "$dir" bin/fx-ok "$entry"
    fi
    printf '%s\n' "$T13_PRE" > "$dir/pre.txt"
    write_settings "$dir" "$dir/pre.txt"
    printf '%s\n' "$dir"
}

# Pattern 1 of protection-fix-tests.md: the exit code alone is not the assertion. A generator
# that rejects the entry AFTER appending the other eight rules has still written a
# half-generated permission set, so the protected resource itself is checked. The exit code is
# reported EXACTLY (2 = usage/IO/validation per the plan's contract), not as "non-zero": a
# crash, a timeout and a deliberate rejection are three different outcomes.
t13_probe() { # <id> <entry> <mkfile> -> "<rc>/<unchanged|MODIFIED>" | sentinel
    have_gen || { missing_gen; return; }
    local dir before after fv
    dir="$(t13_fixture "t13-$1" "$2" "$3")"
    before="$(file_digest "$dir/settings.json")"
    run_gen "$dir" --write
    after="$(file_digest "$dir/settings.json")"
    if [ "$before" = "$after" ]; then fv="unchanged"; else fv="MODIFIED"; fi
    printf '%s/%s' "$GEN_RC" "$fv"
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
traversal|no|../outside/fx-out|2/unchanged|a `..` segment escapes the agents root -- and its target really exists with a real shebang, so existence checking alone cannot reject it
traversal-deep|no|bin/../../outside/fx-out|2/unchanged|the `..` is buried mid-path rather than leading, and resolves to that same real file
absolute|no|@dynamic@|2/unchanged|a leading slash names a file outside the repository -- computed from $TMPROOT so it exists and carries a shebang
drive-letter|no|@dynamic@|2/unchanged|the drive-qualified spelling of that same existing file: an absolute path in the other notation
backslash|no|@dynamic@|2/unchanged|backslashes are the Windows template's own separator, and this spelling resolves to a real file on both hosts
whitespace|yes|bin/fx ok|2/unchanged|an embedded space splits the generated `Bash(... *)` rule at the wrong place -- and this target exists too
semicolon|yes|bin/fx;ok|2/unchanged|`;` ends a command in every shell the generated rule is matched against
dollar|yes|bin/fx$ok|2/unchanged|`$` starts an expansion inside the `"$AGENTS_CONFIG_DIR/<P>"` template's own quotes
single-quote|yes|bin/fx'ok|2/unchanged|`'` closes the quoting of the `bash -c '...'` templates and leaves the rest of the rule unquoted
double-quote|yes|bin/fx"ok|2/unchanged|`"` closes the quoting of the `$AGENTS_CONFIG_DIR` templates in the same way
hash|yes|bin/fx#ok|2/unchanged|`#` starts a comment in the SSOT's own line syntax, so an entry carrying one is ambiguous at the parser as well as at the rule
glob-star|yes|bin/fx*ok|2/unchanged|a `*` in the entry widens the rule from one file to every sibling
glob-question|yes|bin/fx?ok|2/unchanged|`?` is a single-character wildcard in the same matcher
glob-bracket|yes|bin/[f]x-ok|2/unchanged|a character class is the third metacharacter the matcher honours
control|no|EMPTY|0/MODIFIED|POSITIVE CONTROL: the same fixture with only the clean entry is accepted and does append (so the rows above are not passing because everything is rejected)
T13_CASES
}

t13_setup
t13_hostile_entries
