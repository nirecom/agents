#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration/_driver.sh
# Tests: bin/lib/run-all-ledger-migrate.sh
# Tags: tests, bin, ledger, migration, helpers, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# Child entry for lm_run: load the libraries the way their real callers do, then the
# shared helpers and the part file, then call the named part function.

set -uo pipefail
case "${LM_LIBSET:-dur}" in
  dur)
    . "$AGENTS_DIR/bin/lib/run-all-parallelism.sh" || exit 98
    . "$AGENTS_DIR/bin/lib/run-all-durations.sh" || exit 98
    ;;
  base)
    RTB_LEDGER_REPO="$LM_REPO"
    . "$AGENTS_DIR/bin/lib/run-tests-baseline-ledger.sh" || exit 98
    ;;
esac
. "$AGENTS_DIR/tests/bin/feature-2079-ledger-migration/_lib.sh"
for lm_dir in $LM_PART_DIRS; do
  for lm_part in "$lm_dir"/*-cases.sh; do
    [ -f "$lm_part" ] || continue
    . "$lm_part" || exit 98
  done
done
"$@"
