#!/usr/bin/env bash
# tests/bin-concern-ledger-shared-code-review.sh
# Tests: bin/review-code-ledger, bin/concern-ledger, bin/review-code-codex, bin/run-codex-review-loop, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/render.sh, skills/review-code-security/scripts/open-concern-round.sh, skills/review-code-security/scripts/run-quality-gates.sh, skills/review-code-security/scripts/close-concern-round.sh, agents/security-scanner.md
# Tags: concern-ledger, review-code, shared-ledger, exec-label, table-driven, scope:common, pwsh-not-required
#
# TL2 dispatcher for the shared code-review ledger path (#1992 / #1996).
# Drives the real bin/review-code-ledger -> bin/review-code-codex chain inside a
# throwaway git repo, with only the external `codex` CLI mocked.
# Cases live in tests/bin-concern-ledger-shared-code-review/ (rules/coding/file-split.md).

# TL3 gap (mitigation category: skill-orchestration)
#   Not covered here, and covered nowhere below TL3:
#     - The real `codex` CLI and a real LLM response. The mock replays a scripted
#       body, so reviewer wording drift (e.g. a model that stops emitting the
#       `[SEV] <ref> | <path>#<anchor> | <category> | <text>` bullet form) is
#       invisible to this suite.

#     - The SKILL.md text that reaches the three scripts. full-chain-integration.sh
#       runs open-concern-round.sh / run-quality-gates.sh / close-concern-round.sh
#       in the documented order, but a SKILL.md that stops calling one of them,
#       or dispatches the security-scanner subagent without the round it was
#       handed, still passes.
#     - The security-scanner subagent itself: it is replayed as the report file
#       it is contracted to produce, never run.

#     - True concurrency of the SC-P window (two producers writing at the same
#       instant). Staging is sequential here.
#   Mitigation: the orchestration text is pinned statically by
#   tests/bin-concern-ledger-finalize.sh (cases 8/9), and the day-to-day runner
#   for the wiring itself is a manual /review-code-security run.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER_BIN="$AGENTS_ROOT/bin/review-code-ledger"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
CODEX_BIN="$AGENTS_ROOT/bin/review-code-codex"
SUMMARIZE="$AGENTS_ROOT/bin/review-loop-summarize-concerns"

PASS=0
FAIL=0

# Known-gap assertions (the fail-closed cases). Sourced after FAIL exists, which
# the helpers increment on an XPASS. See tests/lib/xfail.sh for the contract.
# shellcheck source=./lib/xfail.sh
. "$AGENTS_ROOT/tests/lib/xfail.sh"

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

# assert_eq with a guard: an expectation that could not be computed (empty) is
# itself a failure, so '' == '' can never pass while the implementation is absent.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

assert_match() {
    local name="$1" re="$2" got="$3"
    if printf '%s' "$got" | grep -Eq -- "$re"; then
        pass "$name"
    else
        echo "FAIL: $name — value=$(printf '%q' "$got") does not match /$re/"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        pass "$name"
    else
        echo "FAIL: $name — output does not contain $(printf '%q' "$needle")"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        echo "FAIL: $name — output unexpectedly contains $(printf '%q' "$needle")"
        FAIL=$((FAIL + 1))
    else
        pass "$name"
    fi
}

# Every non-blank line of <block> must appear in <haystack>. An empty block is a
# failure (grep -F would otherwise treat it as a match-everything pattern).
assert_contains_block() {
    local name="$1" block="$2" hay="$3" line missing=""
    if [ -z "$(trim "$block")" ]; then
        echo "FAIL: $name — the expected block is empty (nothing was rendered)"
        FAIL=$((FAIL + 1))
        return
    fi
    while IFS= read -r line; do
        [ -z "$(trim "$line")" ] && continue
        printf '%s' "$hay" | grep -Fq -- "$line" || missing="$line"
    done <<< "$block"
    if [ -n "$missing" ]; then
        echo "FAIL: $name — line missing from the observed output: $(printf '%q' "$missing")"
        FAIL=$((FAIL + 1))
    else
        pass "$name"
    fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md).
# The inherited session ids are unset here; each case exports a *fixture* id
# instead, because the code under test must resolve a session to stage at all.
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
cd "$TMPDIR_BASE" || exit 1

