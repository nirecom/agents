#!/usr/bin/env bash
# tests/fix-2025-plans-path-contracts.sh
# Tests: bin/concern-ledger, bin/review-code-ledger, bin/run-codex-review-loop, bin/build-codex-context, skills/review-code-security/scripts/open-concern-round.sh, bin/lib/safe-plans-path.sh
# Tags: safe-plans-path, path-traversal, missing-library, exit-codes, wrapper-contract, security, scope:issue-specific, pwsh-not-required
#
# #2025 at the process boundary. The shared path primitive is a new dependency
# of six entrypoints, so each now has a new way to fail: the library missing.
# What each owes its caller differs — a gate must fail closed, a wrapper must
# not block the review it wraps — and this file pins those per entrypoint.
set -uo pipefail

# TL2 — real processes against a copied tree, so exit code and stderr are the
# bytes a caller actually sees.
#
# TL3 gap (skill-orchestration): whether the skill reading a wrapper's
# NOT-STAGED notice actually keeps reviewing isn't covered — the notice is
# asserted as text, but the reader is an LLM. Mitigation: the wrapper's exit
# status is asserted alongside the notice, catching a regression that turns it
# into a hard failure.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        pass "$name"
    else
        echo "FAIL: $name — output does not contain $(printf '%q' "$needle"). Got: $hay"
        FAIL=$((FAIL + 1))
    fi
}

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

# --- two copies of the tree, differing only in the shared library ------------
# Deleting the file (not stubbing it) reproduces "the dependency is not there"
# honestly. The crippled root is derived from an otherwise complete one so the
# missing library is the *only* difference — run-codex-review-loop also exits 4
# when rules/core-principles.md is absent, so an incomplete root would satisfy
# the exit-4 case for the wrong reason.
mk_root() {
    local dst="$1"
    mkdir -p "$dst/rules" "$dst/skills/review-code-security/scripts"
    cp -R "$AGENTS_ROOT/bin" "$dst/bin"
    cp -R "$AGENTS_ROOT/rules/." "$dst/rules/"
    cp "$AGENTS_ROOT/skills/review-code-security/scripts/open-concern-round.sh" \
        "$dst/skills/review-code-security/scripts/open-concern-round.sh"
}

# ROOT_OK — complete. ROOT — the same tree with only the library removed.
ROOT_OK="$TMPDIR_BASE/root-ok"
mk_root "$ROOT_OK"
ROOT="$TMPDIR_BASE/root"
mk_root "$ROOT"
rm -f "$ROOT/bin/lib/safe-plans-path.sh"

# The loop resolves its reviewer from AGENTS_CONFIG_DIR, so a copied root can
# replace it. Stubbed in both roots with an APPROVED verdict: a test must never
# reach the real codex CLI, and a loop that dies over its dependency has to die
# on a path that would otherwise have succeeded.
for _r in "$ROOT" "$ROOT_OK"; do
    cat > "$_r/bin/review-plan-codex" <<'RVEOF'
#!/usr/bin/env bash
printf '## Codex Plan Review: PERFORMED\n\n'
printf '<!-- begin-codex-output -->\nAPPROVED\n<!-- end-codex-output -->\n'
exit 0
RVEOF
done

PLANS="$TMPDIR_BASE/plans-c"
mkdir -p "$PLANS"
SID="c2025"
FORMAT="review-security-shared"

REPORT="$TMPDIR_BASE/report.txt"
{
    printf '## Review: PERFORMED\n\n## Concern Delta\n'
    printf -- '- [HIGH] - | a/b.sh#fn | correctness | an ordinary concern\n'
} > "$REPORT"

# rc_of <command...> — the exit status, run with the crippled tree as the root.
rc_of() {
    (
        export AGENTS_CONFIG_DIR="$ROOT"
        "$@" >/dev/null 2>&1
    )
    printf '%s' "$?"
}

# rc_ok <command...> — the same, against the intact tree. Every missing-library
# assertion is paired with one of these: without the pair, a run that fails for
# an unrelated reason (a bad flag, an unmet required argument) reads as the
# library check firing.
rc_ok() {
    (
        export AGENTS_CONFIG_DIR="$ROOT_OK"
        "$@" >/dev/null 2>&1
    )
    printf '%s' "$?"
}

echo ""
echo "--- contracts 0: the two roots differ in the library and nothing else ---"

