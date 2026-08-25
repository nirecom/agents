#!/usr/bin/env bash
# bin/lib/concern-ledger/finalize.sh — must be `source`d, not executed.
# Sourced by bin/lib/concern-ledger.sh. The non-convergence artifact (#1996):
# the JSON spec builder, the awk renderer that writes it atomically, the
# read-only verdict over a written artifact, and the finalize driver.
# The artifact's own file name is built by cl_json_path in the entrypoint —
# this module never spells a ledger path literal itself.

# _cl_json_spec <plans> <sid> <format> <mode> <reason> <round> <cap> <maxext> <used> <out>
_cl_json_spec() {
    local plans="$1" sid="$2" fmt="$3" mode="$4" reason="$5" round="$6"
    local cap="$7" maxext="$8" used="$9" out="${10}"
    local led ledger_state hdr f line id block_rc pname dtext defang_rc=0
    local -A prec=()
    local -a pord=()
    led="${CL_LEDGER_OVERRIDE:-$(cl_ledger_path "$plans" "$sid" "$fmt")}"
    # cl_ledger_path returns empty when a token fails validation (S9-B); an
    # empty path would make _cl_load_ledger read nothing and report a healthy
    # empty ledger, so it joins the existing failure path instead.
    [ -n "$led" ] || return 1
    # _cl_load_ledger treats a missing file as a healthy empty ledger, so a
    # ledger that was never staged and one whose concerns are all closed reach
    # the artifact as the same zero-concern JSON. The reader cannot tell those
    # apart from the counts alone, so the distinction is recorded here.
    if [ -f "$led" ]; then ledger_state="present"; else ledger_state="absent"; fi
    _cl_load_ledger "$led" "$round"
    # The producer scan below runs in a process-substitution subshell, so the
    # channel is armed here and read after the block: an empty `producers` list
    # is a factual claim that nobody reviewed the round, and publishing that over
    # a round two producers did stage is worse than publishing nothing (#2025 C6).
    _cl_discovery_arm || return 3
    {
        printf 'S|reason|%s\n' "$reason"
        printf 'N|round|%s\n' "$round"
        printf 'N|cap|%s\n' "$cap"
        printf 'N|max_extensions|%s\n' "$maxext"
        printf 'N|extensions_used|%s\n' "$used"
        printf 'S|mode|%s\n' "$mode"
        printf 'S|ledger_state|%s\n' "$ledger_state"
        # The third member of the discovery class (#2088 / round 11 C6): this
        # loop is the only place the artifact's `producers` records come from,
        # so a glob that degrades to zero matches drops them silently while the
        # rest of the JSON still looks right.
        # Producer identity is the header's, not the file name's, so cl_reduce's
        # round filter and LC_ALL=C-last-wins rule are applied here too: this
        # record must name the file that was reduced, not every file claiming
        # the producer, or a hand-placed one enters the audit trail as a
        # declared producer's own report.
        while IFS= read -r -d '' f; do
            [ -f "$f" ] || continue
            hdr="$(grep -m1 '^#producer|' "$f" 2>/dev/null || true)"
            [ -n "$hdr" ] || continue
            [ "$(printf '%s' "$hdr" | cut -d'|' -f6)" = "$round" ] || continue
            pname="$(printf '%s' "$hdr" | cut -d'|' -f2)"
            [ -n "${prec[$pname]:-}" ] || pord+=("$pname")
            prec[$pname]="$(printf 'P|%s|%s|%s|%s' "$pname" \
                "$(printf '%s' "$hdr" | cut -d'|' -f3)" \
                "$(printf '%s' "$hdr" | cut -d'|' -f4)" \
                "$(printf '%s' "$hdr" | cut -d'|' -f5)")"
        done < <(_cl_list_pattern_files "$plans/$sid-$fmt-round-$round-delta-*.txt")
        for pname in "${pord[@]:-}"; do
            [ -n "$pname" ] || continue
            printf '%s\n' "${prec[$pname]}"
        done
        # Text here is producer-authored (reviewer-forgeable, #2025 C10): the
        # same defang applied for on-screen rendering (render.sh) is applied
        # again here so this second generation point can't ship a live
        # sentinel into the JSON artifact that skills read back verbatim.
        # `set -o pipefail` inside each substitution, the cl_render_prior
        # protection (#2025 C13): a sanitizer that dies is otherwise wrapped in a
        # successful printf, and the artifact publishes structurally valid JSON
        # whose concern text was silently emptied. All three reviewer-text record
        # types carry it — the failure class is the pipeline, not the record.
        for id in "${CL_IDS[@]:-}"; do
            [ -n "$id" ] || continue
            case "${CL_E_STATE[$id]}" in open|reopened) ;; *) continue ;; esac
            if ! dtext="$(set -o pipefail; printf '%s' "${CL_E_TEXT[$id]}" | _cl_defang_untrusted)"; then
                defang_rc=1
                continue
            fi
            printf 'C|%s|%s|%s|%s|%s|%s|%s\n' "$id" "${CL_E_SEV[$id]}" "${CL_E_STATE[$id]}" \
                "${CL_E_FIRST[$id]}" "${CL_E_LAST[$id]}" "${CL_E_FLAGS[$id]:--}" "$dtext"
        done
        if [ -f "$led" ]; then
            while IFS= read -r line; do
                case "$line" in
                    '#unparsed|'*)
                        if dtext="$(set -o pipefail; printf '%s' "${line#\#unparsed|}" | _cl_defang_untrusted)"; then
                            printf 'U|%s\n' "$dtext"
                        else
                            defang_rc=1
                        fi
                        ;;
                    '#merged-alt|'*)
                        if dtext="$(set -o pipefail; printf '%s' "${line#\#merged-alt|}" | _cl_defang_untrusted)"; then
                            printf 'M|%s\n' "$dtext"
                        else
                            defang_rc=1
                        fi
                        ;;
                esac
            done < "$led"
        fi
        printf 'T|%s\n' "$(cl_tally "$led")"
    } > "$out"
    # Read before anything else runs: an unwritable $out is still this
    # function's own failure, and the discovery verdict must not overwrite it.
    block_rc=$?
    if _cl_discovery_failed; then
        _cl_discovery_disarm
        return 3
    fi
    _cl_discovery_disarm
    if [ "$defang_rc" -ne 0 ]; then
        printf 'concern-ledger: _cl_json_spec: the reviewer-text sanitizer failed; refusing to publish an artifact whose concern text it could not defang\n' >&2
        return 1
    fi
    return "$block_rc"
}

