#!/usr/bin/env bash
# bootstrap-labels.sh — bootstrap label auto-management for a target repo.
#
# Copies the label-sync skeleton from AGENTS_CONFIG_DIR into <repo-dir>:
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
#
# Required env:
#   AGENTS_CONFIG_DIR  Path to the agents repo (source of master files)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-labels.sh <repo-dir> [--no-sync]

Bootstrap label auto-management for a target repo:
  1. Copy .github/labels.yml from AGENTS_CONFIG_DIR
  2. Copy bin/github-issues/sync-labels.sh
  3. Copy .github/workflows/sync-labels.yml
  4. Run initial sync-labels.sh inside <repo-dir> (skip with --no-sync)

Options:
  --no-sync     Skip initial sync-labels.sh invocation
  --help        Show this help and exit

Required env:
  AGENTS_CONFIG_DIR  Path to the agents repo (source of master files)
EOF
}

REPO_DIR=""
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
      if [[ -z "$REPO_DIR" ]]; then
        REPO_DIR="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$REPO_DIR" ]]; then
  echo "Error: <repo-dir> is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "${AGENTS_CONFIG_DIR:-}" ]]; then
  echo "Error: AGENTS_CONFIG_DIR must be set" >&2
  exit 1
fi

if [[ ! -d "$REPO_DIR" ]]; then
  echo "Error: directory not found: $REPO_DIR" >&2
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
  src="$AGENTS_CONFIG_DIR/$rel"
  dst="$REPO_DIR/$rel"
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
if [[ -f "$REPO_DIR/bin/github-issues/sync-labels.sh" ]]; then
  chmod +x "$REPO_DIR/bin/github-issues/sync-labels.sh" 2>/dev/null || true
fi

echo "bootstrap-labels: copied $copied/$total files to $REPO_DIR"

if [[ "$NO_SYNC" -eq 0 ]]; then
  # Run the trusted sync-labels.sh from AGENTS_CONFIG_DIR (not the copy in REPO_DIR)
  # so pre-existing or divergent target copies cannot execute arbitrary code under
  # the operator's credentials. CWD is REPO_DIR so sync-labels.sh resolves
  # .github/labels.yml relative to the target repo.
  (cd "$REPO_DIR" && bash "$AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh") || \
    echo "bootstrap-labels: sync-labels.sh exited non-zero (labels may need manual sync)" >&2
fi
