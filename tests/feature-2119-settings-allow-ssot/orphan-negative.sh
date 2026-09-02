# tests/feature-2119-settings-allow-ssot/orphan-negative.sh
# Tests: install/lib/settings-allow-rules.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, orphan, scope:issue-specific, pwsh-not-required, TL2
# T42: the PATH-form orphan classifier's NEGATIVE verdict. Sourced AFTER orphan-classifier.sh.

T42_TOOL="bin/fx-keep"

# WHY THIS FILE EXISTS. T14 shows the classifier saying YES to all sixteen path spellings, and
# T35 shows both verdicts for the BARE forms. Nothing shows the path classifier saying NO. A
# reverse matcher that answers "generated-shaped" for everything passes all sixteen T14 rows,
# and its first --check on a real machine reports a developer's own hand-written `Bash(...)`
# rules as orphans -- which, on the next manual cleanup, is how they get deleted. CPR-ORTH:
# every verdict of a classifier needs a row, not only the one the happy path exercises.

T42_OTHER="fx-other"

# The near-misses are derived from the template grammar itself, not invented: each differs from
# a real spelling by exactly one thing the placeholder classes forbid -- an interpreter outside
# bash|node, a space inside the path class, the space in front of the trailing `*`, the literal
# `agents` path segment, and the literal `cd "$AGENTS_CONFIG_DIR" &&` prefix.
#
# The fixture deploys ONE in-SSOT command healthily and then adds the candidate rule to the
# BASE settings.json, which is where a hand-written rule actually lives. Deploying first makes
# rc=0 a real "nothing to report" rather than "there was nothing deployed to compare".
t42_probe() { # <rule-string> -> "<claimed|not-claimed>/rc=<n>" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx claimed rule
    fx="$(mk_fixture "t42-$(printf '%s' "$1" | cksum | tr -d ' ')")"
    rule="$(expand_root_placeholders "$1" "$fx")"
    mk_tool "$fx" "$T42_TOOL" env-bash
    write_ssot "$fx" "$T42_TOOL"
    {
        expected_path_rules bash "$T42_TOOL" "$fx"
        printf '%s\n' "$rule"
    } > "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --write
    run_gen "$fx" --check
    if printf '%s\n' "$GEN_OUT" | grep -Fq -- "$T42_OTHER"; then claimed="claimed"; else claimed="not-claimed"; fi
    printf '%s/rc=%s' "$claimed" "$GEN_RC"
}

t42_negative_table() {
    local id want rule label
    while IFS='|' read -r id want rule label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T42[$id]: $label" "$want" "$(t42_probe "$rule")"
    done <<'T42_CASES'
control-shaped|claimed/rc=1|Bash(bash bin/fx-other *)|POSITIVE CONTROL: the exact `<I> <P> *` spelling for a command the SSOT does not list IS an orphan, so the six rows below are not passing because the classifier answers NO to everything
foreign-interpreter|not-claimed/rc=0|Bash(python3 bin/fx-other *)|an interpreter outside bash and node is not a spelling this generator can ever emit, so the rule is somebody else's and stays unreported
flag-not-wildcard|not-claimed/rc=0|Bash(bash bin/fx-other --flag)|a hand-written rule pinning one FLAG is not the argument-less spelling: the path class cannot span the space, and treating it as generated would delete a deliberately narrow rule
no-space-before-star|not-claimed/rc=0|Bash(bash bin/fx-other*)|the trailing wildcard WITHOUT the space in front of it is different match semantics and not a generated form -- that space is the exact character the argument-less pair turns on
foreign-root|claimed/rc=1|Bash(bash /some/other/checkout/bin/fx-other *)|DERIVED FROM THE CLASS: `<P>` is `[A-Za-z0-9._/-]+`, which contains `/` and therefore spans a whole absolute POSIX path, so the plain `<I> <P> *` family claims a foreign-root POSIX rule even though the `<R>` family would not -- deliberate, per the module's own note that another checkout's root is an orphan here
foreign-root-win|not-claimed/rc=0|Bash(bash D:\some\other\checkout\bin\fx-other *)|THE ASYMMETRY, and why the row above is not a bug: `:` falls outside every placeholder class, so a Windows foreign-root rule can only reach the `<W>` family, which demands THIS checkout's root as a literal `<R2W>` prefix -- it has no `<P>`-style escape hatch and stays unclaimed
foreign-cd-prefix|not-claimed/rc=0|Bash(bash -c 'cd "$HOME" && bash "$AGENTS_CONFIG_DIR/bin/fx-other" *')|the `bash -c 'cd ... && ...'` family requires the literal cd into $AGENTS_CONFIG_DIR: a wrapper that cds somewhere else is a hand-written rule with different behaviour
T42_CASES
}

t42_negative_table

