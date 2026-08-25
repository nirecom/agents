#!/usr/bin/env bash
# tests/fix-2025-module-load-failclosed.sh
# Tests: bin/lib/concern-ledger.sh, bin/concern-ledger, bin/build-codex-context, bin/run-codex-review-loop, skills/review-code-security/scripts/open-concern-round.sh
# Tags: concern-ledger, library-load, fail-closed, incomplete-install, security, scope:issue-specific, pwsh-not-required
#
# None of these scripts runs under `set -e`, so an unchecked `source` leaves
# every cl_* call resolving to "command not found" — and a round whose findings
# vanished exits 0. Each module is therefore hidden one at a time, in a copied
# tree, and the entrypoint has to name the module it could not load and refuse
# (#2025 C10). A half-loaded ledger is the silent findings loss the subsystem
# exists to stop, so "refused loudly" is the only acceptable answer here.
set -uo pipefail

# TL2. Copied bin/ trees driven as real subprocesses: the load sequence under
# test is bash's own `source`, never a stub, and a module is made unloadable the
# way a broken install does it — by not being there, or by not parsing.

# TL3 gap (mitigation category: cost)
#   Not covered behaviourally: bin/review-code-ledger's own guard. Reaching it
#   means running a full codex review first, which is minutes of billed
#   reviewer time per row and needs a live CLI.
#   Mitigation: its two guard lines are pinned structurally below, alongside the
#   sibling wrappers that are exercised for real.

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

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
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

SID="s1"
FMT="detail-plan"

# mktree <name> — a complete, working copy of the installed tree. Every case
# starts from one and removes exactly one thing, so what the case proves is that
# thing and nothing about the copy.
mktree() {
    local d="$TMPDIR_BASE/$1"
    rm -rf "$d"
    mkdir -p "$d/rules" "$d/skills/review-code-security/scripts"
    cp -r "$AGENTS_ROOT/bin" "$d/bin"
    echo "# core principles stub" > "$d/rules/core-principles.md"
    cp "$AGENTS_ROOT/skills/review-code-security/scripts/open-concern-round.sh" \
        "$d/skills/review-code-security/scripts/"
    printf '%s' "$d"
}

# mkplans <name> — a plans dir the wrappers will accept.
mkplans() {
    local p="$TMPDIR_BASE/$1"
    mkdir -p "$p"
    echo "# Draft plan" > "$p/draft.md"
    echo "# Outline" > "$p/outline.md"
    printf '%s' "$p"
}

RC=0
SOUT=""
SERR=""
# ledger_cli <tree> <subcommand-args...> — the real CLI, with stdout and stderr
# kept apart: a fail-closed load must put nothing on stdout, and a caller that
# only reads stdout is exactly the one that would otherwise proceed on silence.
ledger_cli() {
    local d="$1" rc=0
    shift
    run_with_timeout bash "$d/bin/concern-ledger" "$@" \
        >"$TMPDIR_BASE/.out" 2>"$TMPDIR_BASE/.err" || rc=$?
    RC="$rc"; SOUT="$(cat "$TMPDIR_BASE/.out")"; SERR="$(cat "$TMPDIR_BASE/.err")"
}
errsays() { printf '%s' "$SERR" | grep -q -F -e "$1" && printf yes || printf no; }

echo "--- load 1: the control, on a tree with nothing removed ---"

# 1. The classifier has to be seen saying yes: without a working tree, "it
#    refused" below is also what a permanently broken CLI would produce.
{
    D1="$(mktree ok)"
    ledger_cli "$D1" slot --path bin/x --anchor fn:y --category security
    assert_eq "1: a complete tree loads and answers" "0" "$RC"
    assert_eq "1: printing a real slot on stdout" \
        "nonempty" "$([ -n "$SOUT" ] && printf nonempty || printf empty)"
    assert_eq "1: with nothing on stderr" \
        "quiet" "$([ -z "$SERR" ] && printf quiet || printf "noisy:$SERR")"
}

echo ""
echo "--- load 2: one module removed at a time ---"

