#!/usr/bin/env bash
#
# bin/sweep-issues/close-batch.sh — SI-6. THE SINGLE WRITE PATH of /sweep-issues.
# Both the tier-1 (unattended) and tier-2 (human-gated) routes funnel through
# here, so --dry-run has exactly one place to take effect.
#
# ─── JUDGEMENT AXIS TABLE (repository SSOT — CPR-2) ──────────────────────────
# skills/sweep-issues/SKILL.md and bin/sweep-issues.sh REFERENCE this table and
# must not restate it.
#
# | Axis                | Tier | Detection                                        | Close label      | action        |
# |---------------------|------|--------------------------------------------------|------------------|---------------|
# | meta parent done    | 1    | parent-all-closed-check.sh exit 0 (machine)      | completed        | completed     |
# | already resolved    | 2    | SI-2 stale paths + SI-4 evidence + human gate    | completed        | completed     |
# | refactored away     | 2    | SI-2 stale paths + SI-4 evidence + human gate    | status:cancelled | cancelled     |
# | duplicate / merged  | 2    | human gate names the surviving issue             | status:migrated  | migrated      |
# | obsolete premise    | 2    | human gate                                       | status:cancelled | cancelled     |
# | partially resolved  | 2    | human gate                                       | (stays open)     | scope-reduce  |
# ─────────────────────────────────────────────────────────────────────────────
#
# Usage: close-batch.sh --decisions FILE --repo OWNER/REPO [--dry-run] [--apply]
#
# Decisions TSV (headerless, 4 columns — NOT the 3-column survivors schema):
#   number / action / arg / rationale
#   action ∈ completed | migrated | cancelled | scope-reduce
#   arg    — target issue number for `migrated`; `-` otherwise.
#
# `completed` runs the admin_close_path step sequence G→H→J→K. The authority for
# that sequence is bin/github-issues/issue-close-finalize-triage.sh:82, which
# emits NEXT_STEPS="G,H,J,K" for ACTION=admin_close_path; the letters are mapped
# to helpers by what each helper does, never by matching letter names against
# skills/issue-close-finalize/SKILL.md (the two letterings are not aligned).
# Deliberately skipped: find-pr-by-marker (admin closes have no PR) and the
# docs/history.md append (historyEntry=skipped_admin_close; backfill belongs to
# /issue-reconcile).
#
# post-close-sentinels.sh is called with the issue number ONLY. Passing a second
# (commit-hash) argument would post a resolved-by sentinel, which an
# admin_close_path close must not have.
#
# --repo is applied by exporting GH_REPO once, up front: of the downstream
# helpers only close-completed.sh accepts --repo, while close-not-planned.sh
# exits 1 on unknown flags. Never pass --repo to a helper from here.
#
# A helper failing mid-row does not stop the batch. Because close-not-planned.sh
# labels before it closes, a failure there can leave the issue labelled but open
# — such rows are reported as `PARTIAL:` with the last step that succeeded.
#
# TWO INPUT INVARIANTS, both because the TSV is machine-generated from issue text
# that this repository does not author:
#   1. Every issue number (column 1) and every `migrated` target (column 3) must
#      be a bare non-negative integer. Anything else — notably a value starting
#      with `-` — would be eaten as a flag by `gh` or by a close helper. Such a
#      row is SKIPped; the batch continues.
#   2. Every rationale posted to GitHub goes through bin/lib/gh-outbound-guard.sh
#      first. hooks/scan-outbound.js only inspects the literal Bash-tool command
#      string, so a `gh` call made from inside this script is invisible to it;
#      without this guard the batch would be a bulk private-info leak channel.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_DIR="$BIN_DIR/github-issues"

# shellcheck source=../lib/sweep-write-mode.sh
source "$BIN_DIR/lib/sweep-write-mode.sh"
sweep_write_mode_init
# shellcheck source=../lib/gh-outbound-guard.sh
source "$BIN_DIR/lib/gh-outbound-guard.sh"

DECISIONS=""
REPO=""

usage() {
  cat <<'EOF'
Usage: bin/sweep-issues/close-batch.sh --decisions FILE --repo OWNER/REPO [--dry-run]

  --decisions FILE      TSV: number / action / arg / rationale.
  --repo OWNER/REPO     Exported as GH_REPO for every helper (required).
EOF
  sweep_write_mode_usage_lines
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --decisions) DECISIONS="${2:?--decisions requires an argument}"; shift 2 ;;
    --repo) REPO="${2:?--repo requires an argument}"; shift 2 ;;
    --dry-run) sweep_write_mode_dry_run; shift ;;
    --apply) sweep_write_mode_apply; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

: "${DECISIONS:?--decisions FILE is required}"
: "${REPO:?--repo OWNER/REPO is required}"

if [[ ! -f "$DECISIONS" ]]; then
  printf 'ERROR: decisions file not found: %s\n' "$DECISIONS" >&2
  exit 2
fi

# Single point where the repository reaches every helper and every gh call.
export GH_REPO="$REPO"

CLOSED=0
SKIPPED=0
PARTIAL=0

# Column 1 and the `migrated` target must both be bare integers before they can
# reach `gh` or a helper as an argument.
is_issue_number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# 0 = posted (or nothing to post) | 1 = gh call failed | 2 = blocked by the scan.
post_rationale() {
  local number="$1" rationale="$2"
  [[ -z "${rationale// /}" || "$rationale" == "-" ]] && return 0
  # Last point before the content leaves the machine. Redirection, never a pipe:
  # a pipe RHS is a subshell and GH_OUTBOUND_GUARD_MESSAGE would not survive it.
  if ! gh_outbound_guard "sweep-issues rationale for #$number" <<< "$rationale"; then
    return 2
  fi
  gh issue comment "$number" --body "$rationale" </dev/null >/dev/null 2>&1
}