{
    assert_eq "0: the intact root carries what every entrypoint reads first" \
        "core=yes lib=yes" \
        "core=$([ -f "$ROOT_OK/rules/core-principles.md" ] && printf yes || printf no) lib=$([ -f "$ROOT_OK/bin/lib/safe-plans-path.sh" ] && printf yes || printf no)"
    assert_eq "0: and the crippled root differs from it in the library alone" \
        "core=yes lib=no" \
        "core=$([ -f "$ROOT/rules/core-principles.md" ] && printf yes || printf no) lib=$([ -f "$ROOT/bin/lib/safe-plans-path.sh" ] && printf yes || printf no)"
}

echo ""
echo "--- contracts 1: the gate fails closed when its library is missing ---"

# The CLI's own exit vocabulary: 5 is "the artifact could not be produced".
# Anything that reads as success would tell close-concern-round.sh that a round
# it never recorded was recorded.
{
    assert_eq_nz "1: stage refuses rather than claiming a round it cannot write" \
        "5" "$(rc_of bash "$ROOT/bin/concern-ledger" stage --plans-dir "$PLANS" \
            --session-id "$SID" --format "$FORMAT" --round 1 \
            --producer review-code-codex --from-report "$REPORT")"
    assert_eq_nz "1: check-staged reports the same failure, not a passing gate" \
        "5" "$(rc_of bash "$ROOT/bin/concern-ledger" check-staged --plans-dir "$PLANS" \
            --session-id "$SID" --format "$FORMAT" --round 1)"
    assert_eq_nz "1: and nothing was written into the plans dir on the way out" \
        "0" "$(find "$PLANS" -type f 2>/dev/null | wc -l | tr -d ' ')"
}

{
    # The loop's own vocabulary: 4 is "wrapper/config failure". It is also the
    # code the loop uses for a missing --cap, an unknown flag and an absent
    # rules/core-principles.md, so the status alone proves nothing: the argument
    # list below is the loop's real one, and the diagnostic is asserted to name
    # the library rather than any of those.
    L_ARGS=(--format detail-plan --session-id "$SID" --plans-dir "$PLANS"
            --draft-file "$REPORT" --accepted-tradeoffs "$REPORT"
            --cap 1 --max-extensions 0)
    L_ERR="$( (export AGENTS_CONFIG_DIR="$ROOT"; \
        bash "$ROOT/bin/run-codex-review-loop" "${L_ARGS[@]}" 2>&1 >/dev/null) )"
    assert_eq_nz "1: the review loop stops instead of running an unrecordable round" \
        "4" "$(rc_of bash "$ROOT/bin/run-codex-review-loop" "${L_ARGS[@]}")"
    assert_contains "1: naming the dependency it could not load" \
        "safe-plans-path.sh" "$L_ERR"
    assert_eq "1: and not dying over its arguments or its context instead" \
        "clean" \
        "$(printf '%s' "$L_ERR" | grep -Eq 'is required|unknown argument|core-principles' \
            && printf 'wrong-cause' || printf clean)"
}

{
    # build-codex-context takes --plans-dir/--session-id/--output and nothing
    # else; an unknown flag exits 1 before any of its own logic runs, so the
    # success control below is what proves the failing call is a real one.
    B_OUT="$TMPDIR_BASE/ctx-out.md"
    printf '# intent\n' > "$PLANS/$SID-intent.md"
    assert_eq_nz "1: the context builder produces its file when the library is there" \
        "0" "$(rc_ok bash "$ROOT_OK/bin/build-codex-context" --plans-dir "$PLANS" \
            --session-id "$SID" --output "$B_OUT")"
    assert_eq "1: (precondition) that control really wrote the context file" \
        "written" "$([ -s "$B_OUT" ] && printf written || printf missing)"

    rm -f "$B_OUT"
    B_ERR="$( (export AGENTS_CONFIG_DIR="$ROOT"; \
        bash "$ROOT/bin/build-codex-context" --plans-dir "$PLANS" \
            --session-id "$SID" --output "$B_OUT" 2>&1 >/dev/null) )"
    assert_eq "1: and refuses the identical call with its own failure code" \
        "nonzero" \
        "$([ "$(rc_of bash "$ROOT/bin/build-codex-context" --plans-dir "$PLANS" \
            --session-id "$SID" --output "$B_OUT")" -ne 0 ] && printf nonzero || printf zero)"
    assert_contains "1: naming the same dependency the loop named" \
        "safe-plans-path.sh" "$B_ERR"
    assert_eq "1: leaving no half-built context file behind" \
        "absent" "$([ -e "$B_OUT" ] && printf present || printf absent)"
    rm -f "$PLANS/$SID-intent.md"
}