# 2. Per module, not once for the set: five separate source blocks means five
#    separate chances for one to lose its check, and a loop over the set would
#    pass on the four that kept theirs.
{
    while IFS='~' read -r label relpath want_says; do
        case "$label" in ''|'#'*) continue ;; esac
        for v in label relpath want_says; do
            eval "t=\$$v"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; eval "$v=\$t"
        done
        D2="$(mktree "hide-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-')")"
        mv "$D2/$relpath" "$D2/$relpath.hidden"
        assert_eq "2: $label — it really is out of the tree (precondition)" \
            "gone" "$([ -e "$D2/$relpath" ] && printf 'still-there' || printf gone)"

        ledger_cli "$D2" tally --plans-dir "$(mkplans "plans-load")" \
            --session-id "$SID" --format "$FMT"
        assert_eq "2: $label — the CLI reports it could not produce an artifact" "5" "$RC"
        assert_eq "2: $label — naming what it could not load" "yes" "$(errsays "$want_says")"
        assert_eq "2: $label — and refusing rather than running half-loaded" \
            "yes" "$(errsays "refusing to run half-loaded")"
        assert_eq "2: $label — with nothing on stdout for a caller to mistake for a tally" \
            "empty" "$([ -z "$SOUT" ] && printf empty || printf "printed:$SOUT")"
        ROWS2=$((${ROWS2:-0} + 1))
    done <<'TABLE'
# label                  ~ relpath                              ~ want_says
core.sh                  ~ bin/lib/concern-ledger/core.sh       ~ concern-ledger/core.sh — refusing
parse.sh                 ~ bin/lib/concern-ledger/parse.sh      ~ concern-ledger/parse.sh — refusing
reduce.sh                ~ bin/lib/concern-ledger/reduce.sh     ~ concern-ledger/reduce.sh — refusing
render.sh                ~ bin/lib/concern-ledger/render.sh     ~ concern-ledger/render.sh — refusing
finalize.sh              ~ bin/lib/concern-ledger/finalize.sh   ~ concern-ledger/finalize.sh — refusing
the whole module dir     ~ bin/lib/concern-ledger              ~ library modules not found at
safe-plans-path.sh       ~ bin/lib/safe-plans-path.sh           ~ required library not found at
TABLE
    assert_eq_nz "2: every module in the table was removed and tried" "7" "${ROWS2:-0}"
}

echo ""
echo "--- load 3: a module that is present but will not parse ---"

# 3. The check is on what `source` returned, not on whether the file exists — a
#    truncated or half-deployed module is the likelier real-world break, and an
#    existence test would wave it through.
{
    D3="$(mktree broken-syntax)"
    printf 'this is( not ) valid shell {{{\n' > "$D3/bin/lib/concern-ledger/reduce.sh"
    assert_eq "3: the module is still on disk (precondition)" \
        "present" "$([ -f "$D3/bin/lib/concern-ledger/reduce.sh" ] && printf present || printf missing)"
    ledger_cli "$D3" tally --plans-dir "$(mkplans plans-syntax)" \
        --session-id "$SID" --format "$FMT"
    assert_eq "3: a module that cannot be parsed is a failed load, not a loaded one" "5" "$RC"
    assert_eq "3: named the same way a missing one is" \
        "yes" "$(errsays "concern-ledger/reduce.sh — refusing")"
    assert_eq "3: and nothing reached stdout" \
        "empty" "$([ -z "$SOUT" ] && printf empty || printf "printed:$SOUT")"
}

echo ""
echo "--- load 4: the sibling entrypoints that source the same library ---"

