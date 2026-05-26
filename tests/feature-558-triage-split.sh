#!/usr/bin/env bash
# Tests for skills/_shared/triage-split.sh (issue #558).
# Will FAIL until the helper is implemented (test-first).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
SCRIPT="$AGENTS_ROOT/skills/_shared/triage-split.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Helper: build a full markdown document with a given Class members body.
make_doc() {
    local out="$1"
    local cm_body="$2"
    {
        echo "# Plan"
        echo ""
        echo "## Issue"
        echo ""
        echo "Issue body line."
        echo ""
        echo "## Class members"
        echo ""
        printf '%s\n' "$cm_body"
        echo ""
        echo "## Accepted Tradeoffs"
        echo ""
        echo "- tradeoff one"
    } > "$out"
}

# ---------------------------------------------------------------------------
# (1) Executable bit
# ---------------------------------------------------------------------------
if [[ -x "$SCRIPT" ]]; then
    pass "(1) triage-split.sh is executable"
else
    fail "(1) triage-split.sh is not executable or missing: $SCRIPT"
fi

# ---------------------------------------------------------------------------
# (2) New 3-value enum: MUST x2, OPTIONAL x1, NA x1
# ---------------------------------------------------------------------------
FIXTURE2="$TMPDIR_BASE/fixture2.md"
make_doc "$FIXTURE2" "- member-a: first must — disposition: MUST
- member-b: second must — disposition: MUST
- member-c: an optional one — disposition: OPTIONAL
- member-d: out of scope — disposition: NA"

EXPECTED2="$TMPDIR_BASE/expected2.txt"
cat > "$EXPECTED2" << 'EXPECTED_EOF'
### MUST (fix in scope required)
- member-a: first must
- member-b: second must

### OPTIONAL (planner judgment, justify in plan)
- member-c: an optional one

### NA (out of scope, do not address)
- member-d: out of scope
EXPECTED_EOF

ACTUAL2="$TMPDIR_BASE/actual2.txt"
EC=0
run_with_timeout bash "$SCRIPT" "$FIXTURE2" > "$ACTUAL2" 2>&1 || EC=$?
if [[ "$EC" == "0" ]] && diff -q "$EXPECTED2" "$ACTUAL2" >/dev/null 2>&1; then
    pass "(2) 3-value enum output matches expected schema exactly"
else
    fail "(2) 3-value enum output mismatch (exit=$EC). Diff:
$(diff "$EXPECTED2" "$ACTUAL2" 2>&1 | head -40)"
fi

# ---------------------------------------------------------------------------
# (3) Legacy 2-value enum: fix in scope x2, track separately x1
# ---------------------------------------------------------------------------
FIXTURE3="$TMPDIR_BASE/fixture3.md"
make_doc "$FIXTURE3" "- m-a: first legacy must — disposition: fix in scope
- m-b: second legacy must — disposition: fix in scope
- m-c: legacy na — disposition: track separately"

ACTUAL3="$TMPDIR_BASE/actual3.txt"
EC=0
run_with_timeout bash "$SCRIPT" "$FIXTURE3" > "$ACTUAL3" 2>&1 || EC=$?
if [[ "$EC" != "0" ]]; then
    fail "(3) legacy 2-value: exit $EC. Output: $(cat "$ACTUAL3")"
else
    MUST_COUNT=$(awk '/^### MUST/{flag=1;next}/^### /{flag=0}flag && /^- m-/' "$ACTUAL3" | wc -l | tr -d ' ')
    NA_COUNT=$(awk '/^### NA/{flag=1;next}/^### /{flag=0}flag && /^- m-/' "$ACTUAL3" | wc -l | tr -d ' ')
    OPT_NONE=$(awk '/^### OPTIONAL/{flag=1;next}/^### /{flag=0}flag' "$ACTUAL3" | grep -c '^- (none)$' || true)
    if [[ "$MUST_COUNT" == "2" && "$NA_COUNT" == "1" && "$OPT_NONE" == "1" ]]; then
        pass "(3) legacy 2-value normalized: MUST=2, NA=1, OPTIONAL=(none)"
    else
        fail "(3) legacy 2-value mapping wrong (MUST=$MUST_COUNT NA=$NA_COUNT OPT_NONE=$OPT_NONE). Output:
$(cat "$ACTUAL3")"
    fi
fi

