#!/usr/bin/env bash
# Tests: hooks/preuse-auto-approve/script-body-scan.js, hooks/lib/credential-check.js, hooks/lib/unrecognized-exec-check.js
# Tags: script-body-scan, nested-scripts, resource-limits, credential-indirection, scope:issue-specific, pwsh-not-required
# #2170 ROUND-5: the body scan's edges, one section each.
#   G1 = exact resource-limit boundaries (bytes / logical lines / nesting depth)
#   G2 = nested `bash <script>.sh` recursion — order and invocation spelling
#   G3 = credential access reached through a variable
#   G4 = Windows / eval execution channels, seen from a body
#   G5 = recursion bookkeeping shared across a whole scan (cycles, dedupe, budget)
# G2-G4 were GAP-PINned against the pre-fix source; round 6 closed all three, so each
# now asserts the correct verdict in both directions.

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - Claude Code's own reaction to the hook decision (prompt shown, tool blocked)
# - real filesystem race conditions while a nested script is being read
# - the wall-clock cost of a scan that walks to the depth/line budget in a live session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
export AGENTS_DIR
DRIVER="$(cd "$(dirname "$0")/feature-2170-script-body-scan" && pwd)/scan-driver.js"
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

body() { node "$DRIVER" --body "$1" 2>&1; }
line() { node "$DRIVER" --line "$1" 2>&1; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}
# Standard table-driven runner (skills/_shared/test-design/parser-regex-tests.md).
run_table() {
    local prefix="$1" mode="$2" name input want
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        assert_eq "$prefix-$name" "$want" "$(node "$DRIVER" "$mode" "$(trim "$input")" 2>&1)"
    done
}

# --- G1: exact resource-limit boundaries -------------------------------------
# Each limit is a `>` comparison, so the interesting pair is EXACTLY-AT (must stay
# approvable) and ONE-OVER (must give up and answer suspect). Testing only a wildly
# oversized file would leave an off-by-one in either direction undetected.
echo "--- G1: MAX_SCRIPT_BYTES / MAX_LOGICAL_LINES / MAX_SCRIPT_DEPTH ---"
assert_eq "G1-const-max-bytes" "1048576" "$(node "$DRIVER" --const MAX_SCRIPT_BYTES 2>&1)"
assert_eq "G1-const-max-depth" "5"       "$(node "$DRIVER" --const MAX_SCRIPT_DEPTH 2>&1)"
# MAX_LOGICAL_LINES is deliberately not exported, so its value is pinned indirectly:
# toLogicalLines on the fixtures below must report exactly 2000 and 2001.
LIM="$TMPROOT_RAW/limits"
mkdir -p "$LIM"
head -c 1048576 /dev/zero | tr '\0' 'a' >"$LIM/bytes-exact.sh"
head -c 1048577 /dev/zero | tr '\0' 'a' >"$LIM/bytes-over.sh"
assert_eq "G1-bytes-exactly-at-limit" "safe"    "$(body "$TMPROOT/limits/bytes-exact.sh")"
assert_eq "G1-bytes-one-over-limit"   "suspect" "$(body "$TMPROOT/limits/bytes-over.sh")"

# N physical lines each ending in \n produce N+1 logical lines (the trailing empty).
yes 'echo x' | head -n 1999 >"$LIM/lines-exact.sh"
yes 'echo x' | head -n 2000 >"$LIM/lines-over.sh"
count_lines() { node "$DRIVER" --logical-file "$1" 2>&1 | tr ',' '\n' | grep -c '.'; }
assert_eq "G1-lines-fixture-is-exactly-2000" "2000" "$(count_lines "$TMPROOT/limits/lines-exact.sh")"
assert_eq "G1-lines-fixture-is-exactly-2001" "2001" "$(count_lines "$TMPROOT/limits/lines-over.sh")"
assert_eq "G1-lines-exactly-at-limit" "safe"    "$(body "$TMPROOT/limits/lines-exact.sh")"
assert_eq "G1-lines-one-over-limit"   "suspect" "$(body "$TMPROOT/limits/lines-over.sh")"

