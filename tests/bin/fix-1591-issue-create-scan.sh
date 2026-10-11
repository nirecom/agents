#!/bin/bash
# tests/bin/fix-1591-issue-create-scan.sh
# Tests: bin/github-issues/issue-create.sh
# Tags: github, issues, scan-outbound, security, scope:issue-specific, layer:TL2
#
# Issue #1591 — issue-create.sh composes $TITLE + (body-file contents or $BODY)
# into one temp file and guards it before the real gh issue create. A blocked
# pattern in ANY field aborts (exit 1) before gh is invoked; body-file CONTENT is
# scanned (not just its filename). All-clean reaches gh.
# ISSUE_CREATE_SKIP_SCHEMA=1 isolates the guard from the Background/Changes schema check.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IC="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create.sh"
GUARD_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/gh-outbound-guard.sh"
REAL_SCANNER="$SCRIPT_CHECKOUT_ROOT/bin/scan-outbound.sh"

# Keep workflow state and plans inside a throwaway dir, never the live ~/.workflow-*.
ISO_ROOT="$(mktemp -d)"
readonly ISO_ROOT
trap 'rm -rf "$ISO_ROOT"' EXIT
export WORKFLOW_STATE_DIR="$ISO_ROOT/state" WORKFLOW_PLANS_DIR="$ISO_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMP=""

setup() {
    TMP="$(mktemp -d)"
    export MOCK_LOG_DIR="$TMP"
    mkdir -p "$TMP/mock-bin" "$TMP/fake_main_root/bin"
    cp "$REAL_SCANNER" "$TMP/fake_main_root/bin/scan-outbound.sh"
    chmod +x "$TMP/fake_main_root/bin/scan-outbound.sh"
    : > "$TMP/fake_main_root/.private-info-allowlist"
    : > "$TMP/fake_main_root/.private-info-blocklist"
    # is-github-dotcom-remote mock -> non-github (exit 1) so Phase 0a label
    # auto-repair is skipped and no preflight/sync mocks are needed.
    cat > "$TMP/fake_main_root/bin/is-github-dotcom-remote" <<'MOCKREMOTE'
#!/usr/bin/env bash
exit 1
MOCKREMOTE
    chmod +x "$TMP/fake_main_root/bin/is-github-dotcom-remote"
    # gh mock — logs; auth status advertises project scope; issue create returns URL.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$*" in
  auth\ status*) echo "scopes: 'project', 'repo'"; exit 0 ;;
  issue\ create*) echo "https://github.com/nirecom/agents/issues/999"; exit 0 ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_MAIN_ROOT="$TMP/fake_main_root"
    export ISSUE_CREATE_SKIP_SCHEMA=1
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    unset MOCK_LOG_DIR ISSUE_CREATE_SKIP_SCHEMA 2>/dev/null || true
    TMP=""
}

gh_created() { cat "$TMP/gh-calls.log" 2>/dev/null | grep -q "issue create"; }

if [ ! -f "$GUARD_LIB" ]; then
    fail "IC-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# IC-1: blocked pattern ONLY in --title -> abort before gh, exit 1.
setup
RC=0
run_with_timeout 20 bash "$IC" --title "host 10.0.0.1 title" --body "clean body text" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_created; then
    pass "IC-1: blocked --title -> exit 1, gh issue create not reached"
else
    fail "IC-1: expected exit 1 no-create; got rc=$RC created=$(gh_created && echo y || echo n)"
fi
teardown

# IC-2: blocked pattern ONLY in --body -> abort before gh, exit 1.
setup
RC=0
run_with_timeout 20 bash "$IC" --title "clean title" --body "leak 10.0.0.1 here" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_created; then
    pass "IC-2: blocked --body -> exit 1, gh issue create not reached"
else
    fail "IC-2: expected exit 1 no-create; got rc=$RC created=$(gh_created && echo y || echo n)"
fi
teardown

# IC-3: blocked pattern ONLY inside --body-file CONTENTS (filename clean) -> abort.
# Proves body-file content is scanned, not just the path.
setup
BF="$TMP/body.md"; printf 'clean line\ninternal host 10.0.0.1 leaked\n' > "$BF"
RC=0
run_with_timeout 20 bash "$IC" --title "clean title" --body-file "$BF" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_created; then
    pass "IC-3: blocked --body-file CONTENT -> exit 1, gh not reached (content scanned)"
