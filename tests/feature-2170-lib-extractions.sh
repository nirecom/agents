#!/usr/bin/env bash
# Tests: hooks/lib/dotenv-check.js, hooks/lib/memory-path-check.js, hooks/lib/history-path-check.js
# Tags: pretooluse, classifier, table-driven, extraction-parity, scope:issue-specific, pwsh-not-required
# #2170 round-2 C10 extracted the pure predicates out of block-dotenv.js,
# block-memory-direct.js and block-history-direct.js. Two obligations: the
# predicates still classify correctly (G1, both directions), and extraction
# did not shift the ORIGINAL hooks' verdicts (G2, hook subprocess vs lib, same input).
# TL3 gap: real PreToolUse dispatch — feature-2170-capture-echo-guard part2/6.

set -uo pipefail

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
export AGENTS_DIR
HERE="$(cd "$(dirname "$0")/feature-2170-lib-extractions" && pwd)"
SIB="$(cd "$(dirname "$0")/feature-2170-capture-echo-guard" && pwd)"
DRIVER="$HERE/lib-driver.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

# Fixture isolation per rules/test/fixture-isolation.md.
TMPROOT_RAW="$(mktemp -d)"
trap 'rm -rf "$TMPROOT_RAW"' EXIT
to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
TMPROOT="$(to_node_path "$TMPROOT_RAW")"
export TMPDIR="$TMPROOT" TEMP="$TMPROOT" TMP="$TMPROOT"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow" WORKFLOW_PLANS_DIR="$TMPROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

MEMDIR="$(node "$DRIVER" --memdir 2>&1)"
MEMFILE="$MEMDIR/MEMORY.md"

# --- G1: each extracted predicate, hit and miss (Pattern 4) ----------------
echo "--- G1: extracted predicate unit cases (table-driven) ---"
while IFS='|' read -r name mode input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    mode="${mode//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    assert_eq "G1-$name" "$want" "$(node "$DRIVER" "$mode" "$input" 2>&1)"
done <<TABLE
dotenv-hit-read       | --dotenv  | cat /srv/app/.env                 | hit
dotenv-hit-flagvalue  | --dotenv  | gh release upload v1 -f .env      | hit
dotenv-miss-example   | --dotenv  | cat /srv/app/.env.example         | miss
dotenv-miss-envrc     | --dotenv  | cat /srv/app/.envrc               | miss
dotenv-miss-textarg   | --dotenv  | echo "copy .env to prod"          | miss
memory-hit-redirect   | --memory  | printf 'x' > $MEMFILE             | hit
memory-hit-tee        | --memory  | tee -a $MEMFILE                   | hit
memory-hit-copy       | --memory  | cp /tmp/a $MEMFILE                | hit
memory-miss-read      | --memory  | cat $MEMFILE                      | miss
memory-miss-elsewhere | --memory  | printf 'x' > /tmp/MEMORY.md       | miss
history-hit-canonical | --history | printf 'x' > docs/history.md      | hit
history-hit-rotated   | --history | printf 'x' > docs/history/2026.md | hit
history-miss-rulesdoc | --history | printf 'x' > rules/docs/history.md | miss
history-miss-read     | --history | cat docs/history.md               | miss
TABLE

# --- G2: extraction parity — the ORIGINAL hook vs the extracted lib ---------
# Same command string through the hook subprocess and through the lib; block
# must pair with hit, and passthrough/approve with miss. Two representative
# inputs per hook, not a copy of each hook's own suite.
echo ""
echo "--- G2: hook-subprocess vs lib parity ---"
EV="$TMPROOT_RAW/event.json"
OUT="$TMPROOT_RAW/out.json"

hook_verdict() {
    node "$SIB/mk-event.js" Bash "$2" >"$EV"
    node "$AGENTS_DIR/hooks/$1" <"$EV" >"$OUT" 2>/dev/null
    node "$SIB/hook-out.js" "$OUT"
}
# "block"/"deny-partial" are both a denial; the dual-field contract is the
# hook's own suite's business, not this parity check's.
denies() { case "$1" in block|deny-partial) printf 'hit' ;; *) printf 'miss' ;; esac; }

parity() {
    local name="$1" hook="$2" mode="$3" cmd="$4"
    local h l
    h="$(denies "$(hook_verdict "$hook" "$cmd")")"
    l="$(node "$DRIVER" "$mode" "$cmd" 2>&1)"
    assert_eq "G2-$name" "$h" "$l"
}

parity "dotenv-hit"   "block-dotenv.js"         --dotenv  "cat /srv/app/.env"
parity "dotenv-miss"  "block-dotenv.js"         --dotenv  "cat /srv/app/.env.example"
parity "memory-hit"   "block-memory-direct.js"  --memory  "printf 'x' > $MEMFILE"
parity "memory-miss"  "block-memory-direct.js"  --memory  "printf 'x' > /tmp/MEMORY.md"
parity "history-hit"  "block-history-direct.js" --history "printf 'x' > docs/history.md"
parity "history-miss" "block-history-direct.js" --history "printf 'x' > rules/docs/history.md"

echo ""
echo "==================================================="
echo "feature-2170-lib-extractions: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
exit "$FAIL"
