#!/usr/bin/env bash
# tests/feat-1761-candidate-body-safety/tmpfile-residue.sh
# Tests: bin/github-issues/review-survey-verdict-codex.sh
# Tags: issue-create, verdict, review, codex, leak, tmpfile, security, table-driven, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Temp files written by the real codex CLI itself (outside this script's control).
# - OS-level recovery of unlinked-but-not-overwritten blocks.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Split out of tests/feat-1761-candidate-body-safety.sh (rules/coding/file-split.md
# Pattern A). The sibling file covers the *declared* outputs (--out, stdout, stderr,
# --log-dir). This file covers the *undeclared* one: the temp directory.
#
# Why this is a separate concern (CPR-SC): the review has to materialise the prompt
# somewhere before handing it to codex, and the obvious implementation is a temp file.
# A temp file is not an output the author thinks about, it survives the process, and
# on a shared host it is world-readable by default. The sibling file's assertions
# would all still pass while a full candidate body sat in $TMPDIR.
#
# Why all four outcomes (CPR-UNV): cleanup written as a plain last line of the happy
# path disappears the moment the run does not reach that line. success is the case
# an author tests; invalid, timeout and killed are the cases that actually leak.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
RS="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
red()  { fail "$1" "RED-EXPECTED: bin/github-issues/review-survey-verdict-codex.sh not yet created"; }

RS_PRESENT=no; [ -f "$RS" ] && RS_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

# codex mock. CODEX_MOCK_SLEEP outlives the --timeout the script passes (timeout case);
# CODEX_MOCK_SIGNAL makes the child die abruptly with no chance to clean up (killed case).
cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
if [ -n "${CODEX_MOCK_SIGNAL:-}" ]; then kill -"$CODEX_MOCK_SIGNAL" $$; sleep 5; fi
if [ -n "${CODEX_MOCK_SLEEP:-}" ]; then sleep "$CODEX_MOCK_SLEEP"; fi
if [ -n "${CODEX_MOCK_OUT:-}" ] && [ -f "$CODEX_MOCK_OUT" ]; then cat "$CODEX_MOCK_OUT"; fi
exit "${CODEX_MOCK_RC:-0}"
MOCK
chmod +x "$MOCKDIR/codex"

CANARY_BODY='CANARY-TMPBODY-4b81ee-do-not-persist'
CANARY_PROP='CANARY-TMPPROP-c02f5a-do-not-persist'

build_artifact() {  # <path>
    CB="$CANARY_BODY" CP="$CANARY_PROP" \
    "$RWT" 15 node -e "
const fs = require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  proposal: { title: 'review stage temp-file residue',
              background: 'private context ' + process.env.CP,
              changes: 'add a guard' },
  verdict: 'sibling', target: null, children: [], related: [10],
  reason: 'adjacent but distinct',
  relations_mode: 'batched', relation_errors: [],
  candidates: [
    { number: 10, title: 'benign candidate', state: 'open', labels: ['type:task'],
      body: 'ordinary text ' + process.env.CB, relation_status: 'resolved',
      parent_number: null, parent_is_meta: false, has_sub_issues: false }
  ]
}, null, 2));" "$(node_path "$1")"
}

HONEST='{"verdict":"sibling","target":null,"children":[],"related":[10],"reason":"adjacent but distinct concerns"}'

# residue <dir> → newline-separated paths under <dir> containing either canary.
# Reads every regular file, including dotfiles and nested dirs, because a temp file
# named `.review-prompt.XXXX` is exactly as leaky as a visible one.
residue() {
    local d="$1"
    [ -d "$d" ] || return 0
    find "$d" -type f -print 2>/dev/null | while IFS= read -r f; do
        if grep -qF "$CANARY_BODY" "$f" 2>/dev/null || grep -qF "$CANARY_PROP" "$f" 2>/dev/null; then
            printf '%s\n' "$f"
        fi
    done
}

# run_case <name> [extra env assignments...]
# TMPDIR/TMP/TEMP are all redirected: which one the implementation honours depends on
# whether it uses mktemp(1), Node's os.tmpdir(), or $TMPDIR directly, and pinning only
# one of them would let the other two escape into the real system temp directory.
run_case() {
    local name="$1"; shift
    local d="$WORK/$name"
    mkdir -p "$d/tmp" "$d/logs"
    ART="$d/survey.json"; FINAL="$d/final.json"
    build_artifact "$ART"
    printf '%s' "${CASE_OUT:-$HONEST}" > "$d/codex-out.txt"
    [ "$RS_PRESENT" != "yes" ] && { RC=127; return 1; }
    env TMPDIR="$d/tmp" TMP="$d/tmp" TEMP="$d/tmp" \
        CODEX_MOCK_OUT="$d/codex-out.txt" CODEX_PROMPT_LOG="$d/prompt.txt" \
        PATH="$MOCKDIR:$PATH" "$@" \
        "$RWT" 40 bash "$RS" --artifact "$ART" --out "$FINAL" --log-dir "$d/logs" \
        >"$d/stdout.txt" 2>"$d/stderr.txt"
    RC=$?
    return 0
}

