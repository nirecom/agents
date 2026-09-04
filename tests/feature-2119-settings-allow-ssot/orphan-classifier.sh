# tests/feature-2119-settings-allow-ssot/orphan-classifier.sh
# Tests: install/gen-settings-allow.js, install/path-exposed-commands.txt
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T14-T16: --check as a classifier. Sourced AFTER write-and-drift.sh, whose helpers this reuses.

# T14 -- ONE TEMPLATE PER ROW: T7b hands all ten path forms over at once, so recognising
# ONE suffices to pass. Each spelling gets its own fixture, and the in-sync command must
# stay OUT of the report so a "list everything" implementation cannot read as a classifier.
# Addressed by LINE of expected_path_rules, so the two closed forms (lines 1-2, #2170)
# are reachable alongside the eight wildcard forms (lines 3-10).
t14_path_line() { # <line# 1..10> <fixture-tag> -> verdict|sentinel
    have_gen || { missing_gen; return; }
    local fx rcv named silent
    fx="$(mk_fixture "t14-path-$2")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    expected_path_rules bash bin/fx-keep > "$fx/pre.txt"
    expected_path_rules bash bin/fx-dropped | sed -n "$1p" >> "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --check
    if [ "$GEN_RC" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-dropped'; then named="dropped-named"; else named="dropped-NOT-named"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-keep'; then silent="keep-REPORTED"; else silent="keep-silent"; fi
    printf '%s/%s/%s' "$rcv" "$named" "$silent"
}

# Rows c1/c2 are the CLOSED (argument-less) forms #2170 added at the head of
# PATH_TEMPLATES; without them a stale grant in either spelling escapes the
# reverse-matcher entirely, since no wildcard template can match a closed rule.
t14_path_table() {
    local k label
    while IFS='|' read -r k label; do
        [ -n "$k" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T14[path-$k]: an orphan in the '$label' form alone is detected" \
            "nonzero/dropped-named/keep-silent" "$(t14_path_line "${k#c}" "$k")"
    done <<'T14_PATH_CASES'
c1|<I> "$AGENTS_CONFIG_DIR/<P>" (closed, no trailing wildcard)
c2|<I> <P> (closed, no trailing wildcard)
3|<I> "$AGENTS_CONFIG_DIR/<P>" *
4|<I> */agents/<P> *
5|<I> *\agents\<P> * (Windows separators)
6|<I> <P> *
7|"$AGENTS_CONFIG_DIR/<P>" * (no interpreter prefix)
8|*/agents/<P> * (no interpreter prefix)
9|bash -c '<I> "$AGENTS_CONFIG_DIR/<P>" *'
10|bash -c 'cd "$AGENTS_CONFIG_DIR" && <I> "$AGENTS_CONFIG_DIR/<P>" *'
T14_PATH_CASES
}

# T15 -- THE THREE BARE FORMS, which T7b never exercises at all. They are keyed on a different
# SSOT (install/path-exposed-commands.txt) and extract a basename rather than a path, so an
# implementation can reverse-match all ten path forms and still be blind to every one of
# these. The fixture's own command IS PATH-exposed, so its thirteen rules are complete and the
# orphan is the only finding.
t15_bare_template() { # <k 1..3> -> "nonzero/gone-named/keep-silent" | sentinel
    have_gen || { missing_gen; return; }
    local fx rcv named silent
    fx="$(mk_fixture "t15-bare-$1")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    printf '%s\n' 'fx-keep' >> "$fx/install/path-exposed-commands.txt"
    expected_path_rules bash bin/fx-keep > "$fx/pre.txt"
    expected_bare_rules fx-keep >> "$fx/pre.txt"
    expected_bare_rules fx-gone | sed -n "$1p" >> "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --check
    if [ "$GEN_RC" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-gone'; then named="gone-named"; else named="gone-NOT-named"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-keep'; then silent="keep-REPORTED"; else silent="keep-silent"; fi
    printf '%s/%s/%s' "$rcv" "$named" "$silent"
}

t15_bare_table() {
    local k label
    while IFS='|' read -r k label; do
        [ -n "$k" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T15[bare-$k]: a bare-form orphan in the '$label' form alone is detected" \
            "nonzero/gone-named/keep-silent" "$(t15_bare_template "$k")"
    done <<'T15_BARE_CASES'
1|<N> *
2|bash -c '<N> *'
3|bash -c 'cd "$AGENTS_CONFIG_DIR" && <N> *'
T15_BARE_CASES
}

# T16 -- THE REPORT IS THE PRODUCT. `--check` runs from a git hook, where a non-zero exit with
# a vague message costs a developer the whole diagnosis. Two properties are asserted: the
# missing list is COMPLETE (all thirteen spellings for a command with nothing in the file, not
# just the first one the loop noticed), and Missing and Orphaned are reported as two separate
# sections when both conditions hold at once -- the state a real drifted repository is in.
T16_COMPLETE=""
T16_BOTH=""

t16_setup() {
    T16_COMPLETE="$(mk_fixture t16-complete)"
    mk_tool "$T16_COMPLETE" bin/fx-keep env-bash
    write_ssot "$T16_COMPLETE" bin/fx-keep
    printf '%s\n' 'fx-keep' >> "$T16_COMPLETE/install/path-exposed-commands.txt"
    write_settings "$T16_COMPLETE" --
    {
        expected_path_rules bash bin/fx-keep
        expected_bare_rules fx-keep
    } > "$T16_COMPLETE/want.txt"

    T16_BOTH="$(mk_fixture t16-both)"
    mk_tool "$T16_BOTH" bin/fx-keep env-bash
    write_ssot "$T16_BOTH" bin/fx-keep
    expected_path_rules bash bin/fx-dropped > "$T16_BOTH/pre.txt"
    write_settings "$T16_BOTH" "$T16_BOTH/pre.txt"
}

# A section heading is a line that talks about missing or orphaned entries and is not itself a
# rule string, so a report that only lists `Bash(...)` lines cannot pass as sectioned output.
t16_probe() { # <complete|missing-section|orphan-section|both-named|rc> -> verdict | sentinel
    have_gen || { missing_gen; return; }
    local rule
    if [ "$1" = "complete" ]; then
        run_gen "$T16_COMPLETE" --check
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            printf '%s\n' "$GEN_OUT" | grep -Fq -- "$rule" || { printf 'NOT-REPORTED:%s' "$rule"; return; }
        done < "$T16_COMPLETE/want.txt"
        printf 'complete'
        return
    fi
    run_gen "$T16_BOTH" --check
    case "$1" in
        missing-section)
            printf '%s\n' "$GEN_OUT" | grep -vi '^ *Bash(' | grep -qi 'missing' \
                && { printf 'yes'; return; } ;;
        orphan-section)
            printf '%s\n' "$GEN_OUT" | grep -vi '^ *Bash(' | grep -qi 'orphan' \
                && { printf 'yes'; return; } ;;
        both-named)
            printf '%s\n' "$GEN_OUT" | grep -q 'fx-keep' \
                && printf '%s\n' "$GEN_OUT" | grep -q 'fx-dropped' \
                && { printf 'yes'; return; } ;;
        rc)
            [ "$GEN_RC" -ne 0 ] && { printf 'yes'; return; } ;;
    esac
    printf 'no'
}

t16_report_table() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T16[$id]: $label" "yes" "$(t16_probe "$id")"
    done <<'T16_CASES'
missing-section|a Missing section is named when spellings are absent
orphan-section|an Orphaned section is named in the SAME run
both-named|both the missing command and the orphaned one appear in one report
rc|a run carrying both findings exits non-zero
T16_CASES
    ROWS=$((ROWS + 1))
    assert_eq "T16[complete]: every one of the 13 spellings is listed for a command with no rules at all (not just the first)" \
        "complete" "$(t16_probe complete)"
}

t14_path_table
t15_bare_table
t16_setup
t16_report_table
