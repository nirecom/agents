#!/usr/bin/env bash
# Runs orchestrate.sh --dry-run, mirrors its stdout to the user via stderr,
# and emits two export lines on stdout for the skill caller to eval.
# Captured snapshots:
#   MIGRATE_ACK_UP_TO_ISSUE_N       — highest issue number at dry-run time
#   MIGRATE_ACK_SELF_COUNT_AT_ACK   — self-issue count at dry-run time
# (#834 Option γ)
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"
REPO_PATH="${1:?usage: preview-and-capture.sh <repo_path>}"

DRY_RUN_OUT=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --dry-run) || _dry_rc=$?
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

echo "export MIGRATE_ACK_UP_TO_ISSUE_N=${N}"
echo "export MIGRATE_ACK_SELF_COUNT_AT_ACK=${M}"
