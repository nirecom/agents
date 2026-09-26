# tests/feature-2119-settings-allow-ssot/quoted-root-space.sh
# Tests: install/lib/settings-allow-rules.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T49: the quoted families under a root containing a SPACE, and under shell/glob metacharacters.
# Sourced AFTER generator.sh.
# TL3 gap: asserts generated-string correctness only, not that Claude Code's real permission
# matcher honors it live -- see "TL3 verification gap" in docs/architecture/claude-code/settings.md.

T49_FX=""
T49_TOOL="bin/fx-spaced"

# T49 -- THE CASE THAT MAKES QUOTING MANDATORY, NOT STYLISTIC. Every other fixture root in this
# suite is space-free, so an unquoted absolute spelling and a quoted one are interchangeable
# there and #2201's four families look like a redundancy. Put a space in the root -- the shape
# `C:\Users\...\Local Settings\...` and every Windows profile path takes -- and the unquoted
# spelling stops being a command line anyone can issue: the shell splits it. The quoted family
# is then the ONLY rule that can ever match, so this is where it has to be pinned.
t49_setup() {
    T49_FX="$(mk_fixture 't49 root with a space')"
    mk_tool "$T49_FX" "$T49_TOOL" env-bash
    write_ssot "$T49_FX" "$T49_TOOL"
    write_settings "$T49_FX" --
    write_ext "$T49_FX" --
    run_gen "$T49_FX" --write
    deployed_allow_dump "$T49_FX" "$T49_FX/allow.txt"
}

# The precondition is a row, not a comment: mk_fixture builds under $TMPROOT, and a platform
# whose temp path normalises the space away would leave every row below asserting the same
# thing argless-and-prefix.sh already asserts, while still reporting green.
t49_root_shape() { # -> has-space | NO-SPACE-IN-ROOT | sentinel
    have_gen || { missing_gen; return; }
    resolve_root "$T49_FX" || { printf 'ROOT-UNRESOLVED'; return; }
    case "${_ROOT_POSIX[$T49_FX]}" in
        *' '*) printf 'has-space' ;;
        *)     printf 'NO-SPACE-IN-ROOT' ;;
    esac
}

t49_has_in() { # <fixture> <rule-with-placeholders> -> present|absent|sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local rule
    rule="$(expand_root_placeholders "$2" "$1")" || { printf 'ROOT-UNRESOLVED'; return; }
    if grep -Fxq -- "$rule" "$1/allow.txt" 2>/dev/null; then printf 'present'; else printf 'absent'; fi
}

t49_has() { t49_has_in "$T49_FX" "$1"; }

# The quote must enclose the WHOLE path, space included -- a rule that opened its quote after
# the space would still contain both a quote and the root and would still pass a substring
# probe. Whole-line equality against the deployed file is what rules that out.
t49_quoted_table() {
    local id rule label expanded
    while IFS='|' read -r id rule label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        expanded="$(expand_root_placeholders "$rule" "$T49_FX")"
        assert_eq "T49[$id]: $label -- $expanded" "present" "$(t49_has "$rule")"
    done <<'T49_QUOTED_CASES'
interp-posix|Bash(bash "<R>/bin/fx-spaced" *)|interpreter + QUOTED absolute POSIX path, argument-bearing: the space sits inside the quotes
interp-posix-argless|Bash(bash "<R>/bin/fx-spaced")|and its argument-less twin, the spelling a bare invocation produces
interp-win|Bash(bash "<R2W>\bin\fx-spaced" *)|interpreter + QUOTED absolute path in Windows separators, argument-bearing -- the exact string a quoted Windows path with a space becomes
interp-win-argless|Bash(bash "<R2W>\bin\fx-spaced")|and its argument-less twin
plain-posix|Bash("<R>/bin/fx-spaced" *)|QUOTED absolute POSIX path with no interpreter prefix, argument-bearing
plain-posix-argless|Bash("<R>/bin/fx-spaced")|and its argument-less twin
plain-win|Bash("<R2W>\bin\fx-spaced" *)|QUOTED absolute Windows path with no interpreter prefix, argument-bearing
plain-win-argless|Bash("<R2W>\bin\fx-spaced")|and its argument-less twin -- CPR-ORTH: all four families in both forms, none sampled
T49_QUOTED_CASES
}

