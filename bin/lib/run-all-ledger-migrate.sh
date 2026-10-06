#!/usr/bin/env bash
# --- BEGIN temporary: dur.1 / pre-v2 baseline segments → dur.2 / v2 segments migration added 2026-10-03 ---
# deletion-condition: every host the user runs has executed this code once and holds no dur.1.*, pre-v2 *.seg, or *.migrating file (#2079 follow-up issue)
# Removing this file (its one source line in run-all-durations.sh and the `command -v` call
# sites) changes no permanent behaviour — legacy files simply stop being read.
# Why it exists: #2079 S6 re-keyed Windows hosts and versioned both ledger formats, so
# records written before it would otherwise be orphaned. Sourced only, by
# run-all-durations.sh after run-all-durations-consolidate.sh (its lock is shared).

RUN_ALL_MIGRATE_WINDOW_MIN=60

# _ralm_facts — current token, attribute, family and Windows-ness; fork-free when the
# writer already memoised them.
_ralm_facts() {
    run_all_dur_host_token >/dev/null
    [ -n "$RUN_ALL_DUR_OS_ATTR" ] || RUN_ALL_DUR_OS_ATTR="$(run_all_os_attr)"
    _RALM_TOK="$RUN_ALL_DUR_HOST_TOKEN"
    _RALM_ATTR="$RUN_ALL_DUR_OS_ATTR"
    _RALM_FAM="${_RALM_ATTR%%/*}"
    _RALM_WIN=0
    [ "$_RALM_FAM" = "Windows" ] && _RALM_WIN=1
    return 0
}

# _ralm_win_tokens — the pre-#2079 tokens this exact Windows version/build produced under
# each launch path; only computed when there is legacy work.
_ralm_win_tokens() {
    local rest hd x
    _run_all_host_facts
    rest="${_RUN_ALL_RAW_OS#*_NT-}"
    hd="${_RUN_ALL_HOST_ID##*|}"
    _RALM_WIN_TOKS=" "
    for x in "MINGW64_NT-$rest" "MSYS_NT-$rest" "$_RUN_ALL_RAW_OS"; do
        _RALM_WIN_TOKS="$_RALM_WIN_TOKS$(run_all_dur_pad16 "$(run_all_id_digest "$(run_all_host_id_compose "$x" "$_RUN_ALL_ARCH" "$hd")")") "
    done
}

# _ralm_legacy_attr <old-token> — the attribute a legacy record is migrated with.
_ralm_legacy_attr() {
    if [ "$_RALM_WIN" -eq 1 ]; then
        case "$_RALM_WIN_TOKS" in *" $1 "*) printf '%s' "$_RALM_ATTR"; return 0 ;; esac
    fi
    printf '%s/unknown-migrated' "$_RALM_FAM"
}

_ralm_sweep_temps() {
    find "$1" -maxdepth 1 -type f -name '.migrate.tmp.*' -mmin +"$RUN_ALL_MIGRATE_WINDOW_MIN" \
        -exec rm -f {} + 2>/dev/null
    return 0
}

_ralm_sum() { cksum <"$1" 2>/dev/null || printf 'none'; }

# _ralm_may_delete <claim> <sum-before-read> — the claim is unchanged since it was read, so
# no line a legacy writer appended after the rename can be lost by deleting it.
_ralm_may_delete() {
    if declare -F run_all_ledger_migrate_before_delete >/dev/null 2>&1; then
        run_all_ledger_migrate_before_delete "$1"
    fi
    [ "$(_ralm_sum "$1")" = "$2" ]
}

# _ralm_claim <dir> <name-glob> — rename every old-enough legacy file to `<name>.migrating`.
# A failed rename (file held open) or a pending claim of the same name waits for next round.
_ralm_claim() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$2" in '*.seg') case "${f##*/}" in v2.*) continue ;; esac ;; esac
        [ -e "$f.migrating" ] && continue
        [ -n "${_RALM_SKIP_DEST:-}" ] && "$_RALM_SKIP_DEST" "$f" && continue
        mv "$f" "$f.migrating" 2>/dev/null || continue
    done < <(find "$1" -maxdepth 1 -type f -name "$2" -mmin +"$RUN_ALL_MIGRATE_WINDOW_MIN" 2>/dev/null)
    return 0
}

# --- duration ledger ----------------------------------------------------------

_ralm_dur_pat() {
    _RALM_PAT="dur.1.*.log"
    [ "$_RALM_WIN" -eq 1 ] || _RALM_PAT="dur.1.$_RALM_TOK.*.log"
}

# run_all_ledger_migrate_durations_pending <ledger-dir> — 0 when legacy work may exist;
# glob only, so the consolidation quiet path stays process-free.
run_all_ledger_migrate_durations_pending() {
    local dir="${1:-}" f
    [ -d "$dir" ] || return 1
    _ralm_facts
    _ralm_dur_pat
    for f in "$dir"/$_RALM_PAT "$dir"/$_RALM_PAT.migrating "$dir"/.migrate.tmp.*; do
        [ -e "$f" ] && return 0
    done
    return 1
}

