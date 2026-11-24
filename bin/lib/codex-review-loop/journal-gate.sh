#!/usr/bin/env bash
# bin/lib/codex-review-loop/journal-gate.sh — the #2020 round gate of the concern journal, sourced
# by boundary-journal.sh. A stage wrapper buffers the round's journal rows per call, and only an
# exit code that counts the round flushes them, so a failed or retried round is journaled once.

# bj_round_counts <rc> — whether a wrapper exit code counts its round into the journal. The
# Verdict column of Contract B (skills/_shared/codex-review-loop/exit-codes.md) is the SSOT.
bj_round_counts() {
    case "${1:-}" in
        0|1|2|5|6) return 0 ;;
        *) return 1 ;;
    esac
}

# bj_flush_buffer <ctl> <fmt> <buffer> <rc> — a counted round appends the buffer (parked on
# failure, rc 1); any other round discards it. When the rows could be neither appended nor copied
# to a pending file, the buffer itself is renamed into the pending name (a rename needs no new
# space), so the round's rows survive for the next append. When even the rename fails, the buffer
# is left in place (WARN) rather than removed; it is removed in every other case.
bj_flush_buffer() {
    local rc=0 ar=0
    if bj_round_counts "$4"; then
        bj_journal_append "$1" "$2" "$3" 1 || ar=$?
        [ "$ar" -eq 0 ] || rc=1
        if [ "$ar" -eq 2 ]; then
            if mv -n "$3" "$1/$2-journal-pending.$(date +%s)$$${RANDOM}.txt" 2>/dev/null && [ ! -e "$3" ]; then
                echo "WARN: the round's journal buffer was kept as a pending file under $1" >&2
            else
                echo "WARN: the round's journal rows are left unjournaled in $3" >&2
            fi
            return "$rc"
        fi
    fi
    rm -f "$3"
    return "$rc"
}

# bj_export_hash_out [<forwarded args>...] — stage wrappers, before the loop. Caller globals:
# CONTROL_DIR RWC_FORMAT. Sets BJ_OUT_FILE / BJ_ERR_FILE (the loop's captured streams), the
# per-call criteria-hash path and journal buffer, and BJ_PRESTAGED_REPORT / BJ_PRESTAGED_PRODUCER
# for a CC-fallback round. The buffer name carries the wrapper's pid; a stale buffer of the own
# format is swept only when its pid is no longer alive, so a concurrent round keeps its buffer.
bj_export_hash_out() {
    local f a pid prev=""
    for f in "$CONTROL_DIR/.bj-buf-$RWC_FORMAT-"*; do
        [ -f "$f" ] || continue
        pid="${f##*/.bj-buf-"$RWC_FORMAT"-}"; pid="${pid%%-*}"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then continue; fi
        rm -f "$f"
    done
    export REVIEW_CRITERIA_HASH_OUT="$CONTROL_DIR/$RWC_FORMAT-criteria-hash.$$${RANDOM}.txt"
    if ! { BJ_OUT_FILE="$(mktemp "$CONTROL_DIR/.bj-out-XXXXXX")" \
        && BJ_ERR_FILE="$(mktemp "$CONTROL_DIR/.bj-err-XXXXXX")" \
        && BJ_JOURNAL_BUFFER="$(mktemp "$CONTROL_DIR/.bj-buf-$RWC_FORMAT-$$-XXXXXX")"; }; then
        echo "boundary-journal: cannot create the per-call files under $CONTROL_DIR (HALT, exit 4)" >&2
        exit 4
    fi
    export BJ_JOURNAL_BUFFER BJ_LOOP_FORMAT="$RWC_FORMAT"
    unset BJ_PRESTAGED_REPORT BJ_PRESTAGED_PRODUCER
    for a in "$@"; do
        case "$prev" in
            --prestaged-report) export BJ_PRESTAGED_REPORT="$a" ;;
            --prestaged-producer) export BJ_PRESTAGED_PRODUCER="$a" ;;
        esac
        prev="$a"
    done
    # A fallback agent fetched its own block: record the block now, then keep its version only
    # when the agent's BOUNDARY_VERSION echo matches.
    if [ -n "${BJ_PRESTAGED_REPORT:-}" ]; then
        bash "$_BJ_ROOT/bin/review-criteria-block" "$(git rev-parse --show-toplevel 2>/dev/null)" \
            > /dev/null 2>&1 || true
        bj_reconcile_version "$REVIEW_CRITERIA_HASH_OUT" "$BJ_PRESTAGED_REPORT"
    fi
}