# --- fixture git repos ------------------------------------------------------
# mk_repo <dir> <extra-lines>  — main + a feature branch whose diff vs main is
# <extra-lines> long. Git hooks are disabled immediately (fixture-isolation.md).
mk_repo() {
    local dir="$1" lines="$2" i
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
    git -C "$dir" branch -M main
    git -C "$dir" checkout -q -b feature-test
    for ((i = 0; i < lines; i++)); do
        printf 'line %s\n' "$i" >> "$dir/reviewed.txt"
    done
    git -C "$dir" add reviewed.txt
    git -C "$dir" commit -q -m "feature commit"
}

REPO="$TMPDIR_BASE/repo"
mk_repo "$REPO" 20
REPO_BIG="$TMPDIR_BASE/repo-big"
mk_repo "$REPO_BIG" 6000   # > MAX_DIFF_LINES (5000) -> Scope: TRUNCATED

# --- codex CLI mock ---------------------------------------------------------
# The only mocked boundary: the external `codex` binary. It records the prompt
# it received and replays a scripted body with a scripted exit code.
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_MOCK_PROMPT:-/dev/null}"
if [ -n "${CODEX_MOCK_BODY:-}" ] && [ -f "${CODEX_MOCK_BODY}" ]; then
  cat "${CODEX_MOCK_BODY}"
fi
exit "${CODEX_MOCK_EXIT:-0}"
MOCK
chmod +x "$MOCK_BIN/codex"

FULL_PATH="$MOCK_BIN:$PATH"

# A PATH with every directory that holds a `codex` executable removed — the
# SKIPPED label needs codex genuinely absent, and trimming to /usr/bin would
# also strip git/node on some hosts (CPR-UNV: no environment assumption).
path_without_codex() {
    local out="" d
    local OLDIFS="$IFS"
    IFS=':'
    for d in $PATH; do
        [ -n "$d" ] || continue
        if [ -x "$d/codex" ] || [ -x "$d/codex.exe" ] || [ -x "$d/codex.cmd" ]; then
            continue
        fi
        out="${out:+$out:}$d"
    done
    IFS="$OLDIFS"
    printf '%s' "$out"
}
NO_CODEX_PATH="$(path_without_codex)"

# --- reviewer body builders -------------------------------------------------
# anchored <sev> <ref> <path> <anchor> <category> <text> → one delta bullet body
anchored() { printf '[%s] %s | %s#%s | %s | %s' "$1" "$2" "$3" "$4" "$5" "$6"; }

# mk_body <file> <anchored-line>...  — reviewer output grouped by severity, the
# shape skills/review-code-codex documents. No lines → explicit "(none)".
mk_body() {
    local f="$1" sev l
    shift
    {
        printf 'Adversarial review of the diff.\n\n'
        if [ "$#" -eq 0 ]; then
            printf '(none)\n'
        else
            for sev in HIGH MEDIUM LOW; do
                for l in "$@"; do
                    case "$l" in "[$sev]"*) ;; *) continue ;; esac
                    printf '## %s\n- %s\n' "$sev" "$l"
                done
            done
        fi
    } > "$f"
}

NONE_BODY="$TMPDIR_BASE/body-none.txt"
mk_body "$NONE_BODY"

# mk_report <file> <anchored-line>...  — a security-scanner report carrying the
# '## Concern Delta' section that bin/concern-ledger stage --from-report reads.
mk_report() {
    local f="$1" l
    shift
    {
        printf '# Security Scan Report\n\n'
        printf '## Concern Delta\n'
        if [ "$#" -eq 0 ]; then printf '(none)\n'; fi
        for l in "$@"; do printf '%s\n' "$l"; done
        printf '\n'
    } > "$f"
}

# --- environment per case ---------------------------------------------------
ENV_SEQ=0
PLANS=""
SID=""
new_env() {
    ENV_SEQ=$((ENV_SEQ + 1))
    SID="clsess$ENV_SEQ"
    PLANS="$TMPDIR_BASE/plans-$ENV_SEQ"
    mkdir -p "$PLANS" "$PLANS/workflow-state"
    RL_PLANS="$PLANS"
    RL_SID="$SID"
    RL_ROUND=""
    RL_REPO="$REPO"
    RL_PATH="$FULL_PATH"
    RL_BASE_STATE="RECORDED"
    RL_CODEX_BODY="$NONE_BODY"
    RL_CODEX_EXIT=0
    RL_HOME="$TMPDIR_BASE"
}

