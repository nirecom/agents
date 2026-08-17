#!/usr/bin/env bash
# tests/bin-concern-ledger-parse-allowlist.sh
# Tests: bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/lib/concern-ledger.sh, bin/concern-ledger
# Tags: concern-ledger, parser, allowlist, severity, category, table-driven, mutation-probe, scope:common, pwsh-not-required
#
# The anchored delta line is the only wire format between a reviewer and the
# ledger, and SLOT, the tally and the verdict are all functions of its two
# enumerated columns. A parser that repairs a malformed severity, or snaps a
# mistyped category onto the nearest valid one, files the finding under someone
# else's address — the accident the ledger exists to prevent.

# Exhaustive on the accepted side (every SEVERITY x CATEGORY the vocabulary
# declares); mutation-probing on the rejected side, per
# skills/_shared/test-design/parser-regex-tests.md. Every near-miss must land as
# '#unparsed' with a PARTIAL round label, never coerced into a valid value.

# TL2. The per-line matrix runs the real parse adapters inside ONE sourced shell
# (bin/lib/concern-ledger.sh) because ~70 CLI spawns cost minutes on Windows;
# the subprocess boundary is still covered — cases 2, 4 and 6 drive the real
# bin/concern-ledger over real report files and read the real staging files.

# TL3 gap (mitigation category: skill-orchestration). Not covered here, and
# covered nowhere below TL3: a real reviewer's wording (the bodies here follow
# the documented bullet grammar, so a model that drifts off it entirely is
# invisible), and the prompt that teaches that grammar living in
# bin/review-code-codex and the SKILL.md files (a prompt edit renaming a
# category still passes every case below).

# Mitigation: the day-to-day runner is a manual /review-code-security run; the
# vocabulary constant and the prompt's category list are pinned by case 5.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"

PASS=0
FAIL=0

# Known-gap assertions (case 3's unknown-category table). Sourced after FAIL
# exists, which the helpers increment on an XPASS. See tests/lib/xfail.sh.
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
# itself a failure, so '' == '' can never pass while the parser is absent.
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
        echo "FAIL: $name — output does not contain $(printf '%q' "$needle")"
        FAIL=$((FAIL + 1))
    fi
}

# strip <string> — leading/trailing whitespace, for the table readers below.
strip() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md).
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

FORMAT="parse-matrix"

# ---------------------------------------------------------------------------
# The batch prober. One sourced shell, one probe per input line.
#   input  line: '<key><TAB><raw delta bullet>'
#   output line: '<key>|<parse-label>|<recs>|<unparsed>|<first normalized record>'
# A normalized record is REF|SEVERITY|SLOT|DISCRIM|CATEGORY|PRODUCER|ANCHOR|TEXT.
# ---------------------------------------------------------------------------
PROBER="$TMPDIR_BASE/prober.sh"
cat > "$PROBER" <<'PROBER_EOF'
#!/usr/bin/env bash
set +u
source "$1" >/dev/null 2>&1 || exit 127
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
while IFS=$'\t' read -r key line; do
    [ -n "$key" ] || continue
    {
        printf '# Report\n\n## Review: PERFORMED\n\n## Concern Delta\n'
        printf '%s\n' "$line"
        printf '\n'
    } > "$W/report.txt"
    label="$(cl_parse_anchored "$W/report.txt" prod "$W/out.txt")"
    recs=0; unp=0; first=""
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            '') continue ;;
            '#unparsed|'*) unp=$((unp + 1)); continue ;;
            '#'*) continue ;;
        esac
        recs=$((recs + 1))
        [ -n "$first" ] || first="$l"
    done < "$W/out.txt"
    printf '%s|%s|%s|%s|%s\n' "$key" "$label" "$recs" "$unp" "$first"
done
PROBER_EOF

# batch <input-file> — runs the prober, leaving results in BATCH_OUT.
BATCH_OUT=""
batch() {
    BATCH_OUT="$1.result"
    bash "$PROBER" "$LIB" < "$1" > "$BATCH_OUT" 2>/dev/null
}

