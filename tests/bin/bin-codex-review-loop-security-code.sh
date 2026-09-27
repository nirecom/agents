#!/usr/bin/env bash
# tests/bin/bin-codex-review-loop-security-code.sh
# Tests: bin/run-codex-review-loop, bin/review-code-codex, bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/codex-review-loop/format-params.sh, bin/lib/codex-review-loop/ref-kind-input.sh, agents/security-scanner.md
# Tags: concern-ledger, review-code, security-code, shared-ledger, exec-label, TL2, scope:common, pwsh-not-required
# TL2 dispatcher for the shared code-review ledger on its new carrier: the real
# bin/run-codex-review-loop --format security-code chain in a throwaway git repo
# with only `codex` mocked. Cases: tests/bin/bin-codex-review-loop-security-code/.
# TL3 gap: the real codex CLI wording, the SKILL.md text, the security-scanner
# subagent (replayed as its report). Mitigation: a manual /review-code-security run.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)/bin-codex-review-loop-security-code"
LOOP_BIN="$AGENTS_ROOT/bin/run-codex-review-loop"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
CODEX_BIN="$AGENTS_ROOT/bin/review-code-codex"
SUMMARIZE="$AGENTS_ROOT/bin/review-loop-summarize-concerns"
WRAPPER="$AGENTS_ROOT/skills/review-code-security/scripts/run-codex-review-loop.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then fail "$name — the expected value could not be computed (empty)"; return; fi
    assert_eq "$name" "$want" "$got"
}
assert_match() {
    local name="$1" re="$2" got="$3"
    if printf '%s' "$got" | grep -Eq -- "$re"; then pass "$name"
    else fail "$name — value=$(printf '%q' "$got") does not match /$re/"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if [ -z "$needle" ]; then fail "$name — the needle is empty"; return; fi
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then pass "$name"
    else fail "$name — output does not contain $(printf '%q' "$needle")"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if [ -z "$needle" ]; then fail "$name — the needle is empty"; return; fi
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then fail "$name — unexpectedly contains $(printf '%q' "$needle")"
    else pass "$name"; fi
}
assert_contains_block() {
    local name="$1" block="$2" hay="$3" line missing=""
    if [ -z "$(trim "$block")" ]; then fail "$name — the expected block is empty"; return; fi
    while IFS= read -r line; do
        [ -z "$(trim "$line")" ] && continue
        printf '%s' "$hay" | grep -Fq -- "$line" || missing="$line"
    done < <(printf '%s\n' "$block")
    if [ -n "$missing" ]; then fail "$name — missing line: $(printf '%q' "$missing")"
    else pass "$name"; fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_ENV_FILE 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
cd "$TMPDIR_BASE" || exit 1

# --- fixture git repos ------------------------------------------------------
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
    { for ((i = 0; i < lines; i++)); do printf 'line %s\n' "$i"; done; } > "$dir/reviewed.txt"
    git -C "$dir" add reviewed.txt
    git -C "$dir" commit -q -m "feature commit"
}
REPO="$TMPDIR_BASE/repo"
mk_repo "$REPO" 20
REPO_BIG="$TMPDIR_BASE/repo-big"
mk_repo "$REPO_BIG" 6000

# --- codex CLI mock (the only mocked boundary) ------------------------------
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"
printf '%s\n' '#!/usr/bin/env bash' \
    'cat > "${CODEX_MOCK_PROMPT:-/dev/null}"' \
    'if [ -n "${CODEX_MOCK_BODY:-}" ] && [ -f "${CODEX_MOCK_BODY}" ]; then cat "${CODEX_MOCK_BODY}"; fi' \
    'exit "${CODEX_MOCK_EXIT:-0}"' > "$MOCK_BIN/codex"
chmod +x "$MOCK_BIN/codex"
FULL_PATH="$MOCK_BIN:$PATH"

NODE_SHIM_DIR="$TMPDIR_BASE/node-shim"
path_without_codex() {
    local out="" d node_abs OLDIFS="$IFS"
    node_abs="$(command -v node 2>/dev/null || true)"
    IFS=':'
    for d in $PATH; do
        [ -n "$d" ] || continue
        if [ -x "$d/codex" ] || [ -x "$d/codex.exe" ] || [ -x "$d/codex.cmd" ]; then continue; fi
        out="${out:+$out:}$d"
    done
    IFS="$OLDIFS"
    if [ -n "$node_abs" ] && ! ( PATH="$out"; command -v node >/dev/null 2>&1 ); then
        mkdir -p "$NODE_SHIM_DIR"
        printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$node_abs" > "$NODE_SHIM_DIR/node"
        chmod +x "$NODE_SHIM_DIR/node"
        out="${out:+$out:}$NODE_SHIM_DIR"
    fi
    printf '%s' "$out"
}
NO_CODEX_PATH="$(path_without_codex)"