RL_PLANS=""; RL_SID=""; RL_ROUND=""; RL_REPO="$REPO"; RL_PATH="$FULL_PATH"
RL_BASE_STATE="RECORDED"; RL_CODEX_BODY=""; RL_CODEX_EXIT=0; RL_HOME="$TMPDIR_BASE"
LAST_OUT=""; LAST_RC=0; LAST_ERR=""; LAST_PROMPT=""
RUN_SEQ=0

# run_ledger [extra args] — runs bin/review-code-ledger with the current RL_* env.
# Sets LAST_OUT / LAST_RC / LAST_ERR / LAST_PROMPT.
run_ledger() {
    RUN_SEQ=$((RUN_SEQ + 1))
    LAST_PROMPT="$TMPDIR_BASE/prompt-$RUN_SEQ.txt"
    LAST_ERR="$TMPDIR_BASE/rl-err-$RUN_SEQ.txt"
    : > "$LAST_PROMPT"
    : > "$LAST_ERR"
    LAST_RC=0
    LAST_OUT=$(
        cd "$RL_REPO" || exit 1
        export PATH="$RL_PATH" HOME="$RL_HOME"
        export CODEX_MOCK_PROMPT="$LAST_PROMPT" CODEX_MOCK_BODY="$RL_CODEX_BODY" \
               CODEX_MOCK_EXIT="$RL_CODEX_EXIT"
        if [ -n "$RL_PLANS" ]; then
            export PLANS_DIR="$RL_PLANS" WORKFLOW_PLANS_DIR="$RL_PLANS" \
                   CLAUDE_WORKFLOW_DIR="$RL_PLANS/workflow-state" \
                   SESSION_ID="$RL_SID" CLAUDE_SESSION_ID="$RL_SID" \
                   CLAUDE_CODE_SESSION_ID="$RL_SID"
        else
            unset PLANS_DIR WORKFLOW_PLANS_DIR CLAUDE_WORKFLOW_DIR \
                  SESSION_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
        fi
        if [ -n "$RL_ROUND" ]; then export CONCERN_LEDGER_ROUND="$RL_ROUND"
        else unset CONCERN_LEDGER_ROUND; fi
        bash "$LEDGER_BIN" --base main --base-state "$RL_BASE_STATE" "$@" 2>"$LAST_ERR"
    ) || LAST_RC=$?
}

# run_codex_direct — the same invocation without the ledger wrapper (case 2 baseline).
run_codex_direct() {
    RUN_SEQ=$((RUN_SEQ + 1))
    local prompt="$TMPDIR_BASE/prompt-direct-$RUN_SEQ.txt"
    : > "$prompt"
    (
        cd "$RL_REPO" || exit 1
        export PATH="$RL_PATH" HOME="$RL_HOME"
        export CODEX_MOCK_PROMPT="$prompt" CODEX_MOCK_BODY="$RL_CODEX_BODY" \
               CODEX_MOCK_EXIT="$RL_CODEX_EXIT"
        bash "$CODEX_BIN" --base main --base-state "$RL_BASE_STATE" "$@" 2>/dev/null
    )
}

# run_cli <args...> — bin/concern-ledger, replaying what the skill steps do.
run_cli() { bash "$CLI" "$@"; }

# cl <fn> <args...> — direct library probe in an isolated subshell.
cl() { ( set +u; source "$LIB" >/dev/null 2>&1 || exit 127; "$@" ); }

# --- artifact readers -------------------------------------------------------
FORMAT="review-security-shared"
ledger_file()  { printf '%s/%s-%s-concern-ledger.txt' "$1" "$2" "$FORMAT"; }
round_file()   { printf '%s/%s-%s-round-number.txt' "$1" "$2" "$FORMAT"; }
delta_file()   { printf '%s/%s-%s-round-%s-delta-%s.txt' "$1" "$2" "$FORMAT" "$3" "$4"; }

# staging_field <staging-file> <n> — header is
# '#producer|<name>|<completeness>|<exec>|<parse>|<round>'.
staging_field() {
    grep -m1 '^#producer|' "$1" 2>/dev/null | cut -d'|' -f"$2"
}

