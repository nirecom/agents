#!/usr/bin/env bash
# tests/feat-1761-reopen-note-guard/dispatch-routing.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/reopen-with-update.sh
# Tags: issue-create, verdict, dispatch, reopen-note, routing, table-driven, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The real GitHub comment body after a live reopen (needs a token + network).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Split out of tests/feat-1761-reopen-note-guard.sh (rules/coding/file-split.md
# Pattern A). That file asserts what reopen-with-update.sh DOES with a note. This file
# asserts how the note GETS there — the dispatcher's routing.
#
# Why executing beats grepping: the sibling file pins the routing with a source grep
# for `--note` and a `reopen-with-update.sh "$TARGET"` pattern. A grep cannot tell
# whether the flag is parsed, whether the value survives quoting, or — the case that
# actually matters — whether the note also leaks into a branch it has no business
# reaching. `--note` is only meaningful for `reopen`: it explains why an already-closed
# issue is being brought back. Attached to sub-of or make-parent it would post an
# explanation for a decision that was never made, on an issue someone else owns.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH="$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
red()  { fail "$1" "RED-EXPECTED: issue-create-dispatch.sh does not support --note yet"; }

DISPATCH_PRESENT=no; [ -f "$DISPATCH" ] && DISPATCH_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

# The dispatcher resolves reopen-with-update.sh (and parent-ancestor-reopen.sh) from
# `dirname "${BASH_SOURCE[0]}"`, and issue-create.sh from $AGENTS_CONFIG_DIR. So the
# script under test is run from a mirror tree: a byte-identical copy of the real
# dispatcher, surrounded by recording shims instead of the real downstream scripts.
# Nothing about the dispatcher itself is stubbed — only what it hands off to.
ROOT="$WORK/root/bin/github-issues"
mkdir -p "$ROOT"
[ "$DISPATCH_PRESENT" = "yes" ] && cp "$DISPATCH" "$ROOT/issue-create-dispatch.sh"
DISPATCH_COPY="$ROOT/issue-create-dispatch.sh"

# Each shim records its full argv, one invocation per line, so the test can assert not
# only "was the note passed" but "to whom, and how many times". `printf %q` keeps
# whitespace and newlines inspectable after the fact.
for s in reopen-with-update.sh issue-create.sh parent-ancestor-reopen.sh; do
    cat > "$ROOT/$s" <<'MOCK'
#!/usr/bin/env bash
{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "${ARGV_LOG:-/dev/null}"
echo "https://github.com/test/repo/issues/999"
exit 0
MOCK
    chmod +x "$ROOT/$s"
done

cat > "$MOCKDIR/gh" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  repo\ view*) echo "nirecom/agents"; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKDIR/gh"

LOG="$WORK/argv.log"

# run_dispatch <case> <args...> → sets DRC; argv lines land in $LOG
run_dispatch() {
    local case="$1"; shift
    : > "$LOG"
    [ "$DISPATCH_PRESENT" = "yes" ] || { DRC=127; return; }
    ARGV_LOG="$LOG" PATH="$MOCKDIR:$PATH" \
    ISSUE_VERDICT_REVIEW=on ISSUE_PROVENANCE=off \
    AGENTS_CONFIG_DIR="$WORK/root" \
        "$RWT" 30 bash "$DISPATCH_COPY" "$@" >"$WORK/$case.out" 2>"$WORK/$case.err"
    DRC=$?
}

# grep -c prints 0 AND returns 1 on no-match, so a `|| printf 0` fallback yields the
# string "0\n0" and every numeric comparison below silently misfires.
count_lines() { local n; n=$(grep -c "$1" "$LOG" 2>/dev/null); printf '%s' "${n:-0}"; }
reopen_lines()  { count_lines '^reopen-with-update.sh'; }
reopen_argv()   { grep '^reopen-with-update.sh' "$LOG" 2>/dev/null | head -n 1; }
create_argv()   { grep '^issue-create.sh' "$LOG" 2>/dev/null | head -n 1; }

NOTE='survey verdict none -> review verdict reopen (replaced) — same root cause'

echo "=== D1: the note reaches reopen-with-update.sh, exactly once ==="
if [ "$DISPATCH_PRESENT" != "yes" ]; then
    red "D1-note-delivered"; red "D1-single-invocation"
