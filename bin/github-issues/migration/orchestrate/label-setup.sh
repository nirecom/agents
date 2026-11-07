#!/usr/bin/env bash
# label-setup.sh <target_root> <github|gitlab|unknown> [--dry-run] — orchestrate.sh Step 1.
# Labels sync with the trusted sync-labels.sh of this checkout (never the target's copy); a failed
# sync exits non-zero so Step 1 is not recorded. github also gets the label-sync skeleton
# (bootstrap-labels.sh --no-sync) and .github/ISSUE_TEMPLATE; gitlab gets no .github/ files.
# Any other host (unknown) prints a notice and exits 0, live and --dry-run alike.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TARGET_CHECKOUT_ROOT="${1:?usage: label-setup.sh <target_root> <host> [--dry-run]}"
HOST="${2:?usage: label-setup.sh <target_root> <host> [--dry-run]}"
DRY_RUN=0
[[ "${3:-}" == --dry-run ]] && DRY_RUN=1

# Same as /migrate-tracker: an origin that is neither github nor gitlab gets a notice, not a failure.
if [[ "$HOST" != github && "$HOST" != gitlab ]]; then
    echo "Step 1: origin host is $HOST (neither github nor gitlab) — label sync and .github/ setup skipped"
    exit 0
fi

SYNC_LABELS="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/sync-labels.sh"
BOOTSTRAP=(bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/bootstrap-labels.sh" "$TARGET_CHECKOUT_ROOT" --no-sync)
TEMPLATES="$SCRIPT_CHECKOUT_ROOT/.github/ISSUE_TEMPLATE"
LABELS_YML=".github/labels.yml"
[[ "$HOST" == gitlab ]] && LABELS_YML="$SCRIPT_CHECKOUT_ROOT/.github/labels.yml"

if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ "$HOST" == gitlab ]] || echo "[dry-run] would run: ${BOOTSTRAP[*]}"
    echo "[dry-run] would run in $TARGET_CHECKOUT_ROOT: bash $SYNC_LABELS $LABELS_YML"
    [[ "$HOST" == gitlab ]] || echo "[dry-run] would copy $TEMPLATES → $TARGET_CHECKOUT_ROOT/.github/ISSUE_TEMPLATE"
    exit 0
fi

if [[ "$HOST" != gitlab ]]; then
    "${BOOTSTRAP[@]}" || { echo "ERROR: bootstrap-labels.sh failed — Step 1 stopped" >&2; exit 1; }
fi
if ! (cd "$TARGET_CHECKOUT_ROOT" && bash "$SYNC_LABELS" "$LABELS_YML"); then
    echo "ERROR: label sync failed ($HOST) — Step 1 stopped; re-run with --from-step 1 after fixing" >&2
    exit 1
fi
if [[ "$HOST" != gitlab && -d "$TEMPLATES" ]]; then
    mkdir -p "$TARGET_CHECKOUT_ROOT/.github/ISSUE_TEMPLATE"
    # cp -n per file (POSIX: cp -rn behaves differently across platforms).
    for f in "$TEMPLATES"/*; do
        [[ -e "$f" ]] || continue
        cp -n "$f" "$TARGET_CHECKOUT_ROOT/.github/ISSUE_TEMPLATE/" || true
    done
fi
