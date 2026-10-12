#!/bin/bash
# Tests: bin/sweep-shell-snapshots.sh
# Tags: sweep, shell-snapshots, cli, classifier, table-driven, scope:common, TL2
# Part file of tests/bin/feature-sweep-shell-snapshots.sh. Two tables in the shape
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
minage-leading-zero|--dry-run --min-age-minutes 010|reject|10
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

# ---------------------------------------------------------------------------
# T22 — #2221 Windows-form PATH reasons. Pins that the sweep's deletion set and
#   holdback (MIN_AGE_MINUTES) are unchanged and that existing candidates gain the
#   new reason=windows-form / windows-unrepairable labels. That the repair hook
#   leaves the unrepairable shape in place is tested in tests/hooks/fix-shell-snapshot-windows-path/.
#   Columns: name | PATH value | age (old|young) | verdict | dry-run reason (- = no line).
#   Paths are guaranteed-absent (nonexistent-2221) or fixture dirs (@FIX@ POSIX form,
#   @FIXW@ its Windows form, win32 only), so no row depends on what the host has.
# ---------------------------------------------------------------------------
_sspc_is_win() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# _sspc_t22_value <value> <fixdir> — expands @FIX@ / @FIXW@; returns 1 when @FIXW@ cannot be built.
_sspc_t22_value() {
    local v="$1" fix="$2" fixw=""
    case "$v" in
        *@FIXW@*)
            if ! _sspc_is_win || ! command -v cygpath >/dev/null 2>&1; then return 1; fi
            fixw="$(cygpath -w "$fix")" || return 1
            v="${v//@FIXW@/$fixw}"
            ;;
    esac
    printf '%s' "${v//@FIX@/$fix}"
}

# _sspc_reason <dry-run output> <file> — the reason= token on that file's candidate line.
_sspc_reason() {
    printf '%s\n' "$1" | grep -F "snapshot=$2 " | grep -oE 'reason=[a-z-]+' | tail -1
}

_sspc_t22_row() {
    local name="$1" val="$2" age="$3" verdict="$4" want="$5"
    local home="$TMPDIR_BASE/t22-$name/home"
    local d="$home/.claude/shell-snapshots" fix="$home/fixdir"
    mkdir -p "$d" "$fix"
    if ! val="$(_sspc_t22_value "$val" "$fix")"; then
        echo "SKIP: T22/$name: building a Windows-form fixture path needs win32 Git Bash cygpath"
        return
    fi
    printf "%sexport PATH='%s'\n" "$PREAMBLE" "$val" > "$d/subject.sh"
    if [ "$age" = old ]; then backdate "$d/subject.sh"; fi
    local want_reason="reason=$want" want_young=0
    [ "$want" = "-" ] && want_reason=""
    [ "$age" = young ] && want_young=1
    local out rc got_reason young
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" --dry-run 2>&1)"
    rc=$?
    got_reason="$(_sspc_reason "$out" "$d/subject.sh")"
    young="$(field "$out" skipped_young)"
    if [ "$rc" -eq 0 ] && [ "$got_reason" = "$want_reason" ] && [ "${young:-x}" = "$want_young" ]; then
        pass "T22/$name dry-run: ${want_reason:-no candidate line}, skipped_young=$want_young"
    else
        fail "T22/$name dry-run: got '${got_reason:-no candidate line}' (want '${want_reason:-no candidate line}'), skipped_young=${young:-?} (want $want_young), exit=$rc. Output: $out"
    fi
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    local got=keep
    [ -f "$d/subject.sh" ] || got=delete
    if [ "$rc" -eq 0 ] && [ "$got" = "$verdict" ]; then
        pass "T22/$name apply: $verdict"
    else
        fail "T22/$name apply: $got (want $verdict), exit=$rc. Output: $out"
    fi
}

T22_windows_form_reason_table() {
    if [ ! -f "$SWEEP" ]; then
        fail "T22 Windows-form reason table: $SWEEP not found"
        return
    fi
    while IFS='|' read -r name val age verdict want; do
        case "$name" in ''|'#'*) continue ;; esac
        _sspc_t22_row "$name" "$val" "$age" "$verdict" "$want"
    done <<'TABLE'