# The eight rows above name the quoted forms only. This one asserts the space breaks NOTHING
# else: a root carrying a space reaches the regex builder and the string builder alike, and a
# generator that quoted correctly while dropping an unrelated family would pass all eight.
t49_complete_in() { # <fixture> <tool-relpath> -> complete | MISSING:<rule> | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local rule
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        grep -Fxq -- "$rule" "$1/allow.txt" 2>/dev/null || { printf 'MISSING:%s' "$rule"; return; }
    done < <(expected_path_rules bash "$2" "$1")
    printf 'complete'
}

t49_complete() { t49_complete_in "$T49_FX" "$T49_TOOL"; }

t49_complete_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T49[$id]: $label" "$want" "$(t49_$id)"
    done <<'T49_COMPLETE_CASES'
root_shape|has-space|PRECONDITION: the fixture root really does contain a space, so the rows below are asking the question they claim to ask
complete|complete|all twenty-four path spellings survive a space in the root -- the quoting fix did not cost an unrelated family
T49_COMPLETE_CASES
}

# CLASSIFICATION IS THE OTHER HALF. Rendering the rule is worth nothing if `--check` cannot
# read it back: a quoted rule the classifier fails to recognise under its own root is reported
# as somebody else's, and the next --write leaves a duplicate behind instead of owning it.
# Each row deploys a healthy fixture and plants ONE quoted rule for a command that is NOT in
# the SSOT, so "claimed" means the classifier matched the quoted spelling and nothing else.
t49_orphan_probe() { # <rule-with-placeholders> -> "<claimed|not-claimed>/rc=<n>" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx claimed rule tag
    tag="$(printf '%s' "$1" | cksum | tr -d ' ')"
    fx="$(mk_fixture "t49 orphan $tag")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    rule="$(expand_root_placeholders "$1" "$fx")" || { printf 'ROOT-UNRESOLVED'; return; }
    {
        expected_path_rules bash bin/fx-keep "$fx"
        printf '%s\n' "$rule"
    } > "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --write
    run_gen "$fx" --check
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-orphan'; then claimed="claimed"; else claimed="not-claimed"; fi
    printf '%s/rc=%s' "$claimed" "$GEN_RC"
}

t49_orphan_table() {
    local id rule want label
    while IFS='|' read -r id rule want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T49[orphan-$id]: $label" "$want" "$(t49_orphan_probe "$rule")"
    done <<'T49_ORPHAN_CASES'
interp-posix|Bash(bash "<R>/bin/fx-orphan" *)|claimed/rc=1|a quoted absolute POSIX rule under a SPACE-bearing root is recognised as generated-shaped and reported as an orphan
interp-win|Bash(bash "<R2W>\bin\fx-orphan")|claimed/rc=1|so is the quoted Windows-separator spelling, argument-less -- separators and the pair half are independent of the space
plain-posix|Bash("<R>/bin/fx-orphan" *)|claimed/rc=1|and the interpreter-free POSIX spelling
plain-win|Bash("<R2W>\bin\fx-orphan")|claimed/rc=1|and the interpreter-free Windows spelling, argument-less
foreign-root|Bash(bash "/nowhere/some other checkout/bin/fx-orphan" *)|not-claimed/rc=0|NEGATIVE CONTROL: the same quoted shape under a DIFFERENT space-bearing root is left alone -- the four rows above are matching the root, not the quotes
T49_ORPHAN_CASES
}

# T49-meta -- THE SAME QUESTION ASKED OF THE REST OF THE CHARACTER SET. A space is the character
# that makes quoting MANDATORY; it is not the character that makes quoting DANGEROUS. The four
# new families interpolate the checkout root raw into a rule string and, on the classifier side,
# into a regular expression. A root carrying `$`, a backtick, `&`, `;`, a quote or glob brackets
# is what tells shell-safe from shell-shaped: nothing may be expanded or dropped on the way IN
# (inside an already-quoted rule a metacharacter is inert text), and nothing may stay unescaped
# on the way BACK OUT -- an unescaped `[glob]` in the matcher is a character class that claims
# paths nobody ever deployed.
T49_META_TOOL="bin/fx-meta"

# WINDOWS CONSTRAINS THE FIXTURE SET, NOT THE CONCERN: `" * ? < > | :` are illegal in a path
# segment there, and MSYS re-encodes `*`/`?` into private-use code points a native node process
# would never see as the metacharacter -- hence the portable subset, named here rather than left
# implicit. Placeholder confusion is asked with a segment spelling `$AGENTS_CONFIG_DIR`
# literally, the renderer's own placeholder text: `<R>`-shaped segments cannot exist on Windows.
T49_SHELL_ROOT=$'t49 $shell `sub` &and; \'quote\' ~tilde.d'
T49_GLOB_ROOT='t49 [glob] {brace} $AGENTS_CONFIG_DIR'
T49_SHELL_FX=""
T49_GLOB_FX=""

