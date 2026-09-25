# shellcheck shell=bash
# tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tests: tests/bin-concern-ledger-reducer.sh, bin/lib/concern-ledger.sh
# Tags: concern-ledger, test-harness, namespace-guard, harness-guard, TL2, scope:common
# The namespace guard sourced by tests/bin-concern-ledger-reducer.sh — not a case file,
# and it emits no PASS lines of its own.
# WHY (#2111): the library is now sourced ONCE into the harness's own shell instead of
# once per call inside a subshell, so the isolation a fresh subshell used to give away
# for free has to be asserted instead. Three watched sets: the harness's own names, the
# names the library brought in, and the guard's own entry points.

CLG_REPORT_COUNT=0
CLG_LAST_REPORT=""
CLG_GUARD_READY=0
CLG_LIB_READY=0
CLG_USABLE=0
CLG_DIR="${TMPDIR_BASE:-.}/ns-guard"

# Direction A's scalar half: the harness's identity (where it reads its inputs from) and
# its verdict (the two counters the banner is computed from).
CLG_HARNESS_VARS="PASS FAIL AGENTS_ROOT LIB CLI TMPDIR_BASE WORK SUITE_DIR"

# The guard's own entry points — a third set, because a case file that redefines one of
# these disarms both other directions while every case keeps passing.
CLG_SELF_FNS="clg_snapshot_before clg_record_library_names clg_assert_harness_intact clg_assert_library_intact"

# Names bash itself creates or moves as execution position changes; without this list they
# land in the derived library-owned variable set as phantom collisions (detail plan 3-2).
# Guard-owned names are excluded by their clg_/CLG_ prefix instead of by this list.
CLG_VAR_EXCLUDE=" _ FUNCNAME BASH_SOURCE BASH_LINENO LINENO PIPESTATUS BASH_REMATCH OPTIND OPTARG SECONDS RANDOM SRANDOM EPOCHSECONDS EPOCHREALTIME "

CLG_HARNESS_FN_NAMES=""
CLG_LIB_FN_NAMES=""
CLG_LIB_VAR_NAMES=""
declare -A CLG_HARNESS_FN=()
declare -A CLG_HARNESS_VAR=()
declare -A CLG_LIB_FN=()
declare -A CLG_LIB_VAR=()
declare -A CLG_SELF_FN=()

# A fourth set, for the SETUP WINDOW: the commands between the library-name derivation and
# the first check point. Setup is not finished at the second snapshot — the library settles
# CL_SHA_TOOL on its first hash, not at load — and a name born after BOTH snapshots belongs
# to neither direction, so a case file could replace it for free. Names sighted in that
# window are adopted here and then checked exactly like the other three sets.
CLG_WINDOW_OPEN=0
CLG_LATE_FN_NAMES=""
CLG_LATE_VAR_NAMES=""
declare -A CLG_LATE_FN=()
declare -A CLG_LATE_VAR=()

# clg_dump_fns <outfile> <name...> — the bodies of the named functions, captured with one
# redirect. Redirects do not fork; a command substitution per name would spend exactly the
# forks this issue exists to free. An EMPTY name list is never handed to `declare -f`,
# which would then dump the entire namespace onto the caller's stdout (detail plan 3-2).
# `2>/dev/null` precedes the output redirect so a failure to create the file is silent too.
clg_dump_fns() {
    local clg_out="$1"
    shift
    [ -d "$CLG_DIR" ] || return 1
    : 2>/dev/null > "$clg_out" || return 1
    [ "$#" -eq 0 ] && return 0
    declare -f -- "$@" 2>/dev/null > "$clg_out" || true
    return 0
}

# clg_dump_vars <outfile> <name...> — the same discipline for variables. `declare -p`
# prints nothing for a name that does not exist, which is how an unset becomes visible.
clg_dump_vars() {
    local clg_out="$1"
    shift
    [ -d "$CLG_DIR" ] || return 1
    : 2>/dev/null > "$clg_out" || return 1
    [ "$#" -eq 0 ] && return 0
    declare -p -- "$@" 2>/dev/null > "$clg_out" || true
    return 0
}

