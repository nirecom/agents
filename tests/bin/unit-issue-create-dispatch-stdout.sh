#!/bin/bash
# tests/bin/unit-issue-create-dispatch-stdout.sh
# Tests: bin/github-issues/issue-create-dispatch.sh
# Tags: issue-create, github, issues, bin, shell, scope:common
# The stdout-URL contract of the dispatcher: N/C/BK pin the caller's extraction pipeline
# (last line, strip \r, trailing digits) on stubbed text; R runs the reopen branch for real.
# L3 gap: real GitHub API (sub_issues POST, GraphQL databaseId), live MSYS_NO_PATHCONV;
# checked at WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh skill-orchestration).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

extract_url() {
    # Mirrors the caller pipeline: last line, strip \r.
    printf '%s' "$1" | tail -n 1 | tr -d '\r'
}

extract_number() {
    # Mirrors the caller pipeline: trailing digit run. May exit non-zero when
    # no match — that is acceptable in the contract.
    printf '%s' "$1" | grep -oE '[0-9]+$' || true
}

extract_all_urls() {
    # bulk-sub-of contract: each success URL on its own line, in manifest order.
    # A caller that wants every URL keeps only lines matching the issue-URL shape.
    # stderr-style progress prefixes are filtered out (caller must redirect stderr;
    # this models the residual case where progress text leaks onto stdout).
    printf '%s' "$1" | tr -d '\r' | grep -E '^https://github\.com/.+/issues/[0-9]+$' || true
}

extract_all_numbers() {
    # Per-URL trailing-digit extraction, preserving manifest order.
    extract_all_urls "$1" | grep -oE '[0-9]+$' || true
}

# ---- N1: single-line URL → number extracted ----
test_N1_single_line_url() {
    local out="https://github.com/owner/repo/issues/7"
    local url; url="$(extract_url "$out")"
    local n;   n="$(extract_number "$url")"
    if [ "$url" = "https://github.com/owner/repo/issues/7" ] && [ "$n" = "7" ]; then
        pass "N1: single-line URL → number '7'"
    else
        fail "N1: url='$url' n='$n'"
    fi
}

# ---- C1: multi-line output → tail -n 1 picks URL ----
test_C1_multi_line_url_last() {
    local out
    out="$(printf '%s\n' \
        "Creating issue..." \
        "Adding to project..." \
        "https://github.com/owner/repo/issues/42")"
    local url; url="$(extract_url "$out")"
    local n;   n="$(extract_number "$url")"
    if [ "$url" = "https://github.com/owner/repo/issues/42" ] && [ "$n" = "42" ]; then
        pass "C1: multi-line output → URL on last line, number '42'"
    else
        fail "C1: url='$url' n='$n'"
    fi
}

# ---- C2: URL with CRLF → tr -d '\r' strips carriage return ----
test_C2_crlf_url() {
    # Build CRLF line via printf.
    local out
    out="$(printf 'https://github.com/owner/repo/issues/13\r\n')"
    local url; url="$(extract_url "$out")"
    local n;   n="$(extract_number "$url")"
    # If \r is not stripped, the trailing-digit regex will not match against
    # "13\r" because \r breaks the $ anchor. Validate both URL and number.
    if [ "$url" = "https://github.com/owner/repo/issues/13" ] && [ "$n" = "13" ]; then
        pass "C2: CRLF URL → '\r' stripped, number '13' extracted"
    else
        # Show byte counts to disambiguate failures.
        local urlbytes
        urlbytes="$(printf '%s' "$url" | wc -c | tr -d ' ')"
        fail "C2: url='$url' (bytes=$urlbytes) n='$n'"
    fi
}

# ---- C3: URL with number 42 ----
test_C3_url_number_42() {
    local out="https://github.com/owner/repo/issues/42"
    local n; n="$(extract_number "$out")"
    if [ "$n" = "42" ]; then
        pass "C3: URL → number '42'"
    else
        fail "C3: n='$n'"
    fi
}

# ---- C4: URL without trailing number → empty result acceptable ----
test_C4_url_no_trailing_number() {
    local out="https://github.com/owner/repo/issues/"
    local n; n="$(extract_number "$out")"
    # extract_number swallows grep's non-zero exit via `|| true`; result is
    # empty string. The contract is: empty (or non-zero raw exit) is
    # acceptable for malformed input.
    if [ -z "$n" ]; then
        pass "C4: URL with no trailing number → empty result"
    else
        fail "C4: expected empty, got n='$n'"
    fi
}