echo ""
echo "--- contracts 2: a wrapper never blocks the review it wraps ---"

# Both wrappers exist to add ledger bookkeeping to something else. Bookkeeping
# that cannot happen is a notice, never a non-zero exit: the review itself is
# still worth having, and the caller above reads exit status as "did the review
# run" (CPR-ORTH — the two wrappers get the same treatment).
{
    W_OUT="$TMPDIR_BASE/wrapper-out.txt"
    (
        export AGENTS_CONFIG_DIR="$ROOT" SESSION_ID="$SID" PLANS_DIR="$PLANS"
        bash "$ROOT/skills/review-code-security/scripts/open-concern-round.sh" > "$W_OUT" 2>/dev/null
    )
    W_RC=$?
    assert_eq_nz "2: open-concern-round.sh still exits 0" "0" "$W_RC"
    assert_contains "2: reporting the round as unavailable rather than guessing one" \
        "ROUND=0" "$(cat "$W_OUT")"
    assert_contains "2: and saying so on the NOT-STAGED line the skill reads" \
        "## Concern Ledger: NOT-STAGED" "$(cat "$W_OUT")"
    assert_eq "2: with no prior-concerns block, since it has no basis for one" \
        "0" "$(grep -c -F '[PRIOR CONCERNS START]' "$W_OUT" | tr -d ' ')"
}

{
    # review-code-ledger's contract is stronger: stdout must stay byte-for-byte
    # the reviewer's own output, so the notice is appended, never interleaved.
    # The stub goes into both roots: review-code-ledger resolves the reviewer
    # from its own directory, so the intact-root cases below need it too.
    for _r in "$ROOT" "$ROOT_OK"; do
        cat > "$_r/bin/review-code-codex" <<'STUBEOF'
#!/usr/bin/env bash
printf 'REVIEWER SAID THIS\n'
exit 0
STUBEOF
    done
    L_OUT="$TMPDIR_BASE/ledger-out.txt"
    (
        export AGENTS_CONFIG_DIR="$ROOT" SESSION_ID="$SID" PLANS_DIR="$PLANS"
        bash "$ROOT/bin/review-code-ledger" > "$L_OUT" 2>/dev/null
    )
    L_RC=$?
    assert_eq_nz "2: review-code-ledger still exits 0" "0" "$L_RC"
    assert_contains "2: the reviewer's own output reaches the caller unchanged" \
        "REVIEWER SAID THIS" "$(cat "$L_OUT")"
    assert_contains "2: with the bookkeeping failure appended as a notice" \
        "## Concern Ledger: NOT-STAGED" "$(cat "$L_OUT")"
    assert_eq_nz "2: and the notice comes after the review, not before it" \
        "after" \
        "$(R_LINE=$(grep -n -F 'REVIEWER SAID THIS' "$L_OUT" | head -n1 | cut -d: -f1); \
           N_LINE=$(grep -n -F 'NOT-STAGED' "$L_OUT" | head -n1 | cut -d: -f1); \
           [ -n "$R_LINE" ] && [ -n "$N_LINE" ] && [ "$N_LINE" -gt "$R_LINE" ] \
               && printf after || printf "review=$R_LINE notice=$N_LINE")"
}

echo ""
echo "--- contracts 3: a traversing session id never reaches the filesystem ---"