# clg_parse_fns <file> <assoc-array-name> — pure bash, no fork. `declare -f` prints each
# definition as a column-0 `name ()` header followed by its indented body, so the header
# is the only boundary worth recognising.
clg_parse_fns() {
    local -n clg_map="$2"
    local clg_line clg_cur=""
    clg_map=()
    [ -f "$1" ] || return 0
    while IFS= read -r clg_line; do
        if [[ "$clg_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*$ ]]; then
            clg_cur="${BASH_REMATCH[1]}"
            clg_map["$clg_cur"]=""
        elif [ -n "$clg_cur" ]; then
            clg_map["$clg_cur"]+="$clg_line"$'\n'
        fi
    done < "$1"
    return 0
}

# clg_parse_vars <file> <assoc-array-name> — records the ATTRIBUTES of every variable and,
# for a plain scalar, its value as well. An array's CONTENTS are deliberately not recorded:
# cl_sha256 writes an entry into CL_HASH_CACHE on every hash it computes, so contents are
# ordinary traffic while the type and the existence are invariants.
clg_parse_vars() {
    local -n clg_vmap="$2"
    local clg_line clg_cur="" clg_attr
    clg_vmap=()
    [ -f "$1" ] || return 0
    while IFS= read -r clg_line; do
        if [[ "$clg_line" =~ ^declare\ (-[a-zA-Z-]+)\ ([A-Za-z_][A-Za-z0-9_]*)(=(.*))?$ ]]; then
            clg_attr="${BASH_REMATCH[1]}"
            clg_cur="${BASH_REMATCH[2]}"
            if [[ "$clg_attr" == *a* || "$clg_attr" == *A* ]]; then
                clg_vmap["$clg_cur"]="$clg_attr"
                clg_cur=""
            else
                clg_vmap["$clg_cur"]="$clg_attr ${BASH_REMATCH[4]-}"
            fi
        elif [ -n "$clg_cur" ]; then
            clg_vmap["$clg_cur"]+=$'\n'"$clg_line"
        fi
    done < "$1"
    return 0
}

# clg_load_names <file> <assoc-array-name> <field> — one name per key. Field 3 reads
# `declare -F` output (`declare -f <name>`), field 1 reads `compgen -v` output.
clg_load_names() {
    local -n clg_nmap="$2"
    local clg_a clg_b clg_c clg_pick="$3"
    clg_nmap=()
    [ -f "$1" ] || return 0
    while read -r clg_a clg_b clg_c; do
        if [ "$clg_pick" = "3" ]; then clg_a="$clg_c"; fi
        [ -n "${clg_a:-}" ] && clg_nmap["$clg_a"]=1
    done < "$1"
    return 0
}

# clg_report <name> <context> <what> — one line per colliding name per check point, on
# every channel a case file cannot switch off. `fail` is itself a harness name, so the
# verdict is not routed THROUGH it: the FAIL counter the banner is computed from is bumped
# here directly, in `fail`'s own line format, and a case file that replaces `fail` with a
# no-op can no longer silence the report that names the sabotage. The tally and
# CLG_LAST_REPORT remain as the guard-owned channels a swallowed stdout cannot erase.
clg_report() {
    CLG_REPORT_COUNT=$((CLG_REPORT_COUNT + 1))
    CLG_LAST_REPORT="namespace collision at $2: $1 $3"
    echo "FAIL: $CLG_LAST_REPORT"
    # A case file that made FAIL non-numeric would otherwise abort the arithmetic here,
    # killing the report mid-line; re-base to 0 so the bump always lands.
    [[ "${FAIL-}" =~ ^[0-9]+$ ]] || FAIL=0
    FAIL=$((FAIL + 1))
    return 0
}

# clg_check_fns <baseline-map> <names> <context> <what> — existence first, then body.
# A name that stopped existing is as loud as one whose body changed: `unset -f pass` leaves
# the suite calling a command that is gone, and a body-only diff never sees it.
clg_check_fns() {
    local -n clg_base="$1"
    local clg_names="$2" clg_ctx="$3" clg_what="$4" clg_n clg_had clg_has
    [ -n "$clg_names" ] || return 0
    # shellcheck disable=SC2086
    clg_dump_fns "$CLG_DIR/fn-now.txt" $clg_names || return 0
    declare -A clg_now=()
    clg_parse_fns "$CLG_DIR/fn-now.txt" clg_now
    for clg_n in $clg_names; do
        clg_had=0; clg_has=0
        [ -n "${clg_base[$clg_n]+x}" ] && clg_had=1
        [ -n "${clg_now[$clg_n]+x}" ] && clg_has=1
        if [ "$clg_had" != "$clg_has" ]; then
            clg_report "$clg_n" "$clg_ctx" "($clg_what function) came or went after the snapshot"
        elif [ "$clg_had" = "1" ] && [ "${clg_now[$clg_n]}" != "${clg_base[$clg_n]}" ]; then
            clg_report "$clg_n" "$clg_ctx" "($clg_what function) was redefined after the snapshot"
        fi
    done
    return 0
}

# clg_check_vars <baseline-map> <names> <context> <what> — the variable counterpart.
clg_check_vars() {
    local -n clg_vbase="$1"
    local clg_names="$2" clg_ctx="$3" clg_what="$4" clg_n clg_had clg_has
    [ -n "$clg_names" ] || return 0
    # shellcheck disable=SC2086
    clg_dump_vars "$CLG_DIR/var-now.txt" $clg_names || return 0
    declare -A clg_vnow=()
    clg_parse_vars "$CLG_DIR/var-now.txt" clg_vnow
    for clg_n in $clg_names; do
        clg_had=0; clg_has=0
        [ -n "${clg_vbase[$clg_n]+x}" ] && clg_had=1
        [ -n "${clg_vnow[$clg_n]+x}" ] && clg_has=1
        if [ "$clg_had" != "$clg_has" ]; then
            clg_report "$clg_n" "$clg_ctx" "($clg_what variable) came or went after the snapshot"
        elif [ "$clg_had" = "1" ] && [ "${clg_vnow[$clg_n]}" != "${clg_vbase[$clg_n]}" ]; then
            clg_report "$clg_n" "$clg_ctx" "($clg_what variable) changed after the snapshot"
        fi
    done
    return 0
}

clg_check_self() {
    [ "$CLG_USABLE" -eq 1 ] || return 0
    clg_check_fns CLG_SELF_FN "$CLG_SELF_FNS" "$1" "guard"
    return 0
}

# clg_snapshot_before — called at the harness's file scope immediately before the library
# is sourced. Function names may be collected here (bash has no local function scope), but
# the VARIABLE name lists are read from files the harness captured at its own file scope:
# `compgen -v` run inside a function would enumerate that function's locals and hand the
# derivation a set of phantom library names (detail plan 3-2).
clg_snapshot_before() {
    [ "$CLG_USABLE" -eq 1 ] || return 0
    local clg_n
    declare -F 2>/dev/null > "$CLG_DIR/fn-names-before.txt" || return 0
    declare -A clg_before=()
    clg_load_names "$CLG_DIR/fn-names-before.txt" clg_before 3
    CLG_HARNESS_FN_NAMES=""
    for clg_n in "${!clg_before[@]}"; do
        case "$clg_n" in clg_*|CLG_*) continue ;; esac
        CLG_HARNESS_FN_NAMES="$CLG_HARNESS_FN_NAMES $clg_n"
    done
    # shellcheck disable=SC2086
    clg_dump_fns "$CLG_DIR/fn-harness-base.txt" $CLG_HARNESS_FN_NAMES || return 0
    clg_parse_fns "$CLG_DIR/fn-harness-base.txt" CLG_HARNESS_FN
    # shellcheck disable=SC2086
    clg_dump_vars "$CLG_DIR/var-harness-base.txt" $CLG_HARNESS_VARS || return 0
    clg_parse_vars "$CLG_DIR/var-harness-base.txt" CLG_HARNESS_VAR
    CLG_GUARD_READY=1
    return 0
}

# clg_record_library_names — called immediately after the load. The owned sets are DERIVED
# (a `declare -F` diff, and the harness's two `compgen -v` files), never transcribed: a
# typed list ages the moment a module gains a helper and keeps passing while it ages.
clg_record_library_names() {
    [ "$CLG_USABLE" -eq 1 ] || return 0
    [ "$CLG_GUARD_READY" -eq 1 ] || return 0
    local clg_n
    declare -F 2>/dev/null > "$CLG_DIR/fn-names-after.txt" || return 0
    declare -A clg_before=() clg_after=()
    clg_load_names "$CLG_DIR/fn-names-before.txt" clg_before 3
    clg_load_names "$CLG_DIR/fn-names-after.txt" clg_after 3
    CLG_LIB_FN_NAMES=""
    for clg_n in "${!clg_after[@]}"; do
        [ -n "${clg_before[$clg_n]+x}" ] && continue
        case "$clg_n" in clg_*|CLG_*) continue ;; esac
        CLG_LIB_FN_NAMES="$CLG_LIB_FN_NAMES $clg_n"
    done
    declare -A clg_vbefore=() clg_vafter=()
    clg_load_names "$CLG_DIR/var-before.txt" clg_vbefore 1
    clg_load_names "$CLG_DIR/var-after.txt" clg_vafter 1
    CLG_LIB_VAR_NAMES=""
    for clg_n in "${!clg_vafter[@]}"; do
        [ -n "${clg_vbefore[$clg_n]+x}" ] && continue
        case "$clg_n" in clg_*|CLG_*) continue ;; esac
        case "$CLG_VAR_EXCLUDE" in *" $clg_n "*) continue ;; esac
        CLG_LIB_VAR_NAMES="$CLG_LIB_VAR_NAMES $clg_n"
    done
    if [ -n "$CLG_LIB_FN_NAMES" ]; then
        # shellcheck disable=SC2086
        clg_dump_fns "$CLG_DIR/fn-lib-base.txt" $CLG_LIB_FN_NAMES || return 0
        clg_parse_fns "$CLG_DIR/fn-lib-base.txt" CLG_LIB_FN
    fi
    if [ -n "$CLG_LIB_VAR_NAMES" ]; then
        # shellcheck disable=SC2086
        clg_dump_vars "$CLG_DIR/var-lib-base.txt" $CLG_LIB_VAR_NAMES || return 0
        clg_parse_vars "$CLG_DIR/var-lib-base.txt" CLG_LIB_VAR
    fi
    CLG_LIB_READY=1
    CLG_WINDOW_OPEN=1
    # The action string self-checks and self-disarms at top level: bash discards a
    # `trap - DEBUG` issued from inside a function's own body once it returns (absent
    # functrace/extdebug), so the disarm cannot live inside clg_close_window/clg_adopt_late_names.
    trap '[ "$CLG_WINDOW_OPEN" -eq 1 ] && clg_adopt_late_names || trap - DEBUG' DEBUG
    return 0
}

