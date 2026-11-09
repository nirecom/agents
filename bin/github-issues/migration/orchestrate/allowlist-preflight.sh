#!/usr/bin/env bash
# allowlist-preflight.sh <target_root> [--dry-run] — orchestrate.sh first-run check (#2473).
# Step 6 stages the allowlist files whole, so an edit the user already has in one would be pushed
# with the generated files, and only the start of a run can tell them apart. A state file means an
# earlier run's generated files remain, so the check is skipped then.
# Live: uncommitted paths or a failed check exit 1. --dry-run: warns on stdout and exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_CHECKOUT_ROOT="${1:?usage: allowlist-preflight.sh <target_root> [--dry-run]}"
DRY_RUN=0
[[ "${2:-}" == --dry-run ]] && DRY_RUN=1

[[ -f "$TARGET_CHECKOUT_ROOT/.migration-state.json" ]] && exit 0

rc=0
paths="$(bash "$SCRIPT_DIR/../commit-migration-artifacts.sh" "$TARGET_CHECKOUT_ROOT" --skill migrate-issues --check-clean)" || rc=$?
[[ "$rc" -eq 0 ]] && exit 0

if [[ "$rc" -ne 3 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "WARNING: UNCOMMITTED_ALLOWLIST_CHECK_FAILED: the uncommitted-file check on $TARGET_CHECKOUT_ROOT exited rc=$rc; a live run would stop here."
        exit 0
    fi
    echo "ERROR: could not check $TARGET_CHECKOUT_ROOT for uncommitted migration files (rc=$rc)." >&2
    echo "       Confirm the target is a git checkout, then re-run." >&2
    exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    while IFS= read -r path; do
        echo "WARNING: UNCOMMITTED_ALLOWLIST: $path"
    done <<<"$paths"
    exit 0
fi

echo "ERROR: these files have uncommitted changes, and this migration commits and pushes them whole:" >&2
while IFS= read -r path; do
    echo "  $path" >&2
done <<<"$paths"
echo "       Commit, stash, or discard the changes, then re-run. Nothing was changed by this run." >&2
exit 1
