#!/usr/bin/env bash
# tests/TL3-worker-dispatch-child-env-gh-doc-append.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, gh-cli, doc-append, auth-resolution, real-environment, TL3, scope:common, dup-group-keep:size-hard-limit
# doc-append's gh is a GRANDCHILD: the dispatcher starts `bash`, which runs
# bin/compose-doc-append-entry, which calls `gh repo view` / `gh api`. That
# shape cannot be expressed in TL3-worker-dispatch-child-env-gh-auth.sh, whose
# arms dispatch `gh` as the command itself and measure the child env at node's
# spawn site — a grandchild has no such site. Hence a sibling file, not a row.
set -u

# TL3 gap (what this test does NOT catch):
# - A real doc-append run: this file dispatches `bash -c 'gh auth status'`
#   rather than driving bin/compose-doc-append-entry.
# - Token-only hosts: the arms need a config-authenticated gh to tell "the
#   token reached the child" from "nothing reached the child", so a host whose
#   only credential is GH_TOKEN gates out here.
#   Both gaps are closed by tests/TL3-worker-dispatch-doc-append-compose.sh.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stage 1 (buildEnv unit cases) runs ungated and shows the gap on any host.
# Stage 2 adds a real gh: a deliberately invalid GH_TOKEN in the parent is the
# probe — gh prefers an env token over its config file, so a child that RECEIVES
# the token fails auth and a child that does not silently succeeds via config.
# The verdict inverts the usual polarity, which is what makes it conclusive.
# Exit contract: FAIL>0 -> 1; INCONCLUSIVE!=0 or PROVEN<REQUIRED -> 77; else 0.
PASS=0; FAIL=0; SKIP=0; PROVEN=0; INCONCLUSIVE=0; REQUIRED=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
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

HAVE_NODE=1; command -v node >/dev/null 2>&1 || HAVE_NODE=0
HAVE_GIT=1; command -v git >/dev/null 2>&1 || HAVE_GIT=0
if [ -x "$AGENTS_DIR/bin/get-config-var" ]; then
    if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then gate_unmet "RUN_TL3 is off"; fi
else
    gate_unmet "bin/get-config-var is not executable"
fi
[ "$HAVE_NODE" = "1" ] || gate_unmet "node is not on PATH"
[ "$HAVE_GIT" = "1" ] || gate_unmet "git is not on PATH"
command -v bash >/dev/null 2>&1 || gate_unmet "bash is not on PATH"
command -v gh >/dev/null 2>&1 || gate_unmet "gh is not on PATH"

# One host, fixed: a bare `gh auth status` inspects every known account and
# fails on any single stale one, suppressing the file for an unrelated reason.
TARGET_HOST="${GH_HOST:-github.com}"

# Obvious nonsense, never a real credential.
FAKE_GH_TOKEN="ghp-FAKE0000-not-a-real-token"
FAKE_SECRET="unrelated-FAKE0000-not-a-real-secret"

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-ghdoc-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"
MAIN_RAW="$TMPD/mainrepo"; mkdir -p "$MAIN_RAW"
if [ "$HAVE_GIT" = "1" ]; then
    git -C "$MAIN_RAW" init -q -b main
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    git -C "$MAIN_RAW" config core.hooksPath /dev/null
    echo init > "$MAIN_RAW/README.md"
    git -C "$MAIN_RAW" add README.md 2>/dev/null
    git -C "$MAIN_RAW" commit -q --no-verify -m initial 2>/dev/null
fi
MAIN="$(nodepath "$MAIN_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"

# shellcheck source=./TL3-worker-dispatch-child-env-gh-doc-append/probe.sh
. "$(dirname "${BASH_SOURCE[0]}")/TL3-worker-dispatch-child-env-gh-doc-append/probe.sh"


UNIT_CASES=(
    "doc-append/gh-token-reaches-child"
    "doc-append/github-token-reaches-child"
    "issue-reconcile/gh-token-control"
    "commit-push/github-token-control"
    "doc-append/absent-token-is-omitted-not-blanked"
    "doc-append/undeclared-secret-does-not-reach-child"
    "allowlist/tokens-stay-out-of-the-global-child-env-allowlist"
    "session-close-gate/gh-token-stays-out"
    "doc-append/undeclared-extraenv-is-rejected"
)

