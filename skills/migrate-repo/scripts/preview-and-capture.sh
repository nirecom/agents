#!/usr/bin/env bash
# Runs orchestrate.sh --dry-run, mirrors its stdout to the user via stderr,
# and emits two export lines on stdout for the skill caller to eval.
# Captured snapshots:
#   MIGRATE_ACK_UP_TO_ISSUE_N       — highest issue number at dry-run time
#   MIGRATE_ACK_SELF_COUNT_AT_ACK   — self-issue count at dry-run time
# (#834 Option γ)
set -euo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPO_PATH="${1:?usage: preview-and-capture.sh <repo_path>}"

# Self-repo identity guard (#1234): detect REPO_PATH == SCRIPT_CHECKOUT_ROOT.
_resolved_repo="$(cd "$REPO_PATH" && pwd)"
_self_repo_detected=0
if [ "$_resolved_repo" = "$SCRIPT_CHECKOUT_ROOT" ]; then
  _self_repo_detected=1
  echo "WARNING: SELF_REPO_DETECTED: REPO_PATH equals SCRIPT_CHECKOUT_ROOT ($SCRIPT_CHECKOUT_ROOT)." >&2
  echo "         Continuing dry-run to emit sentinels." >&2
  echo "         The /migrate-repo skill (MR-2) confirms with the user via AskUserQuestion." >&2
fi

DRY_RUN_OUT=$(bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --dry-run) || _dry_rc=$?
echo "$DRY_RUN_OUT" >&2
if [ "${_dry_rc:-0}" -ne 0 ]; then
  echo "ERROR: dry-run failed (rc=${_dry_rc:-0}). See output above." >&2
  exit 1
fi

N=$(echo "$DRY_RUN_OUT" | grep '^MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=' | tail -1 | cut -d= -f2)
if [ -z "${N:-}" ]; then
  echo "ERROR: dry-run did not emit MIGRATE_DRY_RUN_HIGHEST_ISSUE_N sentinel." >&2
  echo "       orchestrate.sh version is too old or stdout was filtered." >&2
  exit 1
fi
if ! printf '%s' "$N" | grep -Eq '^(0|[1-9][0-9]*)$'; then
  echo "ERROR: HIGHEST_ISSUE_N sentinel is not a non-negative integer (got: '$N')." >&2
  exit 1
fi

M=$(echo "$DRY_RUN_OUT" | grep '^MIGRATE_DRY_RUN_SELF_COUNT=' | tail -1 | cut -d= -f2)
if [ -z "${M:-}" ]; then
  echo "ERROR: dry-run did not emit MIGRATE_DRY_RUN_SELF_COUNT sentinel." >&2
  exit 1
fi
if ! printf '%s' "$M" | grep -Eq '^(0|[1-9][0-9]*)$'; then
  echo "ERROR: SELF_COUNT sentinel is not a non-negative integer (got: '$M')." >&2
  exit 1
fi

# Self-repo path: forward the dry-run sentinels to stdout so the eval caller and
# the regression test can confirm the guard did not suppress them (#1234).
if [ "$_self_repo_detected" -eq 1 ]; then
  echo "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=${N}"
  echo "MIGRATE_DRY_RUN_SELF_COUNT=${M}"
fi

echo "export MIGRATE_ACK_UP_TO_ISSUE_N=${N}"
echo "export MIGRATE_ACK_SELF_COUNT_AT_ACK=${M}"
echo "export MIGRATE_SELF_REPO_DETECTED=${_self_repo_detected}"