# clg_adopt_late_names — the DEBUG-trap tick that runs across the setup window. First
# sighting wins: a name already in a watched set is never re-recorded, so what a case file
# later replaces is still compared against what setup left behind. Functions are adopted by
# name; VARIABLES only inside the library's own four prefixes, because a loop counter or a
# scratch scalar moves by design and adopting one would turn bookkeeping into a collision.
# The window is one or two commands wide, so the per-tick `declare -F` is not a hot path.
clg_adopt_late_names() {
    local clg_a clg_b clg_c clg_new="" clg_vnew=""
    declare -F 2>/dev/null > "$CLG_DIR/fn-late.txt" || return 0
    while read -r clg_a clg_b clg_c; do
        [ -n "${clg_c:-}" ] || continue
        case "$clg_c" in clg_*|CLG_*) continue ;; esac
        [ -n "${CLG_HARNESS_FN[$clg_c]+x}" ] && continue
        [ -n "${CLG_LIB_FN[$clg_c]+x}" ] && continue
        [ -n "${CLG_LATE_FN[$clg_c]+x}" ] && continue
        clg_new="$clg_new $clg_c"
    done < "$CLG_DIR/fn-late.txt"
    for clg_a in ${!CL_@} ${!cl_@} ${!_CL_@} ${!_cl_@}; do
        [ -n "${CLG_LIB_VAR[$clg_a]+x}" ] && continue
        [ -n "${CLG_HARNESS_VAR[$clg_a]+x}" ] && continue
        [ -n "${CLG_LATE_VAR[$clg_a]+x}" ] && continue
        clg_vnew="$clg_vnew $clg_a"
    done
    if [ -n "$clg_new" ]; then
        declare -A clg_fadd=()
        # shellcheck disable=SC2086
        clg_dump_fns "$CLG_DIR/fn-late-base.txt" $clg_new || return 0
        clg_parse_fns "$CLG_DIR/fn-late-base.txt" clg_fadd
        for clg_c in $clg_new; do
            CLG_LATE_FN["$clg_c"]="${clg_fadd[$clg_c]-}"
            CLG_LATE_FN_NAMES="$CLG_LATE_FN_NAMES $clg_c"
        done
    fi
    if [ -n "$clg_vnew" ]; then
        declare -A clg_vadd=()
        # shellcheck disable=SC2086
        clg_dump_vars "$CLG_DIR/var-late-base.txt" $clg_vnew || return 0
        clg_parse_vars "$CLG_DIR/var-late-base.txt" clg_vadd
        for clg_c in $clg_vnew; do
            CLG_LATE_VAR["$clg_c"]="${clg_vadd[$clg_c]-}"
            CLG_LATE_VAR_NAMES="$CLG_LATE_VAR_NAMES $clg_c"
        done
    fi
    return 0
}

