#!/usr/bin/env bash
# tests/enforce-clearance-token-write/interpreter-widening-evidence-cases.sh
# Tests: hooks/block-clearance-token-write/interpreter-scan.js, hooks/lib/protected-basenames.js
# Tags: anti-cheat, off-clearance, clearance-token, interpreter-scan, flag-cluster, mention-gate, non-vacuity, mutation-evidence, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap: unit-level on the two Tier-1 predicates; the end-to-end verdicts they explain
# live in the sibling read-only-allowlist-cases.sh, whose own TL3 gap covers the real host.

set -u

# #1816/#1821 cycle-3 C3+C8. The sibling table asserts VERDICTS, and a verdict cannot say
# WHY it came out that way: an allow row that never armed Tier-1 approves by early exit and
# proves nothing about the widened cluster path. AW* measures the two Tier-1 predicates on
# the exact payloads that table uses, so "this allow row genuinely entered the gate" is a
# measurement rather than a claim in a comment.

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; [ "$FAIL" -gt 0 ] && exit 1; exit 0; }

echo "=== AW: the #1816 allow rows genuinely arm Tier-1 (C3 non-vacuity) ==="
# Columns: label | want-mention | want-interpreter | payload, the AL-1816* rows of
# read-only-allowlist-cases.sh with @TOK@ expanded. BOTH predicates are asserted per row:
# either alone is satisfiable by accident, and Tier-1 arms only when both are true.
AW_OUT="$("$RWT" 40 node -e '
const A = process.argv[1];
const pb = require(A + "/hooks/lib/protected-basenames.js");
const is = require(A + "/hooks/block-clearance-token-write/interpreter-scan.js");
const T = "/tmp/wf/wsid.off-clearance";
const P = "P=\"" + T + "\"; ";
const rows = [
  ["AL-1816a python3 -c",   true,  true, P + "python3 -c \"print(\x27hello\x27)\""],
  ["AL-1816b perl -e",      true,  true, P + "perl -e \"print(1);\""],
  ["AL-1816c ruby -e",      true,  true, P + "ruby -e \"puts(1)\""],
  ["AL-1816c2 deno --eval", true,  true, P + "deno --eval \"console.log(1)\""],
  ["AL-1816c3 bun -e",      true,  true, P + "bun -e \"console.log(1)\""],
  ["AL-1816d python cluster", false, true, "python3 -bBiuxSPqhIOuc \"open(\x27/tmp/notes.txt\x27,\x27w\x27).write(\x27x\x27)\""],
  ["AL-1816e perl cluster",   false, true, "perl -wnle \"open(F,\x27>\x27,\x27/tmp/notes.txt\x27);\""],
  ["AL-1816f ruby cluster",   false, true, "ruby -wnrtye \"File.write(\x27/tmp/notes.txt\x27,\x27x\x27);\""],
];
let n = 0;
for (const [label, wantMention, wantInterp, text] of rows) {
  n++;
  const m = pb.mentionsProtectedName(text);
  const i = is.looksLikeInterpreterInvocation(text);
  if (m !== wantMention) {
    process.stdout.write("NG|AW " + label + " mention want=" + wantMention + " got=" + m + "\n");
  } else if (i !== wantInterp) {
    process.stdout.write("NG|AW " + label + " interpreter-shape want=" + wantInterp + " got=" + i + "\n");
  } else if (wantMention) {
    process.stdout.write("OK|AW " + label + " ARMS Tier-1 (mention+interpreter both true) and the sibling table still approves it\n");
  } else {
    process.stdout.write("OK|AW " + label + " is the interpreter-shaped baseline that does NOT arm (mention=false), so its approve is an early exit by design\n");
  }
}
// Without a split the AW column would be a row of identical answers and could not tell an
// armed row from an unarmed one (CPR-ORTH, both directions of the same predicate).
const armedN = rows.filter((r) => r[1]).length;
if (armedN > 0 && armedN < rows.length) process.stdout.write("OK|AW-split the table holds both armed and unarmed rows (" + armedN + "/" + rows.length + ")\n");
else process.stdout.write("NG|AW-split every AW row is on the same side (" + armedN + "/" + rows.length + ") — the column asserts nothing\n");
process.stdout.write("DONE|" + n + "\n");
' "$_AGENTS_DIR_NODE" 2>&1)"

AW_DONE=no
while IFS= read -r line; do
    case "$line" in
        OK\|*)   pass "${line#OK|}" ;;
        NG\|*)   fail "${line#NG|}" ;;
        DONE\|*) AW_DONE=yes ;;
        "")      ;;
        *)       echo "  (node stderr: $line)" ;;
    esac
done <<< "$AW_OUT"
if [ "$AW_DONE" = "yes" ]; then pass "AW-run the matrix ran to completion"
else fail "AW-run the matrix did NOT complete (node crashed or timed out); output=$AW_OUT"; fi

echo ""
echo "=== MU: recorded mutation evidence for the #1816 additions (C8) ==="
# bin/mutation-probe.sh cannot reach these: it only rewrites single-line `const NAME = /re/;`
# declarations, while all five additions are String.raw constants or array members. Each was
# therefore neutered to `(?!)` by hand, one at a time, in a SCRATCHPAD COPY of
# interpreter-scan.js (never the real module), with read-only-allowlist-cases.sh run against
# the mutated copy. Every mutation reddened exactly the rows below and nothing else moved.

echo "  alternative -> rows that redden when that alternative alone never matches:"
# PYTHON_CLUSTER_FLAG    -> WR-1816a, WR-1816b1, WR-1816b2         (block -> approve)
# PERL_CLUSTER_FLAG      -> WR-1816e                               (block -> approve)
# FALLBACK_CLUSTER_FLAG  -> WR-1816f, DB-bun-cluster, DB-deno-cluster
# node bare-read shape   -> RD-ro1, RD-ro3, RD-ro5, RD-ro6, RD-ro7, DB-bun-read
# python bare-read shape -> RD-ro2, RD-ro8                         (approve -> block)

# MU1/MU2 keep that record honest: the five additions must still exist under these shapes,
# or the mapping above silently describes a module that no longer has them.
MU_OUT="$("$RWT" 20 node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1] + "/hooks/block-clearance-token-write/interpreter-scan.js", "utf8");
const wanted = ["PYTHON_CLUSTER_FLAG", "PERL_CLUSTER_FLAG", "FALLBACK_CLUSTER_FLAG"];
const missing = wanted.filter((n) => !new RegExp("const " + n + "\\s*=").test(src));
const shapes = (src.match(/^\s*new RegExp\(String\.raw`\^/gm) || []).length;
process.stdout.write(missing.join(",") + "|" + shapes);
' "$_AGENTS_DIR_NODE" 2>/dev/null)"
MU_MISSING="${MU_OUT%%|*}"; MU_SHAPES="${MU_OUT##*|}"
if [ -z "$MU_MISSING" ]; then
    pass "MU1 all three cluster-flag constants named in the mutation record still exist"
else
    fail "MU1 the mutation record names constants that no longer exist: $MU_MISSING — the recorded alternative->row mapping is stale"
fi
if [ -n "$MU_SHAPES" ] && [ "$MU_SHAPES" -ge 4 ]; then
    pass "MU2 READONLY_BODY_SHAPES still carries the anchored members the record maps ($MU_SHAPES body shapes)"
else
    fail "MU2 only ${MU_SHAPES:-0} anchored body shapes found, want >=4 — the two bare-read members the record maps are gone"
fi

report
