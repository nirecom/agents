#!/usr/bin/env bash
# tests/feature-1812-worker-dispatch-uv-no-project.sh
# Tests: bin/compose-doc-append-entry
# Tags: worker-dispatch, doc-append, compose, uv, supply-chain, credential-exposure, security, adversarial, canary, TL2, scope:issue-specific
#
# Issue #1812 / #1744 — `uv run --no-project` at the three compose call sites.
# compose-doc-append-entry runs from the branch-under-review worktree with
# GH_TOKEN/GITHUB_TOKEN live in its environment (#1744). Without --no-project,
# `uv run` walks up from cwd for a pyproject.toml and BUILDS the project it
# finds — executing the branch's own build backend with both tokens present.
set -u

# Offline by design: no RUN_TL3 gate. Every `gh` call is served by a stub on
# PATH, so the only real subprocesses are uv, node, git, jq and base64.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1812_UVNP_INNER:-}" ]; then
    _WD1812_UVNP_INNER=1 timeout 600 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$AGENTS_DIR/bin/compose-doc-append-entry"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# TL3 gap (what this offline test does NOT catch):
# - Real PyPI resolution: the hostile backend is local (backend-path) with no
#   declared build requirement, so a hostile PUBLISHED build dependency — the
#   other half of the same surface — is never exercised.
# - A real `gh`: token handling by the actual CLI stays unverified; that tier is
#   tests/TL3-worker-dispatch-child-env-gh-doc-append.sh.
# - uv's upward walk from an ANCESTOR of the worktree (see the Skipped-Because
#   block near the end of this file).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh.

for tool in uv node git jq base64; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: $tool is not on PATH — the uv/--no-project arms cannot run"
        echo ""
        echo "Total: PASS=0 FAIL=0 SKIP=1"
        exit 77
    fi
done
if [ ! -f "$CLI" ]; then
    fail "0/prerequisite" "missing $CLI"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd1812-uvnp-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Obvious nonsense, and deliberately NOT `ghp_`-shaped: hooks/lib/
# output-sanitize.js would redact a realistic token shape, and this file must be
# able to tell "the canary never ran" from "it ran and the value was scrubbed".
FAKE_GH_TOKEN="FAKE1812-gh-token-not-a-real-credential"
FAKE_GITHUB_TOKEN="FAKE1812-github-token-not-a-real-credential"

# Parts. Sourced, not executed (rules/coding/file-split.md Pattern A): they
# define the fixture builders and the shared assertions in THIS shell, so they
# share the counters and the temp tree above.
# shellcheck source=./feature-1812-worker-dispatch-uv-no-project/fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1812-worker-dispatch-uv-no-project/fixture.sh"

# A1 — history target: reaches uv call site 1 (doc-append.py, history staging).
echo "--- A1: --history reaches uv run --no-project (doc-append.py) ---"
setup_arm 40
run_compose "$CLI" --history
if [ "$RUN_RC" -ne 0 ]; then
    fail "A1/compose-exited-zero" "rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | tr '\n' ' ' | cut -c1-400)"
else
    pass "A1/compose-exited-zero"
fi
# Non-vacuity: an arm that aborted before `uv` satisfies every negative
# assertion below while proving nothing at all.
if grep -q "contents/docs/history.md" "$CALLLOG" && [ -n "$(put_body_text)" ]; then
    pass "A1/run-reached-the-write-stage-so-uv-really-ran"
else
    fail "A1/run-reached-the-write-stage-so-uv-really-ran" \
        "calls=$(tr '\n' ';' < "$CALLLOG") puts=$(ls "$PUTDIR" 2>/dev/null | tr '\n' ' ')"
fi
if put_body_text | grep -q "compose-doc-append-sentinel: branch=feature/1812-uv-no-project pr=#1812"; then
    pass "A1/doc-append.py-produced-the-real-history-entry"
else
    fail "A1/doc-append.py-produced-the-real-history-entry" "$(put_body_text | tail -12 | tr '\n' ' ')"
fi
assert_no_execution "A1"
assert_no_token_leak "A1"