# ---- BK1: 2 URLs on stdout → loop extracts 2 numbers in order ----
test_BK1_two_urls_in_order() {
    local out
    out="$(printf '%s\n' \
        "https://github.com/owner/repo/issues/100" \
        "https://github.com/owner/repo/issues/101")"
    local urls; urls="$(extract_all_urls "$out")"
    local nums; nums="$(extract_all_numbers "$out")"
    local count; count="$(printf '%s\n' "$urls" | grep -c . )"
    local nums_joined; nums_joined="$(printf '%s' "$nums" | paste -sd, -)"
    if [ "$count" = "2" ] && [ "$nums_joined" = "100,101" ]; then
        pass "BK1: 2 URLs → 2 numbers extracted in order (100,101)"
    else
        fail "BK1: count='$count' nums='$nums_joined'"
    fi
}

# ---- BK2: 3 URLs + stderr-style progress prefix mixed → only URLs captured ----
test_BK2_progress_prefix_filtered() {
    # Caller is expected to redirect stderr, but model the residual case where a
    # "Creating child N..." progress line leaks onto stdout: the URL filter must
    # drop it and keep only the 3 well-formed issue URLs in order.
    local out
    out="$(printf '%s\n' \
        "Creating child 1..." \
        "https://github.com/owner/repo/issues/200" \
        "Creating child 2..." \
        "https://github.com/owner/repo/issues/201" \
        "Creating child 3..." \
        "https://github.com/owner/repo/issues/202")"
    local nums; nums="$(extract_all_numbers "$out")"
    local nums_joined; nums_joined="$(printf '%s' "$nums" | paste -sd, -)"
    local count; count="$(extract_all_urls "$out" | grep -c . )"
    if [ "$count" = "3" ] && [ "$nums_joined" = "200,201,202" ]; then
        pass "BK2: progress prefixes filtered → only 3 URLs captured (200,201,202)"
    else
        fail "BK2: count='$count' nums='$nums_joined'"
    fi
}

# ---- BK3: tail -n 1 on 2-URL output → last URL (backward-compat) ----
test_BK3_tail_backward_compat() {
    # Existing single-issue callers use `tail -n 1`. With multi-URL bulk output
    # they still get the LAST URL — they do not break, they just see the final
    # child. This guards the backward-compat contract for non-bulk callers.
    local out
    out="$(printf '%s\n' \
        "https://github.com/owner/repo/issues/300" \
        "https://github.com/owner/repo/issues/301")"
    local url; url="$(extract_url "$out")"
    local n;   n="$(extract_number "$url")"
    if [ "$url" = "https://github.com/owner/repo/issues/301" ] && [ "$n" = "301" ]; then
        pass "BK3: tail -n 1 on 2-URL output → last URL '301' (backward-compat)"
    else
        fail "BK3: url='$url' n='$n'"
    fi
}

# ---- R*: reopen branch run for real (#2019) — a copy of the dispatcher beside fake siblings ----
# stdout carries the URL only on full success; a failed merged-finding comment exits 3 with stdout
# empty, so a caller that annotates from the URL never marks a lost finding as promoted.
R_BASE="$(mktemp -d)"
trap 'rm -rf "$R_BASE"' EXIT
mkdir -p "$R_BASE/gi" "$R_BASE/fakebin" "$R_BASE/cwd"
cp "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create-dispatch.sh" "$R_BASE/gi/issue-create-dispatch.sh"
printf '#!/usr/bin/env bash\nif [[ "$1 $2" == "repo view" ]]; then echo example-owner/example-repo; fi\n' >"$R_BASE/fakebin/gh"
chmod +x "$R_BASE/fakebin/gh"
printf '#!/usr/bin/env bash\necho "reopen $*" >>"%s"\nexit "${R_REOPEN_RC:-0}"\n' "$R_BASE/calls.log" >"$R_BASE/gi/reopen-with-update.sh"
printf '#!/usr/bin/env bash\necho "merge $*" >>"%s"\necho "${R_MERGE_STDOUT:-}"\nexit "${R_MERGE_RC:-0}"\n' "$R_BASE/calls.log" >"$R_BASE/gi/merge-finding-comment.sh"
printf 'merged finding\n' >"$R_BASE/finding.md"
R_URL="https://github.com/example-owner/example-repo/issues/41"

r_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}