# The same token feeds every entrypoint, so a separator that escapes in one
# escapes in all of them (CPR-ORTH). Asserted against the intact tree, because
# this is a rejection the real code must perform, not a missing-library effect.
{
    T_PLANS="$TMPDIR_BASE/plans-t"
    mkdir -p "$T_PLANS/inner"
    T_BEFORE="$(find "$TMPDIR_BASE/plans-t" | LC_ALL=C sort)"

    T_STAGE="$(rc_ok bash "$AGENTS_ROOT/bin/concern-ledger" stage \
        --plans-dir "$T_PLANS/inner" --session-id "../escaped" --format "$FORMAT" \
        --round 1 --producer review-code-codex --from-report "$REPORT")"
    assert_eq "3: the CLI refuses a '..' session id" \
        "rejected" "$([ "$T_STAGE" -eq 0 ] && printf accepted || printf rejected)"

    # Real flags only: build-codex-context has no --format, and an unknown one
    # exits 1 before the token is ever looked at, which would read as a
    # rejection the code never made.
    T_CTX="$(rc_ok bash "$AGENTS_ROOT/bin/build-codex-context" \
        --session-id "../escaped" --plans-dir "$T_PLANS/inner" \
        --output "$T_PLANS/inner/ctx.md")"
    assert_eq "3: so does the context builder" \
        "rejected" "$([ "$T_CTX" -eq 0 ] && printf accepted || printf rejected)"

    T_LOOP="$(rc_ok bash "$AGENTS_ROOT/bin/run-codex-review-loop" --format detail-plan \
        --session-id "../escaped" --plans-dir "$T_PLANS/inner" \
        --draft-file "$REPORT" --accepted-tradeoffs "$REPORT" \
        --cap 1 --max-extensions 0)"
    assert_eq "3: and the loop that drives both of them" \
        "rejected" "$([ "$T_LOOP" -eq 0 ] && printf accepted || printf rejected)"

    assert_eq_nz "3: and the parent of the nominated directory is untouched by all three" \
        "$T_BEFORE" "$(find "$TMPDIR_BASE/plans-t" | LC_ALL=C sort)"
}

echo ""
echo "--- contracts 4: the round-number file is written inside the plans dir ---"

# Both wrappers write a round-number file with a bare `> "$ROUND_FILE"`, which
# follows a symlink pre-placed at that name — the file it lands in is chosen by
# whoever placed the link. A host without real symlinks (Git Bash without
# developer mode) would turn assertions vacuous, so the link is checked for
# being a link first.
link_at() {
    ln -s "$2" "$1" 2>/dev/null || true
    [ -h "$1" ] && printf yes || printf no
}

S_PLANS="$TMPDIR_BASE/plans-s"
mkdir -p "$S_PLANS"
S_OUTSIDE="$TMPDIR_BASE/round-victim.txt"
printf 'untouched\n' > "$S_OUTSIDE"
S_LINKED="$(link_at "$S_PLANS/$SID-$FORMAT-round-number.txt" "$S_OUTSIDE")"

if [ "$S_LINKED" != "yes" ]; then
    echo "SKIP: 4: this host does not create real symlinks — the round-file cases cannot run here"
else
    (
        export AGENTS_CONFIG_DIR="$AGENTS_ROOT" SESSION_ID="$SID" PLANS_DIR="$S_PLANS"
        bash "$AGENTS_ROOT/skills/review-code-security/scripts/open-concern-round.sh" \
            >/dev/null 2>&1
    )
    assert_eq_nz "4: open-concern-round.sh does not write the round through a pre-placed symlink" \
        "untouched" "$(cat "$S_OUTSIDE" 2>/dev/null)"

    # review-code-ledger, against the *intact* root: with the library missing
    # the bookkeeping short-circuits before the round write, which would satisfy
    # the assertion without the defence ever running. The control run directly
    # below establishes that this arrangement does reach the write.
    S2_CTRL="$TMPDIR_BASE/plans-s2-control"
    mkdir -p "$S2_CTRL"
    (
        export AGENTS_CONFIG_DIR="$ROOT_OK" SESSION_ID="$SID" PLANS_DIR="$S2_CTRL"
        bash "$ROOT_OK/bin/review-code-ledger" >/dev/null 2>&1
    )
    assert_eq "4: (precondition) with an ordinary name, the round write is reached" \
        "1" "$([ -s "$S2_CTRL/$SID-$FORMAT-round-number.txt" ] && printf 1 || printf 0)"

    # Same run, with a symlink standing at that name. The decoy has to be empty:
    # review-code-ledger only writes the round file when it is empty.
    S2_PLANS="$TMPDIR_BASE/plans-s2"
    mkdir -p "$S2_PLANS"
    S2_OUTSIDE="$TMPDIR_BASE/round-victim-2.txt"
    : > "$S2_OUTSIDE"
    link_at "$S2_PLANS/$SID-$FORMAT-round-number.txt" "$S2_OUTSIDE" >/dev/null
    (
        export AGENTS_CONFIG_DIR="$ROOT_OK" SESSION_ID="$SID" PLANS_DIR="$S2_PLANS"
        bash "$ROOT_OK/bin/review-code-ledger" >/dev/null 2>&1
    )
    assert_eq "4: and neither does review-code-ledger (CPR-ORTH, same write)" \
        "empty" "$([ -s "$S2_OUTSIDE" ] && cat "$S2_OUTSIDE" || printf empty)"
    assert_eq "4: the name it refused no longer points out of the plans dir" \
        "not-symlink" \
        "$([ -h "$S2_PLANS/$SID-$FORMAT-round-number.txt" ] && printf still-symlink \
            || printf not-symlink)"