# ---------------------------------------------------------------------------
# (4) Mixed: 3-value and 2-value in same Class members block
# ---------------------------------------------------------------------------
FIXTURE4="$TMPDIR_BASE/fixture4.md"
make_doc "$FIXTURE4" "- m1: new must — disposition: MUST
- m2: legacy must — disposition: fix in scope
- m3: new opt — disposition: OPTIONAL
- m4: legacy na — disposition: track separately
- m5: new na — disposition: NA"

ACTUAL4="$TMPDIR_BASE/actual4.txt"
EC=0
run_with_timeout bash "$SCRIPT" "$FIXTURE4" > "$ACTUAL4" 2>&1 || EC=$?
if [[ "$EC" == "0" ]]; then
    MUST_C=$(awk '/^### MUST/{flag=1;next}/^### /{flag=0}flag && /^- m/' "$ACTUAL4" | wc -l | tr -d ' ')
    OPT_C=$(awk '/^### OPTIONAL/{flag=1;next}/^### /{flag=0}flag && /^- m/' "$ACTUAL4" | wc -l | tr -d ' ')
    NA_C=$(awk '/^### NA/{flag=1;next}/^### /{flag=0}flag && /^- m/' "$ACTUAL4" | wc -l | tr -d ' ')
    if [[ "$MUST_C" == "2" && "$OPT_C" == "1" && "$NA_C" == "2" ]]; then
        pass "(4) mixed enum: MUST=2 OPTIONAL=1 NA=2 — all normalized correctly"
    else
        fail "(4) mixed enum counts wrong (MUST=$MUST_C OPT=$OPT_C NA=$NA_C). Output:
$(cat "$ACTUAL4")"
    fi
else
    fail "(4) mixed enum: exit $EC. Output: $(cat "$ACTUAL4")"
fi

# ---------------------------------------------------------------------------
# (5) Empty / (none detected) entry — all 3 sections output "- (none)", exit 0
# ---------------------------------------------------------------------------
FIXTURE5="$TMPDIR_BASE/fixture5.md"
make_doc "$FIXTURE5" "- (none detected)"

ACTUAL5="$TMPDIR_BASE/actual5.txt"
EC=0
run_with_timeout bash "$SCRIPT" "$FIXTURE5" > "$ACTUAL5" 2>&1 || EC=$?
if [[ "$EC" == "0" ]]; then
    NONE_C=$(grep -c '^- (none)$' "$ACTUAL5" || true)
    if [[ "$NONE_C" == "3" ]]; then
        pass "(5) (none detected): all 3 sections emit '- (none)', exit 0"
    else
        fail "(5) (none detected): expected 3 '- (none)' lines, got $NONE_C. Output:
$(cat "$ACTUAL5")"
    fi
else
    fail "(5) (none detected): expected exit 0, got $EC. Output: $(cat "$ACTUAL5")"
fi

# ---------------------------------------------------------------------------
# (6) Unknown disposition → exit 3, stderr non-empty, stdout empty
# ---------------------------------------------------------------------------
FIXTURE6="$TMPDIR_BASE/fixture6.md"
make_doc "$FIXTURE6" "- m1: a member — disposition: whatisthis"

STDOUT6="$TMPDIR_BASE/stdout6.txt"
STDERR6="$TMPDIR_BASE/stderr6.txt"
EC=0
run_with_timeout bash "$SCRIPT" "$FIXTURE6" >"$STDOUT6" 2>"$STDERR6" || EC=$?
if [[ "$EC" == "3" ]]; then
    STDERR_SZ=$(wc -c < "$STDERR6" | tr -d ' ')
    STDOUT_SZ=$(wc -c < "$STDOUT6" | tr -d ' ')
    if [[ "$STDERR_SZ" -gt 0 && "$STDOUT_SZ" -eq 0 ]]; then
        pass "(6) unknown disposition: exit 3, stderr non-empty, stdout empty"
    else
        fail "(6) unknown disposition: exit 3 but stderr_size=$STDERR_SZ stdout_size=$STDOUT_SZ"
    fi
else
    fail "(6) unknown disposition: expected exit 3, got $EC. stderr: $(cat "$STDERR6")"
fi

# ---------------------------------------------------------------------------
# (7) Missing disposition delimiter → exit 3, stderr non-empty
# ---------------------------------------------------------------------------
FIXTURE7="$TMPDIR_BASE/fixture7.md"
make_doc "$FIXTURE7" "- m1: this has no disposition delimiter at all"

