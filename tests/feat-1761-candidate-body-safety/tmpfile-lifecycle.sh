#!/usr/bin/env bash
# tests/feat-1761-candidate-body-safety/tmpfile-lifecycle.sh
# Tests: bin/github-issues/review-survey-verdict-codex.sh
# Tags: issue-create, verdict, review, codex, tmpfile, permissions, signals, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether the surrounding temp directory permits traversal at all. On a host with a
#   per-user $TMPDIR the mode matters less; on a shared /tmp it is the only barrier.
# - SIGKILL. Nothing the script can write survives it — an uninterruptible kill leaves the
#   temp files behind by construction, so it is a property of the OS, not of this code.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Section of tests/feat-1761-candidate-body-safety.sh (subprocess; tests/lib/section-runner.sh).
#
# The sibling tmpfile-residue.sh proves the temp files are GONE at the end. Two windows
# stay unexamined, and the candidate bodies sit in both:
#
#   (a) WHILE the file exists — the whole prompt (verbatim untrusted issue text) lives in
#       $TMPDIR for the life of the codex call. `mktemp` is 0600 on our platforms but does
#       not promise it, so the script pins the mode; a pin that silently failed or was
#       dropped is invisible from outside.
#   (b) WHEN THE OPERATOR INTERRUPTS — the sibling's "killed" case kills the codex CHILD,
#       so the script always reaches its own exit. Cleanup as a plain last line survives
#       that case and still leaks on Ctrl-C/TERM.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
RS="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

CANARY_BODY='CANARY-LIFECYCLE-9d3ac1-do-not-persist'

# codex mock. Two extra jobs beyond the sibling's:
#   - record the mode of every regular file under $TMPDIR while the review is mid-flight
#     (the only moment the prompt file exists);
#   - announce that it has started, so the driver can time a signal to land INSIDE the
#     window rather than guessing at a sleep.
cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
if [ -n "${TMP_MODE_LOG:-}" ]; then
    find "${TMPDIR:-/tmp}" -maxdepth 1 -type f -print 2>/dev/null | while IFS= read -r f; do
        printf '%s\t%s\n' "$(stat -c '%a' "$f" 2>/dev/null)" "$f" >> "$TMP_MODE_LOG"
    done
fi
[ -n "${CODEX_STARTED_FLAG:-}" ] && : > "$CODEX_STARTED_FLAG"
if [ -n "${CODEX_MOCK_SLEEP:-}" ]; then sleep "$CODEX_MOCK_SLEEP"; fi
if [ -n "${CODEX_MOCK_OUT:-}" ] && [ -f "$CODEX_MOCK_OUT" ]; then cat "$CODEX_MOCK_OUT"; fi
exit "${CODEX_MOCK_RC:-0}"
MOCK
chmod +x "$MOCKDIR/codex"

HONEST='{"verdict":"sibling","target":null,"children":[],"related":[10],"reason":"adjacent but distinct concerns"}'

build_artifact() {  # <path>
    CB="$CANARY_BODY" \
    "$RWT" 15 node -e "
const fs = require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  proposal: { title: 'review stage temp-file lifecycle',
              background: 'context', changes: 'add a guard' },
  verdict: 'sibling', same_fix: false, target: null, children: [], related: [10],
  reason: 'adjacent but distinct',
  relations_mode: 'batched', relation_errors: [],
  candidates: [
    { number: 10, title: 'benign candidate', state: 'open', labels: ['type:task'],
      body: 'ordinary text ' + process.env.CB, relation_status: 'resolved',
      parent_number: null, parent_is_meta: false, has_sub_issues: false }
  ]
}, null, 2));" "$(node_path "$1")"
}

# prepare_case <name> → sets CASE_DIR, ART, FINAL and builds the artifact.
prepare_case() {
    CASE_DIR="$WORK/$1"
    mkdir -p "$CASE_DIR/tmp" "$CASE_DIR/logs"
    ART="$CASE_DIR/survey.json"; FINAL="$CASE_DIR/final.json"
    build_artifact "$ART"
    printf '%s' "$HONEST" > "$CASE_DIR/codex-out.txt"
}

