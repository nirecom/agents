#!/usr/bin/env bash
# tests/feature-2223-complexity-judge.sh
# Tests: bin/workflow/normalize-judge-signals, agents/complexity-judge.md, skills/_shared/complexity-and-outline-skip.md, skills/make-detail-plan/SKILL.md, skills/write-code/SKILL.md, skills/write-tests/SKILL.md
# Tags: scope:issue-specific, TL2, complexity, normalize, static, pwsh-not-required

# scope 4: the opus-fixed complexity-judge static contract, the dispatch wiring at
# each self-judgment site, and the strict capture-normalize contract of
# bin/workflow/normalize-judge-signals (C1). Normalize cases run the real node CLI
# (RED until it exists); static/wiring cases are RED until the scope 4 edits land.

# TL3 gap: normalize is exercised with synthetic raw input and the agent/wiring
# statically — no live complexity-judge spawn and no judge->normalize->routing
# end-to-end. That live seam is tests/TL3-complexity-stage-routing-live-judge.sh.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JUDGE_DOC="$AGENTS_DIR/agents/complexity-judge.md"
NORMALIZE_CLI="$AGENTS_DIR/bin/workflow/normalize-judge-signals"
ROUTING_JS="hooks/workflow-state/complexity-routing.js"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Strip trailing newlines/whitespace so a "\n"-terminated one-line output compares
# equal to its bare value, and an empty file compares equal to "".
trim_tail() {
    local s="$1"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

assert_has() {
    local name="$1" file="$2" needle="$3"
    if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then pass "$name"
    else fail "$name — '$needle' absent from $(basename "$file")"; fi
}

# C6: the read-only judge must NOT be granted the tool in ANY frontmatter form —
# inline (`tools: Read, Bash`), YAML list item (`  - Bash`), or mapping (`Bash:`).
# A missing tools: declaration also fails: an agent without one inherits every
# tool, so the read-only constraint would be unprovable.
assert_tools_lacks() {
    local name="$1" file="$2" tool="$3"
    if [[ ! -f "$file" ]]; then
        fail "$name — $(basename "$file") missing; read-only constraint unprovable"; return
    fi
    if ! grep -qE '^tools:' "$file"; then
        fail "$name — no 'tools:' declaration in $(basename "$file"); read-only constraint unprovable"; return
    fi
    if grep -qE "^tools:.*(^|[[:space:],])${tool}([[:space:],]|\$)" "$file" \
        || grep -qE "^[[:space:]]*-[[:space:]]*${tool}[[:space:]]*\$" "$file" \
        || grep -qE "^[[:space:]]*${tool}:[[:space:]]*" "$file"; then
        fail "$name — $tool appears granted in $(basename "$file")"
    else
        pass "$name"
    fi
}

# C4: the two dispatch strings must co-occur within <window> lines of each other,
# proving the site both spawns complexity-judge AND funnels it through normalize
# in the same block (not merely mentions each somewhere in the file).
assert_cooccur() {
    local name="$1" file="$2" a="$3" b="$4" window="$5"
    if [[ ! -f "$file" ]]; then fail "$name — $(basename "$file") missing"; return; fi
    local la lb best=999999 x y d
    la="$(grep -nF -- "$a" "$file" 2>/dev/null | cut -d: -f1)"
    lb="$(grep -nF -- "$b" "$file" 2>/dev/null | cut -d: -f1)"
    if [[ -z "$la" || -z "$lb" ]]; then
        fail "$name — need both '$a' and '$b' (a=${la:-none} b=${lb:-none})"; return
    fi
    for x in $la; do
        for y in $lb; do
            d=$(( x > y ? x - y : y - x ))
            (( d < best )) && best=$d
        done
    done
    if (( best <= window )); then pass "$name"
    else fail "$name — '$a' and '$b' are $best lines apart (> $window) in $(basename "$file")"; fi
}

# ---------------------------------------------------------------------------
# Part A — complexity-judge agent static contract.
# ---------------------------------------------------------------------------
if [[ -f "$JUDGE_DOC" ]]; then pass "T2223CJ-1-judge-doc-exists"
else fail "T2223CJ-1-judge-doc-exists — $JUDGE_DOC does not exist"; fi

# model: opus must be literally present in the frontmatter.
if grep -qE '^model:[[:space:]]*opus[[:space:]]*$' "$JUDGE_DOC" 2>/dev/null; then
    pass "T2223CJ-2-judge-model-opus"
else
    fail "T2223CJ-2-judge-model-opus — 'model: opus' not present in $(basename "$JUDGE_DOC")"
fi

assert_tools_lacks "T2223CJ-3-judge-tools-no-write" "$JUDGE_DOC" "Write"
assert_tools_lacks "T2223CJ-4-judge-tools-no-edit"  "$JUDGE_DOC" "Edit"
assert_tools_lacks "T2223CJ-5-judge-tools-no-bash"  "$JUDGE_DOC" "Bash"
assert_has "T2223CJ-6-judge-refs-rubric" "$JUDGE_DOC" "judge-task-complexity.md"
assert_has "T2223CJ-7-judge-output-single-signals-line" "$JUDGE_DOC" "SIGNALS:"

# ---------------------------------------------------------------------------
# Part B — dispatch wiring (static). All four self-judgment sites must spawn the
# judge AND normalize its output within the same block (C4).
# ---------------------------------------------------------------------------
SKIP_DOC="$AGENTS_DIR/skills/_shared/complexity-and-outline-skip.md"
MDP_DOC="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
WCODE_DOC="$AGENTS_DIR/skills/write-code/SKILL.md"
WTESTS_DOC="$AGENTS_DIR/skills/write-tests/SKILL.md"
assert_cooccur "T2223CJ-8-skip-doc-judge-and-normalize"   "$SKIP_DOC"   "complexity-judge" "normalize-judge-signals" 40
assert_cooccur "T2223CJ-9-mdp-judge-and-normalize"        "$MDP_DOC"    "complexity-judge" "normalize-judge-signals" 40
assert_cooccur "T2223CJ-10-write-code-judge-and-normalize" "$WCODE_DOC"  "complexity-judge" "normalize-judge-signals" 40
assert_cooccur "T2223CJ-11-write-tests-judge-and-normalize" "$WTESTS_DOC" "complexity-judge" "normalize-judge-signals" 40

# ---------------------------------------------------------------------------
# Part C — normalize-judge-signals strict contract (table-driven).
# Each case writes a raw file, runs the real node CLI, and compares the produced
# signals file (trimmed) against the expected content.
# ---------------------------------------------------------------------------
assert_normalize() {
    local name="$1" raw="$2" want="$3" out got
    out="$TMP_ROOT/out-$name.txt"
    rm -f "$out"
    run_with_timeout 30 node "$NORMALIZE_CLI" --raw-file "$raw" --out "$out" >/dev/null 2>&1 || true
    if [[ -f "$out" ]]; then got="$(trim_tail "$(cat "$out")")"; else got="__NOFILE__"; fi
    if [[ "$got" == "$want" ]]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# VALID cases.
printf 'SIGNALS: S1-multi-file, S3-security\n' > "$TMP_ROOT/raw-N01.txt"
assert_normalize "T2223CJ-N01-valid-multi" "$TMP_ROOT/raw-N01.txt" "S1-multi-file,S3-security"

printf 'SIGNALS: S1-multi-file\n' > "$TMP_ROOT/raw-N02.txt"
assert_normalize "T2223CJ-N02-valid-single" "$TMP_ROOT/raw-N02.txt" "S1-multi-file"

printf 'SIGNALS: none\n' > "$TMP_ROOT/raw-N03.txt"
assert_normalize "T2223CJ-N03-valid-none-empty" "$TMP_ROOT/raw-N03.txt" ""

printf '%s\n%s\n%s\n%s\n' 'The task touches several files.' 'It reshapes an interface.' 'Here is my verdict:' 'SIGNALS: S2-architecture' > "$TMP_ROOT/raw-N04.txt"
assert_normalize "T2223CJ-N04-valid-with-preamble" "$TMP_ROOT/raw-N04.txt" "S2-architecture"

# C2: every remaining valid signal ID, each on its own, plus the full combination.
printf 'SIGNALS: S1b-wide-change\n' > "$TMP_ROOT/raw-N15.txt"
assert_normalize "T2223CJ-N15-valid-s1b-wide-change" "$TMP_ROOT/raw-N15.txt" "S1b-wide-change"

printf 'SIGNALS: S4-installer\n' > "$TMP_ROOT/raw-N16.txt"
assert_normalize "T2223CJ-N16-valid-s4-installer" "$TMP_ROOT/raw-N16.txt" "S4-installer"

printf 'SIGNALS: S5-breaking\n' > "$TMP_ROOT/raw-N17.txt"
assert_normalize "T2223CJ-N17-valid-s5-breaking" "$TMP_ROOT/raw-N17.txt" "S5-breaking"

printf 'SIGNALS: S6-long-plan\n' > "$TMP_ROOT/raw-N18.txt"
assert_normalize "T2223CJ-N18-valid-s6-long-plan" "$TMP_ROOT/raw-N18.txt" "S6-long-plan"

printf 'SIGNALS: S1-multi-file, S1b-wide-change, S2-architecture, S3-security, S4-installer, S5-breaking, S6-long-plan\n' > "$TMP_ROOT/raw-N19.txt"
assert_normalize "T2223CJ-N19-valid-all-signals" "$TMP_ROOT/raw-N19.txt" "S1-multi-file,S1b-wide-change,S2-architecture,S3-security,S4-installer,S5-breaking,S6-long-plan"

# INVALID cases -> S0-undecidable.
printf '%s\n%s\n' 'SIGNALS: S1-multi-file' 'SIGNALS: S3-security' > "$TMP_ROOT/raw-N05.txt"
assert_normalize "T2223CJ-N05-invalid-multiple-signals-lines" "$TMP_ROOT/raw-N05.txt" "S0-undecidable"

printf '%s\n%s\n' 'SIGNALS: S1-multi-file' 'S2-architecture' > "$TMP_ROOT/raw-N06.txt"
assert_normalize "T2223CJ-N06-invalid-mixed-signal-line" "$TMP_ROOT/raw-N06.txt" "S0-undecidable"

printf 'SIGNALS: ,S1-multi-file\n' > "$TMP_ROOT/raw-N07.txt"
assert_normalize "T2223CJ-N07-invalid-leading-comma" "$TMP_ROOT/raw-N07.txt" "S0-undecidable"

printf 'SIGNALS: S1-multi-file,,S3-security\n' > "$TMP_ROOT/raw-N08.txt"
assert_normalize "T2223CJ-N08-invalid-double-comma" "$TMP_ROOT/raw-N08.txt" "S0-undecidable"

printf 'SIGNALS: S1-multi-file,\n' > "$TMP_ROOT/raw-N09.txt"
assert_normalize "T2223CJ-N09-invalid-trailing-comma" "$TMP_ROOT/raw-N09.txt" "S0-undecidable"

printf 'SIGNALS: ,\n' > "$TMP_ROOT/raw-N10.txt"
assert_normalize "T2223CJ-N10-invalid-single-comma" "$TMP_ROOT/raw-N10.txt" "S0-undecidable"

printf 'SIGNALS: S99-x\n' > "$TMP_ROOT/raw-N11.txt"
assert_normalize "T2223CJ-N11-invalid-unknown-id" "$TMP_ROOT/raw-N11.txt" "S0-undecidable"

printf 'SIGNALS: S0-undecidable\n' > "$TMP_ROOT/raw-N12.txt"
assert_normalize "T2223CJ-N12-invalid-reserved-value-input" "$TMP_ROOT/raw-N12.txt" "S0-undecidable"

printf '%s\n%s\n' 'Just some free-form reasoning with no verdict line.' 'Nothing structured here.' > "$TMP_ROOT/raw-N13.txt"
assert_normalize "T2223CJ-N13-invalid-no-signals-line" "$TMP_ROOT/raw-N13.txt" "S0-undecidable"

printf 'SIGNALS: S1-multi-file;rm -rf /\n' > "$TMP_ROOT/raw-N14.txt"
assert_normalize "T2223CJ-N14-invalid-shell-metachar" "$TMP_ROOT/raw-N14.txt" "S0-undecidable"

# ---------------------------------------------------------------------------
# C8 (robustness) — missing input, unwritable output, idempotency.
# ---------------------------------------------------------------------------
# C8(a): a missing raw file is unreadable input; the fail-open contract must yield
# the S0-undecidable fallback, never a crash or a spuriously valid signal.
assert_normalize "T2223CJ-N20-missing-input-file" "$TMP_ROOT/does-not-exist.txt" "S0-undecidable"

# C8(b): writing to a path that is a directory cannot succeed; the CLI must exit
# non-zero rather than crash. Gated on the CLI existing so it stays a
# source-attributable RED before scope 4 lands (not a trivial pass on absence).
if [[ -f "$NORMALIZE_CLI" ]]; then
    printf 'SIGNALS: S1-multi-file\n' > "$TMP_ROOT/raw-N21.txt"
    if run_with_timeout 30 node "$NORMALIZE_CLI" --raw-file "$TMP_ROOT/raw-N21.txt" --out "$TMP_ROOT" >/dev/null 2>&1; then
        fail "T2223CJ-N21-unwritable-out-nonzero — CLI reported success writing over a directory path"
    else
        pass "T2223CJ-N21-unwritable-out-nonzero"
    fi
else
    fail "T2223CJ-N21-unwritable-out-nonzero — normalize CLI absent (RED until scope 4 lands)"
fi

# C8(c): re-running with identical input must reproduce byte-identical valid output.
printf 'SIGNALS: S1-multi-file, S3-security\n' > "$TMP_ROOT/raw-N22.txt"
idem1="$TMP_ROOT/idem-1.txt"; idem2="$TMP_ROOT/idem-2.txt"
rm -f "$idem1" "$idem2"
run_with_timeout 30 node "$NORMALIZE_CLI" --raw-file "$TMP_ROOT/raw-N22.txt" --out "$idem1" >/dev/null 2>&1 || true
run_with_timeout 30 node "$NORMALIZE_CLI" --raw-file "$TMP_ROOT/raw-N22.txt" --out "$idem2" >/dev/null 2>&1 || true
if [[ -f "$idem1" && -f "$idem2" ]] \
    && [[ "$(trim_tail "$(cat "$idem1")")" == "S1-multi-file,S3-security" ]] \
    && cmp -s "$idem1" "$idem2"; then
    pass "T2223CJ-N23-idempotent-rerun"
else
    fail "T2223CJ-N23-idempotent-rerun — identical input did not reproduce identical valid output"
fi

# ---------------------------------------------------------------------------
# R1 — the routing vocabulary this feature depends on is intact. The #2148
# allowlist fix legitimately edits complexity-routing.js on this branch, so a
# merge-base no-diff check no longer holds; what scope 4 actually relies on is
# the shared signal vocabulary, which must survive that edit. Assert the
# structural invariants (SSOT contract) rather than byte-equality vs a base.
# ---------------------------------------------------------------------------
if grep -qF 'UNDECIDABLE_SIGNAL = "S0-undecidable"' "$AGENTS_DIR/$ROUTING_JS" 2>/dev/null; then
    pass "T2223CJ-R1a-routing-undecidable-token-intact"
else
    fail "T2223CJ-R1a-routing-undecidable-token-intact — S0-undecidable SSOT token missing from $ROUTING_JS"
fi

r1_ids="$(run_with_timeout 30 node -e '
const cr = require(process.argv[1]);
const ok = Array.isArray(cr.SIGNAL_IDS) && cr.SIGNAL_IDS.length === 7
  && ["S1-multi-file","S1b-wide-change","S2-architecture","S3-security","S4-installer","S5-breaking","S6-long-plan"].every(s => cr.SIGNAL_IDS.includes(s));
process.stdout.write(ok ? "ok" : "bad:" + JSON.stringify(cr.SIGNAL_IDS));
' "$AGENTS_DIR/$ROUTING_JS" 2>&1 || true)"
if [[ "$r1_ids" == "ok" ]]; then
    pass "T2223CJ-R1b-routing-signal-vocabulary-intact"
else
    fail "T2223CJ-R1b-routing-signal-vocabulary-intact — SIGNAL_IDS not the 7-member SSOT set (got: $r1_ids)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
