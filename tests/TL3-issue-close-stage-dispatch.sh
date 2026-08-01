#!/usr/bin/env bash
# tests/TL3-issue-close-stage-dispatch.sh
# Tests: bin/worker-dispatch/workers/issue-close-stage.js, skills/issue-close-stage/scripts/run-stage-chain.sh, bin/worker-dispatch.js
# Tags: worker-dispatch, issue-close-stage, real-environment, linked-worktree, dry-run, TL3, scope:issue-specific
#
# TL3 — one real seam: a real `git worktree`-created linked worktree, the real
# dispatcher, the real spawn boundary (no preload stub) and the REAL
# run-stage-chain.sh with its real Step A/B/D/F/G helper scripts. Only `gh` is
# replaced, by a dry-run stub on PATH that logs every invocation and mutates
# nothing.
#
# Why it cannot be a TL2: the sibling TL2 cans the child process, so it can never
# observe (a) whether PATH actually reaches the grandchild `gh` through
# spawn.js's env allowlist, (b) whether the family-worktree capability check
# accepts a genuinely git-registered linked worktree, or (c) whether the real
# chain's KV bytes match what the worker's parser expects. All three are the
# failure modes that only show up in production.
#
# TL3 gap: no real GitHub API is contacted — the sentinel comment is never
# actually posted, so the live `gh issue comment` URL shape stays unverified
# here. That shape is owned by tests/TL3-worker-dispatch-gh-contract.sh's sibling
# contract checks against the real binary.
#
# Gate: RUN_TL3=on plus git/node/bash. Exits 77 (SKIP) otherwise.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v git >/dev/null 2>&1 || exit 77
command -v node >/dev/null 2>&1 || exit 77

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

DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
WORKER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/issue-close-stage.js"
if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$WORKER_JS" ]; then
    fail "impl/present" "missing dispatcher or bin/worker-dispatch/workers/issue-close-stage.js"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ics1673-tl3-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- real main worktree + real linked worktree -----------------------------
MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/tl3-ics "$LINKED_RAW" >/dev/null 2>&1
if [ ! -d "$LINKED_RAW/.git" ] && [ ! -f "$LINKED_RAW/.git" ]; then
    fail "fixture/linked-worktree" "git worktree add did not produce a linked worktree"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi
pass "fixture/linked-worktree"

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"

# --- dry-run `gh` stub: logs, mutates nothing ------------------------------
GHBIN="$TMPD/ghbin"; mkdir -p "$GHBIN"
GHLOG="$TMPD/gh-calls.log"
: > "$GHLOG"
cat > "$GHBIN/gh" <<EOS
#!/bin/bash
{ printf 'cwd=%s argv=' "\$PWD"; printf '%s ' "\$@"; printf '\n'; } >> "$GHLOG"
case "\$1 \$2" in
    "issue view")
        case "\$*" in
            *"--json state"*)    echo "OPEN"; exit 0 ;;
            *"--json comments"*) echo ""; exit 0 ;;
        esac
        exit 0
        ;;
    "issue comment")
        echo "https://github.com/example-owner/example-repo/issues/12#issuecomment-4242"
        exit 0
        ;;
    "api "*|"api")
        case "\$*" in
            *sub_issues*) echo "0"; exit 0 ;;
        esac
        exit 0
        ;;
esac
exit 0
EOS
chmod +x "$GHBIN/gh"

PAYLOAD="$PLANS_RAW/tl3-stage.json"
printf '%s' \
  "{\"issue_number\":12,\"worktree_path\":\"$LINKED\",\"owner_repo\":\"example-owner/example-repo\",\"artifact_dir\":\"$PLANS\"}" \
  > "$PAYLOAD"

DRC=0
DOUT="$(run_with_timeout 120 env \
    "PATH=$GHBIN:$PATH" \
    "WORKFLOW_PLANS_DIR=$PLANS" \
    node "$(nodepath "$DISPATCH_JS")" issue-close-stage "$MAIN" "$(nodepath "$PAYLOAD")" 2>/dev/null)" || DRC=$?

field_of() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }

assert_eq "dispatch/exit0" "0" "$DRC"
assert_eq "dispatch/three-lines" "3" "$(printf '%s\n' "$DOUT" | grep -c '' | tr -d ' ')"

STATUS="$(field_of status)"
case "$STATUS" in
    phase1_done|blocked_sub_issue|error) pass "dispatch/status-in-vocabulary" ;;
    *) fail "dispatch/status-in-vocabulary" "status='$STATUS' output=$(printf '%q' "$DOUT")" ;;
esac

# The quoted-triple renderer is part of the inherited output contract.
case "$(field_of summary)" in
    '"'*'"') pass "dispatch/summary-is-quoted" ;;
    *) fail "dispatch/summary-is-quoted" "summary=$(field_of summary)" ;;
esac
case "$(field_of artifact_path)" in
    '"'*'"') pass "dispatch/artifact-is-quoted" ;;
    *) fail "dispatch/artifact-is-quoted" "artifact_path=$(field_of artifact_path)" ;;
esac

# PATH really reached the grandchild: if it had not, the real `gh` (or none at
# all) would have run and this log would be empty — every assertion above would
# then be measuring the wrong process.
if [ -s "$GHLOG" ]; then
    pass "dispatch/gh-stub-was-reached"
else
    fail "dispatch/gh-stub-was-reached" "no gh invocation recorded; PATH did not propagate"
fi

# The chain runs INSIDE the linked worktree, not in main-root.
CWD_LINE="$(head -1 "$GHLOG" 2>/dev/null | sed -n 's/^cwd=\([^ ]*\) .*/\1/p')"
if [ -n "$CWD_LINE" ]; then
    assert_eq "dispatch/child-cwd-is-linked-worktree" "$(nodepath "$LINKED_RAW")" "$(nodepath "$CWD_LINE")"
else
    fail "dispatch/child-cwd-is-linked-worktree" "no cwd recorded in $GHLOG"
fi

# Dry run: nothing in either worktree was modified.
if [ -z "$(git -C "$LINKED_RAW" status --porcelain 2>/dev/null)" ]; then
    pass "dispatch/no-worktree-mutation"
else
    fail "dispatch/no-worktree-mutation" "$(git -C "$LINKED_RAW" status --porcelain)"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