# cl_write_json <spec> <dest> — atomic, jq-free, fail-CLOSED.
# The terminator is verified on the temporary file before the rename, so a
# truncated write can never replace a good artifact. The temp is created
# exclusively beside the destination rather than at a predictable "$dest.tmp.$$"
# (#2025 C6). Order on failure is a contract: publish, then copy the kept temp
# to the recovery path, then delete it — going back to sp_publish_file (which
# deletes on failure) would empty CL_RECOVERY (review round 6 #1).
# CL_SERIALIZED names the temp and is only valid on success.
cl_write_json() {
    local spec="$1" dest="$2" tmp
    mkdir -p "$(_sp_dirname "$dest")" 2>/dev/null || true
    tmp="$(sp_mktemp_beside "$dest")" || return 1
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
    printf "    \"ledger_state\": \"%s\",\n", esc(key["ledger_state"])
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
    local kept
    if kept="$(sp_publish_file_keep "$tmp" "$dest")"; then
        CL_RECOVERY=""
        return 0
    fi
    # Publish failed. The verified bytes are still readable at $kept (empty only
    # when even that could not be preserved), so recovery happens *before* any
    # cleanup — deleting first would destroy the round's findings, which is the
    # exact failure this function's fail-closed contract exists to prevent
    # (review round 6 #1).
    CL_RECOVERY=""
    if [ -n "$kept" ]; then
        local rec rbase
        # _sp_basename, not basename(1) (round 9 #2). With a pure-backslash
        # $dest, basename returns the *whole* path, the template becomes
        # "/tmp/C:\Users\...\x.json.recovered.XXXXXX", its parent does not exist,
        # and mktemp fails — losing the round's only verified copy at exactly the
        # moment this contract exists to preserve it. The fallback covers
        # degenerate inputs so the template can never grow a separator of its own.
        rbase="$(_sp_basename "$dest")"
        case "$rbase" in ''|*[/\\]*) rbase="concern-ledger-artifact" ;; esac
        if rec="$(mktemp "${TMPDIR:-/tmp}/$rbase.recovered.XXXXXX" 2>/dev/null)" \
            && chmod 600 "$rec" 2>/dev/null \
            && cp "$kept" "$rec" 2>/dev/null; then
            CL_RECOVERY="$rec"
        else
            rm -f "$rec" 2>/dev/null || true
        fi
        rm -f "$kept" 2>/dev/null || true
    fi
    return 1
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
    # A rejected token makes the builders return empty (S9-B). Writing to an
    # empty path would land the artifact in the caller's CWD, so both derived
    # paths join the existing fail-closed exit instead.
    if [ -z "$led" ] || [ -z "$json" ]; then
        CL_FINALIZE_ERROR="could not derive the concern ledger paths"
        return 1
    fi
    # mktemp -d is 0700 by default, so the spec file needs no extra containment.
    tmpd="$(mktemp -d)" || { CL_FINALIZE_ERROR="no temporary directory"; return 1; }
    spec="$tmpd/spec.txt"
    local spec_rc=0
    _cl_json_spec "$plans" "$sid" "$fmt" "$mode" "$reason" "$round" \
        "$cap" "$maxext" "$used" "$spec" || spec_rc=$?
    if [ "$spec_rc" -ne 0 ]; then
        # rc 3 is the discovery refusal, kept apart from a ledger it could not
        # read: what failed is the listing of the round's deltas, so the reason
        # names that rather than the ledger (#2025 C6).
        if [ "$spec_rc" -eq 3 ]; then
            CL_FINALIZE_ERROR="discovery failed for round $round; the producers list could not be built, so no artifact was published"
        else
            CL_FINALIZE_ERROR="could not read the concern ledger"
        fi
        rm -rf "$tmpd"
        return 1
    fi
    if ! cl_write_json "$spec" "$json"; then
        # CL_FINALIZE_ERROR reaches the CLI's stdout, which is a review report
        # the author keeps; an absolute path there records the OS account name
        # and the checkout layout in a durable artifact. The path is still
        # named, on stderr and in the diagnostic file below.
        CL_FINALIZE_ERROR="could not write the unresolved-concerns artifact"
        printf 'concern-ledger: could not write %s\n' "$json" >&2
        local diag
        diag="$(cl_diag_path "$plans" "$sid" "$fmt")"
        # The diagnostic path is predictable, so it is published rather than
        # redirected into: a symlink left there would otherwise be followed.
        if [ -n "$diag" ]; then
            {
                printf 'finalize failed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"
                printf 'destination: %s\n' "$json"
                printf 'recovered:   %s\n' "${CL_RECOVERY:-none}"
            } | sp_publish_stdin "$diag" 2>/dev/null || true
        fi
        rm -rf "$tmpd"
        return 1
    fi
    rm -rf "$tmpd"
    # Neither half below changes cl_finalize's rc: the artifact is already
    # written, and turning a refused snapshot into a finalize failure would have
    # the CLI exit non-zero over a file that exists. Notice is one stderr line.
    if [ "$mode" = "escalate" ]; then
      if [ ! -f "$led" ]; then
        # Nothing to snapshot and nothing to delete. Checked *before* the
        # publish call because sp_contained_publish_copy would otherwise fail on
        # its own `< "$src"` redirect, return 1, and land in the `*)` arm —
        # telling the reader the snapshot "could not be published", which points
        # at the filesystem when the truth is that there was never anything to
        # publish (review round 11).
        printf 'concern-ledger: no ledger at %s; nothing to snapshot or delete\n' "$led" >&2
      else
        # Order is the contract: containment is decided *before* anything is
        # created, and that decision and the write share one resolution of the
        # parent directory. $snap is derived from $led, so an override whose
        # directory component leaves the plans dir would otherwise have us
        # create the temp — and then the full ledger text — out there before any
        # question was asked (#2025 C6/C8, review round 7). An undecidable case
        # falls to rc 2: a missed delete is recoverable, a wrong one is not.
        sp_contained_publish_copy "$led" "$snap" "$plans"
        case $? in
            0)
                # Deleting is the irreversible half, so it is judged physically,
                # once, on the same directory the unlink happens in (round 5):
                # resolving for the verdict and resolving again for the delete
                # would let a swapped symlink separate the two. The final
                # component is not resolved — rm unlinks the symlink itself.
                if ! sp_contained_rm "$led" "$plans"; then
                    printf 'concern-ledger: the override ledger is not physically inside the plans dir (%s); snapshotted but not deleted\n' "$led" >&2
                fi
                ;;
            2)
                # Refused for containment: nothing was written anywhere, and the
                # ledger is left exactly as it was — which is the archive.
                printf 'concern-ledger: the override ledger does not physically resolve inside the plans dir (%s); it was neither snapshotted nor deleted\n' "$led" >&2
                ;;
            *)
                printf 'concern-ledger: could not publish the cap snapshot to %s; the ledger was left in place\n' "$snap" >&2
                ;;
        esac
      fi
    fi
    return 0
}

:  # load-success rc for the entrypoint's source check