# A chain of scripts that each invoke the next. d0 is depth 0, so d0..d5 is exactly
# MAX_SCRIPT_DEPTH hops and d0..d6 is one too many.
mk_chain() {
    local dir="$1" last="$2" i
    mkdir -p "$TMPROOT_RAW/$dir"
    for ((i = 0; i < last; i++)); do
        printf 'bash %s/%s/d%s.sh\n' "$TMPROOT" "$dir" "$((i + 1))" >"$TMPROOT_RAW/$dir/d$i.sh"
    done
    printf 'echo deepest\n' >"$TMPROOT_RAW/$dir/d$last.sh"
}
mk_chain depth5 5
mk_chain depth6 6
assert_eq "G1-depth-exactly-at-limit" "safe"    "$(body "$TMPROOT/depth5/d0.sh")"
assert_eq "G1-depth-one-over-limit"   "suspect" "$(body "$TMPROOT/depth6/d0.sh")"

# --- G2: nested-script recursion --------------------------------------------
# NESTED_SCRIPT_RE now carries /g and skips leading flags/`--`, so nestedScriptTargets
# returns EVERY nested target on a logical line regardless of order or invocation
# spelling. Order-independence and flag-tolerance are asserted in both directions.
echo ""
echo '--- G2: nested "bash <script>.sh" recursion ---'
NEST="$TMPROOT_RAW/nested"
mkdir -p "$NEST"
printf 'echo fine\n'          >"$NEST/benign.sh"
printf 'winget install evil\n' >"$NEST/danger.sh"
N="$TMPROOT/nested"
printf 'bash %s/benign.sh; bash %s/danger.sh\n' "$N" "$N" >"$NEST/danger-second.sh"
printf 'bash %s/danger.sh; bash %s/benign.sh\n' "$N" "$N" >"$NEST/danger-first.sh"
printf 'bash %s/benign.sh; bash %s/benign.sh\n' "$N" "$N" >"$NEST/both-benign.sh"
printf 'bash -e %s/danger.sh\n'  "$N" >"$NEST/flag-danger.sh"
printf 'bash -e %s/benign.sh\n'  "$N" >"$NEST/flag-benign.sh"
printf 'sh -- %s/danger.sh\n'    "$N" >"$NEST/dashdash-danger.sh"
printf 'sh -- %s/benign.sh\n'    "$N" >"$NEST/dashdash-benign.sh"

run_table "G2" --body <<TABLE
# The dangerous script is followed whichever position it holds on the line, and
# whichever flag spelling introduces it.
danger-second-is-caught      | $N/danger-second.sh   | suspect
danger-first-is-caught       | $N/danger-first.sh    | suspect
bash-e-danger-is-followed    | $N/flag-danger.sh     | suspect
sh-dashdash-danger-is-followed | $N/dashdash-danger.sh | suspect
# Both-direction controls: the benign twins are safe for the ordinary reason, not the
# gap — they catch a fix that over-blocks every flagged invocation.
both-benign-stays-safe       | $N/both-benign.sh     | safe
flagged-benign-safe          | $N/flag-benign.sh     | safe
dashdash-benign-safe         | $N/dashdash-benign.sh | safe
TABLE

# --- G3: credential access through a variable --------------------------------
# textHoldsIndirectCredentialAccess (hooks/lib/credential-check.js) correlates a
# `VAR=<credential-path>` assignment with a later `$VAR` reader across the JOINED
# body, so the two-step read is now caught. The correlation is BODY-level by
# construction: a single line carrying only the assignment, or only the use, still
# has nothing to pair with — those two rows below stay safe by design, not by gap.
echo ""
echo "--- G3: credential path held in a variable ---"
CRED="$TMPROOT_RAW/cred"
mkdir -p "$CRED"
printf 'P=~/.ssh/id_rsa\ncat "$P"\n'                    >"$CRED/indirect.sh"
printf 'KEY=~/.aws/credentials\ncat "$KEY"\n'           >"$CRED/indirect-aws.sh"
printf 'cat ~/.ssh/id_rsa\n'                            >"$CRED/direct.sh"
# Positive control: written literally, the very same read IS caught — so the gap is
# the indirection, not the credential table.
assert_eq "G3-direct-credential-read-caught" "suspect" "$(body "$TMPROOT/cred/direct.sh")"
assert_eq "G3-indirect-ssh-key-caught"  "suspect" "$(body "$TMPROOT/cred/indirect.sh")"
assert_eq "G3-indirect-aws-cred-caught" "suspect" "$(body "$TMPROOT/cred/indirect-aws.sh")"
# Line level, so the scope of the fix is located precisely: in isolation neither
# half pairs with anything, and an over-eager fix that flagged them alone would
# block every ordinary `cat "$SOMEVAR"`.
assert_eq "G3-line-assignment-alone-safe" "safe" "$(line 'P=~/.ssh/id_rsa')"
assert_eq "G3-line-use-alone-safe"        "safe" "$(line 'cat "$P"')"
assert_eq "G3-line-literal-read"    "suspect" "$(line 'cat ~/.ssh/id_rsa')"