# bj_reconcile_version <side-record> <report> — keeps line 2 of the side record only when the
# report's last non-blank line is 'BOUNDARY_VERSION: <v>' and <v> equals it; any mismatch, an echo
# elsewhere in the report, absence or 'unknown' writes 'unknown'. Lines 1 (the criteria hash) and
# 3 (the NFR delivery) are kept; rerunning gives the same file.
bj_reconcile_version() {
    local rec echo_v="" h n
    rec="$(bj_boundary_version_from "$1")"
    h="$(bj_criteria_hash_from "$1")"
    n="$(bj_nfr_from "$1")"
    if [ -f "$2" ]; then
        echo_v="$(tr -d '\r' < "$2" | grep -v '^[[:space:]]*$' | tail -n 1)" || echo_v=""
        if [[ "$echo_v" =~ ^BOUNDARY_VERSION:\ (v[0-9]+|unknown)$ ]]; then echo_v="${BASH_REMATCH[1]}"; else echo_v=""; fi
    fi
    if [ "$echo_v" != "$rec" ]; then rec=unknown; fi
    printf '%s\n%s\n%s\n' "$h" "$rec" "$n" > "$1" 2>/dev/null || true
}

_bj_wrapper_round() {
    local r
    r="$(grep -o '"counter_round":[0-9][0-9]*' "$CONTROL_DIR/$RWC_FORMAT-review-rounds.jsonl" 2>/dev/null | tail -n 1)" || r=""
    r="${r##*:}"
    if [ -z "$r" ]; then r="$(head -n 1 "$CONTROL_DIR/$RWC_FORMAT-round-number.txt" 2>/dev/null | tr -dc '0-9')" || r=""; fi
    printf '%s' "${r:-1}"
}

# bj_post_wrapper <rc> — stage wrappers, after the loop: re-emits the captured streams, adds the
# Threat boundary hint to an all-marker NEEDS_REVISION halt, buffers the stdout marker lines (P2b),
# flushes the buffer through the round gate and removes the per-call files. Never changes the
# caller's exit code.
bj_post_wrapper() {
    local rc="${1:?bj_post_wrapper: the loop exit code is required}" reviewer=codex producer=run-codex-review-loop
    local cl="$_BJ_ROOT/bin/concern-ledger"
    cat "$BJ_OUT_FILE" 2>/dev/null || true
    cat "$BJ_ERR_FILE" >&2 2>/dev/null || true
    if grep -qF 'NEEDS_REVISION with no parseable concerns' "$BJ_ERR_FILE" 2>/dev/null; then
        echo "[$RWC_FORMAT] hint: when every finding is a [NOT-CONCERN] marker line, the Threat boundary rule (skills/_shared/review-criteria.md) makes the verdict APPROVED, not NEEDS_REVISION." >&2
    fi
    if [ -n "${BJ_PRESTAGED_PRODUCER:-}" ]; then reviewer=cc-fallback; producer="$BJ_PRESTAGED_PRODUCER"; fi
    if grep -qF '[NOT-CONCERN]' "$BJ_OUT_FILE" 2>/dev/null; then
        bash "$cl" journal --session "$SESSION_ID" --format "$RWC_FORMAT" --round "$(_bj_wrapper_round)" \
            --producer "$producer" --reviewer "$reviewer" --rows marker --from-report "$BJ_OUT_FILE" \
            --criteria-hash "$(bj_criteria_hash_from "${REVIEW_CRITERIA_HASH_OUT:-}")" \
            --boundary-version "$(bj_boundary_version_from "${REVIEW_CRITERIA_HASH_OUT:-}")" --buffer "$BJ_JOURNAL_BUFFER" \
            > /dev/null || echo "[$RWC_FORMAT] WARN: the marker lines could not be buffered for the journal" >&2
    fi
    bash "$cl" journal-flush --session "$SESSION_ID" --format "$RWC_FORMAT" --buffer "$BJ_JOURNAL_BUFFER" \
        --rc "$rc" > /dev/null || echo "[$RWC_FORMAT] WARN: the concern journal could not be flushed" >&2
    rm -f "$BJ_OUT_FILE" "$BJ_ERR_FILE" "$BJ_JOURNAL_BUFFER" "${REVIEW_CRITERIA_HASH_OUT:-}"
    return 0
}