# Existing candidates (first element absent) gain the new reason.
wf-semicolon|C:\nonexistent-2221\a;C:\nonexistent-2221\b|old|delete|windows-form
wf-mixed|C:\nonexistent-2221\a;/usr/bin|old|delete|windows-form
wu-semicolon|C:\nonexistent-2221\a;relative\dir|old|delete|windows-unrepairable
wu-colon|C:\nonexistent-2221\bin:/c/x|old|delete|windows-unrepairable
# The deletion set does not widen: an existing first element keeps the file, no reason shown.
wu-first-exists|@FIX@:C:\nonexistent-2221\bin:/x|old|keep|-
wf-single-first-exists|@FIXW@|old|keep|-
# Holdback is kept for both new shapes.
wf-young|C:\nonexistent-2221\a;C:\nonexistent-2221\b|young|keep|-
wu-young|C:\nonexistent-2221\a;relative\dir|young|keep|-
healthy-mid-drive-letter|/usr/bin:/bin:C:\nonexistent-2221\x|old|keep|-
wf-after-marker|git fetch Claude session sync ...;C:\nonexistent-2221\a|old|delete|known-marker
TABLE
}

# _sspc_t22_corpus <home> — the portable T22 shapes side by side in one snapshots dir.
_sspc_t22_corpus() {
    local d="$1/.claude/shell-snapshots" fix="$1/fixdir" n v
    mkdir -p "$d" "$fix"
    while IFS='|' read -r n v; do
        printf "%sexport PATH='%s'\n" "$PREAMBLE" "${v//@FIX@/$fix}" > "$d/$n.sh"
        case "$n" in *-young) ;; *) backdate "$d/$n.sh" ;; esac
    done <<'CORPUS'
wf-semicolon|C:\nonexistent-2221\a;C:\nonexistent-2221\b
wf-mixed|C:\nonexistent-2221\a;/usr/bin
wu-semicolon|C:\nonexistent-2221\a;relative\dir
wu-colon|C:\nonexistent-2221\bin:/c/x
wu-first-exists|@FIX@:C:\nonexistent-2221\bin:/x
wf-young|C:\nonexistent-2221\a;C:\nonexistent-2221\b
healthy-mid-drive-letter|/usr/bin:/bin:C:\nonexistent-2221\x
wf-after-marker|git fetch Claude session sync ...;C:\nonexistent-2221\a
generic-broken|/nonexistent-2221/bin:/usr/bin
CORPUS
}

# _sspc_partial_copy <root> — the sweep and the libs it sources, without the classify CLI.
_sspc_partial_copy() {
    mkdir -p "$1/bin/lib"
    cp "$SWEEP" "$1/bin/sweep-shell-snapshots.sh"
    cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/session-sync-markers.sh" "$1/bin/lib/"
    if [ -f "$SCRIPT_CHECKOUT_ROOT/bin/lib/sweep-write-mode.sh" ]; then
        cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/sweep-write-mode.sh" "$1/bin/lib/"
    fi
    printf '%s' "$1/bin/sweep-shell-snapshots.sh"
}

# _sspc_t22_degraded_reasons <label> <output> <dir> — all four new shapes fall back to missing-dir.
_sspc_t22_degraded_reasons() {
    local label="$1" out="$2" d="$3" n bad=""
    for n in wf-semicolon wf-mixed wu-semicolon wu-colon; do
        [ "$(_sspc_reason "$out" "$d/$n.sh")" = "reason=missing-dir" ] || bad="$bad $n"
    done
    if [ -z "$bad" ]; then
        pass "T22/$label: Windows-form candidates fall back to reason=missing-dir"
    else
        fail "T22/$label: not reason=missing-dir:$bad. Output: $2"
    fi
}