# T44 -- PATH-TRAVERSAL-SHAPED RULE STRINGS. T13 pins traversal at the SSOT ENTRY gate, where
# validateEntry rejects `..` and a leading `/` before anything is rendered; nothing pins the
# other end, where such a string arrives already spelled as a rule in the base settings.json
# and the orphan classifier has to judge it. The judgement is SHAPE ONLY -- `<P>` is the class
# `[A-Za-z0-9._/-]+`, which admits `.` and `/` and therefore admits `../` and a leading slash,
# while `<W>` admits `\` but not `/`. So the verdict per row is derived from that class, not
# assumed: a traversal form the class spans IS generated-shaped, and being shaped it is
# reported. What protects it is the other half of the contract -- the report says "--write
# will not remove them ... delete them by hand" -- so every row also pins that the rule is
# still in the deployed file after the --write.
t44_probe() { # <rule-string> -> "<claimed|not-claimed>/rc=<n>/<survives|REMOVED>" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx claimed lives rule
    fx="$(mk_fixture "t44-$(printf '%s' "$1" | cksum | tr -d ' ')")"
    rule="$(expand_root_placeholders "$1" "$fx")"
    mk_tool "$fx" "$T42_TOOL" env-bash
    write_ssot "$fx" "$T42_TOOL"
    {
        expected_path_rules bash "$T42_TOOL" "$fx"
        printf '%s\n' "$rule"
    } > "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --write
    deployed_allow_dump "$fx" "$fx/allow.txt"
    if grep -Fxq -- "$rule" "$fx/allow.txt" 2>/dev/null; then lives="survives"; else lives="REMOVED"; fi
    run_gen "$fx" --check
    if printf '%s\n' "$GEN_OUT" | grep -Fq -- "$T42_OTHER"; then claimed="claimed"; else claimed="not-claimed"; fi
    printf '%s/rc=%s/%s' "$claimed" "$GEN_RC" "$lives"
}

t44_traversal_table() {
    local id want rule label
    while IFS='|' read -r id want rule label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T44[$id]: $label" "$want" "$(t44_probe "$rule")"
    done <<'T44_CASES'
traversal-relative|claimed/rc=1/survives|Bash(bash ../fx-other *)|DERIVED, NOT ASSUMED: `../fx-other` is spanned by the `<P>` class, so the `<I> <P> *` family claims it -- and because validateEntry can never emit a `..` entry, a rule of this shape is always stale or hand-typed and belongs in the report. It is REPORTED, never removed
traversal-argless|claimed/rc=1/survives|Bash(bash ../fx-other)|CPR-ORTH: the argument-less half of that same pair is spanned identically -- a classifier lenient in only one half of a pair is the failure this issue was opened about
traversal-through-configdir|claimed/rc=1/survives|Bash(bash "$AGENTS_CONFIG_DIR/../../fx-other" *)|the traversal buried inside the $AGENTS_CONFIG_DIR family is claimed too: the class sits after the literal prefix, so escaping the root does not escape the classifier
absolute-posix|claimed/rc=1/survives|Bash(bash /tmp/fx-other *)|a leading slash is inside `[A-Za-z0-9._/-]` as well, so an absolute-path rule is generated-shaped and reported for review rather than passed over in silence
win-family-traversal|claimed/rc=1/survives|Bash(bash <R2W>\..\..\fx-other *)|the Windows-separator family's `<W>` class admits `\`, so its own traversal spelling is claimed -- the symmetric counterpart of the row above
drive-letter|not-claimed/rc=0/survives|Bash(bash C:/fx-other *)|`:` is outside every placeholder class, so a drive-qualified rule is somebody else's: claiming it would put a developer's own Windows rule on a delete-by-hand list
home-tilde|not-claimed/rc=0/survives|Bash(bash ~/fx-other *)|`~` is outside the class too, and a home-relative rule is a shape this generator has no way to produce
percent-encoded|not-claimed/rc=0/survives|Bash(bash %2e%2e/fx-other *)|the percent-encoded spelling of `../` is NOT decoded before matching: the classifier is textual, and a matcher that normalised first would start claiming strings no template can render
backslash-no-family|not-claimed/rc=0/survives|Bash(bash ..\..\fx-other *)|backslash traversal WITHOUT the literal Windows-form root in front of it belongs to no family at all -- `<P>` has no `\` and the `<W>` family demands that prefix
win-family-forward-slash|not-claimed/rc=0/survives|Bash(bash <R2W>\../fx-other *)|the mirror of the claimed Windows row: one forward slash puts the tail outside `<W>`, and the two rows together show the class boundary is the actual decision
root-prefix-lookalike|not-claimed/rc=0/survives|Bash(bash <R>-backup/fx-other *)|a root that merely RESEMBLES this checkout's: the literal is the root itself, and `<root>-backup/` is a different tree's rule
prefix-lookalike-var|not-claimed/rc=0/survives|Bash(bash "$AGENTS_CONFIG_DIRX/fx-other" *)|a variable whose name merely starts with $AGENTS_CONFIG_DIR is a different variable, and treating the prefix as a match would claim rules pointing somewhere else entirely
T44_CASES
}

t44_traversal_table