t49_meta_root_name() { # <key> -> root directory name
    case "$1" in
        shell) printf '%s' "$T49_SHELL_ROOT" ;;
        glob)  printf '%s' "$T49_GLOB_ROOT" ;;
    esac
}

t49_meta_fx() { # <key> -> fixture dir
    case "$1" in
        shell) printf '%s' "$T49_SHELL_FX" ;;
        glob)  printf '%s' "$T49_GLOB_FX" ;;
    esac
}

t49_meta_setup() {
    local fx
    T49_SHELL_FX="$(mk_fixture "$T49_SHELL_ROOT")"
    T49_GLOB_FX="$(mk_fixture "$T49_GLOB_ROOT")"
    for fx in "$T49_SHELL_FX" "$T49_GLOB_FX"; do
        mk_tool "$fx" "$T49_META_TOOL" env-bash
        write_ssot "$fx" "$T49_META_TOOL"
        write_settings "$fx" --
        write_ext "$fx" --
        run_gen "$fx" --write
        deployed_allow_dump "$fx" "$fx/allow.txt"
    done
}

# Each precondition is a row for the same reason the space fixture's is: a platform that rejected
# or silently rewrote one of these characters would leave every row below re-asking the space
# question while still reporting green.
t49_meta_shape() { # <fixture> <required-chars> -> has-metachars | MISSING-CHAR:<c> | sentinel
    have_gen || { missing_gen; return; }
    resolve_root "$1" || { printf 'ROOT-UNRESOLVED'; return; }
    local root="${_ROOT_POSIX[$1]}" c i=0
    while [ "$i" -lt "${#2}" ]; do
        c="${2:$i:1}"
        case "$root" in *"$c"*) : ;; *) printf 'MISSING-CHAR:%s' "$c"; return ;; esac
        i=$((i + 1))
    done
    printf 'has-metachars'
}

t49_meta_placeholder() { # -> keeps-placeholder-text | PLACEHOLDER-TEXT-LOST | sentinel
    have_gen || { missing_gen; return; }
    resolve_root "$T49_GLOB_FX" || { printf 'ROOT-UNRESOLVED'; return; }
    case "${_ROOT_POSIX[$T49_GLOB_FX]}" in
        *'$AGENTS_CONFIG_DIR'*) printf 'keeps-placeholder-text' ;;
        *)                      printf 'PLACEHOLDER-TEXT-LOST' ;;
    esac
}

t49_meta_state() { # <id> -> verdict | sentinel
    case "$1" in
        shell-shape)      t49_meta_shape "$T49_SHELL_FX" '$`&;'"'"'.' ;;
        glob-shape)       t49_meta_shape "$T49_GLOB_FX" '[]{}$' ;;
        glob-placeholder) t49_meta_placeholder ;;
        shell-complete)   t49_complete_in "$T49_SHELL_FX" "$T49_META_TOOL" ;;
        glob-complete)    t49_complete_in "$T49_GLOB_FX" "$T49_META_TOOL" ;;
    esac
}

t49_meta_state_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T49[meta-$id]: $label" "$want" "$(t49_meta_state "$id")"
    done <<'T49_META_STATE_CASES'
shell-shape|has-metachars|PRECONDITION: the shell-metacharacter root really survived onto disk with its `$`, backtick, `&`, `;`, quote and `.` intact
glob-shape|has-metachars|PRECONDITION: the glob root really carries its brackets and braces -- the characters an unescaped matcher reads as a character class rather than as text
glob-placeholder|keeps-placeholder-text|PRECONDITION: the glob root still spells `$AGENTS_CONFIG_DIR` literally, so the rows below ask whether the renderer tells a root segment from its own placeholder text
shell-complete|complete|all twenty-four path spellings render exactly under the shell-metacharacter root: inside an already-quoted rule a metacharacter is inert text, escaped by nothing
glob-complete|complete|and under the glob root, whose literal `$AGENTS_CONFIG_DIR` segment must reach the rule as itself rather than as the placeholder it looks like
T49_META_STATE_CASES
}

