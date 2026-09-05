#!/usr/bin/env bash
# Tests: hooks/block-capture-echo/shape.js, hooks/lib/command-ir.js
# Tags: capture-echo-guard, shape-predicate, ir, table-driven, scope:issue-specific, pwsh-not-required
# Section A — detectCaptureEcho(ir) unit table (TL1: pure predicate, no I/O).
# Delimiter is the prescribed "|" (skills/_shared/test-design/parser-regex-tests.md).
# Cases that need a literal pipe inside the command write "<PIPE>"; "<NL>" encodes a
# newline. Both are decoded by shape-driver.js, so every case stays one grep-able row.
# want column: reject = detectCaptureEcho returns a hit; allow = returns null.

set -uo pipefail

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export AGENTS_DIR
DRIVER="$(cd "$(dirname "$0")" && pwd)/shape-driver.js"
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

while IFS='|' read -r name input want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got="$(node "$DRIVER" "$input" 2>&1)"
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
# --- True positives: capture-then-display-only, must be rejected -------------
TP-1|PLANS_DIR=$(bash bin/workflow-plans-dir); echo "$PLANS_DIR"|reject
TP-2|X=$(cmd) && echo "$X"|reject
TP-3|PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")<NL>printf 'PLANS_DIR=%s\n' "$PLANS_DIR"|reject
TP-4|PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \<NL>              <PIPE><PIPE> printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")<NL>printf 'PLANS_DIR=%s\n' "$PLANS_DIR"|reject
TP-5|X=$(a); echo "X=$X"|reject
TP-6|X=$(a); printf 'X=%s\n' "$X"|reject
TP-7|X="$(cmd -a)"; echo "$X"|reject
TP-8|X=`cmd`; echo "$X"|reject
TP-9|export X=$(cmd); echo "$X"|reject
TP-10|X=$(a); Y=$(b); printf '%s %s\n' "$X" "$Y"|reject
TP-11|X=$(a); echo -n "$X"|reject
TP-12|X=$(a); echo "${X}"|reject
TP-13|SKIP=$(cmd <PIPE> tail -1); echo "$SKIP"|reject
TP-14|X=$(a); Y=$(b); echo "$X $Y"|reject
TP-15|X=$(cat <<EOF<NL>hi<NL>EOF<NL>); echo "$X"|reject
# C1: a real registered command with its real argument list must still be caught —
# the guard must not be reachable only by the toy one-word inner commands above.
TP-16|SKIP=$(bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --target outline --advance); echo "$SKIP"|reject
# C1: inner command is an || fallback pair — capture-then-echo regardless.
TP-17|X=$(a <PIPE><PIPE> b); echo "$X"|reject
# C1: two separate capture assignments, only the first one echoed.
TP-18|X=$(a); Y=$(b); echo "$X"|reject
# --- True negatives: something else happens, must NOT be rejected -----------
TN-1|PLANS_DIR=$(bash bin/workflow-plans-dir); cat "$PLANS_DIR/a.md"; echo "$PLANS_DIR"|allow
TN-2|SYSTEM_OPS_APPROVED=1 bash install/foo.sh|allow
TN-3|X=5; echo "$X"|allow
TN-4|X=$(a); echo '$X'|allow
TN-5|X=$(a); echo "${X:-none}"|allow
TN-6|X=$(a); echo "$X $Y"|allow
TN-7|X=$(a); echo hello|allow
TN-8|SKIP_DISPATCH=$(bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --signals-file "<PLANS_DIR>/$SESSION_ID-complexity-signals.txt" --target outline --advance --so-c1 <true<PIPE>false> --so-c2 <true<PIPE>false> <PIPE> tail -1 <PIPE> cut -d= -f2-)|allow
TN-9|SKIP_DISPATCH=$(bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --signals-file "<PLANS_DIR>/$SESSION_ID-complexity-signals.txt" --target outline --advance --so-c1 true --so-c2 false <PIPE> tail -1 <PIPE> cut -d= -f2-)|allow
TN-10|PLANS_DIR="$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")"|allow
TN-11|PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \<NL>              <PIPE><PIPE> printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")<NL>SESSION_ID="${CLAUDE_SESSION_ID:-}"<NL>INTENT_MD="$PLANS_DIR/${SESSION_ID}-intent.md"|allow
TN-12|X=$(a); echo "$X" > /tmp/f|allow
TN-13|X=$(a) <PIPE> echo "$X"|allow
TN-14|echo "$(cmd)"|allow
TN-15|X=$(a); echo "$(other)"|allow
TN-16|X=$(a); echo "unterminated|allow
TN-17a|bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"|allow
TN-17b|bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null|allow
TN-17c|bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --target outline --advance|allow
TN-17d|node "$AGENTS_CONFIG_DIR/bin/parse-closes-issues" "$INTENT_MD"|allow
TN-18|X=$(a); echo "$X" other|allow
TN-19|X=$(a); echo "$X" <<EOF<NL>hi<NL>EOF|allow
TN-20|X=$(a); printf '%q\n' "$X"|allow
TN-21|X=$(a); printf '%d\n' "$X"|allow
TN-22|X=$(a); printf '%s %s\n' "$X" other|allow
TN-23|X=$(a); printf '%s\n' "$X" "$X"|allow
TN-24|X=$(a); echo -e "$X"|allow
TN-25|X=$(a); printf '%-10s\n' "$X"|allow
# --- C2: "looks like echo/printf" must not become a blanket allowlist --------
# The output segment is matched on basename, so an untrusted executable named
# echo/printf, or an echo whose arguments would undergo pathname/brace expansion,
# is still a capture-then-echo — none of these may be waved through as trivial.
AL-1|X=$(a); /tmp/echo "$X"|reject
AL-2|X=$(a); /tmp/printf '%s\n' "$X"|reject
AL-3|X=$(a); ./echo "$X"|reject
AL-4|X=$(a); echo *"$X"|reject
AL-5|X=$(a); echo {a,b}"$X"|reject
AL-6|X=$(a); echo ?"$X"|reject
# --- Boundary ---------------------------------------------------------------
BD-1a||allow
BD-1b|   |allow
BD-2|( X=$(a); echo "$X" )|allow
BD-3|X=$(a); /usr/bin/echo "$X"|reject
BD-4|X=$(a); printf 'literal only\n'|allow
BD-5a|X=$(a)|allow
BD-5b|echo "$X"|allow
BD-6a|X=$(a); echo "$X"|reject
BD-6b|ls|allow
# --- TC (round 13, C1): trailing content after the substitution --------------
# The assigned VALUE is only partly the substitution. Rows TC-1..TC-3 are pinned as
# `reject` because that is what shape.js does today (isSubstitutionValue tests only
# the PREFIX of the value); HIT-7 below records the consequence — innerCommandText
# drops the trailing text, so a matched remedy would hand back a command that
# produces a different string than the one that was blocked. See the KNOWN GAP note
# at the end of this file. TC-4/TC-5 are the mirror shapes that already answer
# `allow`, and they are the both-direction control that keeps the prefix test honest:
# a "reject anything containing $(" implementation would flip them.
TC-1|X=$(cmd)-suffix; echo "$X"|reject
TC-2|X="$(cmd)-suffix"; echo "$X"|reject
TC-3|X="$(cmd) literal"; echo "$X"|reject
TC-4|X="prefix $(cmd)"; echo "$X"|allow
TC-5|X=pre$(cmd); echo "$X"|allow
# --- DECL (round 13, C2): declaration-keyword-prefixed assignments -----------
# assignRawsOf accepts a DECL_KEYWORDS command whose EVERY argument is an assignment.
# DECL-1..DECL-4 pin the bare forms (all four keywords, CPR-ORTH with the existing
# TP-9 `export`). DECL-5..DECL-8 pin the FLAGGED forms, which answer `allow` today:
# `-r` / `--` is not an assignment, so the `every` test fails and the whole run is
# abandoned. That is the second KNOWN GAP recorded below — these rows exist so the
# evasion is visible and so a later fix flips a named row instead of landing silently.
DECL-1|declare X=$(cmd); echo "$X"|reject
DECL-2|local X=$(cmd); echo "$X"|reject
DECL-3|readonly X=$(cmd); echo "$X"|reject
DECL-4|typeset X=$(cmd); echo "$X"|reject
DECL-5|declare -r X=$(cmd); echo "$X"|allow
DECL-6|local -r X=$(cmd); echo "$X"|allow
DECL-7|readonly -r X=$(cmd); echo "$X"|allow
DECL-8|declare -- X=$(cmd); echo "$X"|allow
# Both-direction controls: the keyword alone is not a trigger. A non-capturing value
# and a keyword run that does more than display must both stay allowed, so DECL-1..4
# cannot be satisfied by "any DECL_KEYWORDS segment is a capture".
DECL-9|declare X=5; echo "$X"|allow
DECL-10|declare X=$(a); echo "$X"; ls|allow
DECL-11|declare X=$(a); declare Y=$(b); echo "$X$Y"|reject
# --- SE (round 13, C3): a SIDE-EFFECTING second capture ----------------------
# TP-18 pins `X=$(a); Y=$(b); echo "$X"` as a reject on the assumption that reissuing
# the inner command bare loses nothing. That assumption breaks when the unread capture
# runs for its side effect: SE-1's `mkdir` and SE-2's `git init` happen, and the
# remedy names only `a` (HIT-8). Pinned at today's verdict; third KNOWN GAP below.
SE-1|X=$(a); Y=$(mkdir -p /tmp/zz); echo "$X"|reject
SE-2|X=$(a); Y=$(git init -q /tmp/zz); echo "$X"|reject
# Control: with the side-effecting capture as the ONLY assignment and its own value
# displayed, the shape is the plain capture-echo the guard is for.
SE-3|Y=$(mkdir -p /tmp/zz); echo "$Y"|reject
TABLE

