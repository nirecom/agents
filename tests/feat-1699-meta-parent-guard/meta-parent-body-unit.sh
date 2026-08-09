# tests/feat-1699-meta-parent-guard/meta-parent-body-unit.sh
# Tests: bin/github-issues/lib/meta-parent-body.sh
# Tags: issue-create, meta-parent, body, unit, argv, injection, table-driven, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Whether GitHub renders the produced Markdown the way the group intends, and whether
#   `Grouped at creation: #N` actually cross-links on the live forge.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Group U — meta-parent-body.sh on its own terms.
#
# Why direct coverage (CPR-SC): every other group in this suite reaches this script
# through the dispatcher, where its output is one argv element among many and the only
# thing observed is that a body arrived. That answers "was it called", never "what does
# it do with the input it is given" — so the argument parser, the `--children`
# normaliser and the interpolation of an operator-supplied title are all untested.
#
# Why the title is treated as untrusted: it is free text typed by whoever ran
# /issue-create and it is interpolated into a shell script's printf. It is not
# attacker-controlled in the way a candidate body is, but it travels the same path, and
# `$(...)`/backticks/`;` in a group theme are ordinary punctuation a human might type
# without meaning anything by it. The script must render them, never run them.
#
# This group calls the script directly and does not use the suite's gh mock — there is
# no forge call on this path at all, which is itself part of the contract (U0).

MPB="$AGENTS_DIR/bin/github-issues/lib/meta-parent-body.sh"

u_run() {  # <args...> → U_OUT, U_ERR, U_RC
    U_OUT="$(bash "$RWT" 20 bash "$MPB" "$@" 2>"$U_ERRFILE")"
    U_RC=$?
    U_ERR="$(cat "$U_ERRFILE")"
}

# count_lines_starting <text> <prefix>
u_count_prefix() { printf '%s\n' "$1" | grep -c "^$2" || true; }

U_TMP="$(mktemp -d)"
U_ERRFILE="$U_TMP/stderr.txt"

if [ ! -f "$MPB" ]; then
    fail "U0-script-exists" "RED-EXPECTED: bin/github-issues/lib/meta-parent-body.sh not found"
