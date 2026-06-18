#!/bin/bash
# tests/feature-feat-928-supervisor-report-format/_lib.sh
# Shared helpers and fixtures for feature-feat-928-supervisor-report-format test groups.
#
# Sourced by:
#   - tests/feature-feat-928-supervisor-report-format/formatter-unit.sh
#   - tests/feature-feat-928-supervisor-report-format/guard-integration.sh
#
# Each group script sources this file so it can run standalone, e.g.:
#   bash tests/feature-feat-928-supervisor-report-format/formatter-unit.sh
#
# This library:
#   - sets `set -u`
#   - resolves AGENTS_DIR / path variables
#   - initializes PASS / FAIL / SKIP counters
#   - defines pass / fail / skip / run_with_timeout / require_source /
#     seed_state / format_cumsev_error / format_l2_armed helpers
#   - defines FINDINGS_* constants

set -u

# Resolve AGENTS_DIR relative to this library file
# (tests/feature-feat-928-supervisor-report-format/_lib.sh → repo root is two levels up)
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
FORMATTER="$AGENTS_DIR/hooks/lib/supervisor-report-format.js"
FORMATTER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

seed_state() {
    local tmp="$1" sid="$2" layer2_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = $layer2_json;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

format_cumsev_error() {
    # args: findings_json sid wsid supervisorPath [stateFilePath]
    local findings="$1" sid="$2" wsid="$3" sp="$4" stp="${5:-}"
    if [ -n "$stp" ]; then
        run_with_timeout 5 node -e "
const f = require('$FORMATTER_NODE');
const findings = $findings;
const sid = '$sid';
const wsid = $wsid;
const sp = '$sp';
const stp = '$stp';
process.stdout.write(f.formatCumSevErrorReason(findings, sid, wsid, sp, stp));
" 2>/dev/null
    else
        run_with_timeout 5 node -e "
const f = require('$FORMATTER_NODE');
const findings = $findings;
const sid = '$sid';
const wsid = $wsid;
const sp = '$sp';
process.stdout.write(f.formatCumSevErrorReason(findings, sid, wsid, sp));
" 2>/dev/null
    fi
}

format_l2_armed() {
    # args: cause sid wsid supervisorPath stateFilePath
    local cause="$1" sid="$2" wsid="$3" sp="$4" stp="$5"
    run_with_timeout 5 node -e "
const f = require('$FORMATTER_NODE');
process.stdout.write(f.formatL2ArmedReason('$cause', '$sid', $wsid, '$sp', '$stp'));
" 2>/dev/null
}

FINDINGS_TWO='[{"categories":["workflow"],"severity":"error","detail":"first-finding","timestamp":"2026-06-06T11:00:00.000Z"},{"categories":["code","security"],"severity":"error","detail":"last-detail-text","timestamp":"2026-06-06T12:00:00.000Z"}]'
FINDINGS_ONE='[{"categories":["workflow"],"severity":"error","detail":"only-finding","timestamp":"2026-06-06T12:00:00.000Z"}]'
FINDINGS_NULL='[{"categories":null,"severity":"error","detail":null,"timestamp":"2026-06-06T12:00:00.000Z"}]'
FINDINGS_NO_SEV='[{"categories":["code"],"detail":"d","timestamp":"2026-06-06T12:00:00.000Z"}]'
FINDINGS_SPARSE='[null, {"categories":["code"],"severity":"error","detail":"real-detail","timestamp":"2026-06-06T12:00:00.000Z"}]'
FINDINGS_MIXED='[{"categories":[42, "code"],"severity":"error","detail":"d","timestamp":"2026-06-06T12:00:00.000Z"}]'