# clg_close_window — the first check point ends adoption. Everything after it is a case
# file's doing rather than setup's, and must be compared instead of recorded. Flipping
# CLG_WINDOW_OPEN is all this does; the DEBUG trap disarms itself on its own next tick
# (see the top-level trap string armed in clg_record_library_names), because a `trap - DEBUG`
# issued here would be a function-body change bash discards the instant this function returns.
clg_close_window() {
    [ "$CLG_WINDOW_OPEN" -eq 1 ] || return 0
    CLG_WINDOW_OPEN=0
    return 0
}

# clg_rearm_counters — re-pins PASS and FAIL to their current values so the post-cases
# check point reads the nine case files' by-design advance as ordinary progress rather than
# tampering. Re-arming alone would also launder a DECREASE, which is the shape a case file
# resetting FAIL to hide its own failure takes; so a counter that moved backward from the
# recorded baseline is reported first, and only then re-pinned. A counter that stopped being
# a count at all — emptied, negated, or made non-numeric — is the same sabotage with the
# comparison removed, and is reported on the same path rather than silently re-pinned. The
# six identity scalars stay pinned to the load-time snapshot; only the two counters re-base.
clg_rearm_counters() {
    [ "$CLG_USABLE" -eq 1 ] || return 0
    [ "$CLG_GUARD_READY" -eq 1 ] || return 0
    clg_dump_vars "$CLG_DIR/var-counters.txt" PASS FAIL || return 0
    declare -A clg_vnow=()
    clg_parse_vars "$CLG_DIR/var-counters.txt" clg_vnow
    # clg_parse_vars records a scalar as `<attrs> <declare -p value>`, so the count is the
    # field after the attributes with the quoting removed — extracted here without a fork.
    local clg_n clg_was clg_is
    for clg_n in PASS FAIL; do
        [ -n "${clg_vnow[$clg_n]+x}" ] || continue
        clg_was="${CLG_HARNESS_VAR[$clg_n]-}"
        clg_was="${clg_was#* }"
        clg_was="${clg_was//\"/}"
        clg_is="${clg_vnow[$clg_n]}"
        clg_is="${clg_is#* }"
        clg_is="${clg_is//\"/}"
        if ! [[ "$clg_was" =~ ^[0-9]+$ ]] || ! [[ "$clg_is" =~ ^[0-9]+$ ]]; then
            clg_report "$clg_n" "post-cases" \
                "(harness variable) stopped being a count — was '$clg_was', now '$clg_is'"
        elif [ "$clg_is" -lt "$clg_was" ]; then
            clg_report "$clg_n" "post-cases" \
                "(harness variable) decreased from $clg_was to $clg_is — counters must only advance"
        fi
        CLG_HARNESS_VAR["$clg_n"]="${clg_vnow[$clg_n]}"
    done
    return 0
}

