#!/usr/bin/env bash
# tests/bin-concern-ledger-cli-contract/check-staged-discovery.sh
# Tests: bin/concern-ledger
# Tags: concern-ledger, check-staged, discovery-helper, classifier-guard, mutation-control, windows-path, scope:issue-specific, pwsh-not-required

# Sourced by tests/bin-concern-ledger-cli-contract.sh (shares its counters and
# fixtures); split out per rules/coding/file-split.md.

echo ""
echo "--- cli 7b: the check-staged body itself, and what a revert would look like ---"

# #2088's fix has two class members: cl_reduce, and check-staged's no-producer
# scan. cl_reduce is pinned by behaviour, but check-staged's two spellings are
# runtime-indistinguishable (a quoted-prefix bash glob keeps a backslash
# literal), so this pins the shape of the subcommand body instead, proving the
# detector discriminates by running it against mutants of the old spelling.

# The mutants load their library by $0's directory, so they need one beside them.
MUT="$TMPDIR_BASE/mutants"
mkdir -p "$MUT"
cp -R "$AGENTS_ROOT/bin/lib" "$MUT/lib"

# cs_body <file> — the check-staged case arm with every comment removed, whole
# lines and trailing ones alike, so a name that survives only in prose cannot be
# mistaken for a call. Via a file, never a pipe into `grep -q`: under pipefail a
# short-circuiting reader makes the writer's SIGPIPE the pipeline's status.
cs_body() {
    awk '/^    check-staged\)/,/^        ;;$/' "$1" \
        | sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d'
}

# cs_shape <file> → "call=<yes|no> rawglob=<yes|no>": does that arm invoke the
# shared helper, and does it still carry the raw delta glob the fix removed?
cs_shape() {
    local bf="$TMPDIR_BASE/.cs-body.$$"
    cs_body "$1" > "$bf"
    printf 'call=%s rawglob=%s' \
        "$(grep -qE '_cl_list_pattern_files[[:space:]]+"' "$bf" && printf yes || printf no)" \
        "$(grep -qE 'for[[:space:]]+_f[[:space:]]+in[[:space:]]+".*delta-"\*\.txt' "$bf" \
            && printf yes || printf no)"
    rm -f "$bf"
}

# The pre-#2088 spelling, restored from git history: the NUL-delimited read
# becomes a quoted-prefix glob and the helper call goes away. Runnable, so the
# runtime comparison below is between two live programs.
REVERT="$MUT/concern-ledger-reverted"
sed -e "s|while IFS= read -r -d '' _f; do|for _f in \"\$PLANS/\$SID-\$FORMAT-round-\$ROUND-delta-\"*.txt; do|" \
    -e 's|done < <(_cl_list_pattern_files .*)$|done|' \
    "$CLI" > "$REVERT"

# The mutant the old assertion could not see: the call is gone, but the helper's
# name stays behind in the comment that used to describe it.
COMMENTED="$MUT/concern-ledger-commented"
sed -e 's|^\( *\)done < <(_cl_list_pattern_files .*)$|\1# was: _cl_list_pattern_files "PLANS/SID-FORMAT-round-N-delta-*.txt"\n\1done < <(printf "")|' \
    "$CLI" > "$COMMENTED"

assert_eq_nz "7b: the check-staged arm really is what got extracted (precondition)" \
    "extracted" \
    "$(case "$(cs_body "$CLI")" in *STAGED_MISSING*) printf extracted ;; *) printf empty ;; esac)"
assert_eq_nz "7b: both mutants differ from the real CLI (precondition)" \
    "revert=differs commented=differs" \
    "$(printf 'revert=%s commented=%s' \
        "$(cmp -s "$CLI" "$REVERT" && printf identical || printf differs)" \
        "$(cmp -s "$CLI" "$COMMENTED" && printf identical || printf differs)")"

assert_eq_nz "7b: the shipped arm calls the shared helper and carries no raw delta glob" \
    "call=yes rawglob=no" "$(cs_shape "$CLI")"
assert_eq_nz "7b: a revert to the pre-#2088 glob is caught, not silently accepted" \
    "call=no rawglob=yes" "$(cs_shape "$REVERT")"
assert_eq_nz "7b: and so is a body that keeps the helper's name only in a comment" \
    "call=no rawglob=no" "$(cs_shape "$COMMENTED")"

# Why the arm is extracted instead of grepped whole: the file-wide grep this
# replaces reads the commented body — which has no call left in it at all — as
# indistinguishable from the shipped one. That is the hole being closed.
assert_eq_nz "7b: a file-wide name grep reads a stale comment as a live call" \
    "real=found revert=missing commented=found" \
    "$(printf 'real=%s revert=%s commented=%s' \
        "$(grep -q '_cl_list_pattern_files' "$CLI" && printf found || printf missing)" \
        "$(grep -q '_cl_list_pattern_files' "$REVERT" && printf found || printf missing)" \
        "$(grep -q '_cl_list_pattern_files' "$COMMENTED" && printf found || printf missing)")"

# mut_check <cli> <plans> <sid> <round> → "rc=<n> out=<stdout>", against a
# nominated CLI rather than the shipped one.
mut_check() {
    local out rc
    out="$(bash "$1" check-staged --plans-dir "$2" --session-id "$3" \
        --format "$FORMAT" --round "$4" 2>/dev/null)"
    rc=$?
    printf 'rc=%s out=%s' "$rc" "$out"
}

MP="$TMPDIR_BASE/plans-mutant"
mkdir -p "$MP"
bash "$CLI" stage --plans-dir "$MP" --session-id mut1 --format "$FORMAT" \
    --round 1 --producer review-code-codex --exec PERFORMED --from-report "$REPORT" \
    >/dev/null 2>&1

# The commented mutant proves the mutants are live code and not inert text: with
# the call removed the scan reads nothing and the round reads as missing.
assert_eq_nz "7b: the mutants really execute — dropping the call breaks the scan" \
    "rc=1 out=(no format):missing" "$(mut_check "$COMMENTED" "$MP" mut1 1)"

# And the reverted mutant proves the claim this section rests on: on this host
# the old spelling answers identically, so no runtime case in cli 7 could have
# caught a revert. Asserted against the real CLI's answer, not a literal.
assert_eq_nz "7b: the reverted glob answers identically at runtime, which is why the shape is pinned" \
    "$(mut_check "$CLI" "$MP" mut1 1)" "$(mut_check "$REVERT" "$MP" mut1 1)"
