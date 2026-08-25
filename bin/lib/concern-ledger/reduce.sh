#!/usr/bin/env bash
# bin/lib/concern-ledger/reduce.sh
# Sourced by bin/lib/concern-ledger.sh (never executed directly). The state
# layer: it consumes the bind and merge decisions made in the entrypoint and
# writes the ledger back — new IDs, carried entries, the fail-closed absence
# rule, flags, the tally, the prior-concerns block handed to producers, and
# the cycle boundary.

# ---------------------------------------------------------------------------
# Reduce
# ---------------------------------------------------------------------------
_cl_flag_add() {
    local cur="$1" add="$2"
    case "$cur" in -|'') printf '%s' "$add"; return ;; esac
    case ",$cur," in *",$add,"*) printf '%s' "$cur"; return ;; esac
    printf '%s,%s' "$cur" "$add"
}

_cl_flag_has() {
    case ",$1," in *",$2,"*) return 0 ;; esac
    case "$1" in *"$2:"*) return 0 ;; esac
    return 1
}

_cl_next_id() {
    local id max=0 n
    for id in "${CL_IDS[@]}"; do
        n="${id#C}"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        [ "$n" -gt "$max" ] && max="$n"
    done
    printf 'C%s' "$((max + 1))"
}

# cl_reduce <in-ledger> <staging-glob> <round> <format> <out-ledger>
# <staging-glob> is a directory plus a basename pattern; it is never expanded
# by the shell, and its directory component is taken literally.
cl_reduce() {
    local inl="$1" glob="$2" round="$3" fmt="$4" outl="$5"
    local tmpd f hdr prod comp line
    tmpd="$(mktemp -d)" || return 1
    _cl_load_ledger "$inl" "$round"
    local sid="${CL_HDR_SID:-}" cycle="${CL_HDR_CYCLE:-1}"
    [ -z "$sid" ] && sid="${CL_SESSION_ID:-unknown}"

    # --- collect this round's staging files, in declared producer order -------
    local -a files=() ordered=() staged=()
    local -A fcomp=() fname=()
    # Discovery does not go through pathname expansion: the plans-dir may be a
    # Windows path whose backslashes a glob would eat as escapes (#2088).
    # The helper runs in a process-substitution subshell, so its refusal cannot
    # come back as an exit status; the armed channel is what carries it. Refusing
    # here is not caution but the whole point: a round this reducer could not
    # read is not a round nobody reported, and the absence rule below would
    # otherwise write off every open concern as stale and drop the round's new
    # findings, at rc 0 with a tally attached (#2025 C6).
    if ! _cl_discovery_arm; then
        printf 'concern-ledger: reduce: could not open the discovery channel; refusing round %s rather than read it unverifiably\n' \
            "$round" >&2
        rm -rf "$tmpd"
        return 1
    fi
    while IFS= read -r -d '' f; do
        staged+=("$f")
    done < <(_cl_list_pattern_files "$glob")
    if _cl_discovery_failed; then
        _cl_discovery_disarm
        printf 'concern-ledger: reduce: refusing round %s — its staging files could not be listed, and an unread round is not an empty one; the ledger is left unchanged\n' \
            "$round" >&2
        rm -rf "$tmpd"
        return 1
    fi
    _cl_discovery_disarm
    for f in "${staged[@]:-}"; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        hdr="$(grep -m1 '^#producer|' "$f" 2>/dev/null || true)"
        [ -n "$hdr" ] || continue
        [ "$(printf '%s' "$hdr" | cut -d'|' -f6)" = "$round" ] || continue
        prod="$(printf '%s' "$hdr" | cut -d'|' -f2)"
        comp="$(printf '%s' "$hdr" | cut -d'|' -f3)"
        # Last-wins, but never silently: the CLI puts the producer in the file
        # name, so two files claiming one producer can only be hand-placed, and
        # failing the round over a stray file would be #2088's own outage.
        if [ -n "${fname[$prod]:-}" ]; then
            printf 'concern-ledger: duplicate staging file for producer=%s round=%s; using the LC_ALL=C-last one: %s (ignored: %s)\n' \
                "$prod" "$round" "$f" "${fname[$prod]}" >&2
        fi
        fcomp[$prod]="$comp"
        fname[$prod]="$f"
        files+=("$prod")
    done
    local p
    while IFS= read -r p; do
        [ -n "${fname[$p]:-}" ] && ordered+=("$p")
    done < <(cl_declared_producers "$fmt")
    for p in $(printf '%s\n' "${files[@]:-}" | grep -v '^$' | LC_ALL=C sort -u); do
        case " ${ordered[*]:-} " in *" $p "*) ;; *) ordered+=("$p") ;; esac
    done

    # --- completeness of the round -------------------------------------------
    local complete=1 declared_any=0
    while IFS= read -r p; do
        declared_any=1
        [ "${fcomp[$p]:-MISSING}" = "COMPLETE" ] || complete=0
    done < <(cl_declared_producers "$fmt")
    if [ "$declared_any" -eq 0 ]; then
        [ "${#ordered[@]}" -eq 0 ] && complete=0
        for p in "${ordered[@]:-}"; do
            [ -n "$p" ] || continue
            [ "${fcomp[$p]}" = "COMPLETE" ] || complete=0
        done
    fi

    # --- concatenate the round's deltas ---------------------------------------
    : > "$tmpd/delta.txt"
    : > "$tmpd/unparsed.txt"
    for p in "${ordered[@]:-}"; do
        [ -n "$p" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                '#producer|'*) ;;
                '#unparsed|'*) printf '%s\n' "$line" >> "$tmpd/unparsed.txt" ;;
                ''|'#'*) ;;
                *) printf '%s\n' "$line" >> "$tmpd/delta.txt" ;;
            esac
        done < "${fname[$p]}"
        [ "${fcomp[$p]}" = "COMPLETE" ] || \
            printf 'concern-ledger: delta-parse-incomplete (producer=%s round=%s completeness=%s)\n' \
                "$p" "$round" "${fcomp[$p]}" >&2
    done

    # --- closed admission: plan formats never mint an invented ID -------------
    cl_read_v1_or_v2 "$inl" "$round" > "$tmpd/ledger.txt"
    if [ "$(cl_admission "$fmt" "$round")" = "closed" ]; then
        local dropped="" keep="$tmpd/delta-keep.txt" ref
        : > "$keep"
        while IFS= read -r line || [ -n "$line" ]; do
            ref="$(printf '%s' "$line" | cut -d'|' -f1)"
            if [ "$ref" != "-" ] && [ -n "${CL_E_TEXT[$ref]+x}" ]; then
                printf '%s\n' "$line" >> "$keep"
            elif [ "$ref" != "-" ]; then
                case " $dropped " in *" $ref "*) ;; *) dropped="${dropped:+$dropped }$ref" ;; esac
            fi
        done < "$tmpd/delta.txt"
        mv "$keep" "$tmpd/delta.txt"
        if [ -n "$dropped" ]; then
            printf 'discarded new concern IDs in round %s: %s\n' \
                "$round" "$(printf '%s' "$dropped" | tr ' ' ',')" >&2
        fi
    fi

    _cl_load_delta "$tmpd/delta.txt"
    cl_bind "$tmpd/ledger.txt" "$tmpd/delta.txt" > "$tmpd/bind.txt"
    cl_merge_producers "$tmpd/delta.txt" "$tmpd/bind.txt" > "$tmpd/merge.txt"

    local n="${#CL_D_REF[@]}" i idx tierv id
    local -A boundto=() dnote=() mflag=() leaderof=()
    while IFS=$'\t' read -r id idx tierv; do
        if [ "$id" = "#note" ]; then dnote[$idx]="$tierv"; continue; fi
        [ "$id" = "-" ] && continue
        boundto[$idx]="$id"
    done < "$tmpd/bind.txt"
    local a b c2
    while IFS=$'\t' read -r a b c2; do
        if [ "$a" = "#flag" ]; then mflag[$b]="$c2"; continue; fi
        leaderof[$b]="$a"
    done < "$tmpd/merge.txt"

    # --- group the round's lines and settle each group onto an ID -------------
    local -A gid=() gsev=() gtext=() gprod=() gslot=() gdiscrim=() gorigin=() ganchor=()
    local -a groups=()
    local ld
    for ((i = 0; i < n; i++)); do
        ld="${leaderof[$i]:-$i}"
        if [ -z "${gsev[$ld]:-}" ]; then
            groups+=("$ld")
            gsev[$ld]="${CL_D_SEV[i]}"; gtext[$ld]="${CL_D_TEXT[i]}"
            gslot[$ld]="${CL_D_SLOT[i]}"; gdiscrim[$ld]="${CL_D_DISCRIM[i]}"
            gorigin[$ld]="${CL_D_PROD[i]}"; gprod[$ld]="${CL_D_PROD[i]}"
            ganchor[$ld]="${CL_D_ANCHOR[i]}"
            gid[$ld]="${boundto[$i]:-}"
        else
            gsev[$ld]="$(_cl_sev_max "${gsev[$ld]}" "${CL_D_SEV[i]}")"
            case ",${gprod[$ld]}," in
                *",${CL_D_PROD[i]},"*) ;;
                *) gprod[$ld]="${gprod[$ld]},${CL_D_PROD[i]}" ;;
            esac
            [ -z "${gid[$ld]}" ] && gid[$ld]="${boundto[$i]:-}"
            printf '#merged-alt|@@%s@@|%s\n' "$ld" "${CL_D_TEXT[i]}" >> "$tmpd/alt.txt"
        fi
    done

    # --- mint IDs for the groups that bound to nothing ------------------------
    local newid
    for ld in "${groups[@]:-}"; do
        [ -n "$ld" ] || continue
        [ -n "${gid[$ld]}" ] && continue
        newid="$(_cl_next_id)"
        gid[$ld]="$newid"
        CL_IDS+=("$newid")
        CL_E_SEV[$newid]="${gsev[$ld]}"; CL_E_STATE[$newid]="open"
        CL_E_FIRST[$newid]="$round"; CL_E_LAST[$newid]="$round"
        CL_E_SLOT[$newid]="${gslot[$ld]}"; CL_E_DISCRIM[$newid]="${gdiscrim[$ld]}"
        CL_E_ORIGIN[$newid]="${gorigin[$ld]}"; CL_E_PROD[$newid]="${gprod[$ld]}"
        CL_E_FLAGS[$newid]="-"; CL_E_TEXT[$newid]="${gtext[$ld]}"
    done

    # --- fold each group into its entry ---------------------------------------
    local -A touched=() reopened=()
    local flags oldflags
    for ld in "${groups[@]:-}"; do
        [ -n "$ld" ] || continue
        id="${gid[$ld]}"
        touched[$id]=1
        oldflags="${CL_E_FLAGS[$id]}"
        flags="-"
        if [ "${CL_E_STATE[$id]}" = "resolved" ]; then
            reopened[$id]=1
            flags="$(_cl_flag_add "$flags" "reopened")"
        fi
        CL_E_STATE[$id]="open"
        CL_E_LAST[$id]="$round"
        CL_E_SEV[$id]="$(_cl_sev_max "${CL_E_SEV[$id]}" "${gsev[$ld]}")"
        CL_E_TEXT[$id]="${gtext[$ld]}"
        [ "${gslot[$ld]}" != "-" ] && CL_E_SLOT[$id]="${gslot[$ld]}"
        local pp
        for pp in $(printf '%s' "${gprod[$ld]}" | tr ',' ' '); do
            case ",${CL_E_PROD[$id]}," in
                *",$pp,"*) ;;
                *) CL_E_PROD[$id]="${CL_E_PROD[$id]},$pp" ;;
            esac
        done
        for ((i = 0; i < n; i++)); do
            [ "${leaderof[$i]:-$i}" = "$ld" ] || continue
            [ -n "${dnote[$i]:-}" ] && flags="$(_cl_flag_add "$flags" "${dnote[$i]}")"
            [ -n "${mflag[$i]:-}" ] && flags="$(_cl_flag_add "$flags" "${mflag[$i]}")"
        done
        if _cl_flag_has "$oldflags" "no-anchor" && [ "${ganchor[$ld]}" = "-" ]; then
            flags="$(_cl_flag_add "$flags" "no-anchor")"
        fi
        CL_E_FLAGS[$id]="$flags"
    done

    # --- absent entries: the two gates that must both open before a resolve ---
    local anchored_fmt=0
    [ "$fmt" = "review-security-shared" ] && anchored_fmt=1
    local amb blocked
    for id in "${CL_IDS[@]}"; do
        [ -n "${touched[$id]:-}" ] && continue
        oldflags="${CL_E_FLAGS[$id]}"
        flags="-"
        _cl_flag_has "$oldflags" "no-anchor" && flags="$(_cl_flag_add "$flags" "no-anchor")"
        if [ "${CL_E_STATE[$id]}" != "open" ]; then
            CL_E_FLAGS[$id]="$flags"
            continue
        fi
        amb=0
        for ((i = 0; i < n; i++)); do
            [ "${CL_D_SLOT[i]}" = "${CL_E_SLOT[$id]}" ] || continue
            ld="${leaderof[$i]:-$i}"
            [ "${CL_E_FIRST[${gid[$ld]}]}" = "$round" ] && amb=1
        done
        blocked=0
        [ "$complete" -eq 1 ] || blocked=1
        if [ "$anchored_fmt" -eq 1 ] && _cl_flag_has "$oldflags" "no-anchor"; then blocked=1; fi
        if [ "$blocked" -eq 1 ]; then flags="$(_cl_flag_add "$flags" "stale")"; fi
        if [ "$amb" -eq 1 ]; then flags="$(_cl_flag_add "$flags" "ambiguous")"; blocked=1; fi
        [ "$blocked" -eq 0 ] && CL_E_STATE[$id]="resolved"
        CL_E_FLAGS[$id]="$flags"
    done

    # --- serialize -------------------------------------------------------------
    local out="$tmpd/out.txt"
    {
        printf '#concern-ledger-v2|%s|%s|cycle=%s\n' "$fmt" "$sid" "$cycle"
        for id in $(printf '%s\n' "${CL_IDS[@]:-}" | grep -v '^$' | sed 's/^C//' | LC_ALL=C sort -n); do
            id="C$id"
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "${CL_E_SEV[$id]}" \
                "${CL_E_STATE[$id]}" "${CL_E_FIRST[$id]}" "${CL_E_LAST[$id]}" \
                "${CL_E_SLOT[$id]}" "${CL_E_DISCRIM[$id]}" "${CL_E_ORIGIN[$id]}" \
                "${CL_E_PROD[$id]}" "${CL_E_FLAGS[$id]:--}" "${CL_E_TEXT[$id]}"
        done
        [ -s "$tmpd/unparsed.txt" ] && cat "$tmpd/unparsed.txt"
        if [ -s "$tmpd/alt.txt" ]; then
            while IFS= read -r line; do
                ld="${line#\#merged-alt|@@}"; ld="${ld%%@@|*}"
                printf '#merged-alt|%s|%s\n' "${gid[$ld]}" "${line#*@@|}"
            done < "$tmpd/alt.txt"
        fi
    } > "$out"
    # _sp_dirname, not dirname(1): for a backslash-spelled out-ledger, dirname
    # answers "." and this would create a directory next to the caller instead,
    # leaving sp_publish_copy's temp with no parent to be created in.
    mkdir -p "$(_sp_dirname "$outl")" 2>/dev/null || true
    # Not `mv`: $outl is a fully predictable name, and mv onto a directory (or a
    # symlink to one) puts the new ledger *inside* it and returns 0 — reduce
    # would then tally an unchanged ledger and report success, which is the
    # silent loss of #2088 wearing different clothes. $out also lives in a
    # mktemp -d that may be on another filesystem, where mv degrades to
    # copy+unlink and stops being atomic. sp_publish_copy fixes both, and
    # disposes of its own temp, so the cleanup below is unchanged.
    sp_publish_copy "$out" "$outl" || { rm -rf "$tmpd"; return 1; }
    cl_tally "$outl"
    rm -rf "$tmpd"
    return 0
}

