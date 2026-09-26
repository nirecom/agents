#!/usr/bin/env bash
# tests/feature-2276-review-code-security-codex.sh
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/format-params.sh, bin/lib/codex-review-loop/ref-kind-input.sh
# Tags: review-loop, security-code, concern-ledger, prestaged, issue-2276, TL2, scope:issue-specific, pwsh-not-required
#
# /review-code-security moves onto the shared codex review loop: a new
# security-code format whose input is a git ref rather than a draft path, whose
# reviewer is bin/review-code-codex directly, and whose security-scanner
# fallback re-enters the SAME loop through --prestaged-report instead of
# touching the ledger on its own.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECTION_DIR="$(cd "$(dirname "$0")" && pwd)/feature-2276-review-code-security-codex"
LOOP_BIN="$AGENTS_ROOT/bin/run-codex-review-loop"
FMT_PARAMS="$AGENTS_ROOT/bin/lib/codex-review-loop/format-params.sh"
REF_KIND="$AGENTS_ROOT/bin/lib/codex-review-loop/ref-kind-input.sh"
LEDGER_VERDICT="$AGENTS_ROOT/bin/lib/codex-review-loop/ledger-verdict.sh"
CL_CLI="$AGENTS_ROOT/bin/concern-ledger"
CL_LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
CODEX_BIN="$AGENTS_ROOT/bin/review-code-codex"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

