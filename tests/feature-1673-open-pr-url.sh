#!/usr/bin/env bash
# tests/feature-1673-open-pr-url.sh
# Tests: bin/open-pr-url.js, hooks/lib/open-external.js, skills/commit-push/SKILL.md, hooks/pr-created-open.js
# Tags: worker-dispatch, commit-push, pr-url, open-external, url-validation, fail-open, TL2, scope:issue-specific
#
# Issue #1673 D2 — replacing a PostToolUse hook that no longer fires.
#
# hooks/pr-created-open.js reacted to a Bash-tool `gh pr create`. Once that call
# moves inside a dispatcher child it is no longer a tool invocation, so the hook
# never runs: the browser does not open and the PR URL never reaches the user.
# bin/open-pr-url.js restores the reachable half, and skills/commit-push/SKILL.md
# CP-2b restores the visible half by putting the URL in the turn's final response.
#
# What is deliberately NOT restored: the "Click Allow to proceed, Deny to abort"
# line. It belonged to a tool-permission dialog that no longer exists at that
# point, and leaving the words in would advertise a decision the user is not
# being offered. Group B pins its absence so a copy-paste from the old hook is
# caught rather than shipped.
#
# openInBrowser is diverted through its own documented test mode
# (SHOW_USER_VERIFIED_NO_SPAWN / SHOW_USER_VERIFIED_MARKER_FILE) rather than
# through a duplicate stub, so the SSOT this CLI shares with the hook is the code
# actually exercised.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real browser process starting. openInBrowser's spawn path is diverted
#     here, and no tier of this suite launches a real browser — the marker file
#     is the boundary of what is mechanically checkable.
#   - The SKILL.md CP-2b instruction actually being followed by a live model.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_CP1673_PRURL_INNER:-}" ]; then
    _CP1673_PRURL_INNER=1 timeout 180 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPEN_PR_JS="$AGENTS_DIR/bin/open-pr-url.js"
OPEN_EXTERNAL_JS="$AGENTS_DIR/hooks/lib/open-external.js"
SKILL_MD="$AGENTS_DIR/skills/commit-push/SKILL.md"

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

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/cp1673-prurl-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MARKER="$TMPD/opened.json"
COUT=""
CRC=0
OPENED_URL=""

# run_cli <arg-or-empty> — sets COUT / CRC / OPENED_URL
run_cli() {
    rm -f "$MARKER"
    CRC=0
    if [ "$#" -eq 0 ]; then
        COUT="$(run_with_timeout 60 env "SHOW_USER_VERIFIED_NO_SPAWN=1" \
            "SHOW_USER_VERIFIED_MARKER_FILE=$(nodepath "$MARKER")" \
            node "$(nodepath "$OPEN_PR_JS")" 2>&1)" || CRC=$?
    else
        COUT="$(run_with_timeout 60 env "SHOW_USER_VERIFIED_NO_SPAWN=1" \
            "SHOW_USER_VERIFIED_MARKER_FILE=$(nodepath "$MARKER")" \
            node "$(nodepath "$OPEN_PR_JS")" "$1" 2>&1)" || CRC=$?
    fi
    if [ -f "$MARKER" ]; then
        OPENED_URL="$(node -e '
          const fs = require("fs");
          try {
            const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            process.stdout.write(String((m.args || [])[0]));
          } catch (_e) { process.stdout.write("(unreadable-marker)"); }
        ' "$(nodepath "$MARKER")")"
    else
        OPENED_URL="(not-opened)"
    fi
}

impl_present() {
    if [ -f "$OPEN_PR_JS" ]; then return 0; fi
    fail "$1" "implementation missing: bin/open-pr-url.js"
    return 1
}

# ===========================================================================
# Group A — a well-formed PR URL is opened exactly once and announced
# ===========================================================================
GOOD_URL="https://github.com/nirecom/agents/pull/1711"

group_valid() {
    impl_present "valid/opens-the-url" || { fail "valid/announces-pr-number" "implementation missing"; return; }
    run_cli "$GOOD_URL"
    assert_eq "valid/exit0" "0" "$CRC"
    assert_eq "valid/opens-the-url" "$GOOD_URL" "$OPENED_URL"
    assert_eq "valid/announces-pr-number" "PR #1711 created: $GOOD_URL" "$(printf '%s' "$COUT" | head -1)"
    # http:// is accepted by the same regex the old hook used — keeping the two
    # in step is the point of reusing the pattern rather than tightening it here.
    run_cli "http://github.com/nirecom/agents/pull/42"
    assert_eq "valid/http-scheme-opens" "http://github.com/nirecom/agents/pull/42" "$OPENED_URL"
    assert_eq "valid/http-scheme-announced" "PR #42 created: http://github.com/nirecom/agents/pull/42" "$(printf '%s' "$COUT" | head -1)"
}

