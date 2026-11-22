#!/usr/bin/env bash
# bin/lib/codex-review-loop/path-ledger-pass.sh — the concern-ledger fold shared by the
# codex reviewer pass and the path-kind CC-fallback pass (#2478, CPR-SSOT). Sourced by
# bin/run-codex-review-loop; reads/writes its caller-scope round and ledger globals.

# path_ledger_pass <producer> — parse the round's concerns from $TMP_OUT, stage them under
# <producer>, reduce, and dispatch the verdict into FINAL_EXIT. `exit` ends the process.
path_ledger_pass() {
  local producer="$1"
  # Checked before the reduce commits the round: a missing verdict engine halts while
  # REDUCE_COMMITTED is still false, so the counter rolls back instead of leaving a record gap.
  require_verdict_bin
  # Exclusively created beside TMP_OUT, not the predictable "${TMP_OUT}.delta" (#2025 C6).
  DELTA_SRC="$(sp_mktemp_beside "$TMP_OUT")" \
    || die "cannot stage the round's concerns beside: $TMP_OUT"

  if [[ "$INPUT_KIND" == "path" ]]; then
    if [[ "$ROUND" == "1" ]]; then
      parse_round1_numbered
    else
      parse_round2_cnref
    fi
    STAGE_EXEC_ARGS=(--exec PERFORMED --parser "$PARSER")
  else
    # ref-kind: the whole raw output is the anchored delta; the exec label is
    # auto-derived from the reviewer header, so NO --exec is passed.
    rk_stage_anchored
    STAGE_EXEC_ARGS=(--parser "$PARSER")
  fi

  CL_NO_OPEN_CONCERNS="<!-- concern-ledger: no open concerns in round ${ROUND} -->"
  if [[ ! -s "$DELTA_SRC" ]]; then
    printf '%s\n' "$CL_NO_OPEN_CONCERNS" > "$DELTA_SRC" \
      || die "cannot write concern sentinel: $DELTA_SRC"
  fi

  if ! ledger_cli stage --round "$ROUND" --producer "$producer" \
        "${STAGE_EXEC_ARGS[@]}" --from-report "$DELTA_SRC" >/dev/null 2>&1; then
    # The reviewer's own review still reaches the author even though the ledger
    # write failed: the halt (exit 4) is a wrapper fault, not a lost review.
    cat "$TMP_OUT"
    echo "run-codex-review-loop: failed to write ledger to $LEDGER" >&2
    rm -f "$DELTA_SRC"
    exit 4
  fi
  REDUCE_RC=0
  TALLY="$(ledger_cli reduce --round "$ROUND" 2>/dev/null)" || REDUCE_RC=$?
  rm -f "$DELTA_SRC"
  if (( REDUCE_RC != 0 )) || [[ -z "$TALLY" ]] || [[ ! -f "$LEDGER" ]]; then
    echo "run-codex-review-loop: round ${ROUND} could not be folded into the ledger (reduce rc=${REDUCE_RC}); refusing to judge it from the previous round's tally" >&2
    exit 4
  fi

  if [[ -f "$LEDGER" ]] && ! grep -qE '^C[0-9]+\|' "$LEDGER"; then
    echo "run-codex-review-loop: ledger exists but contains no valid concern entries after reduce (round ${ROUND}); refusing to judge from a header-only ledger" >&2
    exit 4
  fi
  # Committed only after the sanity check: its exit 4 leaves the round unsettled, so
  # _srn_rollback restores ROUND_PREV instead of consuming a round the record has no row for.
  # shellcheck disable=SC2034  # read by round-counter.sh (srn_commits, _srn_rollback)
  REDUCE_COMMITTED=true

  # The tally the verdict reads is the ledger's own view of what is still open.
  local _kv
  for _kv in $TALLY; do
    case "$_kv" in
      open_high=*)   HIGH_N="${_kv#*=}" ;;
      open_medium=*) MED_N="${_kv#*=}" ;;
      open_low=*)    LOW_N="${_kv#*=}" ;;
    esac
  done
  [[ "$HIGH_N" =~ ^[0-9]+$ ]] || HIGH_N=0
  [[ "$MED_N"  =~ ^[0-9]+$ ]] || MED_N=0
  [[ "$LOW_N"  =~ ^[0-9]+$ ]] || LOW_N=0

  dispatch_codex_verdict
}
