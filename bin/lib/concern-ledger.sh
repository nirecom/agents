#!/usr/bin/env bash
# bin/lib/concern-ledger.sh
# Shared concern-ledger library (schema v2) — #1992 / #1996.
#
# Why this exists: a review loop that renumbers its findings every round destroys
# the only handle the author has on "the thing you told me about last time".
# The ledger keeps the identity of a concern stable across rounds, so the success
# metric of every consumer is ID continuity, not how alike two texts read.
#
# Identity is established by declared reference ID (B1) or by a frozen content
# discriminator (B2) — never by position, cardinality, or how alike two texts look.

# Schema v2 (one entry per line, TEXT last so it may contain the separator):
#   #concern-ledger-v2|<format>|<session-id>|cycle=<K>
#   ID|SEVERITY|STATE|FIRST_ROUND|LAST_ROUND|SLOT|DISCRIM|ORIGIN|PRODUCERS|FLAGS|TEXT
#   #unparsed|<raw reviewer line>
#   #merged-alt|<id>|<non-adopted body>
# Normalized delta record (internal, produced by the cl_parse_* adapters):
#   REF|SEVERITY|SLOT|DISCRIM|CATEGORY|PRODUCER|ANCHORKEY|TEXT
# Staging file (one per producer per round):
#   #producer|<name>|<completeness>|<exec-label>|<parse-label>|<round>
#   <normalized delta records and #unparsed records>

# This entrypoint holds what the rest of the repository reasons about directly:
# the two identity decisions (bind, merge) and the derived file names. Everything
# else lives in the sibling bin/lib/concern-ledger/ modules
# (rules/coding/file-split.md Pattern A):
#   core.sh     — normalization, SLOT/DISCRIM hashes, severity and completeness
#   parse.sh    — ledger reading, the producer-report adapters, staging
#   reduce.sh   — new state from the round's bind/merge decisions, cycle rollover
#   render.sh   — the tally line and the prior-open-concerns block
#   finalize.sh — the unresolved-concerns artifact and its verdict

CL_CATEGORY_VOCAB="correctness security contract performance style docs test maintainability portability concurrency usability other"

CL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/concern-ledger"
# Fail loudly here rather than let every cl_* call resolve to "command not found":
# a caller that copied only this file has a broken install, and a ledger that
# half-loads is exactly the silent findings loss the whole subsystem exists to stop.
if [ ! -d "$CL_LIB_DIR" ]; then
    printf 'concern-ledger: library modules not found at %s — incomplete installation\n' "$CL_LIB_DIR" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=./concern-ledger/core.sh
source "$CL_LIB_DIR/core.sh"
# shellcheck source=./concern-ledger/parse.sh
source "$CL_LIB_DIR/parse.sh"
# shellcheck source=./concern-ledger/reduce.sh
source "$CL_LIB_DIR/reduce.sh"
# shellcheck source=./concern-ledger/render.sh
source "$CL_LIB_DIR/render.sh"
# shellcheck source=./concern-ledger/finalize.sh
source "$CL_LIB_DIR/finalize.sh"

# ---------------------------------------------------------------------------
# Derived paths — every ledger file name is built here and nowhere else
# ---------------------------------------------------------------------------
cl_ledger_path()   { printf '%s/%s-%s-concern-ledger.txt' "$1" "$2" "$3"; }
cl_snapshot_path() { printf '%s/%s-%s-concern-ledger-cap-snapshot.txt' "$1" "$2" "$3"; }
cl_json_path()     { printf '%s/%s-%s-unresolved-concerns.json' "$1" "$2" "$3"; }
cl_diag_path()     { printf '%s/%s-%s-finalize-diagnostic.txt' "$1" "$2" "$3"; }
cl_round_path()    { printf '%s/%s-%s-round-number.txt' "$1" "$2" "$3"; }
cl_delta_path()    { printf '%s/%s-%s-round-%s-delta-%s.txt' "$1" "$2" "$3" "$4" "$5"; }