# The correlation is exercised directly, one reader command per row: READ_CMDS_ALT
# lists five, and `cat` alone would leave the other four unpinned. `\n` in the input
# column is unescaped by the driver, so a whole body rides in one argv element.
# The last two rows are the negatives that keep the correlation from degenerating into
# "a credential path appears anywhere": a DIFFERENT variable holding the credential
# must not lend its danger to the one actually read.
run_table "G3cred" --indirect-cred <<'TABLE'
reader-cat   | P=~/.ssh/id_rsa\ncat "$P"\n        | hit
reader-less  | P=~/.ssh/id_rsa\nless "$P"\n       | hit
reader-more  | P=~/.ssh/id_rsa\nmore "$P"\n       | hit
reader-head  | P=~/.ssh/id_rsa\nhead "$P"\n       | hit
reader-tail  | P=~/.ssh/id_rsa\ntail -n 5 "$P"\n  | hit
prefix-collision-stays-safe | P=safe\nPATH2=~/.ssh/id_rsa\ncat "$P"\n | miss
no-credential-anywhere      | P=./notes.txt\ncat "$P"\n              | miss
TABLE
# Over-blocking control (CPR-ORTH twin of the reader rows above): the correlation
# requires a READ of the variable, so a credential path that only ever sits in DATA
# position — echoed, mentioned in a comment, or embedded in a message string — must
# not be reported. Without these rows the predicate could degrade into "a credential
# path appears anywhere" and every script that merely NAMES ~/.ssh would lose its
# auto-approval.
run_table "G3cred" --indirect-cred <<'TABLE'
credential-only-echoed        | P=~/.ssh/id_rsa\necho "$P"\n              | miss
credential-in-comment-only    | P=./notes.txt\n# see ~/.ssh/id_rsa\ncat "$P"\n | miss
credential-inside-message     | MSG="path is ~/.ssh/id_rsa"\ncat "$MSG"\n  | miss
TABLE
# Over-blocking direction, now correctly handled: the correlation is order-SENSITIVE, so
# a read that precedes the assignment — where `$P` cannot yet hold the credential — is
# not reported as a hit.
# TL3 gap: none — a pure text predicate, fully observable here.
run_table "G3cred" --indirect-cred <<'TABLE'
use-before-assignment | cat "$P"\nP=~/.ssh/id_rsa\n | miss
TABLE

# --- G4: Windows / eval execution channels, seen from a body -----------------
# lineIsSuspect delegates to commandInvokesUnrecognizedExec, whose interpreter list
# now carries the Windows arm (pwsh/powershell(.exe), a bare *.exe command word) and
# `eval`. The unit-level reading of the same predicate lives in
# tests/feature-2170-round3-predicates.sh Section A2; this section pins the
# consequence at the BODY layer, which is what actually auto-approves.
echo ""
echo "--- G4: Windows / eval interpreter channels reach the body scan ---"
EXEC="$TMPROOT_RAW/exec"
mkdir -p "$EXEC"
printf 'pwsh %s/exec/a.ps1\n'            "$TMPROOT" >"$EXEC/pwsh.sh"
printf 'powershell -Command Get-Process\n'          >"$EXEC/powershell.sh"
printf 'C:/tools/evil.exe --run\n'                  >"$EXEC/winexe.sh"
printf 'eval "$PAYLOAD"\n'                          >"$EXEC/eval.sh"
printf 'node %s/exec/a.js\n'             "$TMPROOT" >"$EXEC/node.sh"
printf 'echo plain text\n'                          >"$EXEC/benign.sh"
run_table "G4" --body <<TABLE
# Positive control: a recognised interpreter in the same position IS caught.
node-body-caught         | $TMPROOT/exec/node.sh       | suspect
pwsh-body-caught         | $TMPROOT/exec/pwsh.sh       | suspect
powershell-body-caught   | $TMPROOT/exec/powershell.sh | suspect
windows-exe-body-caught  | $TMPROOT/exec/winexe.sh     | suspect
# \`eval\` is on the interpreter list in its own right; it was already suspect
# incidentally (variable expansion trips another arm), so this row must stay suspect.
eval-variable-body-caught | $TMPROOT/exec/eval.sh      | suspect
# Both-direction control: a body with no execution channel at all stays approvable.
plain-body-safe          | $TMPROOT/exec/benign.sh     | safe
TABLE

