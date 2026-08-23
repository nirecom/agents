#!/usr/bin/env bash
# tests/TL3-worker-dispatch-doc-append-compose.sh
# Tests: bin/worker-dispatch/workers/doc-append.js, bin/compose-doc-append-entry, bin/worker-dispatch/spawn.js
# Tags: worker-dispatch, doc-append, compose, gh-cli, gh-token, github-token, auth-resolution, real-environment, TL3, scope:common
# The real dispatcher -> real doc-append worker -> real bin/compose-doc-append-entry
# -> real `gh repo view` / `gh api` network reads, authenticated ONLY by the env
# token #1744 added to the entry. The sibling child-env-gh-doc-append.sh
# substitutes `bash -c 'gh auth status'` for the worker and needs a
# config-authenticated host; this file drives the actual compose CLI and runs on
# a token-only host, which is exactly the case that file gates out of.
set -u

# TL3 gap (what this test does NOT catch):
# - A compose run that WRITES: every arm targets a real public repo that has no
#   docs/history.md, so compose aborts at its "missing on remote" guard after the
#   authenticated reads and before any Contents/Git Data API write. The PUT path,
#   its atomic two-file variant and doc-rotate stay unexercised here — writing to
#   a real repository from a test is not something this suite may do.
# - GH_ENTERPRISE_TOKEN and a non-github.com GH_HOST: neither is declared by the
#   entry, so a GHES host authenticates by neither path.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A real, stable, public repository that has no docs/history.md. The arms need a
# reachable remote whose read succeeds and whose history file is absent.
PROBE_REPO="octocat/Hello-World"
PROBE_URL="https://github.com/octocat/Hello-World.git"

# Exit contract: FAIL>0 -> 1; INCONCLUSIVE!=0 or PROVEN<REQUIRED -> 77; else 0.
# A gated-out host must answer 77, never 0 — "nothing was proved" printing as
# green is the failure mode this file's structure exists to prevent.
PASS=0; FAIL=0; SKIP=0; PROVEN=0; INCONCLUSIVE=0
REQUIRED=8

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; PROVEN=$((PROVEN + 1))
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name"; PROVEN=$((PROVEN + 1)) ;;
        *) fail "$name — want a mention of $(printf '%q' "$needle") got=$(printf '%q' "$hay")" ;;
    esac
}

exit_verdict() {
    if [ "$1" -gt 0 ]; then echo 1
    elif [ "$2" -ne 0 ] || [ "$3" -lt "$4" ]; then echo 77
    else echo 0; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

GATE_OK=1; GATE_REASON=""
gate_unmet() { GATE_OK=0; [ -n "$GATE_REASON" ] || GATE_REASON="$1"; }

if [ -x "$AGENTS_DIR/bin/get-config-var" ]; then
    if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then gate_unmet "RUN_TL3 is off"; fi
else
    gate_unmet "bin/get-config-var is not executable"
fi
for c in node git bash gh uv; do
    command -v "$c" >/dev/null 2>&1 || gate_unmet "$c is not on PATH"
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-composee2e-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"
# A gh config directory with nothing in it: the arms must prove the ENV token
# carried the auth, so no host config may be able to stand in for it.
EMPTY_GH_CONFIG_RAW="$TMPD/gh-config-empty"; mkdir -p "$EMPTY_GH_CONFIG_RAW"
EMPTY_GH_CONFIG="$(nodepath "$EMPTY_GH_CONFIG_RAW")"

PART_DIR="$(dirname "${BASH_SOURCE[0]}")/TL3-worker-dispatch-doc-append-compose"
# shellcheck source=./TL3-worker-dispatch-doc-append-compose/fixture.sh
. "$PART_DIR/fixture.sh"
# shellcheck source=./TL3-worker-dispatch-doc-append-compose/arms.sh
. "$PART_DIR/arms.sh"

finish_unmet() {
    echo "SKIP: $1"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED (gate unmet)"
    exit "$(exit_verdict "$FAIL" 1 "$PROVEN" "$REQUIRED")"
}

# Stage 0 — the exit arithmetic, before anything can depend on it.
assert_eq "exitcode/failure-outranks-everything" "1" "$(exit_verdict 1 0 8 8)"
assert_eq "exitcode/gate-unmet-is-a-skip-not-a-pass" "77" "$(exit_verdict 0 1 0 8)"
assert_eq "exitcode/unproven-required-arm-is-a-skip" "77" "$(exit_verdict 0 0 7 8)"
assert_eq "exitcode/all-required-arms-proven-is-a-pass" "0" "$(exit_verdict 0 0 8 8)"
PROVEN=0

[ "$GATE_OK" = "1" ] || finish_unmet "environment gate unmet — $GATE_REASON"

# Stage 1 premise — established WITHOUT the dispatcher, so an arm's verdict is a
# statement about the dispatcher rather than about this host's gh.
PROBE_TOKEN="$(run_with_timeout 60 gh auth token 2>/dev/null || true)"
[ -n "$PROBE_TOKEN" ] || finish_unmet "no gh token is available on this host"

# Same argv-hygiene contract as run_worker: the pairs are exported inside a
# subshell so the live token never reaches a process command line, and the
# leading unset makes the no-argument call a genuine no-token probe rather than
# one the host's own ambient GH_TOKEN could answer.
direct_gh() { (
    unset GH_TOKEN GITHUB_TOKEN
    for kv in "$@"; do export "$kv"; done
    run_with_timeout 90 env "GH_CONFIG_DIR=$EMPTY_GH_CONFIG" \
        gh repo view "$PROBE_REPO" --json name --jq .name 2>&1
); }

if [ "$(direct_gh "GH_TOKEN=$PROBE_TOKEN")" != "Hello-World" ]; then
    finish_unmet "a token-only gh cannot reach $PROBE_REPO from this host (network or token scope)"
fi
pass "gate/a-token-only-gh-reaches-the-probe-repo-without-any-config"

# The discriminator's own premise: with the same empty config and NO token, gh
# must fail. Without this, arm C could pass for the wrong reason.
if [ "$(direct_gh)" = "Hello-World" ]; then
    finish_unmet "gh authenticates with an empty config and no token — the arms cannot discriminate"
fi
pass "gate/the-same-gh-fails-when-no-token-is-in-the-environment"

build_fixture || finish_unmet "the compose fixture repository could not be built"

arm_gh_token
arm_github_token
arm_no_token
arm_changelog_empty_scope

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED"
VERDICT="$(exit_verdict "$FAIL" "$INCONCLUSIVE" "$PROVEN" "$REQUIRED")"
if [ "$VERDICT" = "77" ]; then
    echo "SKIP: required arms did not reach a definite observation (PROVEN=$PROVEN/$REQUIRED)"
fi
exit "$VERDICT"