STDERR7="$TMPDIR_BASE/stderr7.txt"
EC=0
run_with_timeout bash "$SCRIPT" "$FIXTURE7" >/dev/null 2>"$STDERR7" || EC=$?
if [[ "$EC" == "3" ]]; then
    STDERR7_SZ=$(wc -c < "$STDERR7" | tr -d ' ')
    if [[ "$STDERR7_SZ" -gt 0 ]]; then
        pass "(7) missing disposition: exit 3, stderr non-empty"
    else
        fail "(7) missing disposition: exit 3 but stderr was empty"
    fi
else
    fail "(7) missing disposition: expected exit 3, got $EC"
fi

# ---------------------------------------------------------------------------
# (8) Embedded em-dash in description — rightmost delimiter used
# ---------------------------------------------------------------------------
FIXTURE8="$TMPDIR_BASE/fixture8.md"
make_doc "$FIXTURE8" "- member-foo: some — tricky — desc — disposition: MUST"

ACTUAL8="$TMPDIR_BASE/actual8.txt"
EC=0
run_with_timeout bash "$SCRIPT" "$FIXTURE8" > "$ACTUAL8" 2>&1 || EC=$?
if [[ "$EC" == "0" ]] && grep -qF -- '- member-foo: some — tricky — desc' "$ACTUAL8"; then
    pass "(8) embedded em-dash: rightmost delimiter used, description preserved"
else
    fail "(8) embedded em-dash: parse failed (exit=$EC). Output:
$(cat "$ACTUAL8")"
fi

# ---------------------------------------------------------------------------
# (9) File argument → exit 0, correct output
# ---------------------------------------------------------------------------
EC=0
OUT=$(run_with_timeout bash "$SCRIPT" "$FIXTURE2" 2>&1) || EC=$?
if [[ "$EC" == "0" ]] && echo "$OUT" | grep -q '^### MUST (fix in scope required)$'; then
    pass "(9) file argument: exit 0, MUST header present"
else
    fail "(9) file argument: exit=$EC or MUST header missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# (10) --from-stdin with full document (piped) → exit 0, correct output
# ---------------------------------------------------------------------------
EC=0
OUT=$(run_with_timeout bash "$SCRIPT" --from-stdin < "$FIXTURE2" 2>&1) || EC=$?
if [[ "$EC" == "0" ]] && echo "$OUT" | grep -q '^### MUST (fix in scope required)$'; then
    pass "(10) --from-stdin (full document): exit 0, MUST header present"
else
    fail "(10) --from-stdin: exit=$EC or MUST header missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# (11) --from-stdin with bare Class members block only → exit 2
# ---------------------------------------------------------------------------
BARE11="$TMPDIR_BASE/bare11.md"
cat > "$BARE11" << 'BARE_EOF'
## Class members

- m1: a member — disposition: MUST
BARE_EOF

EC=0
OUT=$(run_with_timeout bash "$SCRIPT" --from-stdin < "$BARE11" 2>&1) || EC=$?
if [[ "$EC" == "2" ]]; then
    pass "(11) --from-stdin bare block (no surrounding doc): exit 2"
else
    fail "(11) --from-stdin bare block: expected exit 2, got $EC. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# (12) AGENTS_CONFIG_DIR unset → exit 2, stderr non-empty
# ---------------------------------------------------------------------------
STDERR12="$TMPDIR_BASE/stderr12.txt"
EC=0
(unset AGENTS_CONFIG_DIR; run_with_timeout bash "$SCRIPT" "$FIXTURE2" 2>"$STDERR12") || EC=$?
if [[ "$EC" == "2" ]]; then
    STDERR12_SZ=$(wc -c < "$STDERR12" | tr -d ' ')
    if [[ "$STDERR12_SZ" -gt 0 ]]; then
        pass "(12) AGENTS_CONFIG_DIR unset: exit 2, stderr non-empty"
    else
        fail "(12) AGENTS_CONFIG_DIR unset: exit 2 but stderr was empty"
    fi
else
    fail "(12) AGENTS_CONFIG_DIR unset: expected exit 2, got $EC"
fi

# ---------------------------------------------------------------------------
# (13) Non-existent file → exit 2
# ---------------------------------------------------------------------------
EC=0
OUT=$(run_with_timeout bash "$SCRIPT" "$TMPDIR_BASE/does-not-exist.md" 2>&1) || EC=$?
if [[ "$EC" == "2" ]]; then
    pass "(13) non-existent file: exit 2"
else
    fail "(13) non-existent file: expected exit 2, got $EC. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
