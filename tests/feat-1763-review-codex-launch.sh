#!/usr/bin/env bash
# tests/feat-1763-review-codex-launch.sh
# Tests: bin/github-issues/review-survey-verdict-codex.sh
# Tags: issue-create, verdict, review, codex, web-search, toggle-removal, prompt-contract, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - A real `codex exec` accepting `-c tools.web_search=true` and actually reaching the
#   network; here codex is a mock that only records its argv and stdin.
# - Whether the search queries a real reviewer composes honour the leak-prevention
#   instruction — only the instruction's presence in the prompt is checkable offline.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Two launch-side changes land together in this PR:
#   1. The reviewer CAN be launched with web search (`-c tools.web_search=true`), so it
#      can check whether an upstream fix or a known issue already exists — but only when
#      ISSUE_VERDICT_WEB_SEARCH is turned on. The default is off, because a query is an
#      outbound channel the prompt can only ask codex not to misuse.
#   2. When search IS enabled the prompt becomes that outbound channel: the candidate
#      bodies and the proposal are private-repo prose, and a query is sent to a third
#      party. The prompt must therefore forbid putting repository identifiers into
#      queries — and, symmetrically, must not advertise search when it is off, or the
#      reviewer would be told to use a tool it was never given.
# And one removal: the ISSUE_VERDICT_REVIEW switch is gone, so setting it must have no
# effect at all — a leftover read would leave a way to silently disable the review.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RS="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
red()  { fail "$1" "RED-EXPECTED: bin/github-issues/review-survey-verdict-codex.sh not found"; }

RS_PRESENT=no; [ -f "$RS" ] && RS_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

# codex mock: records argv (one arg per line) and the prompt it received on stdin.
cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CODEX_ARGV_LOG:-/dev/null}"
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
if [ -n "${CODEX_MOCK_OUT:-}" ] && [ -f "$CODEX_MOCK_OUT" ]; then cat "$CODEX_MOCK_OUT"; fi
exit "${CODEX_MOCK_RC:-0}"
MOCK
chmod +x "$MOCKDIR/codex"

ART="$WORK/survey.json"
cat > "$ART" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "Reviewer must not leak the repo name", "background": "BG", "changes": "CH" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey reason",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": "open", "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "closed", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

REVIEW_OK='{"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true}'

# run_review <case> [env assignments...] → RC / OUT / LAST / ARGV / PROMPT
run_review() {
    local name="$1"; shift
    CASE_DIR="$WORK/$name"; mkdir -p "$CASE_DIR"
    printf '%s' "$REVIEW_OK" > "$CASE_DIR/codex-out.txt"
    ARGV="$CASE_DIR/argv.txt"; PROMPT="$CASE_DIR/prompt.txt"; FINAL="$CASE_DIR/final.json"
    [ "$RS_PRESENT" = "yes" ] || { RC=127; OUT=''; LAST=''; return 0; }
    OUT=$(env "$@" \
            CODEX_MOCK_OUT="$CASE_DIR/codex-out.txt" \
            CODEX_ARGV_LOG="$ARGV" CODEX_PROMPT_LOG="$PROMPT" \
            PATH="$MOCKDIR:$PATH" \
            "$RWT" 40 bash "$RS" --artifact "$ART" --out "$FINAL" --no-log 2>"$CASE_DIR/stderr.txt")
    RC=$?
    LAST=$(printf '%s\n' "$OUT" | grep -E '^review_result:' | tail -n 1)
}

echo "=== W1: web search is OFF by default — no flag, and the prompt never offers it ==="
# ISSUE_VERDICT_WEB_SEARCH is passed empty so an operator's exported value cannot decide
# this case: emptiness sends the script down its configured-default path, which ships off.
# The launch flag and the prompt text are asserted together because they are one decision
# read twice — a script that adds the flag but not the instructions (or the reverse) is
# broken in a way neither assertion alone would show.
run_review w1 ISSUE_VERDICT_WEB_SEARCH=
if [ "$RS_PRESENT" != "yes" ]; then
    red "W1-argv-has-no-web-search-config"; red "W1-argv-still-exec-skip-git"
    red "W1-review-performed"; red "W1-prompt-omits-search-offer"
else
    if [ -s "$ARGV" ] && ! grep -qxF -- 'tools.web_search=true' "$ARGV"; then
        pass "W1-argv-has-no-web-search-config"
    else
        fail "W1-argv-has-no-web-search-config" "codex argv must NOT carry 'tools.web_search=true' by default (got: $(tr '\n' ' ' < "$ARGV" 2>/dev/null))"
    fi
    # The toggle must gate ONLY the flag, not the existing launch shape.
    if grep -qxF -- 'exec' "$ARGV" && grep -qxF -- '--skip-git-repo-check' "$ARGV"; then
        pass "W1-argv-still-exec-skip-git"
    else
        fail "W1-argv-still-exec-skip-git" "the existing 'exec --skip-git-repo-check' launch shape regressed (got: $(tr '\n' ' ' < "$ARGV" 2>/dev/null))"
    fi
    [ "$LAST" = "review_result: upheld" ] && pass "W1-review-performed" \
        || fail "W1-review-performed" "want 'review_result: upheld' (got: '${LAST:-<none>}')"
    # Offering a tool the launch did not grant would spend the reviewer's attention on a
    # capability it does not have, and invites a worth_filing:false justified by a search
    # it never ran.
    # Plain -i regex, not -iF: some grep builds (Git Bash) abort on the -i + -F pair,
    # and an aborting grep would satisfy this negative assertion for the wrong reason.
    if [ -s "$PROMPT" ] && ! grep -qi 'You MAY use web search' "$PROMPT"; then
        pass "W1-prompt-omits-search-offer"
    else
        fail "W1-prompt-omits-search-offer" "with search off the prompt must not tell the reviewer it may search"
    fi