# A2 — changelog target: uv call site 2. CPR-ORTH — the sibling call site is
# exercised rather than argued from A1.
echo "--- A2: --changelog reaches uv run --no-project (doc-append.py) ---"
setup_arm 40
run_compose "$CLI" --changelog
if [ "$RUN_RC" -ne 0 ]; then
    fail "A2/compose-exited-zero" "rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | tr '\n' ' ' | cut -c1-400)"
else
    pass "A2/compose-exited-zero"
fi
if grep -q "contents/CHANGELOG.md" "$CALLLOG" && [ -n "$(put_body_text)" ]; then
    pass "A2/run-reached-the-write-stage-so-uv-really-ran"
else
    fail "A2/run-reached-the-write-stage-so-uv-really-ran" \
        "calls=$(tr '\n' ';' < "$CALLLOG") puts=$(ls "$PUTDIR" 2>/dev/null | tr '\n' ' ')"
fi
if put_body_text | grep -q "PR #1812"; then
    pass "A2/doc-append.py-produced-the-real-changelog-entry"
else
    fail "A2/doc-append.py-produced-the-real-changelog-entry" "$(put_body_text | tail -12 | tr '\n' ' ')"
fi
assert_no_execution "A2"
assert_no_token_leak "A2"

# A3 — the rotation branch: a 500+ line staged history puts the THIRD uv call
# site (doc-rotate.py) in play. The Git Data write that follows is refused by the
# stub, which is after the point this arm measures.
echo "--- A3: rotation reaches uv run --no-project (doc-rotate.py) ---"
setup_arm 300
run_compose "$CLI" --history
if printf '%s' "$RUN_OUT" | grep -q "doc-rotate.py failed"; then
    fail "A3/doc-rotate.py-ran-successfully" "$(printf '%s' "$RUN_OUT" | tr '\n' ' ' | cut -c1-400)"
else
    pass "A3/doc-rotate.py-ran-successfully"
fi
# The rotation write is the only one that takes the Git Data path; reaching it
# proves the rotation branch — and therefore that uv call site — really ran.
if grep -q "git/" "$CALLLOG" || printf '%s' "$RUN_OUT" | grep -q "rotation write failed"; then
    pass "A3/run-reached-the-rotation-write-so-doc-rotate.py-really-ran"
else
    fail "A3/run-reached-the-rotation-write-so-doc-rotate.py-really-ran" \
        "rc=$RUN_RC calls=$(tr '\n' ';' < "$CALLLOG") out=$(printf '%s' "$RUN_OUT" | tr '\n' ' ' | cut -c1-400)"
fi
assert_no_execution "A3"
assert_no_token_leak "A3"

# M1 — the unpatched baseline (Pattern 2). Same fixture, same arguments, one
# difference: `--no-project` is gone. The canary MUST fire and MUST carry both
# token values, or the three arms above proved nothing.
echo "--- M1: without --no-project the hostile backend executes (vulnerable baseline) ---"
setup_arm 40
run_compose "$MUTANT" --history
if [ -e "$CANARY" ] && grep -q "CANARY_EXECUTED" "$CANARY"; then
    pass "M1/unpatched-cli-executes-the-branch-supplied-build-backend"
else
    fail "M1/unpatched-cli-executes-the-branch-supplied-build-backend" \
        "no canary — the attack fixture is not live, so A1-A3 are vacuous. rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | tr '\n' ' ' | cut -c1-500)"
fi
if [ -e "$CANARY" ] && grep -qF "GH_TOKEN=$FAKE_GH_TOKEN" "$CANARY" && \
   grep -qF "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" "$CANARY"; then
    pass "M1/unpatched-cli-hands-the-branch-both-github-tokens"
else
    fail "M1/unpatched-cli-hands-the-branch-both-github-tokens" \
        "canary=$([ -e "$CANARY" ] && tr '\n' ' ' < "$CANARY" || echo '(absent)')"
fi

# SKIPPED: a hostile pyproject.toml in an ANCESTOR of the worktree.
# Because: the fixture lives under mktemp -d, and planting a project file above
# it would leave one in the host's temp root for the run's duration.
# L3 gap: only a real nested checkout proves where uv's upward walk stops.

# SKIPPED: a hostile build DEPENDENCY published to an index.
# Because: this file makes no network call at all.
# L3 gap: a real index resolution — the other half of the surface --no-project
# closes by never entering the project's build.

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