# cl_snapshot_beside <ledger-path> — the snapshot for an already-resolved ledger
# path, so a CL_LEDGER_OVERRIDE is snapshotted beside itself rather than beside
# the path the session would otherwise have used.
cl_snapshot_beside() { printf '%s-cap-snapshot.txt' "${1%.txt}"; }

# ---------------------------------------------------------------------------
# Binding — the only two paths to an existing ID
# ---------------------------------------------------------------------------
# cl_bind <ledger> <delta-file>
# stdout: '<ledger-id>\t<delta-index>\tB1' then '...\tB2' then '-\t<idx>\t<REJ|NEW>',
# followed by '#note\t<idx>\t<note>' lines. Tier B1 is a reference the reviewer
# declared; tier B2 is an exact frozen-discriminator match. There is deliberately
# no third path: nothing about where a finding sits may hand it someone's ID.
cl_bind() {
    local ledger="$1" delta="$2"
    _cl_load_ledger "$ledger" 1
    _cl_load_delta "$delta"
    local n="${#CL_D_REF[@]}" i j ref id cand c probe
    local -a tier=() bound=() note=()
    local -A claimed=()
    for ((i = 0; i < n; i++)); do tier[i]=""; bound[i]="-"; note[i]="-"; done
    # Pass 1 — validate every declared reference before any of them is honoured.
    for ((i = 0; i < n; i++)); do
        ref="${CL_D_REF[i]}"
        [ "$ref" = "-" ] && continue
        if [ -z "${CL_E_TEXT[$ref]+x}" ]; then note[i]="ref-rejected"; continue; fi
        # Contested: two different findings cannot both be the same concern.
        for ((j = 0; j < n; j++)); do
            [ "$j" -eq "$i" ] && continue
            [ "${CL_D_REF[j]}" = "$ref" ] || continue
            [ "${CL_D_DISCRIM[j]}" = "${CL_D_DISCRIM[i]}" ] && continue
            note[i]="ref-rejected"
        done
        [ "${note[i]}" = "ref-rejected" ] && continue
        if [ "${CL_D_SLOT[i]}" != "${CL_E_SLOT[$ref]}" ] && [ "${CL_D_CAT[i]}" != "-" ]; then
            # The address changed. Either the reviewer re-filed it under a
            # different category (a mis-reference) or the code moved (a rename).
            probe=""
            for c in $CL_CATEGORY_VOCAB; do
                cand="$(cl_slot "${CL_D_ANCHOR[i]%%#*}" "${CL_D_ANCHOR[i]#*#}" "$c")"
                if [ "$cand" = "${CL_E_SLOT[$ref]}" ]; then probe="$c"; break; fi
            done
            if [ -n "$probe" ]; then note[i]="ref-rejected"; continue; fi
            note[i]="moved"
        fi
        # Several producers may name the same ID; the merge stage folds them.
        claimed[$ref]="$i"
        bound[i]="$ref"; tier[i]="B1"
    done
    # Pass 2 — frozen discriminator, over whatever the references left behind.
    for ((i = 0; i < n; i++)); do
        [ -n "${tier[i]}" ] && continue
        for id in "${CL_IDS[@]}"; do
            [ -n "${claimed[$id]:-}" ] && continue
            [ "${CL_E_DISCRIM[$id]}" = "${CL_D_DISCRIM[i]}" ] || continue
            claimed[$id]="$i"
            bound[i]="$id"; tier[i]="B2"
            break
        done
    done
    for ((i = 0; i < n; i++)); do
        [ "${tier[i]}" = "B1" ] && printf '%s\t%s\tB1\n' "${bound[i]}" "$i"
    done
    for ((i = 0; i < n; i++)); do
        [ "${tier[i]}" = "B2" ] && printf '%s\t%s\tB2\n' "${bound[i]}" "$i"
    done
    for ((i = 0; i < n; i++)); do
        [ -n "${tier[i]}" ] && continue
        if [ "${note[i]}" = "ref-rejected" ]; then
            printf -- '-\t%s\tREJ\n' "$i"
        else
            printf -- '-\t%s\tNEW\n' "$i"
        fi
    done
    for ((i = 0; i < n; i++)); do
        [ "${note[i]}" = "-" ] && continue
        printf '#note\t%s\t%s\n' "$i" "${note[i]}"
    done
}

# ---------------------------------------------------------------------------
# Same-round merging — the only place cardinality is allowed to decide anything
# ---------------------------------------------------------------------------
# cl_merge_producers <delta-file> <bind-file>
# stdout: '<leader-index>\t<member-index>' for every delta line, then
# '#flag\t<leader-index>\t<flag>' lines.
# Tier M2 folds identical discriminators; tier M3 folds one line per producer
# sharing a slot — that slot-bucket count is the cardinality test, and it lives
# here and nowhere else; tier M4 keeps the rest apart as dup-suspect.
cl_merge_producers() {
    local delta="$1" bindfile="$2"
    _cl_load_delta "$delta"
    local n="${#CL_D_REF[@]}" i j id idx tierv
    local -a leader=() flag=()
    local -A boundto=()
    while IFS=$'\t' read -r id idx tierv; do
        case "$id" in '#note') continue ;; esac
        [ "$id" = "-" ] && continue
        boundto[$idx]="$id"
    done < "$bindfile"
    for ((i = 0; i < n; i++)); do leader[i]="$i"; flag[i]="-"; done
    # (a) lines that bound to the same entry are the same concern by definition.
    for ((i = 0; i < n; i++)); do
        [ -z "${boundto[$i]:-}" ] && continue
        for ((j = 0; j < i; j++)); do
            [ "${boundto[$j]:-}" = "${boundto[$i]}" ] || continue
            leader[i]="${leader[j]}"
            break
        done
    done
    # (b) M2 — identical frozen discriminators among the unbound lines.
    for ((i = 0; i < n; i++)); do
        [ -n "${boundto[$i]:-}" ] && continue
        for ((j = 0; j < i; j++)); do
            [ -n "${boundto[$j]:-}" ] && continue
            [ "${leader[j]}" = "$j" ] || continue
            [ "${CL_D_DISCRIM[j]}" = "${CL_D_DISCRIM[i]}" ] || continue
            leader[i]="$j"
            break
        done
    done
    # (c) M3 — a slot bucket holding exactly one line per producer, at least two
    #     producers, and no declared reference anywhere in the bucket.
    local -a bucket=()
    local k slotv okfold dups prods
    for ((i = 0; i < n; i++)); do
        [ "${leader[i]}" = "$i" ] || continue
        [ -n "${boundto[$i]:-}" ] && continue
        slotv="${CL_D_SLOT[i]}"
        case "$slotv" in -) continue ;; esac
        bucket=()
        for ((j = 0; j < n; j++)); do
            [ "${leader[j]}" = "$j" ] || continue
            [ -n "${boundto[$j]:-}" ] && continue
            [ "${CL_D_SLOT[j]}" = "$slotv" ] || continue
            bucket+=("$j")
        done
        # Cardinality lives only here: fold this slot bucket when each producer's line count == 1.
        [ "${#bucket[@]}" -ge 2 ] || continue
        [ "${bucket[0]}" = "$i" ] || continue
        okfold=1; dups=0; prods=""
        for k in "${bucket[@]}"; do
            [ "${CL_D_REF[k]}" = "-" ] || okfold=0
            case " $prods " in *" ${CL_D_PROD[k]} "*) dups=1 ;; *) prods="$prods ${CL_D_PROD[k]}" ;; esac
        done
        [ "$dups" -eq 1 ] && okfold=0
        if [ "$okfold" -eq 1 ]; then
            for k in "${bucket[@]}"; do
                [ "$k" = "$i" ] && continue
                leader[k]="$i"
            done
            flag[i]="merged-slot:${#bucket[@]}"
        else
            for k in "${bucket[@]}"; do
                flag[k]="dup-suspect"
            done
        fi
    done
    for ((i = 0; i < n; i++)); do printf '%s\t%s\n' "${leader[i]}" "$i"; done
    for ((i = 0; i < n; i++)); do
        [ "${flag[i]}" = "-" ] && continue
        printf '#flag\t%s\t%s\n' "$i" "${flag[i]}"
    done
}

