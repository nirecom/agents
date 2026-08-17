#!/usr/bin/env bash
#
# bin/lib/concern-ledger/finalize.sh
#
# Sourced by bin/lib/concern-ledger.sh. The non-convergence artifact (#1996):
# the JSON spec builder, the awk renderer that writes it atomically, the
# read-only verdict over a written artifact, and the finalize driver.

# The artifact's own file name is built by cl_json_path in the entrypoint —
# this module never spells a ledger path literal itself.
#
# Must be `source`d, not executed directly.

# _cl_json_spec <plans> <sid> <format> <mode> <reason> <round> <cap> <maxext> <used> <out>
_cl_json_spec() {
    local plans="$1" sid="$2" fmt="$3" mode="$4" reason="$5" round="$6"
    local cap="$7" maxext="$8" used="$9" out="${10}"
    local led hdr f line id
    led="${CL_LEDGER_OVERRIDE:-$(cl_ledger_path "$plans" "$sid" "$fmt")}"
    _cl_load_ledger "$led" "$round"
    {
        printf 'S|reason|%s\n' "$reason"
        printf 'N|round|%s\n' "$round"
        printf 'N|cap|%s\n' "$cap"
        printf 'N|max_extensions|%s\n' "$maxext"
        printf 'N|extensions_used|%s\n' "$used"
        printf 'S|mode|%s\n' "$mode"
        for f in "$plans/$sid-$fmt-round-$round-delta-"*.txt; do
            [ -f "$f" ] || continue
            hdr="$(grep -m1 '^#producer|' "$f" 2>/dev/null || true)"
            [ -n "$hdr" ] || continue
            printf 'P|%s|%s|%s|%s\n' \
                "$(printf '%s' "$hdr" | cut -d'|' -f2)" \
                "$(printf '%s' "$hdr" | cut -d'|' -f3)" \
                "$(printf '%s' "$hdr" | cut -d'|' -f4)" \
                "$(printf '%s' "$hdr" | cut -d'|' -f5)"
        done
        for id in "${CL_IDS[@]:-}"; do
            [ -n "$id" ] || continue
            case "${CL_E_STATE[$id]}" in open|reopened) ;; *) continue ;; esac
            printf 'C|%s|%s|%s|%s|%s|%s|%s\n' "$id" "${CL_E_SEV[$id]}" "${CL_E_STATE[$id]}" \
                "${CL_E_FIRST[$id]}" "${CL_E_LAST[$id]}" "${CL_E_FLAGS[$id]:--}" "${CL_E_TEXT[$id]}"
        done
        if [ -f "$led" ]; then
            while IFS= read -r line; do
                case "$line" in
                    '#unparsed|'*) printf 'U|%s\n' "${line#\#unparsed|}" ;;
                    '#merged-alt|'*) printf 'M|%s\n' "${line#\#merged-alt|}" ;;
                esac
            done < "$led"
        fi
        printf 'T|%s\n' "$(cl_tally "$led")"
    } > "$out"
}

