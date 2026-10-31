#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-reducer-merge.sh
# Tests: bin/lib/concern-ledger/reduce.sh
# Tags: concern-ledger, reducer, merge, transitions, scope:common, pwsh-not-required
# Runs the merge group (merge, transitions, backslash-reduce) of bin-concern-ledger-reducer.sh (#2723 split).
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/clg-wrapper-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/clg-wrapper-plans-$$"
# shellcheck source=../lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/harness.sh"
CLG_GROUP=merge
. "$(dirname "${BASH_SOURCE[0]}")/bin-concern-ledger-reducer.sh"
