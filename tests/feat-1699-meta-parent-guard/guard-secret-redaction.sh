# tests/feat-1699-meta-parent-guard/guard-secret-redaction.sh
# Tests: bin/github-issues/lib/require-meta-parent.sh, bin/github-issues/issue-create-dispatch.sh
# Tags: issue-create, meta-parent, guard, security, redaction, credentials, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - What real `gh` actually prints on a failed lookup. The canaries here reproduce the
#   documented GH_DEBUG=api shape (request line + Authorization header); only a real host
#   can confirm the exact text a given gh version emits.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Group T — the guard must not relay the forge client's raw output.
#
# Why (CPR-WPH): require-meta-parent.sh captures `gh issue view ... 2>&1` into one variable
# so a failed lookup can be explained, then re-emits that capture. The capture is the
# CLIENT's output, not the guard's — and the client's output is not under the guard's
# control. With GH_DEBUG=api set (the standard way an operator debugs a failing gh call)
# that text includes the outgoing request headers, and the outgoing request headers include
# `Authorization: token <the user's PAT>`. One diagnostic run then prints a live credential
# into the terminal, the CI log, and anything downstream that captures dispatcher stderr.
#
# The contract asserted here is narrow and does not require the guard to go quiet: it may
# say the lookup failed and why, but it must not pass credential-shaped material through
# verbatim. Both channels are checked, because either one alone is a leak.
#
# Canaries are assembled from fragments at runtime so no credential-shaped literal is ever
# stored in this file — the outbound scanner would (correctly) object to one, and a test
# that has to be exempted from a security check is the wrong test.

TOK_CANARY="gh""p_"'CANARYcanary0000000000000000000000000'
HDR_CANARY="Authorization: token ${TOK_CANARY}"

setup_mock
export GH_MOCK_VIEW_FAIL=1
# The multi-line shape a real GH_DEBUG=api run produces: a request line, the headers, and
# only then the error the user was actually looking for.
GH_MOCK_VIEW_FAIL_MSG="$(printf '> GET /repos/nirecom/agents/issues/99 HTTP/1.1\n> %s\n> User-Agent: GitHub CLI\nerror: HTTP 404 (issue not found)' "$HDR_CANARY")"
export GH_MOCK_VIEW_FAIL_MSG

bash "$RWT" 30 bash "$GUARD" 99 >"$TMP/t.out" 2>"$TMP/t.err"; rc=$?
T_OUT="$(cat "$TMP/t.out")"
T_ERR="$(cat "$TMP/t.err")"

# Positive control: the leak path only exists on the indeterminate branch, so a case that
# never reached rc 4 would report a false green on every absence below.
if [ "$rc" -eq 4 ]; then
    pass "T1-lookup-failure-reached-the-indeterminate-branch"
else
    fail "T1-lookup-failure-reached-the-indeterminate-branch" "want guard rc 4 (got: $rc) — the branch that relays client output was not exercised; stderr: $T_ERR"
fi

# Second positive control: the canary must genuinely have been in the client's output.
# Without this, T3/T4 would pass on a mock that quietly dropped GH_MOCK_VIEW_FAIL_MSG.
if printf '%s' "$GH_MOCK_VIEW_FAIL_MSG" | grep -qF -- "$TOK_CANARY"; then
    pass "T2-canary-was-present-in-the-client-output"
else
    fail "T2-canary-was-present-in-the-client-output" "the injected client output does not contain the canary — the case cannot detect a leak"
fi

if printf '%s' "$T_ERR" | grep -qF -- "$TOK_CANARY"; then
    fail "T3-token-canary-not-relayed-to-stderr" "the credential-shaped canary from the gh client's output was re-emitted verbatim on the guard's stderr — with GH_DEBUG=api this is the operator's real token; stderr: $T_ERR"
else
    pass "T3-token-canary-not-relayed-to-stderr"
fi

if printf '%s' "$T_ERR" | grep -qi '^[>[:space:]]*authorization:'; then
    fail "T4-authorization-header-not-relayed-to-stderr" "an Authorization header line from the client's output reached the guard's stderr: $T_ERR"
else
    pass "T4-authorization-header-not-relayed-to-stderr"
fi

if printf '%s' "$T_OUT" | grep -qF -- "$TOK_CANARY"; then
    fail "T5-token-canary-not-on-stdout" "the canary reached stdout, which callers parse and log: $T_OUT"
else
    pass "T5-token-canary-not-on-stdout"
fi

# The guard must still explain itself. Redaction that also removes the diagnosis would
# trade one defect for another — the operator has to learn that the lookup failed.
if printf '%s' "$T_ERR" | grep -qi 'indeterminate'; then
    pass "T6-failure-is-still-explained"
else
    fail "T6-failure-is-still-explained" "the guard must still say the lookup could not be completed: $T_ERR"
fi
teardown_mock

# --- T7: the same output travelling through the dispatcher -----------------------------
# The guard is never run by hand in production; the dispatcher runs it, and the dispatcher's
# stderr is what a skill captures into a log or a notes file. The leak has to be absent at
# the point where the text actually becomes durable.
setup_mock
export GH_MOCK_VIEW_FAIL=1
export GH_MOCK_VIEW_FAIL_MSG="$(printf '> GET /repos/nirecom/agents/issues/99 HTTP/1.1\n> %s\nerror: HTTP 404 (issue not found)' "$HDR_CANARY")"
run_dispatch --verdict sub-of --parent 99 -- --title "child" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 1 ]; then
    pass "T7-dispatcher-fails-closed-on-the-canary-run"
else
    fail "T7-dispatcher-fails-closed-on-the-canary-run" "want rc 1 (fail CLOSED) from an indeterminate lookup (got: $RC)"
fi
if printf '%s' "$ERR" | grep -qF -- "$TOK_CANARY"; then
    fail "T7b-canary-not-in-dispatcher-stderr" "the canary reached the dispatcher's stderr, the stream a skill captures verbatim; stderr: $ERR"
else
    pass "T7b-canary-not-in-dispatcher-stderr"
fi
if printf '%s' "$OUT" | grep -qF -- "$TOK_CANARY"; then
    fail "T7c-canary-not-in-dispatcher-stdout" "the canary reached the dispatcher's stdout, which the caller treats as the URL contract; stdout: $OUT"
else
    pass "T7c-canary-not-in-dispatcher-stdout"
fi
# Any file the run left behind counts as an artifact: temp bodies, call logs, manifests.
# `gh-args.log` is excluded — it records the mock's own argv, not the guard's output.
leaked_files=""
for f in $(find "$TMP" -type f ! -name 'gh-args.log' 2>/dev/null); do
    grep -qF -- "$TOK_CANARY" "$f" 2>/dev/null && leaked_files="$leaked_files $f"
done
if [ -z "$leaked_files" ]; then
    pass "T7d-canary-not-in-any-artifact-left-on-disk"
else
    fail "T7d-canary-not-in-any-artifact-left-on-disk" "the canary was written to:$leaked_files"
fi
teardown_mock

# --- Paired gaps (Pattern 3, skills/_shared/test-design/protection-fix-tests.md) -------
# SKIPPED: a real `gh` run under GH_DEBUG=api against github.com with a live token.
# Because: it requires a real credential; a test must never handle one.
# L3 gap:  only such a run confirms the exact text modern gh emits, and therefore whether
#          a redaction pattern written against the shape above still matches it.
