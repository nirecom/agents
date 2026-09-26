# tests/feature-2119-settings-allow-ssot/input-validation.sh
# Tests: hooks/lib/allow-command-list.js, install/settings-allow-commands.txt
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T13 -- THE SSOT IS AN INPUT, NOT A CONSTANT. Sourced AFTER fixture.sh. ssot-structure.sh
# T2a inspects today's entries, so it cannot fail for a reader that never validates. Since
# #2264 the reader is hooks/lib/allow-command-list.js: each entry becomes a path bash-guard
# answers with permissionDecision "allow", so an unvalidated `..`, absolute path, drive
# letter, space, backslash, shell or glob metacharacter WIDENS what the hook auto-approves.

T13_OUTSIDE=""
T13_PROBE=""
T13_ABS=""
T13_DRIVE=""
T13_BACKSLASH=""
T13_LIST_PROBE="$AGENTS_DIR/tests/hooks/feature-2265-allow-command-list/probe.js"

# EVERY HOSTILE ROW MUST FAIL FOR THE CHARSET REASON. An entry naming a file that does not
# exist, or one with no shebang, could be dropped by an existence or shebang check before any
# charset rule runs -- a false green. Each name below is therefore a REAL executable file with
# a REAL bash shebang, and the absolute and drive-qualified spellings are computed from
# $TMPROOT at run time so they point at a file that genuinely exists on this host.
try_mk_tool() { # <dir> <relpath> -> 0 when node can open the name, else 1
    local f="$1/$2"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo hostile fixture' > "$f" 2>/dev/null || return 1
    [ -f "$f" ] || return 1
    chmod +x "$f" 2>/dev/null || true
    # Existence is confirmed the way the READER will confirm it -- node joining the raw entry
    # onto the root. On Windows MSYS maps `*`, `?` or `"` into a private Unicode range, so bash
    # finds a file node never can; such a row is skipped with its reason stated instead.
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
    local entry="$2" dir
    dir="$(mk_fixture "$1")"
    mk_tool "$dir" bin/fx-ok env-bash
    mk_tool "$dir" 'bin/fx ok' env-bash
    write_ssot "$dir" bin/fx-ok
    if [ "$entry" != "EMPTY" ]; then
        [ "$3" = "yes" ] && try_mk_tool "$dir" "$entry"
        write_ssot "$dir" bin/fx-ok "$entry"
    fi
    printf '%s\n' "$dir"
}

# Two protected facts per row: the hostile entry never reaches `entries` (the verdict), and
# reading the list writes nothing (the tree). A throw or a missing module is reported as
# itself, never folded into "absent", so a crash cannot pass as a rejection.
t13_probe() { # <id> <entry> <mkfile> -> "<absent|present|HOSTILE-PRESENT|<sentinel>>/<tree>"
    local dir tb ta tv out list verdict
    dir="$(t13_fixture "t13-$1" "$2" "$3")"
    tb="$(repo_tree_manifest "$dir")"
    out="$(run_with_timeout 30 node "$(node_path "$T13_LIST_PROBE")" load "$(node_path "$dir")" 2>/dev/null)"
    ta="$(repo_tree_manifest "$dir")"
    [ "$tb" = "$ta" ] && tv="unchanged" || tv="TREE-MODIFIED"
    case "$out" in
        "<"*|"") printf '%s/%s' "${out:-<NO-OUTPUT>}" "$tv"; return ;;
    esac
    list="${out#entries=}"; list=",${list%%;bare=*},"
    if [ "$2" = "EMPTY" ]; then
        case "$list" in *",bin/fx-ok,"*) verdict="present" ;; *) verdict="CLEAN-DROPPED" ;; esac
    else
        case "$list" in *",$2,"*) verdict="HOSTILE-PRESENT" ;; *) verdict="absent" ;; esac
    fi
    printf '%s/%s' "$verdict" "$tv"
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
traversal|no|../outside/fx-out|absent/unchanged|a `..` segment escapes the agents root -- and its target really exists with a real shebang, so existence checking alone cannot reject it
traversal-deep|no|bin/../../outside/fx-out|absent/unchanged|the `..` is buried mid-path rather than leading, and resolves to that same real file
absolute|no|@dynamic@|absent/unchanged|a leading slash names a file outside the repository -- computed from $TMPROOT so it exists and carries a shebang
drive-letter|no|@dynamic@|absent/unchanged|the drive-qualified spelling of that same existing file: an absolute path in the other notation
backslash|no|@dynamic@|absent/unchanged|a backslash is a second separator the path normalizer would have to agree on, and this spelling resolves to a real file on both hosts
whitespace|yes|bin/fx ok|absent/unchanged|an embedded space splits a command word at the wrong place -- and this target exists too
semicolon|yes|bin/fx;ok|absent/unchanged|`;` ends a command in every shell
dollar|yes|bin/fx$ok|absent/unchanged|`$` starts an expansion
single-quote|yes|bin/fx'ok|absent/unchanged|`'` opens a quoting context the entry would carry into the match
double-quote|yes|bin/fx"ok|absent/unchanged|`"` does the same with the other quote
hash|yes|bin/fx#ok|absent/unchanged|`#` starts a comment in the SSOT's own line syntax, so an entry carrying one is ambiguous at the parser
glob-star|yes|bin/fx*ok|absent/unchanged|a `*` in the entry widens it from one file to every sibling
glob-question|yes|bin/fx?ok|absent/unchanged|`?` is a single-character wildcard
glob-bracket|yes|bin/[f]x-ok|absent/unchanged|a character class is the third glob metacharacter
control|no|EMPTY|present/unchanged|POSITIVE CONTROL: the same fixture left clean loads bin/fx-ok, so the fourteen rows above are rejections and not one shared outage
T13_CASES
}

t13_setup
t13_hostile_entries
