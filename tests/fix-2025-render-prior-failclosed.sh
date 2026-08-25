#!/usr/bin/env bash
# tests/fix-2025-render-prior-failclosed.sh
# Tests: bin/lib/concern-ledger/render.sh, bin/lib/concern-ledger/core.sh, bin/concern-ledger
# Tags: concern-ledger, render-prior, fail-closed, pipefail, silent-loss, security, scope:issue-specific, pwsh-not-required
#
# cl_render_prior renders prior open concerns through a three-stage pipe, and
# empty output legitimately means "nothing is open". A stage that dies looks
# exactly like a clean round: the loop reads as converging when it isn't
# (#2025 C13). The scoped `set -o pipefail` separates the two, so every stage
# is failed in turn and both verdicts are asserted.
set -uo pipefail

# TL2. The real library is sourced and one stage of the pipeline is replaced
# in the subshell that calls it — the middle stages by redefinition, the first
# by shadowing `awk` on PATH, the real dependency rather than a copy of it.

# TL3 gap (environment-specific): the real reasons a stage dies on a host (a
# sed build without -E, an out-of-memory awk, a rejecting locale) aren't
# reproducible in a sandbox. Mitigation: the assertion is on the caller's
# verdict for any non-zero status, not the specific cause.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

# An expectation that could not be computed is itself a failure.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
TMPDIR_BASE="$(mktemp -d)"
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans-root"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

for _f in "$CLI" "$LIB"; do
    [ -f "$_f" ] || fail "implementation missing: ${_f#"$AGENTS_ROOT/"}"
done

# OPEN — two concerns a next round must be told about.
OPEN="$TMPDIR_BASE/open-concern-ledger.txt"
{
    printf '#concern-ledger-v2|review-security-shared|sess-c7|cycle=1\n'
    printf 'C1|HIGH|open|1|1|bin/x#fn:security|dc701|review-code-codex|review-code-codex|-|the first prior concern\n'
    printf 'C2|LOW|reopened|1|2|bin/y#fn:security|dc702|security-scanner|security-scanner|reopen|the second prior concern\n'
} > "$OPEN"

# CLOSED — the same ledger with nothing left open. Empty output is correct here,
# and that is precisely why an emptied pipeline must not look like this.
CLOSED="$TMPDIR_BASE/closed-concern-ledger.txt"
{
    printf '#concern-ledger-v2|review-security-shared|sess-c7|cycle=1\n'
    printf 'C1|HIGH|resolved|1|2|bin/x#fn:security|dc701|review-code-codex|review-code-codex|-|the first prior concern\n'
} > "$CLOSED"

# The first stage's dependency, made to fail the way a broken tool would.
STUB="$TMPDIR_BASE/stub"
mkdir -p "$STUB"
cat > "$STUB/awk" <<'EOF'
#!/usr/bin/env bash
echo "awk: simulated stage failure" >&2
exit 2
EOF
chmod +x "$STUB/awk"

# render <ledger> <path-prefix|-> <injection|-> — cl_render_prior in its own
# subshell under the caller's contract (set -uo pipefail). Sets R_RC/R_OUT/R_ERR
# so a case can assert on all three at once: a refusal that still printed a
# block, or a success that printed nothing, are both distinguishable failures.
R_RC=0; R_OUT=""; R_ERR=""
render() {
    local led="$1" pfx="$2" inj="$3" d rc=0
    [ "$pfx" = "-" ] && pfx=""
    [ "$inj" = "-" ] && inj=""
    d="$(mktemp -d "$TMPDIR_BASE/render.XXXXXX")"
    PATH="${pfx:+$pfx:}$PATH" bash -c '
        set +u
        source "$1" >/dev/null 2>&1 || exit 127
        set -uo pipefail
        [ -z "$3" ] || eval "$3"
        cl_render_prior "$2"
    ' _ "$LIB" "$led" "$inj" >"$d/out" 2>"$d/err" || rc=$?
    R_RC="$rc"
    R_OUT="$(cat "$d/out")"
    R_ERR="$(cat "$d/err")"
}

# verdict — the three observables as one string, so no case can pass by getting
# one of them right while the other two say something else.
verdict() {
    printf 'rc=%s body=%s diag=%s' "$R_RC" \
        "$([ -n "$R_OUT" ] && printf yes || printf no)" \
        "$([ -n "$R_ERR" ] && printf yes || printf no)"
}

echo "--- render 1: the two legitimate outcomes ---"

# 1. Both are successes, and one of them is empty. Every refusal below has to be
#    told apart from this second one, so it is asserted first.
{
    render "$OPEN" - -
    assert_eq "1: an open ledger renders its block and says nothing on stderr" \
        "rc=0 body=yes diag=no" "$(verdict)"
    assert_eq_nz "1: and the block carries both open IDs for the next round" \
        "2" "$(printf '%s\n' "$R_OUT" | grep -c -E '^- C[0-9]+ \[' | tr -d ' ')"

    render "$CLOSED" - -
    assert_eq "1: a ledger with nothing open is an empty success, not a failure" \
        "rc=0 body=no diag=no" "$(verdict)"

    render "$TMPDIR_BASE/no-such-concern-ledger.txt" - -
    assert_eq "1: and so is a ledger that does not exist yet" \
        "rc=0 body=no diag=no" "$(verdict)"
}

