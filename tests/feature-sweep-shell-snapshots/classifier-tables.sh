#!/bin/bash
# Tests: bin/sweep-shell-snapshots.sh
# Tags: sweep, shell-snapshots, cli, classifier, table-driven, scope:common, TL2
# Part file of tests/feature-sweep-shell-snapshots.sh. Two tables in the shape
# skills/_shared/test-design/parser-regex-tests.md prescribes: T15 over the CLI
# parser (a delete-by-default tool, so every rejected input must also leave the
# corpus untouched) and T16 over the PATH-line classifier's string edges.

# T15 — CLI parser table. Columns: name | argv | verdict | survivors.
#   argv @NONE@ = no arguments, @EMPTY@ = a literal empty argument; verdict is
#   allow (exit 0) or reject (non-zero). Every reject row expects all 10 fixtures
#   left: a parse error that still deletes is the worst outcome for this tool.
_sspc_cli_row() {
    local name="$1" argstr="$2" verdict="$3" survivors="$4"
    local home; home="$(make_fixture "cli-$name")"
    local d="$home/.claude/shell-snapshots"
    local argv=() w
    for w in $argstr; do
        case "$w" in
            @NONE@) continue ;;
            @EMPTY@) argv+=("") ;;
            *) argv+=("$w") ;;
        esac
    done
    local out rc
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" ${argv[@]+"${argv[@]}"} 2>&1)"
    rc=$?
    local got_verdict="allow"
    [ "$rc" -eq 0 ] || got_verdict="reject"
    local present; present="$(count_present "$d")"
    if [ "$got_verdict" = "$verdict" ] && [ "$present" = "$survivors" ]; then
        pass "T15/$name: '$argstr' → $verdict, $present/$FIXTURE_COUNT snapshots left"
    else
        fail "T15/$name: '$argstr' → $got_verdict (want $verdict), $present/$FIXTURE_COUNT snapshots left (want $survivors), exit=$rc. Output: $out"
    fi
}

T15_cli_parser_table() {
    if [ ! -f "$SWEEP" ]; then
        fail "T15 CLI parser table: $SWEEP not found"
        return
    fi
    while IFS='|' read -r name argstr verdict survivors; do
        case "$name" in ''|'#'*) continue ;; esac
        _sspc_cli_row "$name" "$argstr" "$verdict" "$survivors"
    done <<'TABLE'
flagless|@NONE@|allow|7
dry-run|--dry-run|allow|10
apply|--apply|allow|7
minage-before-dryrun|--min-age-minutes 60 --dry-run|allow|10
minage-after-dryrun|--dry-run --min-age-minutes 60|allow|10
minage-with-apply|--min-age-minutes 60 --apply|allow|7
minage-zero|--dry-run --min-age-minutes 0|allow|10
minage-maxint|--dry-run --min-age-minutes 2147483647|allow|10
# int64-boundary/beyond-int64 (C4): MAX_INT above is only the 32-bit boundary
# and fits trivially in bash's native 64-bit arithmetic. These two exceed the
# 15-digit cap validate_min_age_minutes enforces (overflow/octal-misparse guard),
# so the parser now rejects them outright instead of risking wraparound arithmetic.
minage-int64-boundary|--dry-run --min-age-minutes 9223372036854775807|reject|10
minage-beyond-int64|--dry-run --min-age-minutes 99999999999999999999999999|reject|10
duplicate-dry-run|--dry-run --dry-run|allow|10
duplicate-minage-last-wins|--dry-run --min-age-minutes 60 --min-age-minutes 0|allow|10
minage-missing-value|--dry-run --min-age-minutes|reject|10
minage-empty-value|--dry-run --min-age-minutes @EMPTY@|reject|10
minage-nonnumeric|--min-age-minutes abc|reject|10
minage-negative|--min-age-minutes -5|reject|10
minage-fractional|--min-age-minutes 1.5|reject|10
minage-flag-as-value|--min-age-minutes --dry-run|reject|10
unknown-flag-dryrun-typo|--dryrun|reject|10
unknown-flag-minage-typo|--min-age 60|reject|10
unknown-short-flag|-n|reject|10
stray-positional|snapshots|reject|10
TABLE
}

