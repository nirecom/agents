#!/usr/bin/env bash
# tests/feature-2134-command-ir-equivalence/snapshot.sh
# Tests: hooks/lib/command-ir.js, hooks/lib/command-parser.js
# Tags: hook, command-ir, equivalence, snapshot, TL1, scope:issue-specific
#
# Reconciles corpus against expected.json. No args: check only; --update: regenerate.
# Regeneration accepts only diffs for ids that have a reason recorded in deliberate-diffs.js.
# The check fails "declared diffs" and "undeclared diffs" with different messages (the former
# means expected.json wasn't updated, the latter means a parser regression -- the fixes are
# opposite, so the wording must not be the same).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$DIR/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

# Fixture isolation (rules/test/fixture-isolation.md): these are pure function calls only, so
# pinning CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR is unnecessary, but the parent session's id
# must always be dropped -- the child node inheriting it could touch real session state.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

PROBE="$(npath "$DIR/probe.js")"
CORPUS="$(npath "$DIR/corpus.js")"
DELIB="$(npath "$DIR/deliberate-diffs.js")"
EXPECTED="$DIR/expected.json"
EXPECTED_N="$(npath "$EXPECTED")"
RUNNER="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; ROWS=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ir-equiv-snap.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT
TAB="$(printf '\t')"

# The current implementation's actual output. probe.js is the sole serializer (enumerable-only / key-sorted).
if ! bash "$RUNNER" 120 node "$PROBE" > "$TMPD/actual.tsv" 2>"$TMPD/probe.err"; then
    fail "probe.js could not produce a snapshot" "$(head -5 "$TMPD/probe.err")"
    echo ""; echo "Total: $PASS passed, $FAIL failed"; exit 1
fi

CORPUS_N="$(bash "$RUNNER" 30 node -e 'process.stdout.write(String(require(process.argv[1]).length));' "$CORPUS" 2>/dev/null)"
ACTUAL_N="$(grep -c . "$TMPD/actual.tsv")"

# List of declared ids (one id per line). An entry with an empty reason does not count as declared.
bash "$RUNNER" 30 node -e '
  const rows = require(process.argv[1]);
  for (const r of rows) {
    if (!r || !r.id) continue;
    if (!r.reason || String(r.reason).trim() === "") continue;
    process.stdout.write(String(r.id) + "\n");
  }
' "$DELIB" > "$TMPD/declared.txt" 2>/dev/null || : > "$TMPD/declared.txt"

render_expected() { # -> id<TAB>json
    bash "$RUNNER" 30 node -e '
      const e = require(process.argv[1]);
      for (const k of Object.keys(e)) process.stdout.write(k + "\t" + JSON.stringify(e[k]) + "\n");
    ' "$EXPECTED_N" 2>/dev/null
}

write_expected() { # actual.tsv -> expected.json
    bash "$RUNNER" 30 node -e '
      const fs = require("fs");
      const src = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
      const out = {};
      for (const ln of src) { const i = ln.indexOf("\t"); out[ln.slice(0, i)] = JSON.parse(ln.slice(i + 1)); }
      fs.writeFileSync(process.argv[2], JSON.stringify(out, null, 2) + "\n");
    ' "$(npath "$TMPD/actual.tsv")" "$EXPECTED_N"
}

MODE="${1:-check}"

if [ ! -f "$EXPECTED" ]; then
    if [ "$MODE" = "--update" ]; then
        write_expected && echo "expected.json generated from the current implementation ($ACTUAL_N ids)"
        exit $?
    fi
    fail "expected.json is missing -- run: bash tests/feature-2134-command-ir-equivalence/snapshot.sh --update"
    echo ""; echo "Total: $PASS passed, $FAIL failed"; exit 1
fi

render_expected > "$TMPD/expected.tsv"

# Reconcile keys with join (associative arrays require bash 4+ and don't work on macOS's bash 3.2).
LC_ALL=C sort -t "$TAB" -k1,1 "$TMPD/actual.tsv"   > "$TMPD/actual.sorted"
LC_ALL=C sort -t "$TAB" -k1,1 "$TMPD/expected.tsv" > "$TMPD/expected.sorted"
LC_ALL=C join -t "$TAB" -a 1 -a 2 -e "<ABSENT>" -o 0,1.2,2.2 \
    "$TMPD/actual.sorted" "$TMPD/expected.sorted" > "$TMPD/joined.tsv"

UNDECLARED=0
DECLARED_PENDING=0

while IFS="$TAB" read -r id got want; do
    [ -z "$id" ] && continue
    ROWS=$((ROWS + 1))
    if [ "$want" = "<ABSENT>" ]; then
        fail "$id: no entry in expected.json (a new corpus case needs --update)"
        continue
    fi
    if [ "$got" = "<ABSENT>" ]; then
        fail "$id: stale expected.json entry -- no such id in corpus.js"
        continue
    fi
    if [ "$got" = "$want" ]; then
        pass "$id: parse() output matches the pinned snapshot"
        continue
    fi
    if grep -Fxq "$id" "$TMPD/declared.txt"; then
        DECLARED_PENDING=$((DECLARED_PENDING + 1))
        fail "$id: declared in deliberate-diffs.js but expected.json is not updated yet -- run --update" \
             "want=$want got=$got"
    else
        UNDECLARED=$((UNDECLARED + 1))
        fail "$id: parse() output changed and NOTHING declares it -- treat as a parser regression, not an expectation to rewrite" \
             "want=$want got=$got"
    fi
done < "$TMPD/joined.tsv"

if [ "$MODE" = "--update" ]; then
    if [ "$UNDECLARED" -gt 0 ]; then
        echo "REFUSED: $UNDECLARED undeclared expectation change(s); add each id + reason to deliberate-diffs.js first" >&2
        exit 1
    fi
    write_expected && echo "expected.json updated ($DECLARED_PENDING declared diff(s) applied)"
    exit $?
fi

# Determinism (idempotency). Snapshot comparison assumes "the same input always serializes the
# same way", so this measures that assumption itself. An implementation whose key order drifts
# between runs makes expected.json meaningless, but a single-run comparison would never reveal it.
bash "$RUNNER" 120 node "$PROBE" > "$TMPD/actual2.tsv" 2>/dev/null
if cmp -s "$TMPD/actual.tsv" "$TMPD/actual2.tsv"; then
    pass "determinism: two consecutive probe runs serialize identically"
else
    fail "determinism: probe.js output differs between two runs -- the snapshot premise is broken" \
         "$(diff "$TMPD/actual.tsv" "$TMPD/actual2.tsv" | head -5)"
fi

# Budget for the number of rows executed. Guards against an empty table or an early return reading as "green with 0 cases".
if [ "$ROWS" = "$CORPUS_N" ] && [ "$ACTUAL_N" = "$CORPUS_N" ]; then
    pass "row budget: all $CORPUS_N corpus cases were probed and compared"
else
    fail "row budget: compared=$ROWS probed=$ACTUAL_N corpus=$CORPUS_N"
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