T22_candidate_set_invariant() {
    if [ ! -f "$SWEEP" ]; then
        fail "T22 candidate-set invariance: $SWEEP not found"
        return
    fi
    local root="$TMPDIR_BASE/t22-inv" home d partial out_cli out_partial rc_cli rc_partial
    home="$root/home"
    d="$home/.claude/shell-snapshots"
    _sspc_t22_corpus "$home"
    partial="$(_sspc_partial_copy "$root/partial")"
    out_cli="$(HOME="$home" run_with_timeout bash "$SWEEP" --dry-run 2>&1)"
    rc_cli=$?
    out_partial="$(HOME="$home" run_with_timeout bash "$partial" --dry-run 2>&1)"
    rc_partial=$?
    local norm_cli norm_partial
    norm_cli="$(printf '%s\n' "$out_cli" | sed -E 's/reason=[a-z-]+/reason=X/g')"
    norm_partial="$(printf '%s\n' "$out_partial" | sed -E 's/reason=[a-z-]+/reason=X/g')"
    if [ "$rc_cli" -eq 0 ] && [ "$rc_partial" -eq 0 ] && [ "$norm_cli" = "$norm_partial" ]; then
        pass "T22/invariance: with and without the classify CLI only reason= differs (same candidates and summary)"
    else
        fail "T22/invariance: exit=$rc_cli/$rc_partial, outputs differ beyond reason=. With CLI: $out_cli --- Without: $out_partial"
    fi
    local r_wf r_wu
    r_wf="$(_sspc_reason "$out_cli" "$d/wf-semicolon.sh")"
    r_wu="$(_sspc_reason "$out_cli" "$d/wu-colon.sh")"
    if [ "$r_wf" = "reason=windows-form" ] && [ "$r_wu" = "reason=windows-unrepairable" ]; then
        pass "T22/invariance: the checkout's classify CLI labels the same candidates with the new reasons"
    else
        fail "T22/invariance: with the CLI got '$r_wf' / '$r_wu' (want reason=windows-form / reason=windows-unrepairable). Output: $out_cli"
    fi
    _sspc_t22_degraded_reasons "partial-copy dry-run" "$out_partial" "$d"
}

T22_degraded_without_classifier() {
    if [ ! -f "$SWEEP" ]; then
        fail "T22 degraded mode: $SWEEP not found"
        return
    fi
    local root="$TMPDIR_BASE/t22-deg" home d partial out rc n missing="" kept_bad=""
    home="$root/home"
    d="$home/.claude/shell-snapshots"
    _sspc_t22_corpus "$home"
    partial="$(_sspc_partial_copy "$root/partial")"
    out="$(HOME="$home" run_with_timeout bash "$partial" 2>&1)"
    rc=$?
    for n in wf-semicolon wf-mixed wu-semicolon wu-colon wf-after-marker generic-broken; do
        [ -f "$d/$n.sh" ] && missing="$missing $n"
    done
    for n in wu-first-exists wf-young healthy-mid-drive-letter; do
        [ -f "$d/$n.sh" ] || kept_bad="$kept_bad $n"
    done
    if [ "$rc" -eq 0 ] && [ -z "$missing" ] && [ -z "$kept_bad" ]; then
        pass "T22/partial-copy apply: Windows-form candidates deleted, first-element-present and young kept"
    else
        fail "T22/partial-copy apply: exit=$rc still present:${missing:- none} wrongly deleted:${kept_bad:- none}. Output: $out"
    fi
    # node off PATH: the real checkout must degrade the same way.
    local home2="$root/home-nonode" d2 nopath="/usr/bin:/bin"
    d2="$home2/.claude/shell-snapshots"
    if [ -n "$(env PATH="$nopath" bash -c 'command -v node' 2>/dev/null)" ]; then
        echo "SKIP: T22/node-off-PATH: node lives in $nopath on this host"
        return
    fi
    _sspc_t22_corpus "$home2"
    out="$(HOME="$home2" run_with_timeout env PATH="$nopath" bash "$SWEEP" --dry-run 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _sspc_t22_degraded_reasons "node-off-PATH dry-run" "$out" "$d2"
    else
        fail "T22/node-off-PATH dry-run: exit=$rc. Output: $out"
    fi
}

T15_cli_parser_table
T16_path_shape_table
T22_windows_form_reason_table
T22_candidate_set_invariant
T22_degraded_without_classifier
