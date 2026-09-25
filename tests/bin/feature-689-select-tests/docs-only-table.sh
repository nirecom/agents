# Part of tests/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/is-docs-only
# Tags: docs-only, allowlist, table-driven, ssot, scope:issue-specific, pwsh-not-required, TL2
# D — bin/is-docs-only alone: a CLASSIFIER over the allowlist (SSOT: DOCS_ONLY_ALLOWLIST
# in hooks/workflow-gate/staged-evidence.js; this helper exposes it so callers don't re-type
# it). The four exit codes are four distinct facts, collapsing any two is a defect: 0 all-docs,
# 1 some non-docs, 2 no input, 3 cannot run (→ resolve toward RUNNING; S12 pins the caller).
# The rows that matter: CLAUDE.md/SKILL.md are .md but NOT docs — a naive `*.md` gets them wrong.

# Encoded input: `;` separates paths, `@CR@` is a literal CR, `@EMPTY@` is no input at all.
# Encoding is needed because the table is line-oriented and the inputs are multi-line.
decode_docs_input() { # <encoded> ; prints the stdin content for one row
    local enc="$1"
    [ "$enc" = "@EMPTY@" ] && return 0
    enc="${enc//;/$'\n'}"
    enc="${enc//@CR@/$'\r'}"
    printf '%s\n' "$enc"
}

trim_field() { # <text> ; strips outer spaces only, keeps inner ones
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Runs the helper for one row. `mode` selects the environment the row is about, because two
# of the four answers are properties of the ENVIRONMENT rather than of the input:
#   normal    the helper as installed
#   nomodule  a copy with no reachable hooks/ tree — the allowlist SSOT cannot be required
#   nonode    a PATH with no node on it
run_docs_only_mode() { # <mode> <stdin-content> ; sets DO_RC
    local mode="$1" content="$2"
    DO_RC=0
    case "$mode" in
        normal)
            printf '%s' "$content" | run_with_timeout 60 bash "$IS_DOCS_ONLY" >/dev/null 2>&1 || DO_RC=$?
            ;;
        nomodule)
            # run_with_timeout is a shell FUNCTION, so `env VAR=VAL run_with_timeout ...` would
            # try to exec it as a binary and every row here would be exit 127 — the same trap
            # documented in auto-merge-base.sh. Export inside a subshell instead.
            local lone="$TMPDIR_BASE/docs-only-lone"
            mkdir -p "$lone/bin"
            cp "$IS_DOCS_ONLY" "$lone/bin/is-docs-only"
            printf '%s' "$content" | (
                export AGENTS_CONFIG_DIR="$lone"
                run_with_timeout 60 bash "$lone/bin/is-docs-only"
            ) >/dev/null 2>&1 || DO_RC=$?
            ;;
        nonode)
            # /usr/bin:/bin only, minus any node that lives there. A version manager (fnm/nvm)
            # keeps node outside these directories, so this is normally enough; when it is not,
            # the row would be asserting the ordinary path and is skipped instead of lying.
            if ( PATH="/usr/bin:/bin"; command -v node >/dev/null 2>&1 ); then
                DO_RC="SKIP"
                return 0
            fi
            printf '%s' "$content" | (
                export PATH="/usr/bin:/bin"
                run_with_timeout 60 bash "$IS_DOCS_ONLY"
            ) >/dev/null 2>&1 || DO_RC=$?
            ;;
    esac
}

test_D_is_docs_only() {
    if [ ! -f "$IS_DOCS_ONLY" ]; then
        fail "D_is_docs_only: bin/is-docs-only does not exist (implementation pending)"
        return
    fi
    local name mode input want content got
    while IFS='|' read -r name mode input want; do
        [ -n "$name" ] || continue
        case "$name" in \#*) continue ;; esac
        name="$(trim_field "$name")"
        mode="$(trim_field "$mode")"
        input="$(trim_field "$input")"
        want="$(trim_field "$want")"
        content="$(decode_docs_input "$input")"
        run_docs_only_mode "$mode" "$content"
        got="$DO_RC"
        if [ "$got" = "SKIP" ]; then
            skip "D-$name: the environment this row needs is not reproducible on this host"
        elif [ "$got" = "$want" ]; then
            pass "D-$name: exit $got"
        else
            fail "D-$name: expected exit $want, got $got"
        fi
    done <<'TABLE'
# name                  | mode     | input (`;`=newline, @CR@=CR, @EMPTY@=no input)      | want
docs-tree               | normal   | docs/history.md;docs/architecture/design.md         | 0
docs-single-item        | normal   | docs/history.md                                     | 0
docs-duplicates         | normal   | docs/history.md;docs/history.md;docs/history.md     | 0
root-allowlisted        | normal   | README.md;CHANGELOG.md                              | 0
root-allowlisted-rest   | normal   | CONTRIBUTING.md;LICENSE.md                           | 0
root-claude-md          | normal   | CLAUDE.md                                           | 1
skill-md-with-docs      | normal   | skills/run-tests/SKILL.md;docs/history.md           | 1
subdir-readme           | normal   | skills/run-tests/README.md                          | 1
code-with-docs          | normal   | bin/select-tests.sh;docs/history.md                 | 1
docs-non-md             | normal   | docs/diagram.png                                    | 1
crlf-line-endings       | normal   | docs/history.md@CR@;README.md@CR@                    | 0
crlf-not-docs           | normal   | CLAUDE.md@CR@                                       | 1
special-characters      | normal   | docs/a b'c$(touch /tmp/pwned-1689)&&x.md            | 0
empty-input             | normal   | @EMPTY@                                             | 2
module-unreachable      | nomodule | docs/history.md                                     | 3
node-unavailable        | nonode   | docs/history.md                                     | 3
TABLE
    # The special-characters row is also a security row: if the path had been evaluated by a
    # shell rather than matched, the substitution above would have run. Assert the side effect
    # never happened, separately from the exit code, because a wrong exit code and an executed
    # path are different defects.
    if [ -e /tmp/pwned-1689 ]; then
        rm -f /tmp/pwned-1689
        fail "D-special-characters-injection: the path was evaluated by a shell, not matched"
    else
        pass "D-special-characters-injection: a path containing shell metacharacters is matched, never evaluated"
    fi
}