fi

echo ""
echo "--- contracts 5: a legal '..' inside a directory name still works ---"

# CPR-UNV. `..` is only a parent reference as a whole path component;
# `user..name` is an ordinary directory name a traversal check must not lock
# out. rc_ok, not rc_of: this is the normal path, not the missing-library one —
# the crippled root would fail closed on the library check before the
# '..'-in-a-name behaviour is ever reached.
{
    U_PLANS="$TMPDIR_BASE/user..name/.workflow-plans"
    mkdir -p "$U_PLANS"

    U_STAGE="$(rc_ok bash "$AGENTS_ROOT/bin/concern-ledger" stage --plans-dir "$U_PLANS" \
        --session-id "$SID" --format "$FORMAT" --round 1 \
        --producer review-code-codex --from-report "$REPORT")"
    assert_eq "5: staging into a directory whose name contains '..' succeeds" \
        "0" "$U_STAGE"
    assert_eq_nz "5: and the delta really landed there, not somewhere up the tree" \
        "1" "$(find "$U_PLANS" -maxdepth 1 -name "$SID-$FORMAT-round-1-delta-*.txt" \
            2>/dev/null | wc -l | tr -d ' ')"
}

echo ""
echo "--- contracts 6: #2088 at the process boundary ---"

# Same defect (#2088) seen the way the user saw it — a plans dir spelled with
# backslashes, the delta on disk, `reduce` producing an empty ledger, which is
# the exit 4 the issue reports. rc_ok, not rc_of: normal path (library
# present) — the crippled root would fail closed on safe-plans-path.sh,
# misreporting #2088 as the unrelated #2025 gate.
{
    if command -v cygpath >/dev/null 2>&1; then
        B_PLANS="$(cygpath -w "$TMPDIR_BASE")\\plans-bs"
    else
        B_PLANS="$TMPDIR_BASE/plans\\evil"
    fi
    mkdir -p "$B_PLANS" 2>/dev/null || true

    assert_eq "6: the plans dir really is spelled with a backslash (precondition)" \
        "backslash" "$(case "$B_PLANS" in *\\*) printf backslash ;; *) printf plain ;; esac)"

    rc_ok bash "$AGENTS_ROOT/bin/concern-ledger" stage --plans-dir "$B_PLANS" \
        --session-id "$SID" --format "$FORMAT" --round 1 \
        --producer review-code-codex --from-report "$REPORT" >/dev/null
    rc_ok bash "$AGENTS_ROOT/bin/concern-ledger" stage --plans-dir "$B_PLANS" \
        --session-id "$SID" --format "$FORMAT" --round 1 \
        --producer review-code-security --from-report "$REPORT" >/dev/null
    assert_eq_nz "6: both deltas were written into that directory (precondition)" \
        "2" "$(find "$B_PLANS" -maxdepth 1 -name "*-round-1-delta-*.txt" 2>/dev/null \
            | wc -l | tr -d ' ')"

    assert_eq_nz "6: reduce exits cleanly on a backslash-spelled plans dir" \
        "0" "$(rc_ok bash "$AGENTS_ROOT/bin/concern-ledger" reduce --plans-dir "$B_PLANS" \
            --session-id "$SID" --format "$FORMAT" --round 1)"
    # A v2 ledger row is `C<n>|SEV|state|...|TEXT`, not the `- ` bullet the
    # renderer emits: matching the bullet here would report a header-only ledger
    # as full once the fix lands.
    B_LED="$B_PLANS/$SID-$FORMAT-concern-ledger.txt"
    assert_eq_nz "6: and the concern it staged is in the ledger, not a header-only file" \
        "1" "$(grep -c -E '^C[0-9]+\|' "$B_LED" 2>/dev/null | tr -d ' ')"
    assert_contains "6: carrying the text of the concern that was staged" \
        "an ordinary concern" "$(cat "$B_LED" 2>/dev/null)"
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