else
    pass "U0-script-exists"

    # -----------------------------------------------------------------------------
    # U1 — argument parser. Every rejection is exit 2 with a message on STDERR and
    # nothing on stdout: a body that is half-written is worse than no body, because the
    # caller pipes stdout straight into `gh issue create --body-file`.
    # -----------------------------------------------------------------------------
    while IFS='|' read -r name want_rc args; do
        [ -z "${name// }" ] && continue
        name="${name//[[:space:]]/}"; want_rc="${want_rc//[[:space:]]/}"
        args="${args#"${args%%[![:space:]]*}"}"; args="${args%"${args##*[![:space:]]}"}"
        # shellcheck disable=SC2086
        if [ "$args" = "__NONE__" ]; then u_run; else u_run $args; fi
        if [ "$U_RC" != "$want_rc" ]; then
            fail "$name" "want exit $want_rc (got $U_RC; stdout='$U_OUT' stderr='$U_ERR')"
        elif [ "$want_rc" != "0" ] && [ -n "$U_OUT" ]; then
            fail "$name" "a rejected invocation wrote to stdout, which the caller feeds to gh --body-file: '$U_OUT'"
        elif [ "$want_rc" != "0" ] && [ -z "$U_ERR" ]; then
            fail "$name" "rejected with exit $U_RC but said nothing on stderr — the operator gets no reason"
        else
            pass "$name"
        fi
    done <<'TABLE'
U1a-no-args-is-usage-error        | 2 | __NONE__
U1b-title-flag-without-value      | 2 | --title
U1c-children-flag-without-value   | 2 | --title T --children
U1d-unknown-flag                  | 2 | --title T --parent 9
U1e-bare-positional               | 2 | T
U1f-empty-title-rejected          | 2 | --title
U1g-title-only-is-accepted        | 0 | --title T
TABLE

    # U1f above passes `--title` with no value; the genuinely empty STRING is a separate
    # input and needs its own row, because `[ -z "$TITLE" ]` is what catches it.
    u_run --title ""
    if [ "$U_RC" -eq 2 ] && [ -z "$U_OUT" ]; then
        pass "U1h-empty-string-title-rejected"
    else
        fail "U1h-empty-string-title-rejected" "want exit 2 and no stdout (got rc=$U_RC stdout='$U_OUT')"
    fi

    # -----------------------------------------------------------------------------
    # U2 — the schema issue-create.sh validates. Exactly one Background line and
    # exactly one Changes line, both at the start of a line.
    # -----------------------------------------------------------------------------
    u_run --title "flaky worker dispatch"
    U_BASE="$U_OUT"
    if [ "$(u_count_prefix "$U_BASE" 'Background: ')" = "1" ]; then
        pass "U2a-exactly-one-background-line"
    else
        fail "U2a-exactly-one-background-line" "want exactly one 'Background: ' line (got $(u_count_prefix "$U_BASE" 'Background: '))"
    fi
    if [ "$(u_count_prefix "$U_BASE" 'Changes: ')" = "1" ]; then
        pass "U2b-exactly-one-changes-line"
    else
        fail "U2b-exactly-one-changes-line" "want exactly one 'Changes: ' line (got $(u_count_prefix "$U_BASE" 'Changes: '))"
    fi
    # The header comment makes a specific promise about the FIRST line: it names the
    # theme and says the parent carries no implementation. Previews and digests show
    # only that line, so its content is a contract, not formatting.
    U_FIRST="$(printf '%s\n' "$U_BASE" | sed -n '1p')"
    case "$U_FIRST" in
        Background:*flaky\ worker\ dispatch*) pass "U2c-first-line-names-the-theme" ;;
        *) fail "U2c-first-line-names-the-theme" "the opening line must carry the group theme (got: '$U_FIRST')" ;;
    esac
    if printf '%s' "$U_FIRST" | grep -qi 'no implementation'; then
        pass "U2d-first-line-says-no-implementation"
    else
        fail "U2d-first-line-says-no-implementation" "the opening line must state that the parent carries no implementation (got: '$U_FIRST')"
    fi
    # Without --children there must be no dangling group reference.
    if printf '%s' "$U_BASE" | grep -q 'Grouped at creation'; then
        fail "U2e-no-children-no-grouped-line" "a 'Grouped at creation' line appeared with no --children"
    else
        pass "U2e-no-children-no-grouped-line"
    fi

    # -----------------------------------------------------------------------------
    # U3 — --children normalisation. The value arrives as one comma-joined string from
    # a shell caller, so whitespace and empty slots are the normal case, not an edge.
    # -----------------------------------------------------------------------------
    while IFS='|' read -r name children want; do
        [ -z "${name// }" ] && continue
        name="${name//[[:space:]]/}"
        children="${children#"${children%%[![:space:]]*}"}"; children="${children%"${children##*[![:space:]]}"}"
        want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
        [ "$children" = "__EMPTY__" ] && children=""
        u_run --title "T" --children "$children"
        GOT="$(printf '%s\n' "$U_OUT" | sed -n 's/^Grouped at creation: //p')"
        if [ "$want" = "__ABSENT__" ]; then
            if [ -z "$GOT" ]; then pass "$name"
            else fail "$name" "want no 'Grouped at creation' line (got: '$GOT')"; fi
        elif [ "$GOT" = "$want" ]; then
            pass "$name"
        else
            fail "$name" "want 'Grouped at creation: $want' (got: '${GOT:-<absent>}')"
        fi
    done <<'TABLE'
U3a-single-child          | 42            | #42
U3b-multiple-children     | 42,43,44      | #42, #43, #44
U3c-surrounding-spaces    |  42 , 43 , 44 | #42, #43, #44
U3d-empty-slots-dropped   | ,42,,43,      | #42, #43
U3e-empty-string-absent   | __EMPTY__     | __ABSENT__
U3f-only-separators       | ,,,           | __ABSENT__
TABLE

    # -----------------------------------------------------------------------------
    # U4 — the title is rendered, never executed, and never reinterpreted.
    #
    # Each row supplies a title that would do something visible if it were evaluated,
    # and asserts (a) the literal text survives into the body and (b) the evidence of
    # evaluation is absent. Asserting only (a) would pass on a shell that expanded the
    # substring and happened to leave the rest; asserting only (b) would pass if the
    # title had been dropped entirely.
    # -----------------------------------------------------------------------------
    u_run --title 'theme $(id) and `id` end'
    if printf '%s' "$U_OUT" | grep -qF 'theme $(id) and `id` end'; then
        pass "U4a-command-substitution-rendered-literally"
    else
        fail "U4a-command-substitution-rendered-literally" "the title's \$( ) / backticks did not survive verbatim (got: '$U_OUT')"
    fi
    if printf '%s' "$U_OUT" | grep -qE 'uid=[0-9]+'; then
        fail "U4b-command-substitution-not-executed" "the title was evaluated — command output landed in the issue body"
    else
        pass "U4b-command-substitution-not-executed"
    fi

    u_run --title 'group; touch '"$U_TMP"'/pwned'
    if [ -e "$U_TMP/pwned" ]; then
        fail "U4c-semicolon-not-a-command-separator" "a semicolon in the title ran a command"
    else
        pass "U4c-semicolon-not-a-command-separator"
    fi

    # A glob in the title must not be expanded against the CWD. Running from a
    # directory that contains files makes the row non-vacuous: an unquoted expansion
    # would substitute their names.
    U_OLDPWD="$PWD"
    cd "$U_TMP" || true
    : > "$U_TMP/glob-bait-one"; : > "$U_TMP/glob-bait-two"
    u_run --title 'group glob-bait-*'
    cd "$U_OLDPWD" || true
    if printf '%s' "$U_OUT" | grep -qF 'group glob-bait-*'; then
        pass "U4d-glob-not-expanded"
    else
        fail "U4d-glob-not-expanded" "the title's glob was expanded against the working directory (got: '$U_OUT')"
    fi

    # printf format directives are the failure mode a naive `printf "$TITLE"` has, and
    # it is silent: %s consumes a missing argument and renders as nothing.
    u_run --title 'coverage %s and %d and 100%%'
    if printf '%s' "$U_OUT" | grep -qF 'coverage %s and %d and 100%%'; then
        pass "U4e-printf-directives-rendered-literally"
    else
        fail "U4e-printf-directives-rendered-literally" "the title was used as a printf FORMAT, not an argument (got: '$U_OUT')"
    fi

    # Backslash escapes: `printf '%s'` renders them literally, `printf '%b'` or `echo -e`
    # would turn \n into a newline and split the Background line in two.
    u_run --title 'a\nb\tc'
    if [ "$(u_count_prefix "$U_OUT" 'Background: ')" = "1" ] && printf '%s' "$U_OUT" | grep -qF 'a\nb\tc'; then
        pass "U4f-backslash-escapes-not-interpreted"
    else
        fail "U4f-backslash-escapes-not-interpreted" "backslash escapes in the title were interpreted (got: '$U_OUT')"
    fi

    # Non-ASCII must survive byte-for-byte; the group theme is the operator's own words.
    u_run --title 'テーマ — grüße'
    if printf '%s' "$U_OUT" | grep -qF 'テーマ — grüße'; then
        pass "U4g-utf8-title-preserved"
    else
        fail "U4g-utf8-title-preserved" "a non-ASCII title was mangled (got: '$U_OUT')"
    fi

    # A leading dash must be consumed as the --title VALUE, not re-parsed as a flag.
    u_run --title '--children'
    if [ "$U_RC" -eq 0 ] && printf '%s' "$U_OUT" | grep -qF -- '--children'; then
        pass "U4h-dash-leading-title-is-a-value"
    else
        fail "U4h-dash-leading-title-is-a-value" "a title beginning with '-' was re-parsed as a flag (rc=$U_RC out='$U_OUT')"
    fi

    # -----------------------------------------------------------------------------
    # U5 — a --children value carrying metacharacters is rendered, not run. Same
    # concern as U4 on the other operand, which is normalised by a different code path
    # (IFS split + substring removal) and so cannot inherit U4's result (CPR-ORTH).
    # -----------------------------------------------------------------------------
    u_run --title "T" --children '1,$(id),`id`,2'
    if printf '%s' "$U_OUT" | grep -qE 'uid=[0-9]+'; then
        fail "U5a-children-not-executed" "a --children entry was evaluated — command output landed in the issue body"
    else
        pass "U5a-children-not-executed"
    fi
    U5GOT="$(printf '%s\n' "$U_OUT" | sed -n 's/^Grouped at creation: //p')"
    if printf '%s' "$U5GOT" | grep -qF '#1' && printf '%s' "$U5GOT" | grep -qF '#2'; then
        pass "U5b-children-ordinary-entries-still-rendered"
    else
        fail "U5b-children-ordinary-entries-still-rendered" "the well-formed entries were lost alongside the hostile ones (got: '${U5GOT:-<absent>}')"
    fi

    # -----------------------------------------------------------------------------
    # U6 — size. A long theme must not truncate or crash; the body is what a human
    # reads, so silent loss is worse than a long line.
    # -----------------------------------------------------------------------------
    U_LONG="$(printf 'x%.0s' $(seq 1 5000))"
    u_run --title "$U_LONG"
    if [ "$U_RC" -eq 0 ] && [ "$(u_count_prefix "$U_OUT" 'Background: ')" = "1" ] \
       && printf '%s' "$U_OUT" | grep -qF "$U_LONG"; then
        pass "U6a-long-title-survives-intact"
    else
        fail "U6a-long-title-survives-intact" "a 5000-char title was truncated or rejected (rc=$U_RC)"
    fi

    # Many children: the normaliser is a loop, so its cost and correctness at 25 (the
    # validator's CANDIDATE_MAX) is the realistic upper bound.
    U_MANY="$(seq -s, 1 25)"
    u_run --title "T" --children "$U_MANY"
    U6GOT="$(printf '%s\n' "$U_OUT" | sed -n 's/^Grouped at creation: //p')"
    if [ "$(printf '%s' "$U6GOT" | grep -o '#' | grep -c .)" = "25" ]; then
        pass "U6b-25-children-all-rendered"
    else
        fail "U6b-25-children-all-rendered" "want 25 '#' references (got: '$U6GOT')"
    fi
fi

rm -rf "$U_TMP"