# clg_assert_harness_intact <context> — direction A: the library, or anything sourced after
# it, shadowing a harness name. Always returns 0; reporting is `fail`'s job and aborting
# would turn one extra FAIL line into a hundred missing ones.
clg_assert_harness_intact() {
    local clg_ctx="${1:-unspecified}"
    clg_close_window
    clg_check_self "$clg_ctx"
    [ "$CLG_USABLE" -eq 1 ] || return 0
    [ "$CLG_GUARD_READY" -eq 1 ] || return 0
    clg_check_fns CLG_HARNESS_FN "$CLG_HARNESS_FN_NAMES" "$clg_ctx" "harness"
    clg_check_vars CLG_HARNESS_VAR "$CLG_HARNESS_VARS" "$clg_ctx" "harness"
    # The setup-window set is checked LAST: clg_report bumps FAIL, and a report raised here
    # before the harness-variable pass would make that bump look like tampering in turn.
    clg_check_fns CLG_LATE_FN "$CLG_LATE_FN_NAMES" "$clg_ctx" "post-baseline"
    clg_check_vars CLG_LATE_VAR "$CLG_LATE_VAR_NAMES" "$clg_ctx" "post-baseline"
    return 0
}

# clg_assert_library_intact <context> — direction B: a case file shadowing a name the
# library owns. An empty owned set returns immediately and silently, so the $LIB-absent
# path prints exactly what it printed before this guard existed (detail plan 3-2).
clg_assert_library_intact() {
    local clg_ctx="${1:-unspecified}"
    clg_close_window
    clg_check_self "$clg_ctx"
    [ "$CLG_USABLE" -eq 1 ] || return 0
    [ "$CLG_LIB_READY" -eq 1 ] || return 0
    [ -n "$CLG_LIB_FN_NAMES" ] || return 0
    clg_check_fns CLG_LIB_FN "$CLG_LIB_FN_NAMES" "$clg_ctx" "library"
    clg_check_vars CLG_LIB_VAR "$CLG_LIB_VAR_NAMES" "$clg_ctx" "library"
    return 0
}

# The guard's own baseline is taken here, at the guard's file scope, so it predates every
# line a case file can run. Everything above is defined by now.
if [ -d "$CLG_DIR" ]; then
    CLG_USABLE=1
    # shellcheck disable=SC2086
    clg_dump_fns "$CLG_DIR/fn-guard-base.txt" $CLG_SELF_FNS || CLG_USABLE=0
    if [ "$CLG_USABLE" -eq 1 ]; then
        clg_parse_fns "$CLG_DIR/fn-guard-base.txt" CLG_SELF_FN
    fi
fi