# ---------------------------------------------------------------------------
# T16 — PATH-line classifier table. Columns: name | shape | verdict
#   The shape token selects a body from _sspc_body; verdict is keep | delete.
#   These are the string/collection edges no fixture in the parent covers: an
#   empty file, a one-character first element, a multi-kilobyte PATH, and more
#   than one `export PATH=` line (only the first may decide the verdict).
# ---------------------------------------------------------------------------
_sspc_long_tail() {
    local i s=""
    for i in $(seq 1 200); do s="$s:/opt/pkg$i/bin"; done
    printf '%s' "$s"
}

_sspc_body() {
    local shape="$1" tail
    tail="$(_sspc_long_tail)"
    case "$shape" in
        empty-file)        printf '' ;;
        root-first)        printf "%sexport PATH='/%s'\n" "$PREAMBLE" "$tail" ;;
        long-healthy)      printf "%sexport PATH='/usr/bin%s'\n" "$PREAMBLE" "$tail" ;;
        long-broken)       printf "%sexport PATH='/definitely/does/not/exist%s'\n" "$PREAMBLE" "$tail" ;;
        empty-first)       printf "%sexport PATH='\n/usr/bin:/bin'\n" "$PREAMBLE" ;;
        dup-healthy-first) printf "%sexport PATH='/usr/bin:/bin'\nexport PATH='/definitely/does/not/exist'\n" "$PREAMBLE" ;;
        dup-broken-first)  printf "%sexport PATH='/definitely/does/not/exist'\nexport PATH='/usr/bin:/bin'\n" "$PREAMBLE" ;;
        marker-outside)    printf "%sexport PATH='/usr/bin:/bin'\n# git fetch Claude session sync ...\n" "$PREAMBLE" ;;
        *)                 printf '' ;;
    esac
}

_sspc_shape_row() {
    local name="$1" shape="$2" verdict="$3"
    local home="$TMPDIR_BASE/shape-$name/home"
    local d="$home/.claude/shell-snapshots"
    mkdir -p "$d"
    # space-* shapes need a home-relative first PATH element, so they build the
    # body here instead of in _sspc_body (T16/space-*: a directory containing a
    # space is an unremarkable real-world PATH element — Windows Git-Bash paths
    # like "/c/Program Files/Git/cmd" are common — and an unquoted classifier
    # check (e.g. bare `[ -d $first ]`) would word-split it into two arguments
    # and misclassify; healthy points at a directory that actually exists,
    # broken does not).
    case "$shape" in
        space-healthy)
            local spaced="$home/Program Files/bin"
            mkdir -p "$spaced"
            printf "%sexport PATH='%s%s'\n" "$PREAMBLE" "$spaced" "$(_sspc_long_tail)" > "$d/subject.sh"
            ;;
        space-broken)
            local spaced="$home/Program Files/does-not-exist"
            printf "%sexport PATH='%s%s'\n" "$PREAMBLE" "$spaced" "$(_sspc_long_tail)" > "$d/subject.sh"
            ;;
        *)
            _sspc_body "$shape" > "$d/subject.sh"
            ;;
    esac
    backdate "$d/subject.sh"
    local out rc
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    local got="keep"
    [ -f "$d/subject.sh" ] || got="delete"
    local want_removed=0
    [ "$verdict" = "delete" ] && want_removed=1
    local removed; removed="$(field "$out" removed)"
    if [ "$rc" -eq 0 ] && [ "$got" = "$verdict" ] && [ "${removed:-x}" = "$want_removed" ]; then
        pass "T16/$name: $shape → $verdict (removed=$want_removed)"
    else
        fail "T16/$name: $shape → $got (want $verdict), exit=$rc removed=${removed:-?} (want $want_removed). Output: $out"
    fi
}

T16_path_shape_table() {
    if [ ! -f "$SWEEP" ]; then
        fail "T16 PATH shape table: $SWEEP not found"
        return
    fi
    while IFS='|' read -r name shape verdict; do
        case "$name" in ''|'#'*) continue ;; esac
        _sspc_shape_row "$name" "$shape" "$verdict"
    done <<'TABLE'
empty-snapshot-file|empty-file|keep
single-char-first-element|root-first|keep
very-long-path-healthy|long-healthy|keep
very-long-path-broken|long-broken|delete
empty-first-element|empty-first|delete
two-path-lines-healthy-first|dup-healthy-first|keep
two-path-lines-broken-first|dup-broken-first|delete
marker-outside-the-path-line|marker-outside|keep
space-in-first-element-healthy|space-healthy|keep
space-in-first-element-broken|space-broken|delete
TABLE
}

T15_cli_parser_table
T16_path_shape_table