# residue <dir> → paths under <dir> whose contents carry the canary.
residue() {
    [ -d "$1" ] || return 0
    find "$1" -type f -print 2>/dev/null | while IFS= read -r f; do
        grep -qF "$CANARY_BODY" "$f" 2>/dev/null && printf '%s\n' "$f"
    done
}

if [ ! -f "$RS" ]; then
    fail "P0-review-script-present" "bin/github-issues/review-survey-verdict-codex.sh not found — nothing to exercise"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

echo "=== P: the prompt file's mode WHILE it exists ==="

# Platform gate, same shape as feat-1699-meta-parent-guard/body-file-mode.sh: on MSYS /
# Git-Bash over NTFS, chmod is a no-op and every file reports 644. Asserting 600 there
# would be a false RED about the host, not a finding about the code.
printf 'x' > "$WORK/mode-probe"
chmod 600 "$WORK/mode-probe" 2>/dev/null || true
MODE_OBSERVABLE=no
[ "$(stat -c '%a' "$WORK/mode-probe" 2>/dev/null)" = "600" ] && MODE_OBSERVABLE=yes

if [ "$MODE_OBSERVABLE" != "yes" ]; then
    skip "P1-prompt-file-observed-while-live (POSIX mode bits unobservable: chmod 600 reports $(stat -c '%a' "$WORK/mode-probe" 2>/dev/null || echo '<stat unavailable>'))"
    skip "P2-every-live-temp-file-is-0600"
else
    prepare_case P-mode
    MODE_LOG="$CASE_DIR/modes.tsv"; : > "$MODE_LOG"
    env TMPDIR="$CASE_DIR/tmp" TMP="$CASE_DIR/tmp" TEMP="$CASE_DIR/tmp" \
        TMP_MODE_LOG="$MODE_LOG" \
        CODEX_MOCK_OUT="$CASE_DIR/codex-out.txt" CODEX_PROMPT_LOG="$CASE_DIR/prompt.txt" \
        PATH="$MOCKDIR:$PATH" \
        "$RWT" 60 bash "$RS" --artifact "$ART" --out "$FINAL" --log-dir "$CASE_DIR/logs" \
        >"$CASE_DIR/stdout.txt" 2>"$CASE_DIR/stderr.txt"

    # Non-vacuity: with no observation there is nothing to judge, and "no bad mode found"
    # would be the same answer as "no file existed".
    OBSERVED=$(grep -c . "$MODE_LOG" 2>/dev/null || true)
    if [ "${OBSERVED:-0}" -ge 1 ]; then
        pass "P1-prompt-file-observed-while-live"
    else
        fail "P1-prompt-file-observed-while-live" "no temp file was visible in \$TMPDIR while codex ran — the mode assertion below would be vacuous"
    fi

    BAD="$(awk -F'\t' '$1 != "600" { printf "%s(%s) ", $2, $1 }' "$MODE_LOG" 2>/dev/null)"
    if [ -z "$BAD" ]; then
        pass "P2-every-live-temp-file-is-0600"
    else
        fail "P2-every-live-temp-file-is-0600" "a temp file holding the prompt (candidate bodies verbatim) was group/world readable for the whole codex call: $BAD"
    fi
fi

echo ""
echo "=== Q: interruption mid-review leaves nothing behind ==="

