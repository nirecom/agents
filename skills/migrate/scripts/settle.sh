#!/usr/bin/env bash
# settle.sh <ROOT> [--no-push] [--dry-run] — /migrate MG-3. Prints MIGRATE_RESULT=ok or =skipped as its only
# stdout line; the commit's text goes to stderr. Exit: 0 result printed, 1 not settled (no result line, reason
# on stderr), 2 bad arguments. Settled: UNCOMMITTED=0 and (UNPUSHED=0 or --no-push).
# Named exception, commit recovery: every needs.js already says done, so a sub-skill would do nothing and the
# missing commit or push is git state, not any skill's criterion. With nothing left to commit, the commit
# script pushes an earlier commit whose push failed. It writes no content, judges nothing, stages .agents.json
# only, and asks nothing.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

usage() {
  echo "usage: settle.sh <ROOT> [--no-push] [--dry-run]" >&2
  exit 2
}

die() {
  echo "settle: $1" >&2
  exit 1
}

[[ $# -ge 1 && -n "$1" && "$1" != -* ]] || usage
MIGRATE_TARGET="$1"
shift

COMMIT_FLAGS=()
NO_PUSH=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-push) NO_PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
  COMMIT_FLAGS+=("$arg")
done

needs_field() {
  sed -n "s/^$1=//p" <<<"$NEEDS_OUT" | tr -d '\r'
}

read_needs() {
  NEEDS_OUT="$(node "$SCRIPT_CHECKOUT_ROOT/bin/migrate-needs" --root "$MIGRATE_TARGET")" || die "bin/migrate-needs failed"
  NEEDED="$(needs_field NEEDED)"
  UNCOMMITTED="$(needs_field UNCOMMITTED)"
  UNPUSHED="$(needs_field UNPUSHED)"
  [[ "$UNCOMMITTED" =~ ^[01]$ && "$UNPUSHED" =~ ^[01]$ ]] || die "unexpected bin/migrate-needs output: $NEEDS_OUT"
}

all_done() {
  [[ -z "$NEEDED" && "$UNCOMMITTED" == 0 && ( "$UNPUSHED" == 0 || "$NO_PUSH" == 1 ) ]]
}

read_needs
if all_done; then
  echo "MIGRATE_RESULT=ok"
  exit 0
fi

if [[ -n "$NEEDED" && "$DRY_RUN" == 0 ]]; then
  die "still needed: $NEEDED"
fi

if [[ -z "$NEEDED" ]]; then
  bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/commit-migration-artifacts.sh" "$MIGRATE_TARGET" --skill migrate ${COMMIT_FLAGS[@]+"${COMMIT_FLAGS[@]}"} >&2 || die "commit recovery failed"
fi

if [[ "$DRY_RUN" == 1 ]]; then
  echo "MIGRATE_RESULT=skipped"
  exit 0
fi

read_needs
if all_done; then
  echo "MIGRATE_RESULT=ok"
  exit 0
fi
die "not settled after commit recovery (NEEDED=$NEEDED UNCOMMITTED=$UNCOMMITTED UNPUSHED=$UNPUSHED)"
