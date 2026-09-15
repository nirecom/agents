#!/usr/bin/env bash
# bin/lib/codex-review-loop/format-params.sh — per-format parameter table for
# bin/run-codex-review-loop (SSOT: skills/_shared/codex-review-loop.md). Sourced by
# the loop; one row per --format. Columns: reviewer (bin/review-plan-codex or
# bin/review-code-codex; the loop prepends "$AGENTS_CONFIG_DIR/bin/"), parse_mode
# (numbered-cnref|anchored), input_kind (path=--draft-file | ref=git diff),
# ledger_format (concern-ledger --format token + ledger file names), prestaged
# (allow|deny for --prestaged-report). fp_resolve sets the FP_* globals below and
# returns 1 if unknown. CAP/MAX_EXTENSIONS are per-invocation flags (S9-c).
fp_resolve() {
  local fmt="$1"
  case "$fmt" in
    detail-plan|outline-plan|security-plan|test-review)
      FP_REVIEWER="review-plan-codex"
      FP_PARSE_MODE="numbered-cnref"
      FP_INPUT_KIND="path"
      FP_LEDGER_FORMAT="$fmt"
      FP_PRESTAGED="deny"
      ;;
    security-code)
      FP_REVIEWER="review-code-codex"
      FP_PARSE_MODE="anchored"
      FP_INPUT_KIND="ref"
      FP_LEDGER_FORMAT="review-security-shared"
      FP_PRESTAGED="allow"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}