# 4. Five scripts source safe-plans-path.sh, and they do not share one contract:
#    two wrappers must halt, and the review-side scripts must degrade to a
#    visible NOT-STAGED and still exit 0. Checked together so a fix applied to
#    one is not mistaken for a fix applied to the class (CPR-ORTH).
{
    D4="$(mktree siblings)"
    mv "$D4/bin/lib/safe-plans-path.sh" "$D4/bin/lib/safe-plans-path.sh.hidden"

    P4B="$(mkplans plans-builder)"
    echo "# Intent" > "$P4B/$SID-intent.md"
    rc=0
    O4B="$(run_with_timeout bash "$D4/bin/build-codex-context" --plans-dir "$P4B" \
        --session-id "$SID" --output "$P4B/ctx.md" 2>&1)" || rc=$?
    assert_eq "4: build-codex-context halts when its safe-path library is gone" "1" "$rc"
    assert_eq "4: saying which library it needed" \
        "yes" "$(printf '%s' "$O4B" | grep -q -F -e 'required library missing' && printf yes || printf no)"
    assert_eq "4: and writing no context anyone could mistake for a real one" \
        "no-context" "$([ -e "$P4B/ctx.md" ] && printf 'wrote-one' || printf no-context)"

    P4L="$(mkplans plans-loop)"
    rc=0
    O4L="$(AGENTS_CONFIG_DIR="$D4" run_with_timeout "$D4/bin/run-codex-review-loop" \
        --format "$FMT" --session-id "$SID" --plans-dir "$P4L" --draft-file "$P4L/draft.md" \
        --cap 2 --max-extensions 2 --extensions-used 0 \
        --accepted-tradeoffs "$P4L/outline.md" --round 1 2>&1)" || rc=$?
    assert_eq "4: the review loop halts on the same absence" "4" "$rc"
    assert_eq "4: saying which library it needed" \
        "yes" "$(printf '%s' "$O4L" | grep -q -F -e 'required library missing' && printf yes || printf no)"
    assert_eq "4: and allocating no round number for a round that never ran" \
        "no-round" "$([ -e "$P4L/$SID-$FMT-round-number.txt" ] && printf 'allocated-one' || printf no-round)"

    P4O="$(mkplans plans-open)"
    rc=0
    O4O="$(AGENTS_CONFIG_DIR="$D4" SESSION_ID="$SID" PLANS_DIR="$P4O" run_with_timeout bash \
        "$D4/skills/review-code-security/scripts/open-concern-round.sh" 2>&1)" || rc=$?
    assert_eq "4: open-concern-round keeps its exit-0 contract" "0" "$rc"
    assert_eq "4: but says out loud that the round is unnumbered" \
        "yes" "$(printf '%s' "$O4O" | grep -q -F -e 'ROUND=0' && printf yes || printf no)"
    assert_eq "4: and gives the reason on the NOT-STAGED line" \
        "yes" "$(printf '%s' "$O4O" | grep -q -F -e 'NOT-STAGED — the safe-path library is missing' && printf yes || printf no)"
}

echo ""
echo "--- load 5: the guards themselves ---"

# 5. bin/review-code-ledger is the fifth caller and the one this file cannot
#    drive (Skipped-Because: reaching its guard needs a full codex review),
#    so its two lines are pinned where they are written. The entrypoint's five
#    checked sources are pinned for the same reason a per-module row exists:
#    the loss of one check is invisible in the other four.
{
    assert_eq_nz "5: review-code-ledger checks the library is there before sourcing it" \
        "1" "$(grep -c -F 'the safe-path library is missing' "$AGENTS_ROOT/bin/review-code-ledger" | tr -d ' ')"
    assert_eq_nz "5: and checks that sourcing it worked" \
        "1" "$(grep -c -F 'the safe-path library failed to load' "$AGENTS_ROOT/bin/review-code-ledger" | tr -d ' ')"
    assert_eq_nz "5: the entrypoint checks the return value of every module it sources" \
        "5" "$(grep -c -E '^if ! source "\$CL_LIB_DIR/' "$AGENTS_ROOT/bin/lib/concern-ledger.sh" | tr -d ' ')"
    assert_eq_nz "5: and the CLI checks the entrypoint's own" \
        "1" "$(grep -c -F 'if ! . "$SELF_DIR/lib/concern-ledger.sh"' "$AGENTS_ROOT/bin/concern-ledger" | tr -d ' ')"
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
