#!/usr/bin/env bash
# apply-section.sh <ROOT> <json> [--no-push] — /migrate-tests MTS-3: write the tests section, then commit it
# (only .agents.json is staged). A refused write commits nothing and leaves its reason on stderr.
# Exit: 0 written and committed, 1 write refused or commit failed, 2 bad arguments, 3 write refused because
# the settings file is malformed (the caller decides on bin/repo-settings --reset-malformed).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

usage() {
  echo "usage: apply-section.sh <ROOT> <json> [--no-push]" >&2
  exit 2
}

[[ $# -ge 2 && -n "$1" && -n "$2" && "$1" != -* && "$2" != -* ]] || usage
MIGRATE_TARGET="$1"
SECTION_JSON="$2"
shift 2

COMMIT_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --no-push) COMMIT_FLAGS+=("$arg") ;;
    *) usage ;;
  esac
done

if ! node "$SCRIPT_CHECKOUT_ROOT/bin/repo-settings" --root "$MIGRATE_TARGET" --write-tests "$SECTION_JSON"; then
  NEEDS_OUT="$(node "$SCRIPT_CHECKOUT_ROOT/bin/migrate-needs" --root "$MIGRATE_TARGET")" || exit 1
  if grep -q '^MALFORMED=1' <<<"$NEEDS_OUT"; then
    exit 3
  fi
  exit 1
fi

bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/commit-migration-artifacts.sh" "$MIGRATE_TARGET" --skill migrate-tests ${COMMIT_FLAGS[@]+"${COMMIT_FLAGS[@]}"} || exit 1
