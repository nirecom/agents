#!/bin/bash
# tests/lib/mewg-groups.sh
# Tests: hooks/enforce-worktree.js
# Tags: TL2, shared-lib, scope:common
# The single fragment -> group table for tests/hooks/main-enforce-worktree-guard-<group>.sh,
# plus the static checks every entrypoint runs. Source AFTER tests/lib/mewg-harness.sh.
# Adding or removing a fragment or an entrypoint means updating MEWG_TABLE: the checks below
# fail until the table, the fragment directory and the entrypoints agree.

# "<fragment file>:<group>" in the original source order (it is also the source order within a group).
# Fragment and group names carry no ':' or whitespace.
MEWG_TABLE=(
    "merge-gate.sh:mixed-c"
    "hooks-bypass-detection.sh:mixed-b"
    "orphan-cwd-fail-closed.sh:mixed-a"
    "block-reporting.sh:mixed-a"
    "sanctioned-bypass.sh:mixed-c"
    "target-extraction.sh:mixed-a"
    "interpreter-readonly.sh:mixed-b"
    "worktree-lifecycle.sh:mixed-b"
    "push-range-basic.sh:push-range"
    "push-range-cross-repo.sh:mixed-a"
    "repo-resolution.sh:mixed-c"
    "exclude-and-session-scope.sh:exclude-scope"
)
# The one group that emits the FRAG1 / FRAG2 PASS lines (the lightest measured group).
MEWG_PASS_OWNER="push-range"

mewg_groups() {
    local entry group seen=" "
    for entry in "${MEWG_TABLE[@]}"; do
        group="${entry##*:}"
        case "$seen" in
            *" $group "*) ;;
            *) seen="$seen$group "; echo "$group" ;;
        esac
    done
}

mewg_fragments_of() {
    local entry
    for entry in "${MEWG_TABLE[@]}"; do
        if [ "${entry##*:}" = "$1" ]; then echo "${entry%%:*}"; fi
    done
    return 0
}

mewg_all_fragments() {
    local entry
    for entry in "${MEWG_TABLE[@]}"; do echo "${entry%%:*}"; done | LC_ALL=C sort
}

mewg_entrypoint_of() {
    echo "$SCRIPT_CHECKOUT_ROOT/tests/hooks/main-enforce-worktree-guard-$1.sh"
}

mewg_only_in_first() {
    comm -23 <(printf '%s\n' "$1" | grep -v '^$') <(printf '%s\n' "$2" | grep -v '^$') \
        | tr '\n' ' ' | sed 's/ *$//'
}

# mewg_static_check <group> — prints FAIL lines only; returns 1 when any check failed.
mewg_static_check() {
    local group="$1" status=0
    local present assigned unassigned absent dup no_entry no_group mislabeled g f
    present="$(ls -1 "$FRAGMENT_DIR" 2>/dev/null | grep '\.sh$' | LC_ALL=C sort)"
    assigned="$(mewg_all_fragments)"
    unassigned="$(mewg_only_in_first "$present" "$assigned")"
    absent="$(mewg_only_in_first "$assigned" "$present")"
    if [ -n "$unassigned" ] || [ -n "$absent" ]; then
        fail "FRAG1 fragment set mismatch — present-but-unsourced: [${unassigned:-none}] sourced-but-missing: [${absent:-none}]"
        status=1
    fi
    dup="$(printf '%s\n' "$assigned" | uniq -d | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "$dup" ]; then
        fail "FRAG3 fragment assigned to more than one group: [$dup]"
        status=1
    fi
    no_entry=""
    for g in $(mewg_groups); do
        if [ ! -f "$(mewg_entrypoint_of "$g")" ]; then no_entry="$no_entry $g"; fi
    done
    no_group=""
    for f in "$SCRIPT_CHECKOUT_ROOT"/tests/hooks/main-enforce-worktree-guard-*.sh; do
        [ -e "$f" ] || continue
        g="${f##*/main-enforce-worktree-guard-}"
        g="${g%.sh}"
        if ! mewg_groups | grep -qx -- "$g"; then no_group="$no_group $g"; fi
    done
    if [ -n "$no_entry" ] || [ -n "$no_group" ]; then
        fail "FRAG3 group/entrypoint mismatch — group-without-entrypoint: [${no_entry# }] entrypoint-without-group: [${no_group# }]"
        status=1
    fi
    # A copied entrypoint whose MEWG_GROUP was not rewritten runs one group twice and another never.
    mislabeled=""
    for f in "$SCRIPT_CHECKOUT_ROOT"/tests/hooks/main-enforce-worktree-guard-*.sh; do
        [ -e "$f" ] || continue
        g="${f##*/main-enforce-worktree-guard-}"
        g="${g%.sh}"
        if [ "$(grep -c '^MEWG_GROUP=' "$f")" != 1 ] || ! grep -qx "MEWG_GROUP=\"$g\"" "$f"; then
            mislabeled="$mislabeled $g"
        fi
    done
    if [ -n "$mislabeled" ]; then
        fail "FRAG3 entrypoint MEWG_GROUP does not match its file name: [${mislabeled# }]"
        status=1
    fi
    if ! mewg_groups | grep -qx -- "$group"; then
        fail "FRAG3 unknown group: [$group] is not in MEWG_TABLE"
        status=1
    fi
    # A renamed or removed owner group would leave FRAG1 / FRAG2 PASS lines emitted by no entrypoint.
    if ! mewg_groups | grep -qx -- "$MEWG_PASS_OWNER"; then
        fail "FRAG3 MEWG_PASS_OWNER is not a group in MEWG_TABLE: [$MEWG_PASS_OWNER]"
        status=1
    fi
    return "$status"
}

# mewg_group_verify <group> — after the group's fragments are sourced; sets MEWG_CHECKS_OK (0/1).
mewg_group_verify() {
    local group="$1" expected done_sorted unfinished unexpected
    MEWG_CHECKS_OK=1
    expected="$(mewg_fragments_of "$group" | LC_ALL=C sort)"
    done_sorted="$(printf '%s' "$FRAG_DONE" | LC_ALL=C sort)"
    unfinished="$(mewg_only_in_first "$expected" "$done_sorted")"
    unexpected="$(mewg_only_in_first "$done_sorted" "$expected")"
    if [ -n "$unfinished" ] || [ -n "$unexpected" ]; then
        fail "FRAG2 fragment completion mismatch — sourced-but-unfinished: [${unfinished:-none}] marked-but-not-sourced: [${unexpected:-none}]"
        MEWG_CHECKS_OK=0
    fi
    if [ "$MEWG_CHECKS_OK" = 1 ] && [ "$group" = "$MEWG_PASS_OWNER" ]; then
        pass "FRAG1 every fragment file is sourced and every sourced fragment exists"
        pass "FRAG2 every sourced fragment ran through to its completion marker"
    fi
    return 0
}