# run_all_ledger_migrate_durations <ledger-dir> <list> — claim legacy dur.1 segments and
# append `<stamp>-<pid>\t<attribute>\t<claim>` per claim to <list>; the caller
# (run_all_dur_consolidate, holding the ledger lock) folds them in and deletes them.
run_all_ledger_migrate_durations() {
    local dir="${1:-}" list="${2:-}" f n sp
    [ -d "$dir" ] && [ -n "$list" ] || return 0
    _ralm_facts
    _ralm_dur_pat
    _ralm_sweep_temps "$dir"
    _RALM_SKIP_DEST="" _ralm_claim "$dir" "$_RALM_PAT"
    [ "$_RALM_WIN" -eq 1 ] && _ralm_win_tokens
    for f in "$dir"/$_RALM_PAT.migrating; do
        [ -f "$f" ] || continue
        n="${f##*/}"
        n="${n#dur.1.}"
        sp="${n#*.}"
        sp="${sp%.log.migrating}"
        case "$sp" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*) ;;
            *) continue ;;
        esac
        case "${sp#*-}" in *[!0-9]*) continue ;; esac
        printf '%s\t%s\t%s\n' "$sp" "$(_ralm_legacy_attr "${n%%.*}")" "$f" >>"$list"
    done
    return 0
}

# --- baseline ledger ----------------------------------------------------------

# _ralm_base_dest_foreign <legacy-file> — 0 when its v2 destination exists and was not
# produced by migrating this same name (a v2 line carries another attribute). Our own
# output there means the legacy writer re-created the name after its claim: merge it.
_ralm_base_dest_foreign() {
    local n="${1##*/}" d
    n="${n%.migrating}"
    d="${1%/*}/v2.$_RALM_TOK-${n#*-}"
    [ -e "$d" ] || return 1
    LC_ALL=C awk -F '\t' -v A="$(_ralm_legacy_attr "${n%%-*}")" \
        '$1 == "v2" && $7 != A { f = 1; exit } END { exit !f }' "$d" 2>/dev/null
}

# run_all_ledger_migrate_baseline <repo-ledger-dir> — rewrite each legacy segment as
# `v2.<current token>-<epoch>-<pid>.seg`, keeping its mtime and epochs (#2079 S7).
run_all_ledger_migrate_baseline() {
    local dir="${1:-}" pat f n dest tmp sum want own
    [ -d "$dir" ] || return 0
    _ralm_facts
    pat="*.seg"
    [ "$_RALM_WIN" -eq 1 ] || pat="$_RALM_TOK-*.seg"
    n=0
    for f in "$dir"/$pat "$dir"/$pat.migrating "$dir"/.migrate.tmp.*; do
        [ -e "$f" ] || continue
        case "${f##*/}" in v2.*) continue ;; esac
        n=1; break
    done
    [ "$n" = "1" ] || return 0
    _ralm_sweep_temps "$dir"
    _run_all_dur_lock "$dir" || return 0
    _ralm_sweep_temps "$dir"
    [ "$_RALM_WIN" -eq 1 ] && _ralm_win_tokens
    _RALM_SKIP_DEST=_ralm_base_dest_foreign _ralm_claim "$dir" "$pat"
    tmp="$dir/.migrate.tmp.$$"
    for f in "$dir"/$pat.migrating; do
        [ -f "$f" ] || continue
        n="${f##*/}"; n="${n%.migrating}"
        case "$n" in v2.*) continue ;; esac
        _ralm_base_dest_foreign "$f" && continue
        dest="$dir/v2.$_RALM_TOK-${n#*-}"
        sum="$(_ralm_sum "$f")"
        LC_ALL=C awk -F '\t' -v OFS='\t' -v TOK="$_RALM_TOK" -v ATTR="$(_ralm_legacy_attr "${n%%-*}")" '
NF == 6 && $1 == "v1" { print "v2", $2, TOK, $4, $5, $6, ATTR; next }
{ print }' "$f" >"$tmp.cv" 2>/dev/null || { rm -f "$tmp.cv"; continue; }
        own="$(awk 'END { print NR }' "$tmp.cv" 2>/dev/null)"; want="$own"
        # Review C4: a round that died after publishing left this exact conversion at the
        # tail of dest — finish it by deleting the claim, leaving dest and its mtime alone.
        if [ -f "$dest" ] && [ "${own:-0}" -gt 0 ] &&
           [ "$(tail -n "$own" "$dest" 2>/dev/null | cksum)" = "$(cksum <"$tmp.cv")" ]; then
            _ralm_may_delete "$f" "$sum" && rm -f "$f"
            rm -f "$tmp.cv"
            continue
        fi
        # A merge keeps the earlier output first and takes the newer mtime of the two.
        if [ -f "$dest" ]; then
            want=$((want + $(awk 'END { print NR }' "$dest" 2>/dev/null)))
            cat "$dest" "$tmp.cv" >"$tmp" 2>/dev/null || { rm -f "$tmp" "$tmp.cv"; continue; }
        else
            cat "$tmp.cv" >"$tmp" 2>/dev/null || { rm -f "$tmp" "$tmp.cv"; continue; }
        fi
        rm -f "$tmp.cv"
        if [ -f "$dest" ] && [ "$dest" -nt "$f" ]; then touch -r "$dest" "$tmp"; else touch -r "$f" "$tmp"; fi 2>/dev/null
        cp -p "$tmp" "$tmp.ref" 2>/dev/null
        mv "$tmp" "$dest"
        if [ "$(awk 'END { print NR }' "$dest" 2>/dev/null)" = "$want" ] &&
           ! [ "$dest" -nt "$tmp.ref" ] && ! [ "$dest" -ot "$tmp.ref" ] &&
           [ "$(_ralm_sum "$dest")" = "$(_ralm_sum "$tmp.ref")" ] && _ralm_may_delete "$f" "$sum"; then
            rm -f "$f"
        elif [ "$want" = "$own" ]; then
            rm -f "$dest"
        fi
        rm -f "$tmp.ref"
    done
    _run_all_dur_unlock "$dir"
    return 0
}
# --- END temporary: dur.1 / pre-v2 baseline segments → dur.2 / v2 segments migration ---
