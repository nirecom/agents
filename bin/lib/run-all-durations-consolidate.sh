#!/usr/bin/env bash
# Duration-ledger consolidation (#2079 S7b): closed, abandoned and leftover segments of this
# host fold into one base segment per OS attribute, `dur.<schema>.<tok>.<S>-0<k>.log`. Each
# series (repo, key, verdict, termination) keeps its RUN_ALL_DUR_KEEP_PER_SERIES records of the
# newest provenances (`#run <stamp>-<pid>`, else the file name; within one provenance the last
# row wins) under the attribute of its (repo, key)'s newest record only, so one key never
# spans two bases; a record older than the retention window is dropped, and a base over
# RUN_ALL_DUR_BASE_MAX_RECORDS loses its oldest-provenance records first.
# Publish-then-delete: an input is deleted only after every base is published and verified
# and only when it is byte-identical to what was read, so every interruption converges on
# the next round. Sourced only, by run-all-durations.sh (after run-all-parallelism.sh).

RUN_ALL_DUR_RETENTION_DAYS=30
RUN_ALL_DUR_ABANDON_MIN=360
RUN_ALL_DUR_LOCK_STALE_MIN=10
# Equal to TEST_TIME.samples in hooks/lib/size-limits.js (consolidation starts no node);
# tests/hooks/feature-2631-size-limits.js pins the two together.
RUN_ALL_DUR_KEEP_PER_SERIES=5
RUN_ALL_DUR_BASE_MAX_RECORDS=40000
_RADS_STATE=""
_RADS_SP=""

# _run_all_dur_seg_state <name> — fork-free, by name only, into _RADS_STATE (open, closed,
# consolidating, base, other) and _RADS_SP (`<stamp>-<pid>`).
_run_all_dur_seg_state() {
    local r="${1#dur."$RUN_ALL_DUR_SCHEMA".*.}" sp st pid
    _RADS_STATE=other
    _RADS_SP=""
    case "$r" in *.log) ;; *) return 0 ;; esac
    r="${r%.log}"
    case "$r" in
        *.closed) sp="${r%.closed}"; st=closed ;;
        *.consolidating) sp="${r%.consolidating}"; st=consolidating ;;
        *) sp="$r"; st=open ;;
    esac
    case "$sp" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*) ;;
        *) return 0 ;;
    esac
    pid="${sp#*-}"
    case "$pid" in *[!0-9]*) return 0 ;; esac
    [ "$st" = open ] && [ "${pid#0}" != "$pid" ] && st=base
    _RADS_STATE="$st"
    _RADS_SP="$sp"
    return 0
}

# _run_all_dur_lock <dir> — 0 when this process holds <dir>/.ledger.lock; a lock older than
# RUN_ALL_DUR_LOCK_STALE_MIN belongs to a dead round and is taken over once.
_run_all_dur_lock() {
    local lock="$1/.ledger.lock"
    mkdir "$lock" 2>/dev/null && return 0
    [ -n "$(find "$lock" -maxdepth 0 -mmin +"$RUN_ALL_DUR_LOCK_STALE_MIN" 2>/dev/null)" ] || return 1
    rm -rf "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null
}

_run_all_dur_unlock() { rmdir "$1/.ledger.lock" 2>/dev/null; return 0; }

# _run_all_dur_needs_round <dir> <tok> — 0 when there is work. Starts no process but `find`,
# so a consolidated ledger costs one glob per start.
_run_all_dur_needs_round() {
    local dir="$1" tok="$2" f s bs="" open=0
    for f in "$dir"/dur."$RUN_ALL_DUR_SCHEMA"."$tok".*.log; do
        [ -f "$f" ] || continue
        _run_all_dur_seg_state "${f##*/}"
        case "$_RADS_STATE" in
            closed|consolidating) return 0 ;;
            base) s="${_RADS_SP%%-*}"; [ -n "$bs" ] && [ "$bs" != "$s" ] && return 0; bs="$s" ;;
            open) open=1 ;;
        esac
    done
    if command -v run_all_ledger_migrate_durations_pending >/dev/null 2>&1 &&
       run_all_ledger_migrate_durations_pending "$dir"; then
        return 0
    fi
    [ "$open" -eq 1 ] || return 1
    while IFS= read -r f; do
        _run_all_dur_seg_state "${f##*/}"
        [ "$_RADS_STATE" = open ] && return 0
    done < <(find "$dir" -maxdepth 1 -type f -name "dur.$RUN_ALL_DUR_SCHEMA.$tok.*.log" -mmin +"$RUN_ALL_DUR_ABANDON_MIN" 2>/dev/null)
    return 1
}