fi

echo ""
echo "=== W2: opt-in ON adds the flag AND forbids repo identifiers in queries ==="
# With search on, whatever the reviewer types into a query leaves the machine. The
# candidate bodies and the proposal come from a repository that may be private, so the
# prompt has to state the constraint explicitly — the model has no other way to know
# which parts of its context are outbound-unsafe.
run_review w2 ISSUE_VERDICT_WEB_SEARCH=on
if [ "$RS_PRESENT" != "yes" ] || [ ! -s "${PROMPT:-/nonexistent}" ]; then
    red "W2-argv-has-web-search-config"; red "W2-prompt-mentions-search"
    red "W2-prompt-prohibits-identifiers"; red "W2-prompt-names-what-to-omit"
else
    if grep -qxF -- '-c' "$ARGV" && grep -qxF -- 'tools.web_search=true' "$ARGV"; then
        pass "W2-argv-has-web-search-config"
    else
        fail "W2-argv-has-web-search-config" "ISSUE_VERDICT_WEB_SEARCH=on must add '-c tools.web_search=true' (got: $(tr '\n' ' ' < "$ARGV" 2>/dev/null))"
    fi
    grep -qiE 'web[ _-]?search|search quer' "$PROMPT" \
        && pass "W2-prompt-mentions-search" \
        || fail "W2-prompt-mentions-search" "the prompt never tells the reviewer that search is available"
    grep -qiE 'do not|never|must not|禁止' "$PROMPT" \
        && pass "W2-prompt-prohibits-identifiers" \
        || fail "W2-prompt-prohibits-identifiers" "the prompt carries no prohibition wording around search"
    # The three identifiers that would make a query traceable back to the repository.
    MISSING=''
    grep -qiE 'repositor|repo name' "$PROMPT" || MISSING="$MISSING repo-name"
    grep -qiE 'url' "$PROMPT"                 || MISSING="$MISSING url"
    grep -qiE 'issue number|#[0-9]'  "$PROMPT" || MISSING="$MISSING issue-number"
    if [ -z "$MISSING" ]; then
        pass "W2-prompt-names-what-to-omit"
    else
        fail "W2-prompt-names-what-to-omit" "the prompt must name each identifier to keep out of queries; missing:$MISSING"
    fi
fi

echo ""
echo "=== W3: the deleted ISSUE_VERDICT_REVIEW switch no longer disables anything ==="
# The switch is removed in this PR. If any read of it survives, the review silently
# becomes optional again — and an env var left over in a developer's .env would turn
# the gate's most informative input off without a single visible symptom.
run_review w3 ISSUE_VERDICT_REVIEW=off
if [ "$RS_PRESENT" != "yes" ]; then
    red "W3-off-does-not-skip"; red "W3-off-still-invokes-codex"
else
    [ "$LAST" = "review_result: upheld" ] && pass "W3-off-does-not-skip" \
        || fail "W3-off-does-not-skip" "ISSUE_VERDICT_REVIEW=off must have no effect; want 'review_result: upheld' (got: '${LAST:-<none>}')"
    [ -s "$PROMPT" ] && pass "W3-off-still-invokes-codex" \
        || fail "W3-off-still-invokes-codex" "codex was never invoked — a removed switch still gates the review"
fi

echo ""
echo "=== W4: the review timeout is read from CODEX_TIMEOUT_SECS ==="
# The old ISSUE_VERDICT_REVIEW_TIMEOUT_SECS name is retired with the switch it was
# named after. A wrapper that still read the old name would silently fall back to the
# default, so the rename has to be observable rather than cosmetic.
if [ "$RS_PRESENT" != "yes" ]; then
    red "W4-new-timeout-name-honoured"; red "W4-old-timeout-name-gone"
else
    cat > "$MOCKDIR/codex" <<'SLOW'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CODEX_ARGV_LOG:-/dev/null}"
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
sleep 10
SLOW
    chmod +x "$MOCKDIR/codex"

    # Elapsed time is the discriminating assertion, not the verdict: a wrapper that
    # ignores CODEX_TIMEOUT_SECS still folds to invalid once the 10s mock finishes with
    # no output, so "invalid" alone would be green against an unread variable.
    T0=$(date +%s)
    run_review w4 CODEX_TIMEOUT_SECS=2
    ELAPSED=$(( $(date +%s) - T0 ))
    if [ "$LAST" = "review_result: invalid" ] && [ "$ELAPSED" -lt 8 ]; then
        pass "W4-new-timeout-name-honoured (elapsed=${ELAPSED}s)"
    else
        fail "W4-new-timeout-name-honoured" "CODEX_TIMEOUT_SECS=2 must cut the 10s reviewer short and fold to invalid (got: '${LAST:-<none>}', elapsed=${ELAPSED}s)"
    fi

    if grep -qF 'ISSUE_VERDICT_REVIEW_TIMEOUT_SECS' "$RS"; then
        fail "W4-old-timeout-name-gone" "the retired ISSUE_VERDICT_REVIEW_TIMEOUT_SECS name is still read by the script"
    else
        pass "W4-old-timeout-name-gone"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
