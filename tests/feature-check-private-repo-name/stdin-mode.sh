#!/bin/bash
# tests/feature-check-private-repo-name/stdin-mode.sh
# Tests: bin/check-private-repo-name.js
# Tags: private-repo, outbound-scan, security, classifier, stdin, table-driven, TL2, scope:common
# S1-S6 [F3] — PRIVATE_REPO_NAMES_STDIN=1, the third and highest-precedence name source.
#
# Why: PRIVATE_REPO_NAMES_CACHE put the full private-repo list in the caller's
# environment, readable by any process-inspection interface. F3 hands it to the
# sole consumer over stdin. This file owns the consumer half; the caller half
# (no export) is in ../feature-worktree-start-non-interactive/env-nonexposure.sh.

# Classifier, so both verdicts are covered on the new source: over-blocking
# degrades every derived name, under-blocking reopens the leak.
# STDIN=1 marks the list AUTHORITATIVE, so an empty list means "confirmed none",
# not "not asked yet" — the empty-list rows pin that distinction.
# Fixtures are fictional (`acme-org/acme-internal`, `secret-thing`); no `gh`, no
# network. Part of the feature-check-private-repo-name suite.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

if [ ! -f "$CHECK" ]; then
    fail "setup: bin/check-private-repo-name.js must exist (check='$CHECK')"
    finish
fi

setup_fixture

# ── S1: stdin matching semantics and wire-format boundaries ─────────────────
# label | stdin bytes (\n, \r interpreted) | candidate | expected exit code
#
# The production caller writes `printf '%s\n' "$list"`, so the trailing-newline rows are
# the normal shape; the others are the shapes a different caller, a Windows-authored
# file, or a partially-populated list would produce. Each must classify the same way, or
# the gate's verdict would depend on how its input happened to be framed.
S1_ROWS=(
    # -- the classifier's two verdicts on the plain, production-shaped list --
    'match|secret-thing\n|1910-secret-thing-fix|1'
    'no-match|secret-thing\n|1910-public-refactor|0'
    'owner-repo-form|acme-org/acme-internal\n|1910-acme-internal-fix|1'
    'owner-repo-no-match|acme-org/acme-internal\n|1910-public-refactor|0'
    'second-entry|pub-one\nsecret-thing\n|1910-secret-thing-fix|1'
    # Boundary semantics are the shared matcher's, not stdin's — one row each way is
    # enough to prove the stdin arm reaches the same findPrivateName(), rather than a
    # second, looser comparison of its own.
    'substring-not-a-match|fix\n|1910-fixture-setup|0'
    # -- authoritative empty: the state that distinguishes "none" from "unknown" --
    # A caller that declares STDIN=1 has ASKED and been told nothing; the answer is the
    # empty list, not a reason to consult another source. A candidate that a populated
    # list would reject must therefore pass.
    'empty-authoritative||1910-secret-thing-fix|0'
    'empty-newline-only|\n|1910-secret-thing-fix|0'
    'empty-many-newlines|\n\n\n|1910-secret-thing-fix|0'
    # -- boundary: no trailing newline --
    # A caller using `printf '%s'` (or a list built by string concatenation) delivers a
    # final entry with no terminator. Dropping it would silently shrink the list by one,
    # and the entry most likely to be last is as protected as any other.
    'no-trailing-newline|secret-thing|1910-secret-thing-fix|1'
    'no-trailing-newline-second|pub-one\nsecret-thing|1910-secret-thing-fix|1'
    # -- boundary: CRLF line endings --
    # The producer runs under Git Bash on Windows, so a CRLF-framed list is a realistic
    # delivery. split('\n') leaves a trailing '\r' on every entry; the match survives it
    # because findPrivateName() tokenizes on [^a-zA-Z0-9]+ and the '\r' is absorbed as a
    # separator. Pinned rather than assumed: were the entry compared as one literal, a
    # CRLF list would match nothing at all and the gate would be silently dead on the
    # very platform that produces it.
    'crlf-match|secret-thing\r\n|1910-secret-thing-fix|1'
    'crlf-second-entry|pub-one\r\nsecret-thing\r\n|1910-secret-thing-fix|1'
    'crlf-no-match|secret-thing\r\n|1910-public-refactor|0'
    # -- boundary: blank lines interspersed --
    # An empty entry must be FILTERED, never compiled: joining zero tokens yields
    # /(^|[^a-zA-Z0-9])([^a-zA-Z0-9]|$)/i, which matches almost any hyphenated slug, so
    # a single stray blank line would turn the gate into "reject everything" and degrade
    # every derived name to a timestamp fallback.
    'blank-lines-ignored|\n\nsecret-thing\n\n|1910-nothing-here|0'
    'blank-lines-still-match|\n\nsecret-thing\n\n|1910-secret-thing-x|1'
    'leading-blank-only|\n\n|1910-anything-at-all|0'
)
for s1_row in "${S1_ROWS[@]}"; do
    IFS='|' read -r s1_label s1_list_raw s1_cand s1_want <<< "$s1_row"
    s1_list="$(printf '%b' "$s1_list_raw")"
    run_stdin "$s1_list" "$s1_cand"
    assert_eq "S1/$s1_label: candidate '$s1_cand' -> exit $s1_want" "$s1_want" "$RC"