# --- Hit payload: the fields buildRemedy consumes ----------------------------
# Pinned only for single-assignment cases, where innerCommandText is unambiguous.
got="$(node "$DRIVER" --fields 'PLANS_DIR=$(bash bin/workflow-plans-dir); echo "$PLANS_DIR"' 2>&1)"
assert_eq "HIT-1 varNames+inner (TP-1)" "vars=PLANS_DIR inner=bash bin/workflow-plans-dir" "$got"

got="$(node "$DRIVER" --fields 'X="$(cmd -a)"; echo "$X"' 2>&1)"
assert_eq "HIT-2 inner from quoted substitution (TP-7)" "vars=X inner=cmd -a" "$got"

# innerCommandText is ambiguous with two assignments, so only varNames is pinned.
got="$(node "$DRIVER" --fields 'X=$(a); Y=$(b); printf '"'"'%s %s\n'"'"' "$X" "$Y"' 2>&1)"
got_vars="${got%% inner=*}"
assert_eq "HIT-3 multi-assign varNames (TP-10)" "vars=X,Y" "$got_vars"

got="$(node "$DRIVER" --fields 'X=$(a); echo hello' 2>&1)"
assert_eq "HIT-4 non-match yields no hit (TN-7)" "null" "$got"

# C1: innerCommandText is what the remedy quotes back, so it must carry the WHOLE
# invocation — interpreter, script and every argument. A truncated inner would let
# the remedy hand back a command that does something other than what was blocked.
want='vars=SKIP inner=bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --target outline --advance'
got="$(node "$DRIVER" --fields 'SKIP=$(bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --target outline --advance); echo "$SKIP"' 2>&1)"
assert_eq "HIT-5 inner keeps full argument list (TP-16)" "$want" "$got"