trim() { printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name (want: [$want] got: [$got])"; fi
}
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then fail "$name (expectation is empty — the fixture produced no baseline)"; return; fi
    assert_eq "$name" "$want" "$got"
}
assert_match() {
    local name="$1" re="$2" got="$3"
    if printf '%s' "$got" | grep -Eq -- "$re"; then pass "$name"
    else fail "$name (want match: [$re] got: [$got])"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if [ -z "$needle" ]; then fail "$name (needle is empty)"; return; fi
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then pass "$name"
    else fail "$name (missing: [$needle] in: [$(printf '%s' "$hay" | head -c 400)])"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if [ -z "$needle" ]; then fail "$name (needle is empty)"; return; fi
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then fail "$name (unexpectedly present: [$needle])"
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

# --- fixture repo -----------------------------------------------------------
mk_repo() {
    local dir="$1" lines="$2" i=1
    mkdir -p "$dir"
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config user.email "fixture@example.com"
    git -C "$dir" config user.name "Fixture"
    git -C "$dir" config commit.gpgsign false
    printf 'base\n' > "$dir/README.md"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -qm "base" >/dev/null 2>&1
    git -C "$dir" branch -M main >/dev/null 2>&1
    git -C "$dir" checkout -qb feature-test >/dev/null 2>&1
    : > "$dir/reviewed.txt"
    while [ "$i" -le "$lines" ]; do printf 'line %s\n' "$i" >> "$dir/reviewed.txt"; i=$((i + 1)); done
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -qm "change" >/dev/null 2>&1
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
chmod +x "$MOCK_BIN/codex" 2>/dev/null || true
FULL_PATH="$MOCK_BIN:$PATH"

path_without_codex() {
    local d out=""
    local IFS=:
    for d in $PATH; do
        [ -n "$d" ] || continue
        if [ -x "$d/codex" ] || [ -x "$d/codex.exe" ] || [ -x "$d/codex.cmd" ]; then continue; fi
        out="${out:+$out:}$d"
    done
    NO_CODEX_PATH="$out"
    if ! PATH="$NO_CODEX_PATH" command -v node >/dev/null 2>&1; then
        NODE_SHIM_DIR="$TMPDIR_BASE/node-shim"
        mkdir -p "$NODE_SHIM_DIR"
        local nodebin
        nodebin="$(command -v node 2>/dev/null || true)"
        if [ -n "$nodebin" ]; then
            printf '%s\n' '#!/usr/bin/env bash' "exec \"$nodebin\" \"\$@\"" > "$NODE_SHIM_DIR/node"
            chmod +x "$NODE_SHIM_DIR/node" 2>/dev/null || true
            NO_CODEX_PATH="$NODE_SHIM_DIR:$NO_CODEX_PATH"
        fi
    fi
}
path_without_codex

anchored() { printf '[%s] %s | %s#%s | %s | %s' "$1" "$2" "$3" "$4" "$5" "$6"; }

mk_body() {
    local f="$1"; shift
    {
        printf '## Concern Delta\n\n## HIGH\n'
        if [ "$#" -eq 0 ]; then printf '(none)\n'; else printf '%s\n' "$@"; fi
        printf '\n## MEDIUM\n(none)\n\n## LOW\n(none)\n'
    } > "$f"
}
mk_clean_body() {
    printf '## Concern Delta\n\n## HIGH\n(none)\n\n## MEDIUM\n(none)\n\n## LOW\n(none)\n' > "$1"
}

# --- per-case environment ---------------------------------------------------
LEDGER_FORMAT="review-security-shared"
LOOP_FORMAT="security-code"
N=0
new_env() {
    N=$((N + 1))
    SID="scsess$N"
    PLANS="$TMPDIR_BASE/plans-$N"
    mkdir -p "$PLANS"
    printf 'none\n' > "$PLANS/tradeoffs.md"
    RL_REPO="$REPO"
    RL_PATH="$FULL_PATH"
    RL_CODEX_BODY=""
    RL_CODEX_EXIT=0
    RL_EXT_USED=0
    RL_EXTRA=()
}
ledger_file()  { printf '%s/%s-%s-concern-ledger.txt' "$PLANS" "$SID" "$LEDGER_FORMAT"; }
round_file()   { printf '%s/%s-%s-round-number.txt' "$PLANS" "$SID" "$LOOP_FORMAT"; }
delta_file()   { printf '%s/%s-%s-round-%s-delta-%s.txt' "$PLANS" "$SID" "$LEDGER_FORMAT" "$1" "$2"; }
staging_field() { grep -m1 '^#producer|' "$1" 2>/dev/null | cut -d'|' -f"$2"; }
file_state()   { if [ -f "$1" ]; then printf 'present'; else printf 'missing'; fi; }
counter_state() { if [ -f "$(round_file)" ]; then trim "$(cat "$(round_file)" 2>/dev/null || true)"; else printf 'deleted'; fi; }
entry_count()  { grep -cE '^C[0-9]+\|' "$1" 2>/dev/null || true; }
entry_state()  { grep -m1 -E "^$2\|" "$1" 2>/dev/null | cut -d'|' -f3; }

run_loop_sc() {
    local args=(--format "$LOOP_FORMAT" --session-id "$SID" --plans-dir "$PLANS"
        --cap 2 --max-extensions 1 --extensions-used "$RL_EXT_USED"
        --accepted-tradeoffs "$PLANS/tradeoffs.md" --repo-root "$RL_REPO")
    args+=("${RL_EXTRA[@]+"${RL_EXTRA[@]}"}")
    args+=("$@")
    LAST_OUT="$(cd "$RL_REPO" && PATH="$RL_PATH" CODEX_MOCK_BODY="$RL_CODEX_BODY" \
        CODEX_MOCK_EXIT="$RL_CODEX_EXIT" CODEX_MOCK_PROMPT="$PLANS/prompt.txt" \
        bash "$LOOP_BIN" "${args[@]}" 2>&1)"
    LAST_RC=$?
}

run_cli() { bash "$CL_CLI" "$@"; }

for _f in "$LOOP_BIN" "$FMT_PARAMS" "$REF_KIND" "$CL_CLI" "$CL_LIB" "$CODEX_BIN"; do
    if [ ! -f "$_f" ]; then
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (every case below fails for this reason)"
    fi
done

for _sec in static-contracts.sh ref-input-chain.sh prestaged-fallback.sh; do
    if [ -f "$SECTION_DIR/$_sec" ]; then
        # shellcheck source=/dev/null
        . "$SECTION_DIR/$_sec"
    else
        fail "section file missing: feature-2276-review-code-security-codex/$_sec"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