done

# ── S2: the env-cache contract still classifies identically ─────────────────
# Adding a source must not perturb the one already in production. These rows drive the
# SAME (list, candidate) pairs through both arms and assert the verdicts agree AND equal
# the expected value — agreement alone would be satisfied by two equally broken arms.
# label | list | candidate | expected exit code
S2_ROWS=(
    'match|secret-thing|1910-secret-thing-fix|1'
    'no-match|secret-thing|1910-public-refactor|0'
    'empty-list|Q|1910-secret-thing-fix|0'
    'owner-repo|acme-org/acme-internal|1910-acme-internal-fix|1'
)
for s2_row in "${S2_ROWS[@]}"; do
    IFS='|' read -r s2_label s2_list s2_cand s2_want <<< "$s2_row"
    # 'Q' is the table's spelling for "no entries at all" — an empty field would be
    # indistinguishable from a malformed row.
    [ "$s2_list" = 'Q' ] && s2_list=''
    run_check "$s2_list" "$s2_cand"
    s2_env_rc="$RC"
    run_stdin "$s2_list" "$s2_cand"
    if [ "$s2_env_rc" = "$s2_want" ] && [ "$RC" = "$s2_want" ]; then
        pass "S2/$s2_label: the env-cache and stdin arms both exit $s2_want for candidate '$s2_cand'"
    else
        fail "S2/$s2_label: expected both arms to exit $s2_want (env=$s2_env_rc, stdin=$RC, list='$s2_list', candidate='$s2_cand')"
    fi
done