t49_meta_quoted_table() {
    local id key rule label fx expanded
    while IFS='|' read -r id key rule label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        fx="$(t49_meta_fx "$key")"
        expanded="$(expand_root_placeholders "$rule" "$fx")"
        assert_eq "T49[meta-$id]: $label -- $expanded" "present" "$(t49_has_in "$fx" "$rule")"
    done <<'T49_META_QUOTED_CASES'
shell-interp-posix|shell|Bash(bash "<R>/bin/fx-meta" *)|interpreter + QUOTED absolute POSIX path under a root full of shell metacharacters, none of them expanded on the way in
shell-interp-win|shell|Bash(bash "<R2W>\bin\fx-meta" *)|the same in Windows separators, where the backslashes and the metacharacters share one string
shell-plain-posix|shell|Bash("<R>/bin/fx-meta" *)|the interpreter-free POSIX spelling, whose opening quote is the first character of the rule body
shell-plain-win|shell|Bash("<R2W>\bin\fx-meta" *)|and the interpreter-free Windows spelling
glob-interp-posix|glob|Bash(bash "<R>/bin/fx-meta" *)|interpreter + QUOTED absolute POSIX path under a root carrying glob brackets, braces and the literal text `$AGENTS_CONFIG_DIR`
glob-interp-win|glob|Bash(bash "<R2W>\bin\fx-meta" *)|the same in Windows separators
glob-plain-posix|glob|Bash("<R>/bin/fx-meta" *)|the interpreter-free POSIX spelling
glob-plain-win|glob|Bash("<R2W>\bin\fx-meta" *)|and the interpreter-free Windows spelling -- CPR-ORTH: both roots, all four families
T49_META_QUOTED_CASES
}

# CLASSIFICATION UNDER A METACHARACTER ROOT, BOTH DIRECTIONS IN ONE VERDICT. As two rows the
# negative half would read green today for the wrong reason -- nothing matches anything while the
# quoted families are unwritten. Asserted together, `claimed` for this root and `not-claimed` for
# a near-miss differing from it only where a regex metacharacter sits is reachable only when the
# root is escaped EXACTLY: escape too little and the near-miss is claimed as ours and deleted on
# the next --write; escape wrongly and the rule this root really deployed is disowned.
t49_meta_orphan_one() { # <root-name> <tag> <rule> <from> <to> -> "<claimed|not-claimed>/rc=<n>"
    local fx rule claimed
    fx="$(mk_fixture "$1 $2")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    rule="$(expand_root_placeholders "$3" "$fx")" || { printf 'ROOT-UNRESOLVED'; return; }
    # Pattern and replacement are both QUOTED: unquoted, `[glob]` is a glob character class and
    # would rewrite a single letter somewhere else in the path instead of the segment named here.
    if [ -n "$4" ]; then rule="${rule//"$4"/"$5"}"; fi
    {
        expected_path_rules bash bin/fx-keep "$fx"
        printf '%s\n' "$rule"
    } > "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --write
    run_gen "$fx" --check
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-orphan'; then claimed="claimed"; else claimed="not-claimed"; fi
    printf '%s/rc=%s' "$claimed" "$GEN_RC"
}

t49_meta_orphan() { # <key> <rule> <from> <to> -> "<self>/<near-miss>" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local root
    root="$(t49_meta_root_name "$1")"
    printf '%s/%s' "$(t49_meta_orphan_one "$root" "$1-self" "$2" '' '')" \
                   "$(t49_meta_orphan_one "$root" "$1-near" "$2" "$3" "$4")"
}

t49_meta_orphan_table() {
    local key rule from to want label
    while IFS='|' read -r key rule from to want label; do
        [ -n "$key" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T49[meta-orphan-$key]: $label" "$want" "$(t49_meta_orphan "$key" "$rule" "$from" "$to")"
    done <<'T49_META_ORPHAN_CASES'
shell|Bash(bash "<R>/bin/fx-orphan" *)|tilde.d|tildeXd|claimed/rc=1/not-claimed/rc=0|a quoted rule under the shell-metacharacter root is claimed as this checkout's own, while the near-miss differing only where the root's `.` sits is left alone: an unescaped dot matches any character and would hand one clone another clone's rule to delete
glob|Bash("<R>/bin/fx-orphan" *)|[glob]|g|claimed/rc=1/not-claimed/rc=0|and the interpreter-free quoted rule under the glob root, whose near-miss replaces `[glob]` with the single letter an unescaped character class would happily match
T49_META_ORPHAN_CASES
}

t49_setup
t49_complete_table
t49_quoted_table
t49_orphan_table
t49_meta_setup
t49_meta_state_table
t49_meta_quoted_table
t49_meta_orphan_table