# assert_clean <name>: the temp sandbox holds no canary, and the prompt did carry one.
assert_clean() {
    local name="$1" d="$WORK/$1" hits
    # Positive control per case: if codex never received the body, "no residue" is
    # vacuous. The timeout/killed cases still reach the mock, which logs the prompt
    # before dying, so this control holds for all four outcomes.
    if grep -qF "$CANARY_BODY" "$d/prompt.txt" 2>/dev/null; then
        pass "$name-prompt-carried-canary"
    else
        fail "$name-prompt-carried-canary" "codex never received the candidate body — the residue assertion below would be vacuous"
    fi

    hits=$(residue "$d/tmp" | tr '\n' ' ')
    if [ -z "$hits" ]; then pass "$name-no-tmp-residue"
    else fail "$name-no-tmp-residue" "canary text survives in the temp sandbox: $hits"; fi

    # Not just "no canary" but "no leftovers at all": an emptied-but-not-removed temp
    # file still discloses that a review ran and on what.
    LEFT=$(find "$d/tmp" -mindepth 1 2>/dev/null | tr '\n' ' ')
    if [ -z "$LEFT" ]; then pass "$name-tmp-sandbox-empty"
    else fail "$name-tmp-sandbox-empty" "temp entries left behind: $LEFT"; fi

    # The retained log is a declared output, but it must not become a leak channel
    # on the failure paths either (the sibling file only checks the success path).
    hits=$(residue "$d/logs" | tr '\n' ' ')
    if [ -z "$hits" ]; then pass "$name-no-log-residue"
    else fail "$name-no-log-residue" "canary text survives in --log-dir: $hits"; fi
}

CASES="T1-success T2-invalid T3-timeout T4-killed"

if [ "$RS_PRESENT" != "yes" ]; then
    for c in $CASES; do
        for t in prompt-carried-canary no-tmp-residue tmp-sandbox-empty no-log-residue; do red "$c-$t"; done
    done
    red "T5-exit-0-on-every-outcome"
    red "T6-canary-absent-from-system-tmpdir"
else
    echo "=== T1: success — the outcome an author does test ==="
    run_case T1-success
    RC1=$RC
    assert_clean T1-success

    echo ""
    echo "=== T2: invalid — codex answered, but not with a usable verdict ==="
    # Garbage output folds to review_result: invalid. The prompt still existed, so the
    # cleanup obligation is identical; only the exit path through the script differs.
    CASE_OUT='I could not determine a verdict. Sorry!' run_case T2-invalid
    RC2=$RC
    assert_clean T2-invalid

    echo ""
    echo "=== T3: timeout — the script's own timeout fires mid-review ==="
    run_case T3-timeout CODEX_MOCK_SLEEP=30
    RC3=$RC
    assert_clean T3-timeout

    echo ""
    echo "=== T4: killed — the child dies with no chance to run a cleanup line ==="
    run_case T4-killed CODEX_MOCK_SIGNAL=KILL
    RC4=$RC
    assert_clean T4-killed

    echo ""
    echo "=== T5/T6: the fold and the real system temp directory ==="
    if [ "${RC1:-1}" -eq 0 ] && [ "${RC2:-1}" -eq 0 ] && [ "${RC3:-1}" -eq 0 ] && [ "${RC4:-1}" -eq 0 ]; then
        pass "T5-exit-0-on-every-outcome"
    else
        fail "T5-exit-0-on-every-outcome" "the review must always exit 0 (got: $RC1/$RC2/$RC3/$RC4)"
    fi

    # Belt and braces: if the implementation ignores all three temp env vars, the
    # per-case sandboxes stay clean and every assertion above passes vacuously. This
    # looks for the canary where it would actually have landed in that scenario.
    SYS_TMP="${TMPDIR:-/tmp}"
    SYS_HITS=$(find "$SYS_TMP" -maxdepth 2 -type f -newer "$WORK" 2>/dev/null | while IFS= read -r f; do
        grep -qF "$CANARY_BODY" "$f" 2>/dev/null && printf '%s\n' "$f"
    done | tr '\n' ' ')
    if [ -z "$SYS_HITS" ]; then pass "T6-canary-absent-from-system-tmpdir"
    else fail "T6-canary-absent-from-system-tmpdir" "TMPDIR was ignored and the body landed in the real temp dir: $SYS_HITS"; fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
