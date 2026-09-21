#!/usr/bin/env bash
# bin/lib/codex-review-loop/ref-kind-input.sh — ref-kind (security-code) input
# adapter for bin/run-codex-review-loop (SSOT: skills/_shared/codex-review-loop.md,
# #2276 S8-b/S8-d). review-code-codex diffs the tree directly; the raw output is
# the anchored round delta; the scanner fallback re-enters via --prestaged-report.
# Caller globals: TMP_OUT DELTA_SRC ROUND CONTEXT_OUT CORE_PRINCIPLES EXTRA_CTX
# REPO_ROOT_ARG AGENTS_CONFIG_DIR PRESTAGED_REPORT VERDICT ARGS BASE_STATE_ARG.
SAFE_PATH_LIB="${AGENTS_CONFIG_DIR:-}/bin/lib/safe-plans-path.sh"
[[ -f "$SAFE_PATH_LIB" ]] || die "the safe-path library is missing: $SAFE_PATH_LIB"
source "$SAFE_PATH_LIB" || die "the safe-path library failed to load: $SAFE_PATH_LIB"

# rk_build_args — populate the global ARGS array for review-code-codex: the merge
# base (resolve-merge-base.sh kv), the rendered prior concerns for round >= 2
# (via --concerns-file), plus context and project root. NO --input, NO
# --accepted-tradeoffs, NO --draft-file: the reviewer diffs the working tree.
rk_build_args() {
  ARGS=()
  local RMB base="" state="" key val mbout ctx priortmp prior
  RMB="$AGENTS_CONFIG_DIR/bin/resolve-merge-base.sh"
  if [[ -x "$RMB" ]]; then
    mbout="$(bash "$RMB" --format kv 2>/dev/null || true)"
    while IFS='=' read -r key val; do
      case "$key" in
        base)  base="$val" ;;
        state) state="$val" ;;
      esac
    done <<RMB_EOF
$mbout
RMB_EOF
  fi
  # A caller-supplied --base-state pins the reviewer's base classification and
  # wins over the auto-resolved merge-base state (#2276 S8): the reviewer then
  # emits "## Codex Review Scope: BASE-<state>" and the exec label derives to
  # PARTIAL. The resolved $base still travels so the reviewer has a diff anchor.
  [[ -n "$BASE_STATE_ARG" ]] && state="$BASE_STATE_ARG"
  [[ -n "$base" ]]  && ARGS+=(--base "$base")
  [[ -n "$state" ]] && ARGS+=(--base-state "$state")

  # The reviewer may only speak about IDs the ledger already holds, so it is
  # handed the rendered prior — the same text cl_render_prior produces for the
  # CLI (N1: one implementation). Handed on round >= 2, and ALSO on round 1 when
  # the ledger already holds prior C-entries: a re-review of committed work
  # (#2344) opens as round 1 but must still carry the prior concerns forward.
  local have_prior_entries=0
  if [[ -f "$LEDGER" ]] && grep -qE '^C[0-9]+\|' "$LEDGER"; then have_prior_entries=1; fi
  if (( ROUND >= 2 )) || (( have_prior_entries == 1 )); then
    prior="$(ledger_cli render-prior 2>/dev/null || true)"
    if [[ -n "$prior" ]]; then
      priortmp="$(sp_mktemp_beside "$TMP_OUT")" \
        || die "cannot stage prior concerns beside: $TMP_OUT"
      printf '%s\n' "$prior" > "$priortmp"
      ARGS+=(--concerns-file "$priortmp")
    fi
  fi

  if [[ -f "$CONTEXT_OUT" && -s "$CONTEXT_OUT" ]]; then
    ARGS+=(--context "$CONTEXT_OUT")
  fi
  for ctx in "${EXTRA_CTX[@]+"${EXTRA_CTX[@]}"}"; do
    [[ -z "$ctx" ]] && continue
    [[ -f "$ctx" && -s "$ctx" ]] && ARGS+=(--context "$ctx")
  done
  ARGS+=(--context "$CORE_PRINCIPLES")
  [[ -n "$REPO_ROOT_ARG" ]] && ARGS+=(--project-root "$REPO_ROOT_ARG")
}

# rk_synthetic_verdict — ref-kind has no begin/end-codex-output block; the verdict
# is synthesised from whether the raw output anchors any severity bullet.
rk_synthetic_verdict() {
  if grep -qE '^[[:space:]]*([-*][[:space:]]+)?\[(HIGH|MEDIUM|LOW)\]' "$TMP_OUT"; then
    VERDICT="NEEDS_REVISION"
  else
    VERDICT="APPROVED"
  fi
}

# rk_stage_anchored — round 1 archives any live cycle (begin-round), then the
# whole raw reviewer output becomes the round delta and PARSER=anchored. The
# stage caller passes NO --exec: the label is auto-derived from the reviewer's
# own '## Codex Review: PERFORMED' header (concern-ledger stage).
rk_stage_anchored() {
  if [[ "$ROUND" == "1" ]]; then
    if ! ledger_cli begin-round --round 1 >/dev/null; then
      echo "run-codex-review-loop: the previous concern cycle could not be archived (round 1 on a live ledger at ${LEDGER}); refusing to reduce round 1 into it" >&2
      rm -f "$DELTA_SRC"
      exit 4
    fi
  fi
  cp "$TMP_OUT" "$DELTA_SRC" || die "cannot stage anchored delta beside: $TMP_OUT"
  PARSER="anchored"
}

# rk_load_prestaged — the scanner fallback pass: the report the caller already
# produced becomes TMP_OUT. Missing or empty is a config fault (exit 4).
rk_load_prestaged() {
  [[ -n "$PRESTAGED_REPORT" ]] || die "--prestaged-report requires a value"
  [[ -f "$PRESTAGED_REPORT" ]] || die "prestaged report does not exist: $PRESTAGED_REPORT"
  [[ -s "$PRESTAGED_REPORT" ]] || die "prestaged report is empty: $PRESTAGED_REPORT"
  cp "$PRESTAGED_REPORT" "$TMP_OUT" || die "cannot load prestaged report into: $TMP_OUT"
}