# Shared handling of a scan-blocked rationale: never a PARTIAL, because nothing
# was written at all.
report_scan_blocked() {
  local number="$1"
  printf 'SKIP: issue=%s rationale blocked by the outbound scan; nothing was written\n' \
    "$number" >&2
  SKIPPED=$(( SKIPPED + 1 ))
}

report_partial() {
  local number="$1" last_step="$2"
  PARTIAL=$(( PARTIAL + 1 ))
  printf 'PARTIAL: issue=%s last_successful_step=%s — verify state by hand\n' \
    "$number" "$last_step"
}

do_completed() {
  local number="$1" rationale="$2"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: close #%s as completed via admin_close_path G,H,J,K — %s\n' \
      "$number" "${rationale:--}"
    return 0
  fi

  # G — refresh the parent body before the child disappears from the open set.
  if ! "$HELPER_DIR/parent-body-update.sh" "$GH_REPO" "$number" </dev/null >/dev/null 2>&1; then
    report_partial "$number" "none (G parent-body-update failed)"
    return 1
  fi
  # H — the close itself.
  if ! "$HELPER_DIR/close-completed.sh" "$number" </dev/null >/dev/null 2>&1; then
    report_partial "$number" "G parent-body-update"
    return 1
  fi
  # J — appended sentinel only (no commit hash → no resolved-by).
  if ! "$HELPER_DIR/post-close-sentinels.sh" "$number" </dev/null >/dev/null 2>&1; then
    report_partial "$number" "H close-completed"
    return 1
  fi
  # K — WIP clear. Idempotent; a failure here is a warning, not a partial close.
  if ! "$HELPER_DIR/wip-state.sh" clear "$number" </dev/null >/dev/null 2>&1; then
    printf 'WARNING: issue=%s wip-state clear failed (issue is closed)\n' "$number" >&2
  fi

  printf 'CLOSED: issue=%s action=completed\n' "$number"
  CLOSED=$(( CLOSED + 1 ))
  return 0
}

do_not_planned() {
  local number="$1" type="$2" arg="$3" rationale="$4"

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$type" == "migrated" ]]; then
      printf 'DRY-RUN: close #%s as migrated into #%s — %s\n' \
        "$number" "${arg:--}" "${rationale:--}"
    else
      printf 'DRY-RUN: close #%s as cancelled — %s\n' "$number" "${rationale:--}"
    fi
    return 0
  fi

  # Validate the flag-bearing argument BEFORE anything is written, so a bad row
  # never leaves a rationale comment behind on an issue it then refuses to close.
  if [[ "$type" == "migrated" ]] && ! is_issue_number "$arg"; then
    printf 'SKIP: issue=%s action=migrated requires a bare issue number in column 3, got: %s\n' \
      "$number" "${arg:--}" >&2
    SKIPPED=$(( SKIPPED + 1 ))
    return 1
  fi

  local prc=0
  post_rationale "$number" "$rationale" || prc=$?
  if [[ "$prc" -eq 2 ]]; then
    report_scan_blocked "$number"
    return 1
  fi

  local rc=0
  if [[ "$type" == "migrated" ]]; then
    "$HELPER_DIR/close-not-planned.sh" --type migrated --into "$arg" "$number" </dev/null >/dev/null 2>&1 || rc=$?
  else
    "$HELPER_DIR/close-not-planned.sh" --type cancelled "$number" </dev/null >/dev/null 2>&1 || rc=$?
  fi

  if [[ "$rc" -ne 0 ]]; then
    report_partial "$number" "rationale comment (close-not-planned exited $rc)"
    return 1
  fi

  printf 'CLOSED: issue=%s action=%s\n' "$number" "$type"
  CLOSED=$(( CLOSED + 1 ))
  return 0
}

do_scope_reduce() {
  local number="$1" rationale="$2"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: comment on #%s and leave it open (scope-reduce) — %s\n' \
      "$number" "${rationale:--}"
    return 0
  fi

  local prc=0
  post_rationale "$number" "$rationale" || prc=$?
  if [[ "$prc" -eq 2 ]]; then
    report_scan_blocked "$number"
    return 1
  fi
  if [[ "$prc" -ne 0 ]]; then
    report_partial "$number" "none (scope-reduce comment failed)"
    return 1
  fi
  printf 'SCOPE-REDUCED: issue=%s (left open)\n' "$number"
  return 0
}

while IFS=$'\t' read -r number action arg rationale || [[ -n "${number:-}" ]]; do
  number="${number:-}"
  [[ -z "${number// /}" ]] && continue
  [[ "$number" == \#* ]] && continue
  action="${action:-}"
  arg="${arg:-}"
  rationale="${rationale:-}"

  # Skip the row, never abort the batch: one malformed line must not strand the
  # remaining decisions.
  if ! is_issue_number "$number"; then
    printf 'SKIP: issue=%s not a bare issue number; row ignored\n' "$number" >&2
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi

  case "$action" in
    completed)    do_completed "$number" "$rationale" || true ;;
    migrated)     do_not_planned "$number" migrated "$arg" "$rationale" || true ;;
    cancelled)    do_not_planned "$number" cancelled "$arg" "$rationale" || true ;;
    scope-reduce) do_scope_reduce "$number" "$rationale" || true ;;
    *)
      printf 'SKIP: issue=%s unknown action: %s\n' "$number" "${action:--}" >&2
      SKIPPED=$(( SKIPPED + 1 ))
      ;;
  esac
done < "$DECISIONS"

printf 'SUMMARY: closed=%s skipped=%s partial=%s\n' "$CLOSED" "$SKIPPED" "$PARTIAL"
sweep_write_mode_footer
exit 0
