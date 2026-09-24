#!/bin/bash
# tests/fix-1899-parse-remote-url/redaction.sh
# Tests: hooks/lib/parse-remote-url.js
# Tags: parse-remote-url, security, secret-redaction, table-driven, TL1, scope:issue-specific
#
# Groups H and I of the fix-1899-parse-remote-url split suite — credential
# redaction. F2 [MEDIUM]: parseOriginOwnerRepo parsed the TRIMMED url but redacted
# the UNTRIMMED one, and redactUserinfo's SCP branch is anchored (^), so a
# leading-whitespace SCP url bearing a token skipped redaction and the raw token
# landed verbatim in the failure .message. F3 [MEDIUM]: redactUserinfo itself had
# zero coverage.
#
# Every credential here is a FAKE placeholder — short enough that
# bin/scan-outbound.sh's github-token pattern cannot read it as live.
#
# TL3 gap: no proof that a real `git remote get-url origin` on a token-bearing
# checkout routes through this redaction before reaching a log.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group H — F2 [MEDIUM]: the redaction must run on the same string the parser did
#
#   One leading space defeats redaction entirely and the credential is echoed
#   verbatim in .message — which callers put into logs and NEXT_HINT lines.
#   FAKE placeholder credential only: 16 chars after `ghp_`, well under the 36
#   bin/scan-outbound.sh's github-token pattern needs, so it cannot read as live.
# ===========================================================================
group_redaction_on_failure_message() {
    local fake='ghp_EXAMPLEEXAMPLE'
    # SCP form carrying credentials in the user position: <user>@<host>:<path>.
    local scp_url="x-access-token:${fake}@github.com:notarepo"
    local msg

    # CONTROL: no leading whitespace — this path already redacts today. If this
    # one ever goes red the harness itself is broken, not F2.
    msg="$(call_fail_message "$scp_url")"
    case "$msg" in
        *"$fake"*) fail "redact/control-no-whitespace-hides-token — token present in message" ;;
        ERR:*) fail "redact/control-no-whitespace-hides-token — helper error: $msg" ;;
        *) pass "redact/control-no-whitespace-hides-token" ;;
    esac

    # F2: identical URL, two leading spaces. Must still redact.
    msg="$(call_fail_message "  $scp_url")"
    case "$msg" in
        *"$fake"*) fail "redact/leading-whitespace-hides-token — raw token leaked into .message: $(printf '%q' "$msg")" ;;
        ERR:*) fail "redact/leading-whitespace-hides-token — helper error: $msg" ;;
        *) pass "redact/leading-whitespace-hides-token" ;;
    esac
    case "$msg" in
        *'***@'*) pass "redact/leading-whitespace-emits-mask" ;;
        *) fail "redact/leading-whitespace-emits-mask — no '***@' in message: $(printf '%q' "$msg")" ;;
    esac

    # CONTROL 2: the scheme form reaches the message through the unanchored
    # branch, so leading whitespace never defeated it. Green today and after the
    # fix — it pins that the F2 repair does not regress the branch that worked.
    msg="$(call_fail_message "  https://x-access-token:${fake}@github.com/onlyowner")"
    case "$msg" in
        *"$fake"*) fail "redact/control-scheme-form-with-whitespace — raw token leaked into .message" ;;
        ERR:*) fail "redact/control-scheme-form-with-whitespace — helper error: $msg" ;;
        *) pass "redact/control-scheme-form-with-whitespace" ;;
    esac
}

# ===========================================================================
# Group I — F3 [MEDIUM]: redactUserinfo table-driven suite (was zero coverage).
#   The NEGATIVE row is load-bearing: the SCP branch is anchored on purpose so an
#   ordinary email mid-sentence in a log line is NOT rewritten. Unanchoring it to
#   "fix" F2 would break that row — F2 must be fixed at the trim site instead.
# ===========================================================================
group_redact_userinfo() {
    local name input want got
    while IFS='|' read -r name input want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        input="$(echo "$input" | xargs)"
        [ "$want" = "__EMPTY__" ] && want=""
        got="$(call_fn "$PRU_JS" redactUserinfo "$input")"
        assert_eq "redactUserinfo/$name" "$want" "$got"
    done <<'TABLE'
# name              | input                                                        | expected output
https-token         | https://x-access-token:ghp_EXAMPLEEXAMPLE@example.com/a/b.git | https://***@example.com/a/b.git
https-user-pass     | https://user:pw@example.com/a/b.git                           | https://***@example.com/a/b.git
ssh-scheme-userinfo | ssh://git@example.com/a/b.git                                 | ssh://***@example.com/a/b.git
scp-form            | git@example.com:a/b.git                                       | ***@example.com:a/b.git
scp-form-token      | x-access-token:ghp_EXAMPLEEXAMPLE@example.com:a/b.git         | ***@example.com:a/b.git
no-userinfo         | https://github.com/a/b                                       | https://github.com/a/b
no-userinfo-plain   | github.com/a/b                                               | github.com/a/b
mid-sentence-url    | origin is https://u:p@example.com/a/b.git today               | origin is https://***@example.com/a/b.git today
leading-scp-in-text | git@example.com:a/b.git is the origin url                     | ***@example.com:a/b.git is the origin url
empty-string        | __EMPTY__                                                    | __EMPTY__
# NEGATIVE — a bare email in prose is NOT a remote URL and must survive intact.
email-in-prose      | contact someone@example.com for help                         | contact someone@example.com for help
email-at-start      | someone@example.com wrote the patch                          | ***@example.com wrote the patch
TABLE

    # Non-string inputs: returned unchanged, never coerced and never thrown on.
    assert_eq "redactUserinfo/null-input"      "NULL"      "$(call_redact_expr 'null')"
    assert_eq "redactUserinfo/undefined-input" "UNDEFINED" "$(call_redact_expr 'undefined')"
    assert_eq "redactUserinfo/number-input"    "number:123" "$(call_redact_expr '123')"
}

group_redaction_on_failure_message
group_redact_userinfo

finish
