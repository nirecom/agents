#!/usr/bin/env bash
# bin/lib/codex-review-loop/verdict-dispatch.sh — tally->verdict mapping for
# bin/run-codex-review-loop (SSOT: skills/_shared/codex-review-loop.md). Holds
# the reviewer-pass verdict dispatch, the prestaged/fallback-pass completeness
# gate, and the prestaged verdict+finalize. Caller globals: ROUND HIGH_N MED_N
# LOW_N CAP MAX_EXT EXT_USED RISK_SIGNAL AGENTS_CONFIG_DIR FINAL_EXIT FINAL_RC
# LEDGER_FORMAT PLANS_DIR SID TMP_OUT CL_CLI.

# cl_allowed_producers_list — the closed producer set for $LEDGER_FORMAT, read
# from the ledger library itself (CPR-SSOT: the mapping lives in core.sh) in a
# subshell so none of its cl_* functions leak into the loop's namespace.
cl_allowed_producers_list() {
  local lib
  lib="$(dirname "$CL_CLI")/lib/concern-ledger.sh"
  [[ -f "$lib" ]] || return 1
  (
    # shellcheck source=/dev/null
    . "$lib" >/dev/null 2>&1 || exit 1
    cl_allowed_producers "$LEDGER_FORMAT" 2>/dev/null || true
  )
}

# dispatch_codex_verdict — the reviewer-pass mapping (planner formats and the
# security-code codex pass). Sets FINAL_EXIT; the per-round-cap finalize is the
# only place a reviewer pass writes an artifact.
dispatch_codex_verdict() {
  local VERDICT_BIN BUDGET_REMAINING VERDICT_DECISION VERDICT_RC
  VERDICT_BIN="${AGENTS_CONFIG_DIR}/bin/review-loop-verdict"
  [[ -x "$VERDICT_BIN" ]] || {
    echo "run-codex-review-loop: review-loop-verdict not found or not executable: $VERDICT_BIN" >&2
    exit 4
  }
  BUDGET_REMAINING=$(( MAX_EXT - EXT_USED ))
  local -a VERDICT_ARGS=("$ROUND" "$HIGH_N" "$MED_N" "$LOW_N" "--cap" "$CAP" "--budget-remaining" "$BUDGET_REMAINING")
  [[ -n "$RISK_SIGNAL" ]] && VERDICT_ARGS+=("--risk-signal" "$RISK_SIGNAL")
  VERDICT_DECISION=$("$VERDICT_BIN" "${VERDICT_ARGS[@]}")
  VERDICT_RC=$?
  : "${VERDICT_DECISION:=}"

  # Round 1 is the first review — no fix->re-review iteration has happened yet, so
  # an unresolved verdict must CONTINUE (exit 1) and hand the author a round to
  # fix, even for CAP=1 formats whose round 1 already sits at the cap (#2276
  # S9-c). The cap menu (escalate/auto-extend/terminal) only applies from round 2
  # on; a cap-round artifact is still written by the trailing terminal-finalize.
  case "$VERDICT_RC" in
    1|2|5|6) if (( ROUND <= 1 )); then VERDICT_RC=1; fi ;;
  esac

  case "$VERDICT_RC" in
    0)
      cleanup_ledger
      FINAL_EXIT=0
      ;;
    1)
      if declare -f codex_core_hard_cap_check > /dev/null 2>&1; then
        if ! codex_core_hard_cap_check "$ROUND" "$CAP" "$EXT_USED" "$MAX_EXT" > /dev/null 2>&1; then
          finalize_ledger escalate "hard round cap reached without convergence" 2
          FINAL_EXIT=2
        else
          FINAL_EXIT=1
        fi
      else
        FINAL_EXIT=1
      fi
      ;;
    2)
      finalize_ledger escalate "risk signal present at the budget ceiling" 2
      FINAL_EXIT=2
      ;;
    6) finalize_ledger terminal \
         "high-severity concerns remain unresolved at the budget ceiling" 6
       FINAL_EXIT=6 ;;
    4)
      echo "run-codex-review-loop: review-loop-verdict argument error (round=$ROUND high=$HIGH_N med=$MED_N low=$LOW_N)" >&2
      exit 4
      ;;
    5)
      # AUTO_EXTEND — but never past the absolute 2+1 ceiling (#2276 S9-c). A
      # review-only skill restarts as a fresh invocation and re-reports
      # EXTENSIONS_USED=0, so EXT_USED alone cannot prove how many extensions a
      # long-running review already consumed; the persisted round counter can.
      # Once ROUND reaches CAP + MAX_EXT there is no extension left to grant,
      # so collapse to the terminal verdict rather than emit another AUTO_EXTEND.
      # Round CAP+MAX_EXT is the last permitted round (the one extension round);
      # it runs and terminates here. Only rounds strictly beyond it are mistracked.
      if (( ROUND >= CAP + MAX_EXT )); then
        finalize_ledger terminal "round cap reached without convergence (auto-extend ceiling)" 6
        FINAL_EXIT=6
      else
        FINAL_EXIT=5
      fi
      ;;
    *)
      echo "run-codex-review-loop: review-loop-verdict unexpected exit: $VERDICT_RC" >&2
      exit 4
      ;;
  esac

  # The last round the caller is allowed to run has ended unresolved: there is
  # no next round to carry the ledger, so this is where it is finalized.
  if [[ "$FINAL_EXIT" == "1" ]] && (( ROUND >= CAP )); then
    finalize_ledger terminal "round cap reached without convergence" 1
  fi
}