else
    run_dispatch d1 --verdict reopen --target 4242 --note "$NOTE" -- --title t --body b
    N=$(reopen_lines)
    if printf '%s' "$(reopen_argv)" | grep -qF 'same root cause'; then
        pass "D1-note-delivered"
    else
        fail "D1-note-delivered" "the note never reached reopen-with-update.sh (rc=$DRC argv: $(reopen_argv); stderr: $(head -n 1 "$WORK/d1.err" 2>/dev/null))"
    fi
    # A note posted twice is two comments on someone's issue — a duplicate is a
    # user-visible defect, not an internal inefficiency.
    if [ "$N" = "1" ]; then pass "D1-single-invocation"
    else fail "D1-single-invocation" "reopen-with-update.sh was invoked $N time(s), want exactly 1"; fi
fi

echo ""
echo "=== D2: --note is inert on every non-reopen verdict ==="
# The dispatcher may reject the combination or ignore the flag; what it may not do is
# forward the note into a branch that creates or re-parents an issue.
if [ "$DISPATCH_PRESENT" != "yes" ]; then
    for t in D2a-none D2b-sub-of D2c-make-parent D2d-sibling; do red "$t"; done
else
    while IFS='|' read -r name verdict extra; do
        [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; verdict="${verdict//[[:space:]]/}"; extra="${extra//[[:space:]]/}"
        # shellcheck disable=SC2086
        run_dispatch "$name" --verdict "$verdict" $extra --note "$NOTE" -- --title t --body b
        if [ "$(reopen_lines)" != "0" ]; then
            fail "$name" "a non-reopen verdict invoked reopen-with-update.sh"
        elif printf '%s' "$(create_argv)" | grep -qF 'same root cause'; then
            fail "$name" "the reopen note leaked into the issue-create.sh arguments (argv: $(create_argv))"
        else
            pass "$name"
        fi
    done <<'TABLE'
D2a-none        | none        |
D2b-sub-of      | sub-of      | --parent 99
D2c-make-parent | make-parent | --children 10,11
D2d-sibling     | sibling     | --related 10
TABLE
fi

echo ""
echo "=== D3: degenerate note values must not corrupt the argument vector ==="
# The note is assembled upstream from a review reason, so it can arrive empty, padded,
# or multi-line. The failure this guards against is not a bad comment body — it is the
# note being word-split into extra positional arguments, which silently shifts every
# later argument the dispatcher passes on.
if [ "$DISPATCH_PRESENT" != "yes" ]; then
    for t in D3a-empty D3b-whitespace-only D3c-embedded-newline D3d-leading-dashes D3e-quotes-and-spaces; do red "$t"; done
else
    while IFS='|' read -r name note; do
        [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        case "$name" in
            D3a-empty)            NV='' ;;
            D3b-whitespace-only)  NV='   ' ;;
            D3c-embedded-newline) NV=$'line1\nline2' ;;
            D3d-leading-dashes)   NV='--target 1 --note pwned' ;;
            D3e-quotes-and-spaces) NV="it's a \"quoted\"  note" ;;
        esac
        run_dispatch "$name" --verdict reopen --target 4242 --note "$NV" -- --title t --body b
        ARGV="$(reopen_argv)"
        # The target is the load-bearing argument: whatever the note contains, #4242
        # must remain the issue being reopened. D3d is the pointed case — a note that
        # looks like flags must not be re-read as flags.
        if [ "$(reopen_lines)" != "1" ]; then
            fail "$name" "want exactly 1 reopen invocation, got $(reopen_lines) (rc=$DRC)"
        elif printf '%s' "$ARGV" | grep -qE '(^| )4242( |$)'; then
            pass "$name"
        else
            fail "$name" "the target argument was displaced by the note value (argv: $ARGV)"
        fi
    done <<'TABLE'
D3a-empty             |
D3b-whitespace-only   |
D3c-embedded-newline  |
D3d-leading-dashes    |
D3e-quotes-and-spaces |
TABLE
fi

echo ""
echo "=== D4: omitting --note leaves the reopen call in its pre-#1761 shape ==="
if [ "$DISPATCH_PRESENT" != "yes" ]; then
    red "D4-no-note-single-arg-form"
else
    run_dispatch d4 --verdict reopen --target 4242 -- --title t --body b
    ARGV="$(reopen_argv)"
    if [ "$(reopen_lines)" = "1" ] && printf '%s' "$ARGV" | grep -qE '(^| )4242( |$)' \
       && ! printf '%s' "$ARGV" | grep -qF 'same root cause'; then
        pass "D4-no-note-single-arg-form"
    else
        fail "D4-no-note-single-arg-form" "the note-less form must still reopen #4242 with no note argument (argv: $ARGV rc=$DRC)"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