run_unit_cases() {
    local n got
    if ! run_probe unit doc-append; then
        fail "unit/probe-ran-to-completion — $PROBE_OUT"
        return 0
    fi
    for n in "${UNIT_CASES[@]}"; do
        got="$(pv "U__$n")"
        if [ -z "$got" ]; then fail "unit/$n — the probe reported no result for this case"
        elif [ "$got" = "ok" ]; then pass "unit/$n"
        else fail "unit/$n — $got"; fi
    done
    assert_eq "unit/case-count-matches-the-table" "${#UNIT_CASES[@]}" "$(pv unit_case_count)"
    return 0
}

finish_unmet() {
    echo "SKIP: $1"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED (gate unmet)"
    exit "$(exit_verdict "$FAIL" 1 "$PROVEN" "$REQUIRED")"
}

# Stage 0 — the exit arithmetic itself, checked before anything can depend on
# it. A gate-unmet run must answer 77, never 0.
assert_eq "exitcode/failure-outranks-everything" "1" "$(exit_verdict 1 0 3 3)"
assert_eq "exitcode/gate-unmet-is-a-skip-not-a-pass" "77" "$(exit_verdict 0 1 0 3)"
assert_eq "exitcode/unproven-required-arm-is-a-skip" "77" "$(exit_verdict 0 0 2 3)"
assert_eq "exitcode/all-required-arms-proven-is-a-pass" "0" "$(exit_verdict 0 0 3 3)"

# Stage 1 — ungated.
if [ "$HAVE_NODE" = "1" ]; then
    run_unit_cases
else
    skip "unit/* — node is not on PATH, buildEnv contract unchecked"
fi

if [ "$GATE_OK" != "1" ]; then
    finish_unmet "environment gate unmet — $GATE_REASON"
fi

# Stage 2 premise A — this host resolves gh auth from its CONFIG, with no
# credential in the environment. Without it, "authenticated" below would carry
# no information about where the credential came from.
if ! run_probe direct doc-append; then
    finish_unmet "the direct (non-dispatcher) gh probe did not run to completion"
fi
if [ "$(pv class)" != "authenticated" ]; then
    finish_unmet "gh is not config-authenticated for $TARGET_HOST — class=$(pv class)"
fi
pass "gate/direct-gh-resolves-auth-from-config-without-a-token"

# Stage 2 premise B — an env token really does outrank that config on this
# host. If it does not, the arms below cannot distinguish the two causes and
# are skipped rather than quietly reinterpreted.
PREMISE_B=0
if run_probe direct doc-append "GH_TOKEN=$FAKE_GH_TOKEN"; then
    if [ "$(pv class)" = "unauthenticated" ]; then
        PREMISE_B=1
        pass "gate/an-env-token-outranks-the-config-for-direct-gh"
    fi
fi

REQUIRED=3
if [ "$PREMISE_B" != "1" ]; then
    INCONCLUSIVE=1
    skip "arms/* — premise false: a fake GH_TOKEN did not break direct gh on this host"
else
    # The targeted arm. Pre-fix, doc-append declares no token, so the fake one
    # never reaches the grandchild gh and it succeeds via config — the inverted
    # polarity is what makes "authenticated" the failing verdict here.
    if run_probe dispatch doc-append "GH_TOKEN=$FAKE_GH_TOKEN"; then
        expect_class "arm/doc-append-child-receives-the-parent-gh-token" "unauthenticated" 1
    else
        fail "arm/doc-append-child-receives-the-parent-gh-token — probe did not complete: $PROBE_OUT"
    fi
    # Control on an entry that already declares the pair: proves the dispatched
    # bash->gh path can carry a token at all on this host.
    if run_probe dispatch commit-push "GH_TOKEN=$FAKE_GH_TOKEN"; then
        expect_class "arm/declared-worker-child-receives-the-parent-gh-token" "unauthenticated" 1
    else
        fail "arm/declared-worker-child-receives-the-parent-gh-token — probe did not complete: $PROBE_OUT"
    fi
    # Discriminator: with no token in the parent, the same dispatched entry must
    # authenticate from config. Without this row, an arm that failed for an
    # unrelated reason (no PATH, no config vars) would read as proof.
    if run_probe dispatch doc-append; then
        expect_class "arm/doc-append-child-still-resolves-config-auth-without-a-token" "authenticated" 1
    else
        fail "arm/doc-append-child-still-resolves-config-auth-without-a-token — probe did not complete: $PROBE_OUT"
    fi
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED"
VERDICT="$(exit_verdict "$FAIL" "$INCONCLUSIVE" "$PROVEN" "$REQUIRED")"
if [ "$VERDICT" = "77" ]; then
    echo "SKIP: required arms did not reach a definite classification (PROVEN=$PROVEN/$REQUIRED)"
fi
exit "$VERDICT"