# r_dispatch <reopen_rc> <merge_rc> <dispatcher args...> — sets R_RC, R_OUT, R_ERR.
r_dispatch() {
    local reopen_rc="$1" merge_rc="$2"; shift 2
    rm -f "$R_BASE/calls.log"
    R_RC=0
    (cd "$R_BASE/cwd" && export PATH="$R_BASE/fakebin:$PATH" R_REOPEN_RC="$reopen_rc" R_MERGE_RC="$merge_rc" \
        R_MERGE_STDOUT="${R_MERGE_STDOUT:-}" && r_timeout 60 bash "$R_BASE/gi/issue-create-dispatch.sh" "$@") >"$R_BASE/out.txt" 2>"$R_BASE/err.txt" || R_RC=$?
    R_OUT="$(tr -d '\r' <"$R_BASE/out.txt")"
    R_ERR="$(tr -d '\r' <"$R_BASE/err.txt")"
}
r_logged() { grep -qE "$1" "$R_BASE/calls.log" 2>/dev/null; }

test_R1_merge_comment_fails_exit3_stdout_empty() {
    r_dispatch 0 1 --verdict reopen --target 41 --merged-finding-file "$R_BASE/finding.md" --
    if [[ "$R_RC" == "3" && -z "$R_OUT" ]] \
        && grep -qx 'merge_comment: failed' <<<"$R_ERR" \
        && grep -qxF "reopened: $R_URL" <<<"$R_ERR" \
        && r_logged '^reopen 41' && r_logged '^merge 41 '; then
        pass "R1: reopen ok + merged-finding comment fails → exit 3, stdout empty, stderr names failure and reopened URL"
    else
        fail "R1: rc='$R_RC' out='$R_OUT' err='$R_ERR' calls='$(cat "$R_BASE/calls.log" 2>/dev/null)'"
    fi
}

test_R2_merge_comment_ok_url_only() {
    r_dispatch 0 0 --verdict reopen --target 41 --merged-finding-file "$R_BASE/finding.md" --
    if [[ "$R_RC" == "0" && "$R_OUT" == "$R_URL" ]] \
        && ! grep -q 'merge_comment:' <<<"$R_OUT$R_ERR" && r_logged '^merge 41 '; then
        pass "R2: reopen + merged-finding comment ok → exit 0, stdout exactly the URL, no merge_comment line"
    else
        fail "R2: rc='$R_RC' out='$R_OUT' err='$R_ERR'"
    fi
}

test_R3_no_merged_file_no_comment() {
    r_dispatch 0 1 --verdict reopen --target 41 --
    if [[ "$R_RC" == "0" && "$R_OUT" == "$R_URL" ]] && ! r_logged '^merge'; then
        pass "R3: reopen without --merged-finding-file → comment not attempted, exit 0, URL on stdout"
    else
        fail "R3: rc='$R_RC' out='$R_OUT' calls='$(cat "$R_BASE/calls.log" 2>/dev/null)'"
    fi
}

test_R4_reopen_fails_no_comment() {
    r_dispatch 1 0 --verdict reopen --target 41 --merged-finding-file "$R_BASE/finding.md" --
    if [[ "$R_RC" != "0" && -z "$R_OUT" ]] && ! r_logged '^merge'; then
        pass "R4: reopen fails → non-zero, no URL, comment not attempted"
    else
        fail "R4: rc='$R_RC' out='$R_OUT' calls='$(cat "$R_BASE/calls.log" 2>/dev/null)'"
    fi
}

test_R5_comment_stdout_kept_off_stdout() {
    local comment_url="$R_URL#issuecomment-1"
    R_MERGE_STDOUT="$comment_url" r_dispatch 0 0 --verdict reopen --target 41 --merged-finding-file "$R_BASE/finding.md" --
    if [[ "$R_RC" == "0" && "$R_OUT" == "$R_URL" ]] && grep -qxF "$comment_url" <<<"$R_ERR"; then
        pass "R5: comment script's stdout goes to stderr → dispatcher stdout is the issue URL line only"
    else
        fail "R5: rc='$R_RC' out='$R_OUT' err='$R_ERR'"
    fi
}

# ============ Run all ============

test_N1_single_line_url
test_C1_multi_line_url_last
test_C2_crlf_url
test_C3_url_number_42
test_C4_url_no_trailing_number
test_BK1_two_urls_in_order
test_BK2_progress_prefix_filtered
test_BK3_tail_backward_compat
test_R1_merge_comment_fails_exit3_stdout_empty
test_R2_merge_comment_ok_url_only
test_R3_no_merged_file_no_comment
test_R4_reopen_fails_no_comment
test_R5_comment_stdout_kept_off_stdout

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