# ===========================================================================
# Group B — the deliberate wording difference from pr-created-open.js
# ===========================================================================
group_wording() {
    impl_present "wording/no-allow-deny-prompt" || { fail "wording/no-deny-wording" "implementation missing"; return; }
    run_cli "$GOOD_URL"
    case "$COUT" in
        *"Click Allow"*) fail "wording/no-allow-deny-prompt" "the retired permission-dialog wording is still emitted" ;;
        *) pass "wording/no-allow-deny-prompt" ;;
    esac
    case "$COUT" in
        *"Deny to abort"*) fail "wording/no-deny-wording" "the retired permission-dialog wording is still emitted" ;;
        *) pass "wording/no-deny-wording" ;;
    esac
    # Non-vacuity: the old hook DOES carry that wording, so the greps above are
    # matching something that exists rather than a typo of my own.
    if [ -f "$AGENTS_DIR/hooks/pr-created-open.js" ] && grep -qF "Click Allow" "$AGENTS_DIR/hooks/pr-created-open.js"; then
        pass "wording/old-hook-still-has-it (grep is live)"
    else
        fail "wording/old-hook-still-has-it (grep is live)" \
            "hooks/pr-created-open.js no longer contains 'Click Allow' — the assertions above prove nothing"
    fi
}

# ===========================================================================
# Group C — fail-open on anything that is not a github.com PR URL
#
# This CLI runs after a successful push. Exiting non-zero, or opening whatever it
# was handed, would turn a cosmetic problem into a broken commit-push run.
# ===========================================================================
group_reject() {
    impl_present "reject/(all rows)" || return
    local name arg
    while IFS='|' read -r name arg; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        arg="$(echo "$arg" | xargs)"
        case "$arg" in
            NOARG) run_cli ;;
            EMPTY) run_cli "" ;;
            *) run_cli "$arg" ;;
        esac
        assert_eq "reject/$name/exit0" "0" "$CRC"
        assert_eq "reject/$name/nothing-opened" "(not-opened)" "$OPENED_URL"
        case "$COUT" in
            *" created: "*) fail "reject/$name/no-announcement" "announced a PR for a rejected input: $COUT" ;;
            *) pass "reject/$name/no-announcement" ;;
        esac
    done <<'TABLE'
no-arg               | NOARG
empty-string         | EMPTY
not-a-url            | not-a-url-at-all
wrong-host           | https://evil.example.com/nirecom/agents/pull/1711
host-suffix-spoof    | https://github.com.evil.example.com/o/r/pull/1
non-numeric-number   | https://github.com/nirecom/agents/pull/abc
issues-not-pull      | https://github.com/nirecom/agents/issues/1711
trailing-segment     | https://github.com/nirecom/agents/pull/1711/files
javascript-scheme    | javascript:alert(1)
file-scheme          | file:///etc/passwd
TABLE
}

# ===========================================================================
# Group D — SKILL.md CP-2b, the other half of D2
# ===========================================================================
group_skill() {
    if [ ! -f "$SKILL_MD" ]; then
        fail "skill/cp-2b-exists" "missing skills/commit-push/SKILL.md"
        return
    fi
    local cp2b
    # CP-2b runs from the "CP-2b" label to the next top-level step label.
    cp2b="$(awk '/^ *CP-2b\./ {f=1} f && /^ *CP-3\./ {f=0} f' "$SKILL_MD")"
    if [ -n "$cp2b" ]; then pass "skill/cp-2b-exists"
    else fail "skill/cp-2b-exists" "no CP-2b step found in skills/commit-push/SKILL.md"; return; fi

    case "$cp2b" in
        *open-pr-url.js*) pass "skill/cp-2b-calls-the-cli" ;;
        *) fail "skill/cp-2b-calls-the-cli" "CP-2b never names bin/open-pr-url.js" ;;
    esac
    # Faithful equivalence with the retired hook: it only ever reacted to
    # `gh pr create`, so a reused PR must not re-open a browser tab.
    case "$cp2b" in
        *pr_created*) pass "skill/cp-2b-gated-on-pr-created" ;;
        *) fail "skill/cp-2b-gated-on-pr-created" "CP-2b is not gated on the pr_created status" ;;
    esac
    case "$cp2b" in
        *pr_reused*) pass "skill/cp-2b-mentions-pr-reused-exclusion" ;;
        *) fail "skill/cp-2b-mentions-pr-reused-exclusion" "CP-2b does not say pr_reused is excluded" ;;
    esac
    # codex C6: the dialog is gone, so the URL has to arrive in the response text.
    case "$cp2b" in
        *"final response"*|*"最終応答"*) pass "skill/cp-2b-requires-url-in-final-response" ;;
        *) fail "skill/cp-2b-requires-url-in-final-response" \
                "CP-2b does not require the PR URL to appear in the turn's final response" ;;
    esac
    # The superseded claim must not stay behind and contradict CP-2b.
    if grep -qF 'pr-created-open.js` PostToolUse hook automatically opens' "$SKILL_MD"; then
        fail "skill/stale-posttooluse-claim-removed" \
            "SKILL.md still claims the PostToolUse hook opens the PR — it cannot fire on the dispatcher path"
    else
        pass "skill/stale-posttooluse-claim-removed"
    fi
}

if [ ! -f "$OPEN_EXTERNAL_JS" ]; then
    fail "0/prerequisite" "missing hooks/lib/open-external.js — the SSOT this CLI must reuse"
fi

group_valid
group_wording
group_reject
group_skill

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
