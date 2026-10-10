#!/usr/bin/env bash
# bootstrap-labels.sh — bootstrap label auto-management for a target repo.
#
# Copies the label-sync skeleton from this checkout into <repo-dir>:
#   1. .github/labels.yml
#   2. bin/github-issues/sync-labels.sh
#   3. .github/workflows/sync-labels.yml
# Then runs the initial sync-labels.sh inside <repo-dir> unless --no-sync is given.
#
# Usage:
#   bootstrap-labels.sh <repo-dir> [--no-sync]
#   bootstrap-labels.sh --help
#
# Options:
#   --no-sync     Skip initial sync-labels.sh invocation
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: bootstrap-labels.sh <repo-dir> [--no-sync]

Bootstrap label auto-management for a target repo:
  1. Copy .github/labels.yml from this checkout
  2. Copy bin/github-issues/sync-labels.sh
  3. Copy .github/workflows/sync-labels.yml
  4. Run initial sync-labels.sh inside <repo-dir> (skip with --no-sync)

Options:
  --no-sync     Skip initial sync-labels.sh invocation
  --help        Show this help and exit
EOF
}

TARGET_CHECKOUT_ROOT=""
NO_SYNC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --no-sync)
      NO_SYNC=1
      shift
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$TARGET_CHECKOUT_ROOT" ]]; then
        TARGET_CHECKOUT_ROOT="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$TARGET_CHECKOUT_ROOT" ]]; then
  echo "Error: <repo-dir> is required" >&2
  usage >&2
  exit 1
fi

if [[ ! -d "$TARGET_CHECKOUT_ROOT" ]]; then
  echo "Error: directory not found: $TARGET_CHECKOUT_ROOT" >&2
  exit 1
fi

# Source → destination triples (relative paths inside each tree).
SRC_PATHS=(
  ".github/labels.yml"
  "bin/github-issues/sync-labels.sh"
  ".github/workflows/sync-labels.yml"
)

copied=0
total=${#SRC_PATHS[@]}
for rel in "${SRC_PATHS[@]}"; do
  src="$SCRIPT_CHECKOUT_ROOT/$rel"
  dst="$TARGET_CHECKOUT_ROOT/$rel"
  if [[ ! -f "$src" ]]; then
    echo "Warning: source missing, skipping: $src" >&2
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" ]]; then
    # cp -n: do not overwrite existing destination.
    continue
  fi
  cp "$src" "$dst"
  copied=$((copied + 1))
done

# Preserve executable bit for sync-labels.sh when freshly copied.
if [[ -f "$TARGET_CHECKOUT_ROOT/bin/github-issues/sync-labels.sh" ]]; then
  chmod +x "$TARGET_CHECKOUT_ROOT/bin/github-issues/sync-labels.sh" 2>/dev/null || true
fi

echo "bootstrap-labels: copied $copied/$total files to $TARGET_CHECKOUT_ROOT"

if [[ "$NO_SYNC" -eq 0 ]]; then
  # Run the trusted sync-labels.sh from this checkout (not the copy in TARGET_CHECKOUT_ROOT)
  # so pre-existing or divergent target copies cannot execute arbitrary code under
  # the operator's credentials. CWD is TARGET_CHECKOUT_ROOT so sync-labels.sh resolves
  # .github/labels.yml relative to the target repo.
  (cd "$TARGET_CHECKOUT_ROOT" && bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/sync-labels.sh") || \
    echo "bootstrap-labels: sync-labels.sh exited non-zero (labels may need manual sync)" >&2
fi