# cl_write_json <spec> <dest> — atomic, jq-free, fail-CLOSED.
# The terminator is verified on the temporary file before the rename, so a
# truncated write can never replace a good artifact.
cl_write_json() {
    local spec="$1" dest="$2" tmp="$2.tmp.$$"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    if ! LC_ALL=C awk -f /dev/stdin "$spec" > "$tmp" 2>/dev/null <<'AWKEOF'
function esc(s,   i, c, o, n, d) {
    o = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") o = o "\\\\"
        else if (c == "\"") o = o "\\\""
        else if (c == "\t") o = o "\\t"
        else if (c == "\n") o = o "\\n"
        else if (c == "\r") o = o "\\r"
        else { d = index(CTL, c); if (d > 0) o = o sprintf("\\u%04x", d); else o = o c }
    }
    return o
}
BEGIN {
    FS = "|"
    CTL = ""
    for (i = 1; i < 32; i++) CTL = CTL sprintf("%c", i)
    np = 0; nc = 0; nu = 0; nm = 0
    tally = "open_high=0 open_medium=0 open_low=0 reopened=0 resolved=0"
}
$1 == "S" { key[$2] = $3; skey[$2] = 1; next }
$1 == "N" { key[$2] = $3; nkey[$2] = 1; next }
$1 == "P" { np++; pn[np] = $2; pc[np] = $3; pe[np] = $4; pp[np] = $5; next }
$1 == "C" {
    nc++; ci[nc] = $2; cs[nc] = $3; ct[nc] = $4; cf[nc] = $5; cl[nc] = $6; cg[nc] = $7
    b = $0; sub(/^([^|]*\|){7}/, "", b); cb[nc] = b
    next
}
$1 == "U" { nu++; b = $0; sub(/^[^|]*\|/, "", b); ub[nu] = b; next }
$1 == "M" {
    nm++; b = $0; sub(/^[^|]*\|/, "", b)
    p = index(b, "|"); mi[nm] = substr(b, 1, p - 1); mb[nm] = substr(b, p + 1)
    next
}
$1 == "T" { b = $0; sub(/^[^|]*\|/, "", b); tally = b; next }
END {
    n = split(tally, tk, " ")
    for (i = 1; i <= n; i++) { p = index(tk[i], "="); tc[substr(tk[i], 1, p - 1)] = substr(tk[i], p + 1) }
    printf "{\n"
    printf "  \"schema\": \"unresolved-concerns/v1\",\n"
    printf "  \"converged\": false,\n"
    printf "  \"termination\": {\n"
    printf "    \"reason\": \"%s\",\n", esc(key["reason"])
    printf "    \"mode\": \"%s\",\n", esc(key["mode"])
    printf "    \"round\": %d,\n", key["round"] + 0
    printf "    \"cap\": %d,\n", key["cap"] + 0
    printf "    \"max_extensions\": %d,\n", key["max_extensions"] + 0
    printf "    \"extensions_used\": %d\n", key["extensions_used"] + 0
    printf "  },\n"
    printf "  \"producers\": ["
    for (i = 1; i <= np; i++) {
        printf "%s\n    { \"name\": \"%s\", \"completeness\": \"%s\", \"exec_label\": \"%s\", \"parse_label\": \"%s\" }", \
            (i > 1 ? "," : ""), esc(pn[i]), esc(pc[i]), esc(pe[i]), esc(pp[i])
    }
    printf "%s],\n", (np > 0 ? "\n  " : "")
    printf "  \"counts\": { \"open_high\": %d, \"open_medium\": %d, \"open_low\": %d, \"reopened\": %d, \"resolved\": %d, \"unparsed\": %d },\n", \
        tc["open_high"] + 0, tc["open_medium"] + 0, tc["open_low"] + 0, tc["reopened"] + 0, tc["resolved"] + 0, nu
    printf "  \"concerns\": ["
    for (i = 1; i <= nc; i++) {
        printf "%s\n    { \"id\": \"%s\", \"severity\": \"%s\", \"state\": \"%s\", \"first_round\": %d, \"last_round\": %d, \"flags\": \"%s\", \"text\": \"%s\" }", \
            (i > 1 ? "," : ""), esc(ci[i]), esc(cs[i]), esc(ct[i]), cf[i] + 0, cl[i] + 0, esc(cg[i]), esc(cb[i])
    }
    printf "%s],\n", (nc > 0 ? "\n  " : "")
    printf "  \"unparsed\": ["
    for (i = 1; i <= nu; i++) printf "%s\n    \"%s\"", (i > 1 ? "," : ""), esc(ub[i])
    printf "%s],\n", (nu > 0 ? "\n  " : "")
    printf "  \"merged_alternates\": ["
    for (i = 1; i <= nm; i++) printf "%s\n    { \"id\": \"%s\", \"text\": \"%s\" }", (i > 1 ? "," : ""), esc(mi[i]), esc(mb[i])
    printf "%s],\n", (nm > 0 ? "\n  " : "")
    printf "  \"eof\": \"unresolved-concerns/v1-end\"\n"
    printf "}\n"
}
AWKEOF
    then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! cl_artifact_ok "$tmp" ""; then
        CL_RECOVERY=""
        if [ -s "$tmp" ]; then :; fi
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    CL_SERIALIZED="$tmp"
    # A destination that is not a plain file must never be "replaced": mv would
    # move the artifact *into* a directory sitting on the path and report success.
    if { [ -e "$dest" ] && [ ! -f "$dest" ]; } || ! mv "$tmp" "$dest" 2>/dev/null; then
        # The destination cannot be replaced. Keep the good bytes on a side path
        # so the round's findings are never lost to a filesystem problem.
        local rec="${TMPDIR:-/tmp}/$(basename "$dest").recovered.$$"
        mkdir -p "${TMPDIR:-/tmp}" 2>/dev/null || true
        cp "$tmp" "$rec" 2>/dev/null || true
        rm -f "$tmp" 2>/dev/null || true
        CL_RECOVERY="$rec"
        return 1
    fi
    CL_RECOVERY=""
    return 0
}

# cl_artifact_ok <file> [<round>] — read-only verdict over the artifact.
cl_artifact_ok() {
    local f="$1" round="${2:-}"
    [ -f "$f" ] || return 1
    [ -s "$f" ] || return 1
    grep -Fq '"schema": "unresolved-concerns/v1"' "$f" 2>/dev/null || return 1
    local last2
    last2="$(tail -n 2 "$f" 2>/dev/null | tr '\n' '/')"
    [ "$last2" = '  "eof": "unresolved-concerns/v1-end"/}/' ] || return 1
    if [ -n "$round" ]; then
        grep -Fq "\"round\": $round," "$f" 2>/dev/null || return 1
    fi
    return 0
}

# cl_finalize <plans> <sid> <format> <mode> <reason> <round> <cap> <maxext> <used>
# Returns 0 on success, 1 when the artifact could not be produced.
cl_finalize() {
    local plans="$1" sid="$2" fmt="$3" mode="$4" reason="$5" round="$6"
    local cap="$7" maxext="$8" used="$9"
    local led snap json spec tmpd
    led="${CL_LEDGER_OVERRIDE:-$(cl_ledger_path "$plans" "$sid" "$fmt")}"
    snap="$(cl_snapshot_beside "$led")"
    json="$(cl_json_path "$plans" "$sid" "$fmt")"
    CL_RECOVERY=""; CL_FINALIZE_ERROR=""
    tmpd="$(mktemp -d)" || { CL_FINALIZE_ERROR="no temporary directory"; return 1; }
    spec="$tmpd/spec.txt"
    if ! _cl_json_spec "$plans" "$sid" "$fmt" "$mode" "$reason" "$round" \
            "$cap" "$maxext" "$used" "$spec"; then
        CL_FINALIZE_ERROR="could not read the concern ledger"
        rm -rf "$tmpd"
        return 1
    fi
    if ! cl_write_json "$spec" "$json"; then
        CL_FINALIZE_ERROR="could not write $json"
        {
            printf 'finalize failed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"
            printf 'destination: %s\n' "$json"
            printf 'recovered:   %s\n' "${CL_RECOVERY:-none}"
        } > "$(cl_diag_path "$plans" "$sid" "$fmt")" 2>/dev/null || true
        rm -rf "$tmpd"
        return 1
    fi
    rm -rf "$tmpd"
    if [ "$mode" = "escalate" ]; then
        cp "$led" "$snap" 2>/dev/null || true
        rm -f "$led" 2>/dev/null || true
    fi
    return 0
}