# res <key> → '<parse-label> recs=<n> unparsed=<n>' from the last batch, or
# 'NO-RESULT' when the prober produced nothing for that key — a value that can
# never read as a successful rejection.
res() {
    local row
    row="$(grep -m1 -- "^$1|" "$BATCH_OUT" 2>/dev/null || true)"
    [ -n "$row" ] || { printf 'NO-RESULT'; return; }
    printf '%s recs=%s unparsed=%s' \
        "$(printf '%s' "$row" | cut -d'|' -f2)" \
        "$(printf '%s' "$row" | cut -d'|' -f3)" \
        "$(printf '%s' "$row" | cut -d'|' -f4)"
}

# rec <key> <field> → field <field> of the normalized record for <key>.
rec() {
    local row
    row="$(grep -m1 -- "^$1|" "$BATCH_OUT" 2>/dev/null || true)"
    [ -n "$row" ] || return 0
    printf '%s' "$row" | cut -d'|' -f5- | cut -d'|' -f"$2"
}

# --- real-CLI helpers (cases 2, 4 and 6) ------------------------------------
ENV_SEQ=0
PLANS=""
SID=""
new_env() {
    ENV_SEQ=$((ENV_SEQ + 1))
    SID="clpa$ENV_SEQ"
    PLANS="$TMPDIR_BASE/plans-$ENV_SEQ"
    mkdir -p "$PLANS"
}

delta_file() { printf '%s/%s-%s-round-%s-delta-%s.txt' "$1" "$2" "$FORMAT" "$3" "$4"; }

mk_report() {
    local f="$1" l
    shift
    {
        printf '# Report\n\n## Review: PERFORMED\n\n## Concern Delta\n'
        for l in "$@"; do printf '%s\n' "$l"; done
        printf '\n'
    } > "$f"
}

stage() {
    bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round "$2" --producer "$3" --from-report "$1" >/dev/null 2>&1
}

# staging_field <file> <n> — '#producer|<name>|<completeness>|<exec>|<parse>|<round>'
staging_field() { grep -m1 '^#producer|' "$1" 2>/dev/null | cut -d'|' -f"$2"; }
rec_count()      { grep -cvE '^(#|$)' "$1" 2>/dev/null || true; }
unparsed_count() { grep -c '^#unparsed|' "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Implementation presence. Reported as a FAILURE (never PASS, never a silent
# skip) so the suite exits non-zero when the parser is absent.
# ---------------------------------------------------------------------------
for _f in "$CLI" "$LIB" "$AGENTS_ROOT/bin/lib/concern-ledger/parse.sh"; do
    if [ ! -f "$_f" ]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (every case below fails for this reason)"
    fi
done

# The vocabulary the binder probes with, read from the library rather than
# retyped, so this suite cannot drift from the implementation (CPR-SSOT).
VOCAB="$(grep -m1 '^CL_CATEGORY_VOCAB=' "$LIB" 2>/dev/null | sed -e 's/^CL_CATEGORY_VOCAB="//' -e 's/"$//')"
VOCAB_N="$(printf '%s\n' $VOCAB | grep -c . 2>/dev/null || printf 0)"


# ---------------------------------------------------------------------------
# Cases. Split into a sibling folder per rules/coding/file-split.md Pattern A;
# each file is sourced, not executed, so it shares the fixture and helpers
# above. Order is the case numbering: 1-2, 3, then 4-6.
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_ROOT/tests/bin-concern-ledger-parse-allowlist"

# shellcheck source=./bin-concern-ledger-parse-allowlist/severity-matrix.sh
. "$SUITE_DIR/severity-matrix.sh"
# shellcheck source=./bin-concern-ledger-parse-allowlist/category-columns.sh
. "$SUITE_DIR/category-columns.sh"
# shellcheck source=./bin-concern-ledger-parse-allowlist/labels-and-vocabulary.sh
. "$SUITE_DIR/labels-and-vocabulary.sh"

xfail_summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