# C1: an || fallback inner is captured whole, not just its left branch.
got="$(node "$DRIVER" --fields 'X=$(a <PIPE><PIPE> b); echo "$X"' 2>&1)"
assert_eq "HIT-6 inner keeps both || branches (TP-17)" 'vars=X inner=a || b' "$got"

# C1 (round 13): what the trailing-content reject actually reports. The suffix is not
# part of innerCommandText, so the remedy cannot reproduce it.
got="$(node "$DRIVER" --fields 'X="$(cmd) literal"; echo "$X"' 2>&1)"
assert_eq "HIT-7 trailing text is dropped from inner (TC-3)" "vars=X inner=cmd" "$got"

# C3 (round 13): the second, side-effecting capture is absent from the remedy payload.
got="$(node "$DRIVER" --fields 'X=$(a); Y=$(mkdir -p /tmp/zz); echo "$X"' 2>&1)"
assert_eq "HIT-8 side-effecting second capture absent from inner (SE-1)" "vars=X,Y inner=a" "$got"

# C2 (round 13): the declaration keyword is peeled, so the payload matches the bare form.
got="$(node "$DRIVER" --fields 'declare X=$(cmd); echo "$X"' 2>&1)"
assert_eq "HIT-9 declaration keyword peeled from inner (DECL-1)" "vars=X inner=cmd" "$got"

# --- KNOWN GAPS pinned above (tests-only round; source untouched) -------------
# 1. TC-1..TC-3 / HIT-7  — a value whose substitution carries trailing text is still
#    rejected, and innerCommandText keeps only the substitution body.
# 2. DECL-5..DECL-8      — a declaration FLAG (`-r`, `--`) makes the whole run
#    unrecognised, so the guard can be evaded by spelling the assignment `declare -r`.
# 3. SE-1/SE-2 / HIT-8   — an unread capture that runs for its side effect is dropped
#    from the remedy payload, so the suggested reissue is not equivalent.
# Each row is pinned at CURRENT behavior on purpose: when the source is fixed, the
# named row fails loudly and is flipped, rather than the fix landing unobserved.

echo ""
echo "Section A: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