# ── S3: precedence — stdin outranks the env cache, in both directions ───────
# The stdin branch must sit above the env-cache block and `return`, since stdin
# resolves asynchronously. Both directions fail differently:
#   (a) stdin match + env empty -> reject (else the gate is dead for stdin callers)
#   (b) stdin empty + env match -> accept (proves precedence, not mere presence;
#       consulting both would pass (a) and re-arm the leak F3 removed)
s3_run() {  # $1 = stdin bytes, $2 = env cache value, $3 = candidate
    local errf="$TMP/s3-err.txt"
    OUT="$(printf '%s' "$1" | PRIVATE_REPO_NAMES_STDIN=1 PRIVATE_REPO_NAMES_CACHE_SET=1 \
        PRIVATE_REPO_NAMES_CACHE="$2" node "$CHECK" "$3" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}
s3_run "$(printf 'acme-internal\n')" '' '1910-acme-internal-fix'
assert_eq "S3/stdin-wins-positive: a matching name on stdin rejects even though the armed env cache is empty" "1" "$RC"
s3_run '' 'acme-internal' '1910-acme-internal-fix'
assert_eq "S3/stdin-wins-empty: an authoritative empty stdin accepts even though the armed env cache holds a matching name" "0" "$RC"
# Counterfactual for the row above: without PRIVATE_REPO_NAMES_STDIN the very same
# environment rejects. Without this, "stdin won" would be indistinguishable from "the
# env cache was never armed in the first place" — a vacuous green.
S3_ERRF="$TMP/s3-cf-err.txt"
printf '' | PRIVATE_REPO_NAMES_CACHE_SET=1 PRIVATE_REPO_NAMES_CACHE='acme-internal' \
    node "$CHECK" '1910-acme-internal-fix' >/dev/null 2>"$S3_ERRF"
assert_eq "S3/counterfactual: the same env cache, with the stdin flag absent, still rejects (the row above really is precedence)" "1" "$?"

# ── S4: diagnostic discipline on a stdin-mode rejection ─────────────────────
# The stdin arm ends in the same finish() as the other two, so it must be exactly as
# non-identifying (CPR-ORTH). Everything in play is secret-bearing: the matched name is
# the one the gate exists to keep off shared surfaces, the candidate is caller text that
# may carry private information of its own, and the rest of the delivered list is the
# user's complete private-repo inventory — the single most damaging thing this process
# could ever print. Asserted against the actual strings this case used, not a generic
# pattern, so a re-introduced `%s` anywhere in the path cannot slip through.
S4_LIST="$(printf 'pub-one\nacme-internal\nsecond-secret\n')"
S4_CAND='ops-runbook-for-acme-internal-cluster'
run_stdin "$S4_LIST" "$S4_CAND"
S4_LINES="$(printf '%s\n' "$ERR" | grep -c '[^[:space:]]')"
assert_eq "S4/rc: a stdin-mode match exits 1" "1" "$RC"
if [ "$S4_LINES" -eq 1 ] && printf '%s\n' "$ERR" | grep -qxF "$REJECT_MSG"; then
    pass "S4/stderr: the stdin arm emits the same single fixed, non-identifying line as the other two sources"
else
    fail "S4/stderr: expected the single line '$REJECT_MSG' (lines=$S4_LINES, err='$ERR')"
fi
S4_BOTH="$OUT$ERR"
S4_LEAKED=""
for s4_secret in "$S4_CAND" 'ops-runbook' 'cluster' 'acme-internal' 'acme' 'internal' \
                 'pub-one' 'second-secret'; do
    [[ "$S4_BOTH" == *"$s4_secret"* ]] && S4_LEAKED="$S4_LEAKED '$s4_secret'"
done
if [ -z "$S4_LEAKED" ]; then
    pass "S4/no-echo: neither the candidate, the matched name, nor any other entry of the delivered list appears on stdout or stderr"
else
    fail "S4/no-echo: leaked to stdout/stderr:$S4_LEAKED (out='$OUT', err='$ERR')"
fi

# ── S5: silence on the accepting verdicts ───────────────────────────────────
# scan_clean() discards both streams, so anything written on a clean pass is pure noise
# the caller pays for on every one of its several invocations per run. Both accepting
# shapes are covered: a populated list that did not match, and the authoritative empty
# list — the latter is the state every insulated fixture in this repo runs under, so
# noise there would contaminate output captures suite-wide.
run_stdin "$(printf 'acme-internal\n')" '1910-public-refactor'
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    pass "S5/quiet-no-match: a non-matching candidate exits 0 with both streams empty"
else
    fail "S5/quiet-no-match: expected rc=0 and empty stdout/stderr (rc=$RC, out='$OUT', err='$ERR')"
fi
run_stdin '' 'ops-runbook-for-acme-internal-cluster'
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    pass "S5/quiet-empty: an authoritative empty list exits 0 with both streams empty, whatever the candidate"
else
    fail "S5/quiet-empty: expected rc=0 and empty stdout/stderr (rc=$RC, out='$OUT', err='$ERR')"
fi

# ── S6: no candidate argument, with stdin armed ─────────────────────────────
# argv[2] is checked before any source is consulted, so an absent candidate must
# fail open on this arm too rather than block on a pending stdin read. The gate is
# invoked from shell (`node ... "$1"`), where an unset caller variable is the realistic
# way this happens mid-cascade.
S6_ERRF="$TMP/s6-err.txt"
printf 'acme-internal\n' | PRIVATE_REPO_NAMES_STDIN=1 node "$CHECK" >/dev/null 2>"$S6_ERRF"
S6_RC=$?
if [ "$S6_RC" -eq 0 ] && [ ! -s "$S6_ERRF" ]; then
    pass "S6/absent-arg: no candidate argument exits 0 (fail-open) and stays silent with stdin armed"
else
    fail "S6/absent-arg: expected rc=0 with empty stderr (rc=$S6_RC, err='$(cat "$S6_ERRF")')"
fi

finish
