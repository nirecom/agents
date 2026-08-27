#!/usr/bin/env bash
# tests/feature-1812-worker-dispatch-secret-leak-errors.sh
# Tests: bin/worker-dispatch/workers/doc-append.js, bin/worker-dispatch/workers/commit-push/procedure.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/emit.js
# Tags: worker-dispatch, doc-append, commit-push, credential-exposure, artifact-log, redaction, error-path, adversarial, security, TL2, scope:issue-specific
#
# Issue #1812 / #1744 — what the workers do with a child's output once a
# credential has been propagated into that child. The child is the untrusted
# half: a `gh` that echoes its Authorization header, a repo-planted pre-commit
# hook, a verbose transport. This file drives both real workers to a real
# failure and follows the printed value to every place it lands.
set -u

# Finding, pinned rather than asserted away: fsguard.writeFile applies only
# redactSentinels, and emit.js's sanitizeLine only collapses control characters,
# redacts sentinels and caps length. redactSecrets — in the SAME module,
# hooks/lib/output-sanitize.js — is never reached from either seam, so raw child
# stdout/stderr is persisted and surfaced verbatim. Rows named LEAK-REPRODUCES
# assert the leak HAPPENS; a redaction seam added later turns them red on
# purpose, so the fix arrives with this file rather than around it. Arm A1 is
# the one containment that does hold — and it is compose-doc-append-entry's own
# `2>/dev/null` at each gh call site, not anything the worker does.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1812_LEAK_INNER:-}" ]; then
    _WD1812_LEAK_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="feature/1812-leak-probe"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# TL3 gap (what this offline test does NOT catch):
# - A REAL gh/git printing a REAL token: the leak is driven by stubs and a
#   planted hook, so the exact wording of a real tool's error is not covered.
# - Whether the persisted artifact log is later read by a human or shipped
#   anywhere — this file measures the write, not the downstream audience.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh.

for tool in git node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: $tool is not on PATH"
        echo ""
        echo "Total: PASS=0 FAIL=0 SKIP=1"
        exit 77
    fi
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd1812-leak-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"

# `ghp_`-SHAPED on purpose: hooks/lib/output-sanitize.js's redactSecrets already
# recognises this exact shape, so a value that survives verbatim proves the
# mechanism is not applied at these seams rather than that it does not exist.
FAKE_GH_TOKEN="ghp_FAKE1812leakprobeAAAAAAAAAAAAAAAAAA"
FAKE_GITHUB_TOKEN="github_pat_FAKE1812leakprobeBBBBBBBBBBBBBBBB"
FAKE_SSH_SOCK="/tmp/fake-1812-leak-agent.sock"
LEAK_HOOK_TOKEN="ghp_FAKE1812hookprobeCCCCCCCCCCCCCCCCCC"
LEAK_HOOK_SOCK="/tmp/fake-1812-hook-agent.sock"
export LEAK_HOOK_TOKEN LEAK_HOOK_SOCK

# shellcheck source=./feature-1812-worker-dispatch-secret-leak-errors/arms.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1812-worker-dispatch-secret-leak-errors/arms.sh"

build_gh_stub
build_leaky_hook
if ! build_repos; then
    fail "0/fixture-built" "the probe repo could not be seeded"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi
pass "0/fixture-built"

# 0 — the mechanism half of the finding. redactSecrets WOULD mask every planted
# value; the arms below show the workers never call it.
MASKED="$(run_with_timeout 60 node -e '
const { redactSecrets } = require(process.argv[1]);
const line = "err: token " + process.argv[2] + " and " + process.argv[3];
process.stdout.write(redactSecrets(line).indexOf(process.argv[2]) === -1 &&
  redactSecrets(line).indexOf(process.argv[3]) === -1 ? "masked" : "unmasked");
' "$(nodepath "$AGENTS_DIR/hooks/lib/output-sanitize.js")" "$FAKE_GH_TOKEN" "$FAKE_GITHUB_TOKEN" 2>&1)"
assert_eq "0/redactSecrets-would-mask-both-planted-tokens" "masked" "$MASKED"

arm_doc_append_contained
arm_doc_append_leak
arm_commit_push

# SKIPPED: asserting a redacted artifact log.
# Because: no redaction seam exists on the fsguard/emit write paths, and this
# file may only edit tests/ — fabricating the assertion would encode a
# guarantee the shipped code does not make.
# L3 gap: whether redactSecrets belongs at fsguard.writeFile, at emit.js, or at
# both is a source decision, tracked outside this file.

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