# --- producer output builders -----------------------------------------------
anchored() { printf '[%s] %s | %s#%s | %s | %s' "$1" "$2" "$3" "$4" "$5" "$6"; }

# mk_body <file> <anchored-line>... — a security-code reviewer body: the status
# header the loop greps for, then the delta section the ledger parses.
mk_body() {
    local f="$1" sev l
    shift
    {
        printf '## Codex Review: PERFORMED\n\n'
        printf '## Concern Delta\n'
        for sev in HIGH MEDIUM LOW; do
            printf '\n## %s\n' "$sev"
            local any=0
            for l in "$@"; do
                case "$l" in "[$sev]"*) printf -- '- %s\n' "$l"; any=1 ;; esac
            done
            [ "$any" -eq 0 ] && printf '(none)\n'
        done
    } > "$f"
}
NONE_BODY="$TMPDIR_BASE/body-none.txt"
mk_body "$NONE_BODY"

# mk_report <file> <anchored-line>... — a security-scanner report.
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
SCAN_NONE="$TMPDIR_BASE/scan-none.txt"
mk_report "$SCAN_NONE"

# --- per-case environment ---------------------------------------------------
LEDGER_FORMAT="review-security-shared"
LOOP_FORMAT="security-code"
ENV_SEQ=0
PLANS=""; SID=""
RL_REPO="$REPO"; RL_PATH="$FULL_PATH"; RL_ROOT=""; RL_CODEX_BODY=""; RL_CODEX_EXIT=0
RL_EXT_USED=0; RL_CAP=2; RL_MAXEXT=1; RL_EXTRA=()
LAST_OUT=""; LAST_ERR=""; LAST_RC=0; LAST_PROMPT=""
RUN_SEQ=0
new_env() {
    ENV_SEQ=$((ENV_SEQ + 1))
    SID="sc$ENV_SEQ"
    PLANS="$TMPDIR_BASE/plans-$ENV_SEQ"
    mkdir -p "$PLANS/workflow-state"
    printf 'none\n' > "$PLANS/tradeoffs.md"
    RL_REPO="$REPO"
    RL_PATH="$FULL_PATH"
    RL_ROOT="$AGENTS_ROOT"
    RL_CODEX_BODY="$NONE_BODY"
    RL_CODEX_EXIT=0
    RL_EXT_USED=0
    RL_CAP=2
    RL_MAXEXT=1
    RL_EXTRA=()
}

# run_loop [extra args] — bin/run-codex-review-loop --format security-code with
# the current RL_* environment. Sets LAST_OUT / LAST_ERR / LAST_RC / LAST_PROMPT.
run_loop() {
    RUN_SEQ=$((RUN_SEQ + 1))
    LAST_PROMPT="$TMPDIR_BASE/prompt-$RUN_SEQ.txt"
    local errf="$TMPDIR_BASE/err-$RUN_SEQ.txt"
    : > "$LAST_PROMPT"; : > "$errf"
    LAST_RC=0
    LAST_OUT="$(
        cd "$RL_REPO" || exit 1
        export PATH="$RL_PATH" HOME="$TMPDIR_BASE" AGENTS_CONFIG_DIR="$RL_ROOT"
        export CODEX_MOCK_PROMPT="$LAST_PROMPT" CODEX_MOCK_BODY="$RL_CODEX_BODY" \
               CODEX_MOCK_EXIT="$RL_CODEX_EXIT"
        bash "$RL_ROOT/bin/run-codex-review-loop" --format "$LOOP_FORMAT" \
            --session-id "$SID" --plans-dir "$PLANS" --cap "$RL_CAP" \
            --max-extensions "$RL_MAXEXT" --extensions-used "$RL_EXT_USED" \
            --accepted-tradeoffs "$PLANS/tradeoffs.md" --repo-root "$RL_REPO" \
            "${RL_EXTRA[@]+"${RL_EXTRA[@]}"}" "$@" 2>"$errf"
    )" || LAST_RC=$?
    LAST_ERR="$(cat "$errf" 2>/dev/null || true)"
}