else
    fail "IC-3: expected exit 1 no-create; got rc=$RC created=$(gh_created && echo y || echo n)"
fi
teardown

# IC-4: all-clean -> gh issue create IS reached.
setup
RC=0
run_with_timeout 20 bash "$IC" --title "clean title" --body "perfectly ordinary body" >/dev/null 2>&1 || RC=$?
if gh_created; then
    pass "IC-4: all-clean -> gh issue create reached (rc=$RC)"
else
    fail "IC-4: expected gh issue create reached; got rc=$RC gh='$(cat "$TMP/gh-calls.log" 2>/dev/null)'"
fi
teardown

# IC-5/IC-6 (#2561) run a copy of the checkout whose bin/is-github-dotcom-remote is a stub
# (exit $1); a PATH-first is-github-dotcom-remote leaves a marker and must never run.
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
setup_checkout() {
    CO="$TMP/co"
    mkdir -p "$CO/bin" "$TMP/path-fake"
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$CO/bin/is-github-dotcom-remote"
    chmod +x "$CO/bin/is-github-dotcom-remote"
    script_checkout_fixture_copy "$CO" bin || return 1
    # The copy is outside git, so its scanner reads the lists of the copy itself (never
    # AGENTS_MAIN_ROOT); without a blocklist there it fail-closes with rc 4 (#2589).
    : > "$CO/.private-info-allowlist"
    : > "$CO/.private-info-blocklist"
    printf '#!/usr/bin/env bash\ntouch "%s/path-remote-called"\nexit 0\n' "$TMP" > "$TMP/path-fake/is-github-dotcom-remote"
    chmod +x "$TMP/path-fake/is-github-dotcom-remote"
    # gh: label list reports type:task (preflight rc 0); everything else goes to the mock.
    printf '#!/usr/bin/env bash\ncase "$*" in label\\ list*) echo "gh $*" >> "%s/gh-calls.log"; echo type:task; exit 0 ;; esac\nexec "%s/mock-bin/gh" "$@"\n' "$TMP" "$TMP" > "$TMP/path-fake/gh"
    chmod +x "$TMP/path-fake/gh"
    export PATH="$TMP/path-fake:$PATH"
}

# IC-5: the checkout's is-github-dotcom-remote decides Phase 0a, never the PATH one.
setup
setup_checkout 1
RC=0
run_with_timeout 30 bash "$CO/bin/github-issues/issue-create.sh" --title "clean title" --body "ordinary body" >/dev/null 2>"$TMP/err" || RC=$?
if [ ! -e "$TMP/path-remote-called" ] && grep -q 'skipping label auto-repair' "$TMP/err"; then
    pass "IC-5: the checkout's is-github-dotcom-remote is used; the PATH one is not called"
else
    fail "IC-5: rc=$RC path_called=$([ -e "$TMP/path-remote-called" ] && echo y || echo n) stderr=$(head -3 "$TMP/err")"
fi
teardown

# IC-6: a REPO_OVERRIDE not shaped owner/repo is refused (rc 2) before any gh write;
# a well-formed one is named on stderr when used.
for row in 'not-a-repo|2' 'a/b/c|2' 'a/b;touch x|2' '/repo|2' 'owner/|2' 'owner/repo|ok'; do
    ov="${row%|*}"; want="${row##*|}"
    setup
    setup_checkout 0
    RC=0
    REPO_OVERRIDE="$ov" run_with_timeout 30 bash "$CO/bin/github-issues/issue-create.sh" --title "clean title" --body "ordinary body" >/dev/null 2>"$TMP/err" || RC=$?
    if [ "$want" = 2 ]; then
        if [ "$RC" -eq 2 ] && ! gh_created && grep -q 'REPO_OVERRIDE' "$TMP/err"; then
            pass "IC-6[$ov]: malformed REPO_OVERRIDE -> rc 2, named on stderr, no issue created"
        else
            fail "IC-6[$ov]: rc=$RC created=$(gh_created && echo y || echo n) stderr=$(head -3 "$TMP/err")"
        fi
    elif grep -qF "$ov" "$TMP/err" && gh_created; then
        pass "IC-6[$ov]: well-formed REPO_OVERRIDE is named on stderr and used"
    else
        fail "IC-6[$ov]: rc=$RC created=$(gh_created && echo y || echo n) stderr=$(head -5 "$TMP/err")"
    fi
    teardown
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