F_SEV=2; F_STATE=3; F_FIRST=4; F_LAST=5; F_SLOT=6; F_DISCRIM=7
F_ORIGIN=8; F_PRODUCERS=9; F_FLAGS=10

entry_field() { grep -m1 -- "^$2|" "$1" 2>/dev/null | cut -d'|' -f"$3"; }
entry_text()  { grep -m1 -- "^$2|" "$1" 2>/dev/null | cut -d'|' -f11-; }
entry_count() { grep -cE '^C[0-9]+\|' "$1" 2>/dev/null || true; }

# id_for_text <ledger> <text> → the ID whose TEXT is exactly <text>, else NONE.
id_for_text() {
    local f="$1" t="$2" line body
    [ -f "$f" ] || { printf 'NONE'; return; }
    while IFS= read -r line; do
        case "$line" in C[0-9]*\|*) ;; *) continue ;; esac
        body="$(printf '%s' "$line" | cut -d'|' -f11-)"
        [ "$body" = "$t" ] || continue
        printf '%s' "$(printf '%s' "$line" | cut -d'|' -f1)"
        return
    done < "$f"
    printf 'NONE'
}

# id_is <ledger> <text> <expected-id> → same | different | not-found
# 'not-found' covers both an absent entry and an uncomputable expectation, so a
# missing implementation can never read as "the ID was preserved".
id_is() {
    local got
    got="$(id_for_text "$1" "$2")"
    case "$got" in C[0-9]*) ;; *) printf 'not-found'; return ;; esac
    case "$3" in C[0-9]*) ;; *) printf 'not-found'; return ;; esac
    if [ "$got" = "$3" ]; then printf 'same'; else printf 'different'; fi
}

# id_class <id> <forbidden>... → new | inherited | invalid
id_class() {
    local id="$1" f
    shift
    case "$id" in C[0-9]*) ;; *) printf 'invalid'; return ;; esac
    for f in "$@"; do
        [ "$id" = "$f" ] && { printf 'inherited'; return; }
    done
    printf 'new'
}

# flag_state <ledger> <id> <flag> → has | absent | missing-entry
flag_state() {
    local row
    row="$(grep -m1 -- "^$2|" "$1" 2>/dev/null || true)"
    if [ -z "$row" ]; then printf 'missing-entry'; return; fi
    if printf '%s' "$row" | cut -d'|' -f10 | grep -Fq -- "$3"; then
        printf 'has'
    else
        printf 'absent'
    fi
}

# file_state <path> → present | empty | missing
file_state() {
    if [ ! -e "$1" ]; then printf 'missing'
    elif [ ! -s "$1" ]; then printf 'empty'
    else printf 'present'; fi
}

# ---------------------------------------------------------------------------
# Implementation presence. Reported as a FAILURE (never PASS, never a silent
# skip) so the suite exits non-zero until /write-code lands the wrapper.
# ---------------------------------------------------------------------------
for _f in "$LEDGER_BIN" "$CLI" "$LIB"; do
    if [ ! -f "$_f" ]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (every case below fails for this reason)"
    fi
done

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_ROOT/tests/bin-concern-ledger-shared-code-review"

# shellcheck source=./bin-concern-ledger-shared-code-review/labels-stdout.sh
. "$SUITE_DIR/labels-stdout.sh"
# shellcheck source=./bin-concern-ledger-shared-code-review/prior-producers.sh
. "$SUITE_DIR/prior-producers.sh"
# shellcheck source=./bin-concern-ledger-shared-code-review/prompt-contract-wiring.sh
. "$SUITE_DIR/prompt-contract-wiring.sh"
# shellcheck source=./bin-concern-ledger-shared-code-review/continuity.sh
. "$SUITE_DIR/continuity.sh"
# shellcheck source=./bin-concern-ledger-shared-code-review/full-chain-integration.sh
. "$SUITE_DIR/full-chain-integration.sh"
# shellcheck source=./bin-concern-ledger-shared-code-review/fail-closed.sh
. "$SUITE_DIR/fail-closed.sh"
# Sourced after fail-closed.sh: reuses its FC_ROOT shimmed tree and fc_shim.
# shellcheck source=./bin-concern-ledger-shared-code-review/chain-failure-branches.sh
. "$SUITE_DIR/chain-failure-branches.sh"

xfail_summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