# cl_begin_cycle <ledger> <format> <round> — a round 1 that meets a live ledger
# starts a new cycle. Plan formats archive and rebuild an empty ID space; the
# shared code-review ledger carries its entries over.
cl_begin_cycle() {
    local f="$1" fmt="$2" round="$3"
    [ "${round:-1}" -eq 1 ] || return 0
    [ -f "$f" ] || return 0
    _cl_load_ledger "$f" 1
    local sid="${CL_HDR_SID:-${CL_SESSION_ID:-unknown}}" cyc="${CL_HDR_CYCLE:-1}"
    local next=$((cyc + 1))
    # Every write below goes through a publish primitive. The old shapes needed
    # no '$$' to be unsafe: $f and the archive name beside it are both fully
    # predictable, so a plain `cp` and a plain redirect followed whatever
    # symlink was left there (#2025 C6, round 4 #2).
    case "$fmt" in
        review-security-shared)
            {
                printf '#concern-ledger-v2|%s|%s|cycle=%s\n' "$fmt" "$sid" "$next"
                grep -v '^#concern-ledger-v2|' "$f" 2>/dev/null || true
            } | sp_publish_stdin "$f" || return 1
            ;;
        *)
            # Archive first, and refuse to advance the cycle if it fails: the
            # header rewrite below is what makes the old entries unreachable, so
            # writing it over an archive that was never taken destroys them.
            sp_publish_copy "$f" "${f%.txt}-cycle${cyc}.txt" || return 1
            printf '#concern-ledger-v2|%s|%s|cycle=%s\n' "$fmt" "$sid" "$next" \
                | sp_publish_stdin "$f" || return 1
            ;;
    esac
    # All three callers must honour this rc. A failure here leaves the previous
    # cycle live, and a round 1 reduced into it folds this round's concerns into
    # the old entries and loses them — which is why the review wrappers stop on
    # it rather than degrading, the one hole in their exit-0 contracts.
}


:  # load-success rc for the entrypoint's source check