# --- G5: recursion bookkeeping across a whole scan ----------------------------
# G1 sizes one file at a time; scanScript instead carries `state.stack` (cycle guard),
# `state.done` (dedupe) and `state.lines` (a CUMULATIVE budget) across every file it
# opens. Those three are only observable through a multi-file fixture: a self-
# referential pair, a child included twice, and a parent+child whose line counts only
# breach the budget when added together.
echo ""
echo "--- G5: cycles, dedupe, and the cumulative logical-line budget ---"
AGG="$TMPROOT_RAW/agg"
mkdir -p "$AGG"
A="$TMPROOT/agg"
# A cycle must terminate, and it does so by answering suspect — fail-to-suspect, since
# a self-referential include is not a shape the scanner can vouch for even when every
# line in the loop is innocuous. The dangerous twin pins that the guard terminates
# WITHOUT swallowing a real finding.
printf 'echo a\nbash %s/cyc-b.sh\n' "$A" >"$AGG/cyc-a.sh"
printf 'echo b\nbash %s/cyc-a.sh\n' "$A" >"$AGG/cyc-b.sh"
printf 'winget install evil\nbash %s/cycd-b.sh\n' "$A" >"$AGG/cycd-a.sh"
printf 'echo b\nbash %s/cycd-a.sh\n' "$A" >"$AGG/cycd-b.sh"
# The same benign child named twice is scanned once; a repeated DANGEROUS child must
# still be reported, so dedupe cannot be short-circuiting the verdict.
printf 'echo fine\n' >"$AGG/dup-child.sh"
printf 'bash %s/dup-child.sh\nbash %s/dup-child.sh\n' "$A" "$A" >"$AGG/dup-parent.sh"
printf 'winget install evil\n' >"$AGG/dupd-child.sh"
printf 'bash %s/dupd-child.sh\nbash %s/dupd-child.sh\n' "$A" "$A" >"$AGG/dupd-parent.sh"
# dup-parent above cannot tell dedupe from a no-op: its child is two lines long, so the
# budget is nowhere near either way. These two parents make `state.done` OBSERVABLE by
# putting the cumulative budget between the deduped and the recounted total. Each big
# child is 1500 physical -> 1501 logical lines; the parent adds 2.
#   same child twice, deduped  -> 2 + 1501       = 1503  <= 2000  -> safe
#   same child twice, recounted -> 2 + 1501 + 1501 = 3004 >  2000 -> suspect
# The distinct-children twin spends exactly the recounted total with dedupe intact, so
# it pins that 3004 really does breach the budget — the safe verdict above comes from
# dedupe, not from an unreachable limit.
yes 'echo x' | head -n 1500 >"$AGG/big-a.sh"
yes 'echo x' | head -n 1500 >"$AGG/big-b.sh"
printf 'bash %s/big-a.sh\nbash %s/big-a.sh\n' "$A" "$A" >"$AGG/dedup-same-big.sh"
printf 'bash %s/big-a.sh\nbash %s/big-b.sh\n' "$A" "$A" >"$AGG/dedup-distinct-big.sh"
# Parent is 1 physical line -> 2 logical lines. Child at 1998 physical lines -> 1999
# logical, for 2001 cumulative; at 1997 -> 1998 logical, for exactly 2000.
printf 'bash %s/agg-child-exact.sh\n' "$A" >"$AGG/agg-exact.sh"
printf 'bash %s/agg-child-over.sh\n'  "$A" >"$AGG/agg-over.sh"
yes 'echo x' | head -n 1997 >"$AGG/agg-child-exact.sh"
yes 'echo x' | head -n 1998 >"$AGG/agg-child-over.sh"
# Neither child breaches the budget alone (G1 pins 1999 physical lines as safe), so a
# suspect verdict on agg-over can only come from the cumulative count.
run_table "G5" --body <<TABLE
cycle-benign-terminates-suspect | $A/cyc-a.sh      | suspect
cycle-dangerous-still-caught   | $A/cycd-a.sh      | suspect
duplicate-benign-child-safe    | $A/dup-parent.sh  | safe
duplicate-danger-child-caught  | $A/dupd-parent.sh | suspect
dedupe-same-big-child-twice-safe    | $A/dedup-same-big.sh     | safe
dedupe-distinct-big-children-suspect | $A/dedup-distinct-big.sh | suspect
cumulative-lines-exactly-at-limit | $A/agg-exact.sh | safe
cumulative-lines-one-over-limit   | $A/agg-over.sh  | suspect
TABLE

echo ""
echo "==================================================="
echo "feature-2170-round5-body-gaps: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
exit "$FAIL"
