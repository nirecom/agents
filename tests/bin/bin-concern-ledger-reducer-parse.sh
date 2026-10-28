#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-reducer-parse.sh
# Tests: bin/lib/concern-ledger/parse.sh
# Tags: concern-ledger, reducer, parse, pattern-discovery, scope:common, pwsh-not-required
# Runs the parse group (pattern-discovery, path-shapes-and-framing) of bin-concern-ledger-reducer.sh (#2723 split).
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/clg-wrapper-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/clg-wrapper-plans-$$"
# shellcheck source=../lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/harness.sh"
CLG_GROUP=parse
. "$(dirname "${BASH_SOURCE[0]}")/bin-concern-ledger-reducer.sh"