# run_interrupted <name> <signal> — start the review, wait until codex is actually running,
# signal the REVIEW SCRIPT (not the child), and return once it has gone.
#
# The signal is timed on the mock's own start flag rather than a fixed sleep: a
# sleep-and-hope would drift into signalling before the temp files exist, and the case
# would then pass without ever having tested anything.
run_interrupted() {
    local name="$1" sig="$2"
    prepare_case "$name"
    STARTED="$CASE_DIR/codex-started"
    rm -f "$STARTED"
    env TMPDIR="$CASE_DIR/tmp" TMP="$CASE_DIR/tmp" TEMP="$CASE_DIR/tmp" \
        CODEX_MOCK_OUT="$CASE_DIR/codex-out.txt" CODEX_PROMPT_LOG="$CASE_DIR/prompt.txt" \
        CODEX_STARTED_FLAG="$STARTED" CODEX_MOCK_SLEEP=4 \
        PATH="$MOCKDIR:$PATH" \
        bash "$RS" --artifact "$ART" --out "$FINAL" --log-dir "$CASE_DIR/logs" \
        >"$CASE_DIR/stdout.txt" 2>"$CASE_DIR/stderr.txt" &
    RS_PID=$!

    local waited=0
    while [ ! -f "$STARTED" ] && [ "$waited" -lt 300 ]; do
        sleep 0.1; waited=$((waited + 1))
    done
    STARTED_OK=no; [ -f "$STARTED" ] && STARTED_OK=yes

    kill -"$sig" "$RS_PID" 2>/dev/null || true
    # The script is blocked on its codex child, so the handler runs once that child exits.
    # Bounded so a script that ignores the signal outright cannot hang the suite.
    waited=0
    while kill -0 "$RS_PID" 2>/dev/null && [ "$waited" -lt 300 ]; do
        sleep 0.1; waited=$((waited + 1))
    done
    wait "$RS_PID" 2>/dev/null; RS_RC=$?
    ALIVE=no; kill -0 "$RS_PID" 2>/dev/null && ALIVE=yes
}

assert_interrupted_clean() {  # <name> <signal>
    local name="$1" sig="$2" hits left

    if [ "$STARTED_OK" = "yes" ]; then
        pass "Q-$sig-signal-landed-inside-the-review-window"
    else
        fail "Q-$sig-signal-landed-inside-the-review-window" "codex never started, so the signal did not interrupt a live review — the residue assertions below are vacuous"
    fi

    if [ "$ALIVE" = "no" ]; then
        pass "Q-$sig-review-terminated"
    else
        fail "Q-$sig-review-terminated" "the review is still running after SIG$sig — it ignores the signal an operator uses to stop it"
    fi

    hits="$(residue "$CASE_DIR/tmp" | tr '\n' ' ')"
    if [ -z "$hits" ]; then
        pass "Q-$sig-no-canary-left-in-tmp"
    else
        fail "Q-$sig-no-canary-left-in-tmp" "candidate body text survives an interrupted review in \$TMPDIR: $hits"
    fi

    # Stricter than the canary check: an emptied-but-present temp file still discloses that
    # a review ran, and is the shape a partial cleanup leaves.
    left="$(find "$CASE_DIR/tmp" -mindepth 1 2>/dev/null | tr '\n' ' ')"
    if [ -z "$left" ]; then
        pass "Q-$sig-tmp-sandbox-empty"
    else
        fail "Q-$sig-tmp-sandbox-empty" "temp entries survive SIG$sig: $left"
    fi

    hits="$(residue "$CASE_DIR/logs" | tr '\n' ' ')"
    if [ -z "$hits" ]; then
        pass "Q-$sig-no-canary-in-log-dir"
    else
        fail "Q-$sig-no-canary-in-log-dir" "candidate body text reached --log-dir on the interrupted path: $hits"
    fi
}

# TERM: what a supervising process (CI runner, timeout wrapper, worktree teardown) sends.
run_interrupted Q1-term TERM
assert_interrupted_clean Q1-term TERM

# INT: what the operator sends with Ctrl-C. Same obligation, different arrival — a handler
# registered for only one of the two is the asymmetry this pair exists to catch (CPR-ORTH).
run_interrupted Q2-int INT
assert_interrupted_clean Q2-int INT

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
