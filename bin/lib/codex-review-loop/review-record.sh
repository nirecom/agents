#!/usr/bin/env bash
# bin/lib/codex-review-loop/review-record.sh — the loop's side of the step-wide review record
# (#2938 D1 / D2 / D2a). Every file of the record is owned by bin/review-rounds; this lib only
# calls it. Sourced by bin/run-codex-review-loop. Caller-scope globals: SID FORMAT
# ROUND PRESTAGED_MODE PRESTAGED_POLICY FINAL_RC; optional INPUT_FP (reviewed-input
# fingerprint). Sets RR_RUN_ID. Depends on srn_commits (round-counter.sh) and vs_name.

_REVIEW_RECORD_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

RR_RUN_ID=""

_rr_cli() { node "$_REVIEW_RECORD_SCRIPT_CHECKOUT_ROOT/bin/review-rounds" "$@"; }

_rr_fp_args() {
  RR_FP_ARGS=()
  [[ -n "${INPUT_FP:-}" ]] && RR_FP_ARGS=(--fingerprint "$INPUT_FP")
  return 0
}

# rr_preflight — D2a: the record must take a row, parked rows are replayed, a leftover
# inflight or an unconsumed fallback pending halts (exit 4); then this run's inflight is opened.
rr_preflight() {
  local out
  if ! out="$(_rr_cli preflight --session "$SID" --format "$FORMAT")"; then
    echo "run-codex-review-loop: review record preflight failed for ${SID}/${FORMAT}; no review round was started" >&2
    exit 4
  fi
  RR_RUN_ID="$out"
}

# rr_close_inflight — EXIT-trap cleanup of an inflight no append consumed (a non-committing exit).
rr_close_inflight() {
  [[ -n "$RR_RUN_ID" ]] || return 0
  _rr_cli inflight-close --session "$SID" --format "$FORMAT" --run-id "$RR_RUN_ID" 2>/dev/null || true
  RR_RUN_ID=""
}

# rr_record_round <rc> — append this run's row when <rc> commits the round (D2). Non-zero when
# the row did not reach the record (it is parked, or the inflight is kept for accept-gap).
rr_record_round() {
  local rc="$1" source="codex" run_id="$RR_RUN_ID"
  srn_commits "$rc" || return 0
  [[ "${PRESTAGED_MODE:-0}" == "1" ]] && source="cc-fallback"
  _rr_fp_args
  # The store consumes the inflight on every outcome but a total write failure, which it keeps.
  RR_RUN_ID=""
  if ! _rr_cli append --session "$SID" --format "$FORMAT" --counter-round "$ROUND" \
        --exit "$rc" --verdict "$(vs_name "$rc")" --source "$source" --run-id "$run_id" \
        "${RR_FP_ARGS[@]}"; then
    echo "run-codex-review-loop: counter round ${ROUND} is committed but is not in the review record; re-run once the record is writable (the row is replayed), or run bin/review-rounds accept-gap" >&2
    return 1
  fi
}

# rr_exit_codex_unavailable — exit 3, after staging the fallback pending the caller's CC
# fallback consumes (D2). A format whose fallback re-enters the loop (prestaged allow) stages none.
rr_exit_codex_unavailable() {
  if [[ "${PRESTAGED_POLICY:-deny}" != "allow" ]]; then
    _rr_fp_args
    if ! _rr_cli stage-fallback --session "$SID" --format "$FORMAT" --counter-round "$ROUND" \
          "${RR_FP_ARGS[@]}" >/dev/null; then
      echo "run-codex-review-loop: the CC fallback could not be staged in the review record; halting instead of falling back" >&2
      exit 4
    fi
  fi
  exit 3
}

# rr_derive_extensions_used <round> — EXTENSIONS_USED as the record counts it (D3); non-zero
# when the record cannot derive it.
rr_derive_extensions_used() {
  local out
  out="$(_rr_cli derive-ext --session "$SID" --format "$FORMAT" --counter-round "$1" 2>/dev/null)" || return 1
  printf '%s' "${out#extensions_used=}"
}

# rr_apply_extensions_used <round> — D3: the record, not the caller, owns EXT_USED. Round 1 is 0;
# an underivable count spends the whole budget so the cap can never be overrun.
rr_apply_extensions_used() {
  local derived
  if (( $1 == 1 )); then
    derived=0
  elif ! derived="$(rr_derive_extensions_used "$1")" || [[ ! "$derived" =~ ^[0-9]+$ ]]; then
    echo "run-codex-review-loop: the review record cannot derive EXTENSIONS_USED for this cycle; treating the extension budget as spent" >&2
    EXT_USED="$MAX_EXT"
    return 0
  fi
  if [[ "$EXT_USED" != "$derived" ]]; then
    echo "run-codex-review-loop: EXTENSIONS_USED from the caller (${EXT_USED}) differs from the review record (${derived}); using ${derived}" >&2
  fi
  EXT_USED="$derived"
}

# rr_older_input — D8: the open concerns last raised against an earlier reviewed input, one
# "<id> <round>" per line. Display only; empty without a fingerprint or a ledger.
rr_older_input() {
  [[ -n "${INPUT_FP:-}" && -f "${LEDGER:-}" ]] || return 0
  _rr_cli older-input --session "$SID" --format "$FORMAT" --ledger "$LEDGER" \
    --fingerprint "$INPUT_FP" 2>/dev/null || true
}