# _run_all_dur_take <dir> <tok> — rename closed and abandoned (quiet > ABANDON_MIN) open
# segments to their consolidating name; a taken target or a refused rename waits a round.
_run_all_dur_take() {
    local f n
    for f in "$1"/dur."$RUN_ALL_DUR_SCHEMA"."$2".*.closed.log; do
        [ -f "$f" ] || continue
        _run_all_dur_seg_state "${f##*/}"
        [ "$_RADS_STATE" = closed ] || continue
        n="${f%.closed.log}.consolidating.log"
        [ -e "$n" ] || mv "$f" "$n" 2>/dev/null
    done
    while IFS= read -r f; do
        _run_all_dur_seg_state "${f##*/}"
        [ "$_RADS_STATE" = open ] || continue
        n="${f%.log}.consolidating.log"
        [ -e "$n" ] || mv "$f" "$n" 2>/dev/null
    done < <(find "$1" -maxdepth 1 -type f -name "dur.$RUN_ALL_DUR_SCHEMA.$2.*.log" -mmin +"$RUN_ALL_DUR_ABANDON_MIN" 2>/dev/null)
    return 0
}

# _run_all_dur_fold <list> <now> <tmp-prefix> <inputs>... — the kept records per series, one
# `<prefix>.<i>` per attribute; prints `<i>\t<lines>` per file, then `E\t<S>` on success.
# A <list> file (a migration claim) may hold legacy 3-field rows, read as `?|?` v3 rows,
# and an attribute `-` there means "take it from the file's `#os` header".
_run_all_dur_fold() {
    local list="$1" now="$2" tmpp="$3"
    shift 3
    LC_ALL=C awk -v LIST="$list" -v NOW="$now" -v DAYS="$RUN_ALL_DUR_RETENTION_DAYS" \
        -v ATTRRE="$RUN_ALL_OS_ATTR_CLASS" -v FAM="${RUN_ALL_DUR_OS_ATTR%%/*}" \
        -v SCH="$RUN_ALL_DUR_SCHEMA" -v KEEP="$RUN_ALL_DUR_KEEP_PER_SERIES" "$RUN_ALL_DUR_AWK_PARSE"'
function secs(t,   y, m, d, era, yoe, doy) {
    y = substr(t, 1, 4) + 0; m = substr(t, 5, 2) + 0; d = substr(t, 7, 2) + 0
    if (m <= 2) y--
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
    return (era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468) * 86400 \
        + substr(t, 10, 2) * 3600 + substr(t, 12, 2) * 60 + substr(t, 14, 2)
}
function okprov(sp) { return index(sp, "-") == 16 && substr(sp, 1, 15) ~ ST && substr(sp, 17) ~ /^[0-9]+$/ }
function hdrattr(a) { return (a !~ ATTRRE || length(a) > 97) ? FAM "/unknown" : a }
function legacy3(l,   p, r, q) {
    p = index(l, "|"); r = substr(l, p + 1); q = index(r, "|")
    if (p == 0 || q == 0 || index(substr(r, q + 1), "|") > 0) return l
    return substr(l, 1, p) substr(r, 1, q) "?|?|" substr(r, q + 1)
}
BEGIN {
    D = "[0-9]"; ST = "^" D D D D D D D D "T" D D D D D D "$"
    while ((getline l < LIST) > 0) { split(l, f, "\t"); LSP[f[3]] = f[1]; LAT[f[3]] = f[2] }
    cut = secs(NOW) - DAYS * 86400
}
FNR == 1 {
    hdr = (substr($0, 1, 4) == "#os ") ? substr($0, 5) : ""
    mig = (FILENAME in LSP)
    if (mig) { prov = LSP[FILENAME]; at = LAT[FILENAME]; if (at == "-") at = hdrattr(hdr) }
    else {
        b = FILENAME; sub(/.*\//, "", b); sub("^dur\\." SCH "\\.[^.]*\\.", "", b)
        sub(/\.log$/, "", b); sub(/\.(closed|consolidating)$/, "", b); prov = b; at = hdrattr(hdr)
    }
}
substr($0, 1, 5) == "#run " { r = substr($0, 6); if (okprov(r)) prov = r; next }
substr($0, 1, 1) == "#" { next }
{
    l = mig ? legacy3($0) : $0
    if (!okprov(prov) || !dur_parse(l)) next
    pk = substr(prov, 1, 15) sprintf("%015d", substr(prov, 17) + 0)
    id = P_RID SUBSEP P_KEY SUBSEP P_VERDICT SUBSEP P_TERM
    if (!((id, pk) in L)) { NP[id]++; PK[id, NP[id]] = pk }
    L[id, pk] = l; A[id, pk] = at; SP[id, pk] = prov
    kk = P_RID SUBSEP P_KEY; KK[id] = kk
    if (!(kk in WP) || pk >= WP[kk]) { WP[kk] = pk; WA[kk] = at }
}
END {
    for (id in NP) {
        n = NP[id]
        for (i = 2; i <= n; i++) {
            v = PK[id, i]
            for (j = i - 1; j >= 1 && PK[id, j] < v; j--) PK[id, j + 1] = PK[id, j]
            PK[id, j + 1] = v
        }
        kept = 0
        for (i = 1; i <= n && kept < KEEP; i++) {
            pk = PK[id, i]
            if (secs(substr(pk, 1, 15)) < cut) break
            if (A[id, pk] != WA[KK[id]]) continue
            printf "%s\t%s\t%s\t%s\n", pk, A[id, pk], SP[id, pk], L[id, pk]; m++; kept++
        }
    }
    print "!N\t" (m + 0)
}' "$@" 2>/dev/null | LC_ALL=C sort | LC_ALL=C awk -v MAX="$RUN_ALL_DUR_BASE_MAX_RECORDS" '
NR == 1 { if (substr($0, 1, 3) != "!N\t") exit; drop = substr($0, 4) - MAX; ok = 1; next }
drop > 0 { drop--; next }
{
    p = index($0, "\t"); pk = substr($0, 1, p - 1); r = substr($0, p + 1)
    printf "%s\t%s\t%s\n", substr(r, 1, index(r, "\t") - 1), substr(pk, 1, 15) "\t" substr(pk, 16), substr(r, index(r, "\t") + 1); c++
}
END { if (ok) print "~END\t" (c + 0) }' 2>/dev/null | LC_ALL=C sort | LC_ALL=C awk -v P="$tmpp" '
substr($0, 1, 5) == "~END\t" { want = substr($0, 6) + 0; done = 1; next }
{
    r = $0; for (j = 1; j <= 4; j++) { p = index(r, "\t"); F[j] = substr(r, 1, p - 1); r = substr(r, p + 1) }
    if (F[1] != pa) { if (k) close(P "." k); k++; pa = F[1]; psp = ""; print "#os " pa > (P "." k); c[k] = 1 }
    if (F[4] != psp) { psp = F[4]; print "#run " psp > (P "." k); c[k]++ }
    print r > (P "." k); c[k]++; recs++
    if (F[2] > S) S = F[2]
}
END {
    if (k) close(P "." k)
    for (i = 1; i <= k; i++) print i "\t" c[i]
    if (done && recs == want) print "E\t" S
}' 2>/dev/null
}

_run_all_dur_in() {
    local x="$1" y
    shift
    for y in "$@"; do [ "$y" = "$x" ] && return 0; done
    return 1
}

# _run_all_dur_lines <file> — line count, or `x` when unreadable.
_run_all_dur_lines() { LC_ALL=C awk 'END { print NR }' "$1" 2>/dev/null || printf 'x'; }

# run_all_dur_consolidate <ledger-dir> <now-stamp> — one round; always returns 0 and every
# failure leaves the inputs in place for the next round.
run_all_dur_consolidate() {
    local dir="${1:-}" now="${2:-}" tok f n k i cnt S="" ok=0 tmpp list man sums line nl=$'\n'
    local -a own=() bases=() first=() rest=() inputs=() idx=() cnts=()
    [ -d "$dir" ] || return 0
    case "$now" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) return 0 ;;
    esac
    run_all_dur_host_token >/dev/null
    tok="$RUN_ALL_DUR_HOST_TOKEN"
    _run_all_dur_needs_round "$dir" "$tok" || return 0
    _run_all_dur_lock "$dir" || return 0
    if ! _run_all_dur_needs_round "$dir" "$tok"; then _run_all_dur_unlock "$dir"; return 0; fi
    [ -n "$RUN_ALL_DUR_OS_ATTR" ] || RUN_ALL_DUR_OS_ATTR="$(run_all_os_attr)"
    find "$dir" -maxdepth 1 -type f -name '.dur.tmp.*' -mmin +"$RUN_ALL_DUR_LOCK_STALE_MIN" -exec rm -f {} + 2>/dev/null

    # Every base moves aside first, so publishing never overwrites one; a refused move
    # (Windows: held open) ends the round before anything else changed.
    for f in "$dir"/dur."$RUN_ALL_DUR_SCHEMA"."$tok".*.log; do
        [ -f "$f" ] || continue
        _run_all_dur_seg_state "${f##*/}"
        [ "$_RADS_STATE" = base ] || continue
        n="${f%.log}.consolidating.log"
        if [ -e "$n" ]; then bases+=("$f"); continue; fi
        if ! mv "$f" "$n" 2>/dev/null; then _run_all_dur_unlock "$dir"; return 0; fi
        own+=("$n")
    done
    _run_all_dur_take "$dir" "$tok"

    tmpp="$dir/.dur.tmp.$$"
    list="$tmpp.list"
    man="$tmpp.man"
    if ! : >"$list" 2>/dev/null; then _run_all_dur_unlock "$dir"; return 0; fi
    if command -v run_all_ledger_migrate_durations >/dev/null 2>&1; then
        run_all_ledger_migrate_durations "$dir" "$list"
    fi
    # Bases first, raw segments after: on a provenance tie the later read wins.
    for f in "$dir"/dur."$RUN_ALL_DUR_SCHEMA"."$tok".*.consolidating.log; do
        [ -f "$f" ] || continue
        _run_all_dur_seg_state "${f##*/}"
        [ "$_RADS_STATE" = consolidating ] || continue
        case "${_RADS_SP#*-}" in 0*) first+=("$f") ;; *) rest+=("$f") ;; esac
    done
    while IFS=$'\t' read -r _ _ f; do
        [ -n "$f" ] && rest+=("$f")
    done <"$list"
    inputs=(${first[@]+"${first[@]}"} ${bases[@]+"${bases[@]}"} ${rest[@]+"${rest[@]}"})
    if [ "${#inputs[@]}" -eq 0 ]; then
        rm -f "$list" 2>/dev/null
        _run_all_dur_unlock "$dir"
        return 0
    fi

    sums="$(cksum "${inputs[@]}" 2>/dev/null)"
    _run_all_dur_fold "$list" "$now" "$tmpp" "${inputs[@]}" >"$man"
    while IFS=$'\t' read -r i cnt; do
        case "$i" in
            E) S="$cnt"; ok=1 ;;
            *) idx+=("$i"); cnts+=("$cnt"); [ "$(_run_all_dur_lines "$tmpp.$i")" = "$cnt" ] || ok=0 ;;
        esac
    done <"$man"
    [ "${#idx[@]}" -eq 0 ] || [ -n "$S" ] || ok=0

    # Publish each attribute's base under the lowest free number; a leftover aside of an
    # earlier round still holds its number until it is deleted.
    k=0
    for i in "${!idx[@]}"; do
        [ "$ok" -eq 1 ] || break
        k=$((k + 1))
        while :; do
            n="$dir/dur.$RUN_ALL_DUR_SCHEMA.$tok.$S-0$k.log"
            if [ -e "$n" ]; then k=$((k + 1)); continue; fi
            if [ -e "${n%.log}.consolidating.log" ] &&
               ! _run_all_dur_in "${n%.log}.consolidating.log" ${own[@]+"${own[@]}"}; then
                k=$((k + 1)); continue
            fi
            break
        done
        if declare -F run_all_dur_before_publish >/dev/null 2>&1 && ! run_all_dur_before_publish "$n"; then
            ok=0; break
        fi
        mv "$tmpp.${idx[$i]}" "$n" 2>/dev/null || { ok=0; break; }
        [ "$(_run_all_dur_lines "$n")" = "${cnts[$i]}" ] || ok=0
    done
    if [ "$ok" -eq 1 ]; then
        if declare -F run_all_dur_before_delete >/dev/null 2>&1; then
            for f in "${inputs[@]}"; do run_all_dur_before_delete "$f"; done
        fi
        # Only an input still byte-identical to what was read goes: a late line keeps it.
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$nl$sums$nl" in
                *"$nl$line$nl"*) f="${line#* }"; rm -f "${f#* }" 2>/dev/null ;;
            esac
        done < <(cksum "${inputs[@]}" 2>/dev/null)
    fi
    rm -f "$tmpp".* 2>/dev/null
    _run_all_dur_unlock "$dir"
    return 0
}