# run_codex_direct — bin/review-code-codex on its own, the stdout baseline.
run_codex_direct() {
    RUN_SEQ=$((RUN_SEQ + 1))
    (
        cd "$RL_REPO" || exit 1
        export PATH="$RL_PATH" HOME="$TMPDIR_BASE" AGENTS_CONFIG_DIR="$RL_ROOT"
        export CODEX_MOCK_PROMPT="$TMPDIR_BASE/prompt-direct-$RUN_SEQ.txt" \
               CODEX_MOCK_BODY="$RL_CODEX_BODY" CODEX_MOCK_EXIT="$RL_CODEX_EXIT"
        bash "$CODEX_BIN" --base main --base-state RECORDED "$@" 2>/dev/null
    )
}

run_cli() { bash "$CLI" "$@"; }
cl() { ( set +u; . "$LIB" >/dev/null 2>&1 || exit 127; "$@" ); }

# --- artifact readers -------------------------------------------------------
ledger_file()  { printf '%s/%s-%s-concern-ledger.txt' "$1" "$2" "$LEDGER_FORMAT"; }
round_file()   { printf '%s/%s-%s-round-number.txt' "$1" "$2" "$LOOP_FORMAT"; }
delta_file()   { printf '%s/%s-%s-round-%s-delta-%s.txt' "$1" "$2" "$LEDGER_FORMAT" "$3" "$4"; }
json_file()    { printf '%s/%s-%s-unresolved-concerns.json' "$1" "$2" "$LEDGER_FORMAT"; }
staging_field() { grep -m1 '^#producer|' "$1" 2>/dev/null | cut -d'|' -f"$2"; }

F_SEV=2; F_STATE=3; F_FIRST=4; F_LAST=5; F_SLOT=6; F_DISCRIM=7
F_ORIGIN=8; F_PRODUCERS=9; F_FLAGS=10

entry_field() { grep -m1 -- "^$2|" "$1" 2>/dev/null | cut -d'|' -f"$3"; }
entry_count() { grep -cE '^C[0-9]+\|' "$1" 2>/dev/null || true; }
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
id_is() {
    local got
    got="$(id_for_text "$1" "$2")"
    case "$got" in C[0-9]*) ;; *) printf 'not-found'; return ;; esac
    case "$3" in C[0-9]*) ;; *) printf 'not-found'; return ;; esac
    if [ "$got" = "$3" ]; then printf 'same'; else printf 'different'; fi
}
id_class() {
    local id="$1" f
    shift
    case "$id" in C[0-9]*) ;; *) printf 'invalid'; return ;; esac
    for f in "$@"; do [ "$id" = "$f" ] && { printf 'inherited'; return; }; done
    printf 'new'
}
flag_state() {
    local row
    row="$(grep -m1 -- "^$2|" "$1" 2>/dev/null || true)"
    if [ -z "$row" ]; then printf 'missing-entry'; return; fi
    if printf '%s' "$row" | cut -d'|' -f10 | grep -Fq -- "$3"; then printf 'has'; else printf 'absent'; fi
}
file_state() {
    if [ ! -e "$1" ]; then printf 'missing'
    elif [ -d "$1" ]; then printf 'not-a-file'
    elif [ ! -s "$1" ]; then printf 'empty'
    else printf 'present'; fi
}
nonzero_word() { if [ "$1" -ne 0 ] 2>/dev/null; then printf 'nonzero'; else printf 'zero'; fi; }
digest() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# Implementation presence — a FAILURE, never a silent skip.
# ---------------------------------------------------------------------------
for _f in "$LOOP_BIN" "$CLI" "$LIB" "$CODEX_BIN" "$WRAPPER" \
          "$AGENTS_ROOT/bin/lib/codex-review-loop/format-params.sh" \
          "$AGENTS_ROOT/bin/lib/codex-review-loop/ref-kind-input.sh"; do
    if [ ! -f "$_f" ]; then
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (cases below fail for this reason)"
    fi
done

for _sec in exec-labels-stdout.sh prior-producers.sh prompt-contract-wiring.sh \
            continuity.sh full-chain-integration.sh fail-closed.sh chain-failure-branches.sh \
            concerns-log-wiring.sh; do
    if [ -f "$SUITE_DIR/$_sec" ]; then
        # shellcheck source=/dev/null
        . "$SUITE_DIR/$_sec"
    else
        fail "case file missing: bin-codex-review-loop-security-code/$_sec"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