# dispatch_prestaged_verdict — the fallback/scanner pass. Same verdict engine as
# the reviewer pass (so W4's round-2 auto-extend still returns 5), but every
# unconverged round ends with a per-round terminal artifact (converged:false)
# regardless of cap position (#2276 S8-d / X1). terminal mode never deletes the
# ledger, so the round persists for the next pass; a refused finalize exits 7.
dispatch_prestaged_verdict() {
  local VERDICT_BIN BUDGET_REMAINING VERDICT_RC
  VERDICT_BIN="${AGENTS_CONFIG_DIR}/bin/review-loop-verdict"
  [[ -x "$VERDICT_BIN" ]] || {
    echo "run-codex-review-loop: review-loop-verdict not found or not executable: $VERDICT_BIN" >&2
    exit 4
  }
  BUDGET_REMAINING=$(( MAX_EXT - EXT_USED ))
  local -a VERDICT_ARGS=("$ROUND" "$HIGH_N" "$MED_N" "$LOW_N" "--cap" "$CAP" "--budget-remaining" "$BUDGET_REMAINING")
  [[ -n "$RISK_SIGNAL" ]] && VERDICT_ARGS+=("--risk-signal" "$RISK_SIGNAL")
  "$VERDICT_BIN" "${VERDICT_ARGS[@]}" >/dev/null
  VERDICT_RC=$?

  # Round-1 continuation, symmetric with the reviewer pass (#2276 S9-c): the
  # first fallback round hands back a revision (exit 1) rather than escalating,
  # while its per-round terminal artifact is still written below.
  case "$VERDICT_RC" in
    1|2|5|6) if (( ROUND <= 1 )); then VERDICT_RC=1; fi ;;
  esac

  case "$VERDICT_RC" in
    0)
      # Converged: no open concerns remain — no artifact, drop the ledger.
      cleanup_ledger
      FINAL_EXIT=0
      return 0
      ;;
    1) FINAL_EXIT=1 ;;
    2) FINAL_EXIT=2 ;;
    6) FINAL_EXIT=6 ;;
    5)
      # See dispatch_codex_verdict: the first extension round (== CAP + MAX_EXT)
      # still extends; only a mistracked round beyond the ceiling collapses to 6.
      if (( ROUND >= CAP + MAX_EXT )); then FINAL_EXIT=6; else FINAL_EXIT=5; fi
      ;;
    4)
      echo "run-codex-review-loop: review-loop-verdict argument error (round=$ROUND high=$HIGH_N med=$MED_N low=$LOW_N)" >&2
      exit 4
      ;;
    *)
      echo "run-codex-review-loop: review-loop-verdict unexpected exit: $VERDICT_RC" >&2
      exit 4
      ;;
  esac

  finalize_ledger terminal "unresolved concerns remain at the end of the round" "$FINAL_EXIT"
}