echo ""
echo "--- render 2: each stage of the pipeline, failed in turn ---"

# 2. One property, three stages (CPR-ORTH): whichever stage dies, the caller
#    must be told. The table names the stage and how it is broken; the verdict
#    is the same for all of them, which is the point.

ROWS=0
while IFS='~' read -r label pfx inj; do
    label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
    pfx="${pfx#"${pfx%%[![:space:]]*}"}"; pfx="${pfx%"${pfx##*[![:space:]]}"}"
    inj="${inj#"${inj%%[![:space:]]*}"}"; inj="${inj%"${inj##*[![:space:]]}"}"
    [ -z "$label" ] && continue
    case "$label" in \#*) continue ;; esac
    ROWS=$((ROWS + 1))
    render "$OPEN" "$pfx" "$inj"
    assert_eq "2: $label is refused, with a diagnostic and no block" \
        "rc=2 body=no diag=yes" "$(verdict)"
    assert_eq_nz "2: $label names the function that failed" \
        "1" "$(printf '%s' "$R_ERR" | grep -c -F 'cl_render_prior: rendering pipeline failed' | tr -d ' ')"
done <<TABLE
a first stage that cannot run       ~ $STUB ~ -
a defanging stage that fails        ~ -     ~ _cl_defang_untrusted() { return 3; }
a defanging stage that fails loudly ~ -     ~ _cl_defang_untrusted() { cat >/dev/null; return 3; }
a husk-filter stage that fails      ~ -     ~ _cl_placehold_empty_concerns() { return 4; }
TABLE

assert_eq_nz "2: every stage in the table was actually failed" "4" "$ROWS"

echo ""
echo "--- render 3: a refusal is never mistaken for a clean round ---"

# 3. The defect this whole file exists for. A broken stage and a converged round
#    both print nothing, so stdout alone cannot separate them; only the status
#    can. Asserted as one comparison rather than two, so a build that made both
#    of them rc 0 could not pass either half.
{
    render "$CLOSED" - -
    CLEAN="rc=$R_RC body=$([ -n "$R_OUT" ] && printf yes || printf no)"
    render "$OPEN" - '_cl_defang_untrusted() { return 3; }'
    BROKEN="rc=$R_RC body=$([ -n "$R_OUT" ] && printf yes || printf no)"

    assert_eq_nz "3: both print nothing, which is why stdout cannot decide it" \
        "no" "$(printf '%s' "$CLEAN" | sed 's/.*body=//')"
    assert_eq "3: and the status is what tells the converged round from the broken one" \
        "distinct" "$([ "$CLEAN" = "$BROKEN" ] && printf identical || printf distinct)"
    assert_eq "3: the broken one carries the refusal code the CLI passes on" \
        "rc=2 body=no" "$BROKEN"
}

echo ""
echo "--- render 4: the refusal survives the real CLI ---"

# 4. Everything above calls the library directly. The reviewer's prompt is built
#    by the CLI, so the status has to reach a shell script's `|| exit` there too
#    — a rc that got swallowed at the boundary would restore the whole defect.
{
    RC4=0
    OUT4="$(PATH="$STUB:$PATH" bash "$CLI" render-prior --ledger "$OPEN" \
        --plans-dir "$TMPDIR_BASE" --session-id sess-c7 \
        --format review-security-shared 2>/dev/null)" || RC4=$?
    assert_eq "4: the CLI refuses instead of printing an empty prior-concerns block" \
        "rc=2 body=no" \
        "rc=$RC4 body=$([ -n "$OUT4" ] && printf yes || printf no)"

    RC4B=0
    OUT4B="$(bash "$CLI" render-prior --ledger "$OPEN" --plans-dir "$TMPDIR_BASE" \
        --session-id sess-c7 --format review-security-shared 2>/dev/null)" || RC4B=$?
    assert_eq "4: and with the stage working it still renders the block normally" \
        "rc=0 body=yes" \
        "rc=$RC4B body=$([ -n "$OUT4B" ] && printf yes || printf no)"
}

echo ""
echo "--- render 5: the mechanism that makes the status visible ---"

# 5. Cases 2-4 observe the verdict; this pins how it is obtained. `$(...)` runs
#    in a subshell that does not inherit a pipefail set outside it, so the
#    scoped `set -o pipefail` is the whole defence — without it only the last
#    stage's status would ever be seen and two of the three rows above would
#    silently become empty successes again.
{
    BODY="$(awk '/^cl_render_prior\(\)/, /^}/' "$AGENTS_ROOT/bin/lib/concern-ledger/render.sh")"
    assert_eq_nz "5: the render pipeline sets pipefail inside its own subshell" \
        "1" "$(printf '%s' "$BODY" | grep -c -F 'set -o pipefail' | tr -d ' ')"
    assert_eq_nz "5: takes the status of that pipeline" \
        "1" "$(printf '%s' "$BODY" | grep -c -F 'rc=$?' | tr -d ' ')"
    assert_eq_nz "5: and returns a refusal rather than the empty body" \
        "1" "$(printf '%s' "$BODY" | grep -c -F 'return 2' | tr -d ' ')"
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
