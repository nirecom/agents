#!/usr/bin/env bash
# tests/bin/TL3-worker-dispatch-gh-contract.sh
# Tests: bin/worker-dispatch/workers/issue-reconcile.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, issue-reconcile, gh-cli, external-contract, real-environment, TL3, scope:common
#
# TL3 — single real seam: the real `gh` CLI's `issue list` flag surface.
#
# Why: `gh issue list --page N` never existed; a TL2 stub only confirms the stub.
# Detects (a) a gh change removing a flag the dispatcher passes, (b) `--page` returning.
# Gate: RUN_TL3=on and a real `gh` on PATH, else exit 77. Read-only (`--help` only).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
# TL3 legitimately uses the real gh: take the command guard (#2590) off PATH.
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/command-guard.sh"
command_guard_use_real
command -v gh >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

HELP="$TMPD/gh-issue-list-help.txt"
run_with_timeout 60 gh issue list --help > "$HELP" 2>&1 || true
if [ -s "$HELP" ]; then
    pass "gh/help-readable"
else
    fail "gh/help-readable — 'gh issue list --help' produced no output"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

# ---------------------------------------------------------------------------
# (a) every flag the dispatcher passes must exist
# ---------------------------------------------------------------------------
for flag in --repo --state --limit --json; do
    if grep -qE "(^|[[:space:],])${flag}([[:space:],=]|$)" "$HELP"; then
        pass "gh/flag-present${flag}"
    else
        fail "gh/flag-present${flag} — '$flag' absent from 'gh issue list --help'"
    fi
done

# ---------------------------------------------------------------------------
# (b) --page must NOT exist (regression fence for the old worker's instruction)
# ---------------------------------------------------------------------------
if grep -qE "(^|[[:space:],])--page([[:space:],=]|$)" "$HELP"; then
    fail "gh/page-flag-absent — '--page' now exists; revisit the paging design (limit-based scan)"
else
    pass "gh/page-flag-absent"
fi

# ---------------------------------------------------------------------------
# (c) --json must accept number / title / comments
# gh prints the field list when --json is given an unknown value; that error text
# is the authoritative enumeration.
# ---------------------------------------------------------------------------
FIELDS="$TMPD/json-fields.txt"
run_with_timeout 60 gh issue list --json __definitely_not_a_field__ > "$FIELDS" 2>&1 || true
if [ ! -s "$FIELDS" ]; then
    fail "gh/json-field-enumeration — no output from the unknown --json probe"
else
    pass "gh/json-field-enumeration"
    for field in number title comments; do
        if grep -qE "(^|[[:space:],\"])${field}([[:space:],\"]|$)" "$FIELDS"; then
            pass "gh/json-field-$field"
        else
            fail "gh/json-field-$field — '$field' not in the --json field list"
        fi
    done
fi

# ---------------------------------------------------------------------------
# (d) the source of truth must not have reintroduced --page
# ---------------------------------------------------------------------------
WORKER_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/workers/issue-reconcile.js"
if [ ! -f "$WORKER_JS" ]; then
    fail "gh/source-no-page-flag — implementation missing: bin/worker-dispatch/workers/issue-reconcile.js"
else
    if grep -q -- '--page' "$WORKER_JS"; then
        fail "gh/source-no-page-flag — issue-reconcile.js references --page"
    else
        pass "gh/source-no-page-flag"
    fi
    if grep -q -- '--limit' "$WORKER_JS"; then
        pass "gh/source-uses-limit"
    else
        fail "gh/source-uses-limit — issue-reconcile.js does not pass --limit"
    fi
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
