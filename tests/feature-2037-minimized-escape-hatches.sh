#!/usr/bin/env bash
# tests/feature-2037-minimized-escape-hatches.sh
# Tests: hooks/lib/rules-injection-policy.js, CLAUDE.md, rules/workflow-off.md, rules/stop-guard-exemptions.md, rules/supervisor-reporting.md, rules/worktree.md, skills/enforce-workflow-off/SKILL.md, skills/supervisor-report/SKILL.md
# Tags: rules-injection, minimized-unconditional, escape-hatch, progressive-disclosure, relocation, frontmatter, membership, pointer, TL2, scope:issue-specific
#
# WHY (CPR-WPH): #2037 splits the rules corpus into two classes with opposite treatments. Class A rules are de-injected and Read on demand by an owning skill. Escape hatches are the exception: a rule that tells you how to get UNSTUCK is worthless if reaching it requires the very machinery you are stuck in, so those stay unconditional and are instead MINIMIZED — trigger conditions only, with the procedure moved into a skill.
# That leaves two failure modes no other test covers. First, the classes can silently overlap: a rule listed as a minimized escape hatch AND wired as an on-demand reader row is being de-injected and kept unconditional at once, and whichever check runs last wins. Second, minimization is a MOVE, and a move loses content whenever the destination is never checked — the sentinel spellings and the reporting tables would simply cease to exist, with every remaining test still green because they only ever asserted the rule got smaller.
# So this file checks the two classes are disjoint, that each minimized rule still carries its trigger section and its pointer, and that the relocated material round-trips: gone from the rule AND present at the destination.
# Layer: TL2 (real repo tree, real policy file read as text through the real reader; no live Claude session).
# TL3 gap: whether a live session actually reaches the moved procedure — i.e. that the minimized rule's pointer causes the model to invoke the owning skill when the trigger fires, rather than acting on the trigger section alone. Mitigated at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$AGENTS_DIR/hooks/lib/rules-injection-policy.js"
READER="$AGENTS_DIR/hooks/lib/rules-policy-reader.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

MISSING=0
for f in "$POLICY" "$READER"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented)"
    exit 1
fi

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# Fixture isolation: this file spawns a plain node harness rather than a hook, so it pins
# neither half of the workflow-dir pair (pinning one alone is the contamination bug). It
# does drop the inherited session ids and run the harness from a neutral CWD.
unset CLAUDE_SESSION_ID || true
unset CLAUDE_CODE_SESSION_ID || true

# --- the declaration, read as TEXT. The policy file is contributor-editable data and is
# never require()d by its consumers; a test that evaluated it would be asserting on a
# different artifact than the one production reads. ---
cat > "$BASE/minimized.js" <<'MIN_EOF'
"use strict";
const fs = require("fs");
const R = require(process.argv[2]);
const src = fs.readFileSync(process.argv[3], "utf8");
const havePair = typeof R.readPairArrayConst === "function";
console.log("HAVE_PAIR=" + (havePair ? "yes" : "no"));
console.log("MIN_DECLARED=" + (/const\s+MINIMIZED_UNCONDITIONAL\s*=/.test(src) ? "yes" : "no"));
console.log("MAXBYTES=" + String(R.readStringConst(src, "MINIMIZED_MAX_BYTES")));
if (!havePair) process.exit(0);
const min = R.readPairArrayConst(src, "MINIMIZED_UNCONDITIONAL") || [];
const readers = R.readPairArrayConst(src, "ON_DEMAND_READERS") || [];
for (const row of min) {
    console.log("MIN|" + row.key + "|" + (row.values === null ? "MALFORMED" : row.values.join(",")));
}
for (const row of readers) console.log("ODKEY=" + row.key);
const uncond = R.readStringArrayConst(src, "EXPECTED_UNCONDITIONAL") || [];
for (const u of uncond) console.log("UNCOND=" + u);
MIN_EOF

REPORT="$( cd "$BASE" && node "$(node_path "$BASE/minimized.js")" "$(node_path "$READER")" "$(node_path "$POLICY")" 2>&1 )"
field() { printf '%s\n' "$REPORT" | grep "^$1=" | head -1 | cut -d= -f2-; }

echo "=== E1: the minimized class is declared and readable ==="

E_DECL="$(field MIN_DECLARED)"
if [ "$E_DECL" = "yes" ]; then
    pass "E1a: MINIMIZED_UNCONDITIONAL is declared in the policy"
else
    fail "E1a: MINIMIZED_UNCONDITIONAL is not declared — the escape-hatch class exists only in prose, so nothing can distinguish a deliberately-minimized rule from an untouched one; report: $(printf '%s' "$REPORT" | tr '\n' ' ' | cut -c1-300)"
fi

MIN_ROWS="$(printf '%s\n' "$REPORT" | grep -c '^MIN|' || true)"
if [ "${MIN_ROWS:-0}" -ge 1 ]; then
    pass "E1b: $MIN_ROWS minimized rule row(s) recovered — the per-rule cases below have subjects"
else
    fail "E1b: zero minimized rule rows recovered — E2/E3 would iterate nothing and pass vacuously; report: $(printf '%s' "$REPORT" | tr '\n' ' ' | cut -c1-300)"
fi

E_MB="$(field MAXBYTES)"
case "$E_MB" in
    ''|null|undefined|*[!0-9]*)
        fail "E1c: MINIMIZED_MAX_BYTES is not a numeric string literal (got '$E_MB') — the re-inflation ceiling cannot be applied" ;;
    *) pass "E1c: MINIMIZED_MAX_BYTES is the numeric string literal '$E_MB'" ;;
esac

echo ""
echo "=== E2: the two classes are mutually exclusive ==="

# A rule cannot be both de-injected (a reader row) and deliberately kept unconditional.
# Declaring both is not a contradiction the checker can resolve: it decides which of two
# opposite treatments applies to the same file, so the answer has to be one or the other.
E2_BAD=""
E2_N=0
while IFS='|' read -r _tag rule _ptr; do
    [ "$_tag" = "MIN" ] || continue
    E2_N=$((E2_N + 1))
    if printf '%s\n' "$REPORT" | grep -qx "ODKEY=$rule"; then
        E2_BAD="$E2_BAD $rule"
    fi
done <<EOF
$REPORT
EOF

if [ "$E2_N" -ge 1 ] && [ -z "$E2_BAD" ]; then
    pass "E2a: none of the $E2_N minimized rules also appears as an ON_DEMAND_READERS row"
elif [ "$E2_N" -lt 1 ]; then
    fail "E2a: no minimized rows to compare — the exclusivity check proved nothing (see E1b)"
else
    fail "E2a: rule(s) declared as BOTH a minimized escape hatch and an on-demand reader row —$E2_BAD; the file would be de-injected and kept unconditional at the same time"
fi

# The mirror property: minimized rules are a SUBSET of EXPECTED_UNCONDITIONAL, which is
# what "kept unconditional on purpose" means in the declaration.
E2_NOTUNCOND=""
while IFS='|' read -r _tag rule _ptr; do
    [ "$_tag" = "MIN" ] || continue
    printf '%s\n' "$REPORT" | grep -qx "UNCOND=$rule" || E2_NOTUNCOND="$E2_NOTUNCOND $rule"
done <<EOF
$REPORT
EOF

if [ "$E2_N" -ge 1 ] && [ -z "$E2_NOTUNCOND" ]; then
    pass "E2b: every minimized rule is also listed in EXPECTED_UNCONDITIONAL (the class is a subset, not a third state)"
else
    fail "E2b: minimized rule(s) absent from EXPECTED_UNCONDITIONAL —${E2_NOTUNCOND:- (no rows)}; a rule nobody injects is not an escape hatch"
fi

echo ""
echo "=== E3: each minimized rule keeps a trigger section and its pointer ==="

# What survives minimization is exactly the part a reader needs BEFORE deciding to act:
# when this applies, and where the procedure lives. A rule that lost the trigger cannot be
# recognized as relevant; one that lost the pointer is a dead end.
while IFS='|' read -r _tag rule ptr; do
    [ "$_tag" = "MIN" ] || continue
    abs="$AGENTS_DIR/$rule"
    if [ ! -f "$abs" ]; then
        fail "E3 [$rule]: declared minimized but the file does not exist"
        continue
    fi
    if grep -qiE '^##+ .*(when to use|when to report|when to)' "$abs"; then
        pass "E3-trigger [$rule]: keeps a trigger section saying when the hatch applies"
    else
        fail "E3-trigger [$rule]: no 'When to ...' section remains — the rule is injected into every session but no longer says when it is relevant"
    fi

    # A heading is not guidance. Minimization is done with a byte budget in hand, and the
    # cheapest way to satisfy a heading check is to keep the heading and cut the sentences
    # under it — which passes E3-trigger while leaving a session that has to decide whether
    # the hatch applies with nothing to decide from. So the SECTION is read: it must carry
    # actual body text, and at least one line stating a CONDITION rather than a fact.
    sect="$(awk 'tolower($0) ~ /^##+ .*when to/ {f=1; next} f && /^##+ /{exit} f{print}' "$abs")"
    body_lines="$(printf '%s\n' "$sect" | grep -cE '[^[:space:]]')"
    if [ "${body_lines:-0}" -lt 2 ]; then
        fail "E3-substance [$rule]: the trigger section has $body_lines non-blank line(s) — the heading survived minimization but the guidance under it did not"
    elif printf '%s\n' "$sect" | grep -qiE '^[[:space:]]*[-*|] |when |if |only |last resort|appropriate for|場合|とき|のみ'; then
        pass "E3-substance [$rule]: the trigger section states conditions, not just a heading ($body_lines lines)"
    else
        fail "E3-substance [$rule]: the trigger section has text but names no condition (no list item, no when/if/only/last-resort phrasing) — a reader cannot tell from it whether this session is one of the cases"
    fi

    if [ "$ptr" = "MALFORMED" ]; then
        fail "E3-pointer [$rule]: the MINIMIZED_UNCONDITIONAL row carries no '|' separator, so no pointer was declared"
        continue
    fi
    slash=""
    case "$ptr" in
        skills/*/SKILL.md) slash="/$(printf '%s' "$ptr" | cut -d/ -f2)" ;;
    esac
    if grep -qF "$ptr" "$abs" || { [ -n "$slash" ] && grep -qF "$slash" "$abs"; }; then
        pass "E3-pointer [$rule]: body names its pointer ($ptr${slash:+ or $slash})"
    else
        fail "E3-pointer [$rule]: body names neither '$ptr'${slash:+ nor '$slash'} — the moved procedure is unreachable from the rule"
    fi

    if [ -e "$AGENTS_DIR/$ptr" ]; then
        pass "E3-target [$rule]: the pointer target $ptr exists"
    else
        fail "E3-target [$rule]: the pointer target $ptr does not exist in the tree"
    fi
done <<EOF
$REPORT
EOF

echo ""
echo "=== E4: relocation round-trip — content moved, not deleted ==="

# has_at <label> <file> <fixed-string> <present|absent>
has_at() {
    local label="$1" f="$2" needle="$3" want="$4"
    if [ ! -f "$AGENTS_DIR/$f" ]; then
        fail "$label: $f does not exist"
        return
    fi
    if grep -qF "$needle" "$AGENTS_DIR/$f"; then
        if [ "$want" = "present" ]; then pass "$label: '$needle' is present in $f"
        else fail "$label: '$needle' is STILL in $f — the move left a copy behind, so the fact now has two owners (CPR-SSOT)"; fi
    else
        if [ "$want" = "absent" ]; then pass "$label: '$needle' is gone from $f"
        else fail "$label: '$needle' is missing from $f — minimization dropped it instead of moving it"; fi
    fi
}

EWO="skills/enforce-workflow-off/SKILL.md"
SRS="skills/supervisor-report/SKILL.md"

has_at "E4a" "$EWO" "WORKFLOW_ENFORCE_WORKFLOW_OFF" present
has_at "E4b" "$EWO" "WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY" present
has_at "E4c" "$EWO" "WORKFLOW_ENFORCE_WORKFLOW_ON" present

# The WORKTREE_OFF hatch is absorbed into the same skill: gone from rules/worktree.md,
# alive at the destination. Checked in both directions on purpose — either half alone is
# satisfied by a plain deletion.
has_at "E4d" "rules/worktree.md" "WORKFLOW_ENFORCE_WORKTREE_OFF" absent
has_at "E4e" "$EWO" "WORKFLOW_ENFORCE_WORKTREE_OFF" present
has_at "E4f" "$EWO" "WORKFLOW_ENFORCE_WORKTREE_ON" present

# The supervisor reporting tables are the whole payload of that rule; if the move dropped
# them, a reporter has categories and severities to choose from and no list to choose off.
has_at "E4g" "$SRS" "Categories" present
has_at "E4h" "$SRS" "Severity" present
has_at "E4i" "$SRS" "bin/supervisor-report" present

echo ""
echo "=== E5: the new skills declare user-invocable explicitly ==="

# Relying on the default is the failure this checks: whether a human may invoke a skill by
# name is a decision, and an absent key records no decision at all — it silently inherits
# whatever the default happens to be the next time it changes.

# Each skill is pinned to the ONE value its role implies, not to "either value, stated".
# `enforce-workflow-off` is the last-resort hatch a human reaches for by name, and its own
# body says explicit user invocation IS the human decision — so `false` there would remove
# the only way to reach it. `supervisor-report` is the mirror case: CC calls it on its own
# observation, no human ever types it, and `true` would put a slash command in front of
# users for something they have no reason to run.
E5_EXPECT="$EWO:true $SRS:false"
for row in $E5_EXPECT; do
    s="${row%:*}"; want="${row##*:}"
    abs="$AGENTS_DIR/$s"
    if [ ! -f "$abs" ]; then
        fail "E5 [$s]: file does not exist"
        continue
    fi
    fm="$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 {print}' "$abs")"
    got="$(printf '%s\n' "$fm" | grep -E '^user-invocable:' | head -1 | sed -E 's/^user-invocable:[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "$got" ]; then
        fail "E5 [$s]: frontmatter has no explicit 'user-invocable:' key — the invocation decision is left to the default"
    elif [ "$got" = "$want" ]; then
        pass "E5 [$s]: user-invocable is explicitly $want"
    else
        fail "E5 [$s]: user-invocable is '$got', want '$want' — the key is present but records the opposite decision, which is worse than absent: it reads as deliberate"
    fi
done

echo ""
echo "=== E6: the settled target state of #2037, as concrete membership ==="

# WHY this is not redundant with E1-E3: every case above asserts INTERNAL CONSISTENCY —
# whatever the declaration says, the tree agrees with it. That is exactly the property a
# half-finished change also has. Delete four of the five reader rows and E1-E3 stay green,
# because the tree and the declaration shrink together. So this block states the intended
# END STATE as literal names, once, and is the only thing here that goes red when the
# change lands partially. It is the counterpart of #1651's undocumented 14-rule residue:
# that stall was invisible precisely because nothing ever wrote down where it should stop.
E6_EXPECT_ONDEMAND="rules/branch.md rules/coding.md rules/docs.md rules/github-issues.md rules/mid-workflow-findings.md rules/ops.md rules/test.md rules/worktree.md"
E6_EXPECT_MINIMIZED="rules/stop-guard-exemptions.md rules/supervisor-reporting.md rules/workflow-off.md"
E6_EXPECT_DELETED="rules/docs-only-short-circuit.md rules/issue-close-verified.md"
E6_EXPECT_MAXBYTES="1500"

e6_sorted() { printf '%s\n' "$@" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//'; }

E6_GOT_OD="$(printf '%s\n' "$REPORT" | grep '^ODKEY=' | cut -d= -f2- | sort | tr '\n' ' ' | sed 's/ $//')"
E6_WANT_OD="$(e6_sorted "$E6_EXPECT_ONDEMAND")"
if [ "$E6_GOT_OD" = "$E6_WANT_OD" ]; then
    pass "E6a: ON_DEMAND_READERS declares exactly the 8 intended rules"
else
    fail "E6a: the on-demand set is not the intended one — want [$E6_WANT_OD], got [$E6_GOT_OD]; #2037 adds five rules to #1651's three, and a set that merely agrees with the tree can still be a change that stopped halfway"
fi

E6_GOT_MIN="$(printf '%s\n' "$REPORT" | grep '^MIN|' | cut -d'|' -f2 | sort | tr '\n' ' ' | sed 's/ $//')"
E6_WANT_MIN="$(e6_sorted "$E6_EXPECT_MINIMIZED")"
if [ "$E6_GOT_MIN" = "$E6_WANT_MIN" ]; then
    pass "E6b: MINIMIZED_UNCONDITIONAL declares exactly the 3 intended escape hatches"
else
    fail "E6b: the minimized set is not the intended one — want [$E6_WANT_MIN], got [$E6_GOT_MIN]; an escape hatch missing from this list is one nobody promised to keep small, and re-inflation is unpoliced there"
fi

for gone in $E6_EXPECT_DELETED; do
    if [ -e "$AGENTS_DIR/$gone" ]; then
        fail "E6c [$gone]: still present — its content was supposed to move into a skill, and while the file exists the rule and the skill are two owners of one procedure (CPR-SSOT)"
    else
        pass "E6c [$gone]: deleted"
    fi
    if printf '%s\n' "$REPORT" | grep -qx "UNCOND=$gone" || printf '%s\n' "$REPORT" | grep -qx "ODKEY=$gone"; then
        fail "E6d [$gone]: a deleted rule is still named in the policy declaration — the checker will look for a file that does not exist"
    else
        pass "E6d [$gone]: absent from both policy declarations"
    fi
done

if [ "$E_MB" = "$E6_EXPECT_MAXBYTES" ]; then
    pass "E6e: MINIMIZED_MAX_BYTES is the agreed ceiling ($E6_EXPECT_MAXBYTES)"
else
    fail "E6e: MINIMIZED_MAX_BYTES is '$E_MB', not the agreed '$E6_EXPECT_MAXBYTES' — E1c only asks that it be numeric, so raising the ceiling instead of shrinking a rule would pass every other case here"
fi

echo ""
echo "=== E7: the real CLAUDE.md still routes the reader to every de-injected rule ==="

# A de-injected rule is only reachable because CLAUDE.md names it. The static checker
# raises MISSING_ONDEMAND_POINTER for that, but it SKIPS the whole check when CLAUDE.md is
# absent (an arbitrary checked root need not have one), so on this repo — where the file
# does exist and is the actual entry point — the property deserves a direct assertion.
# The expected list is the declaration's key column, not a copy: adding a reader row and
# forgetting the pointer must turn this red without anyone editing this file.
E7_CLAUDE="$AGENTS_DIR/CLAUDE.md"
if [ ! -f "$E7_CLAUDE" ]; then
    fail "E7: CLAUDE.md does not exist in the repo root — nothing points at any de-injected rule"
else
    E7_MISSING=""
    E7_N=0
    for rule in $(printf '%s\n' "$REPORT" | grep '^ODKEY=' | cut -d= -f2-); do
        E7_N=$((E7_N + 1))
        grep -qF "$rule" "$E7_CLAUDE" || E7_MISSING="$E7_MISSING $rule"
    done
    if [ "$E7_N" -lt 1 ]; then
        fail "E7a: no on-demand rules to check — the pointer assertion proved nothing (see E6a)"
    elif [ -z "$E7_MISSING" ]; then
        pass "E7a: CLAUDE.md names all $E7_N de-injected rule(s)"
    else
        fail "E7a: CLAUDE.md names no pointer for —$E7_MISSING; those rules are now injected nowhere and mentioned nowhere, so a session simply never learns they exist"
    fi

    E7_STALE=""
    for gone in $E6_EXPECT_DELETED; do
        grep -qF "$gone" "$E7_CLAUDE" && E7_STALE="$E7_STALE $gone"
    done
    if [ -z "$E7_STALE" ]; then
        pass "E7b: CLAUDE.md carries no pointer to either deleted rule"
    else
        fail "E7b: CLAUDE.md still points at deleted rule(s) —$E7_STALE; the pointer survives the file, so the instruction sends a session to Read something that is not there"
    fi
fi

echo ""
echo "=== E8: the relocated WORKFLOW_OFF procedure is a procedure, not a word list ==="

# E4a-E4f prove the three sentinel spellings survived the move. That is satisfied by a
# glossary — a page that lists the tokens and never says to run them in an order. The
# hazard the move introduces is specific and asymmetric: the OFF sentinel suspends
# enforcement session-wide and the ON sentinel is the only thing that restores it, so a
# destination that documents OFF before ON, or documents OFF without insisting on ON,
# leaves a reader with a working way to disable the guards and no stated way back.
EWO_ABS="$AGENTS_DIR/$EWO"
if [ ! -f "$EWO_ABS" ]; then
    fail "E8: $EWO does not exist"
else
    E8_OFF_LINE="$(grep -n 'WORKFLOW_ENFORCE_WORKFLOW_OFF' "$EWO_ABS" | head -1 | cut -d: -f1)"
    E8_ON_LINE="$(grep -n 'WORKFLOW_ENFORCE_WORKFLOW_ON' "$EWO_ABS" | head -1 | cut -d: -f1)"
    if [ -n "$E8_OFF_LINE" ] && [ -n "$E8_ON_LINE" ] && [ "$E8_OFF_LINE" -lt "$E8_ON_LINE" ]; then
        pass "E8a: the OFF sentinel is documented before the ON sentinel (L$E8_OFF_LINE < L$E8_ON_LINE)"
    else
        fail "E8a: the sentinels are not documented in suspend-then-restore order (OFF=L${E8_OFF_LINE:-<none>} ON=L${E8_ON_LINE:-<none>}) — following the page top to bottom restores enforcement that was never suspended, then suspends it and stops"
    fi

    # The restore step has to be stated as obligatory, in prose. Syntax alone cannot
    # carry "do this even when the work you suspended enforcement for failed".
    if grep -qiE '^[^#]*\b(always|must|even if|even when|regardless|unconditional|without fail|必ず)\b.*(WORKFLOW_ENFORCE_WORKFLOW_ON|restore|re-?enable|復旧|戻)' "$EWO_ABS"; then
        pass "E8b: the skill states the restore step is obligatory, not optional"
    else
        fail "E8b: no obligatory-restore sentence found — a session that suspends enforcement and then hits an error has nothing telling it to emit the ON sentinel anyway, and the marker is session-scoped, so enforcement stays off for the rest of the session"
    fi

    # And it has to say what the hatch is FOR. rules/workflow-off.md kept only the
    # trigger; if the destination also dropped the last-resort framing, the combined
    # documentation now reads as an ordinary tool with a convenient off switch.
    if grep -qiE 'last resort|最後の手段|only when|do not use|use only' "$EWO_ABS"; then
        pass "E8c: the skill still frames the hatch as a last resort with a stated boundary"
    else
        fail "E8c: no last-resort / do-not-use-for framing survived the move — the minimized rule points here for the 'when', so if the boundary is not stated here it is stated nowhere"
    fi
fi

echo ""
echo "=== E9: the WORKTREE_OFF hatch is still reachable from what a session always sees ==="

# The asymmetry E4d/E4e create: WORKTREE_OFF's procedure leaves rules/worktree.md, and
# rules/worktree.md itself becomes on-demand — so after this change NOTHING unconditional
# mentions WORKTREE_OFF unless rules/workflow-off.md says so. That matters precisely in the
# situation the hatch exists for: a session blocked by enforce-worktree, which is the state
# in which it is least able to go Read an on-demand rule to discover its own way out.
# So the surviving unconditional rule must (a) name the trigger and (b) route somewhere.
E9_WFO="$AGENTS_DIR/rules/workflow-off.md"
if [ ! -f "$E9_WFO" ]; then
    fail "E9: rules/workflow-off.md does not exist — the minimized class has no unconditional member left to carry the trigger"
else
    if grep -qE 'WORKTREE_OFF' "$E9_WFO"; then
        pass "E9a: the unconditional rules/workflow-off.md still names WORKTREE_OFF"
    else
        fail "E9a: rules/workflow-off.md never mentions WORKTREE_OFF, and rules/worktree.md is on-demand — a session blocked by enforce-worktree sees no unconditional text saying the hatch exists"
    fi

    # Naming it is not enough: the reader has to be told the relationship, or the mention
    # reads as a second, separate hatch whose procedure is missing from the page.
    if grep -qiE 'WORKTREE_OFF.*(subsum|包含|includ|cover|同時に|redundant)|(subsum|包含|includ|cover|同時に|redundant).*WORKTREE_OFF' "$E9_WFO"; then
        pass "E9b: the rule states the relationship (WORKFLOW_OFF subsumes WORKTREE_OFF), so one sentinel is enough"
    else
        fail "E9b: WORKTREE_OFF is named but the subsumption is not stated — a blocked session cannot tell whether emitting WORKFLOW_OFF is sufficient or whether it is missing a second step it has no procedure for"
    fi

    # And the trigger has to lead to where the procedure ACTUALLY went. E4e puts the
    # WORKTREE_OFF sentinels in the enforce-workflow-off skill and E4d takes them out of
    # rules/worktree.md, so a rule that still routed the reader to rules/worktree.md would
    # send them to the one page guaranteed no longer to hold it.
    if grep -qE '/enforce-workflow-off|skills/enforce-workflow-off/SKILL\.md' "$E9_WFO"; then
        pass "E9c: the rule routes to the enforce-workflow-off skill, where the sentinels now live"
    else
        fail "E9c: the rule names no route to $EWO — the trigger is stated unconditionally but the procedure it triggers is unreachable from it"
    fi
    if grep -qE 'rules/worktree\.md' "$E9_WFO"; then
        fail "E9d: rules/workflow-off.md still routes WORKTREE_OFF detail to rules/worktree.md, which E4d empties of the sentinels — the pointer outlived what it pointed at"
    else
        pass "E9d: no stale route to rules/worktree.md survives"
    fi
fi

# --- E10: the OFF/ON commands driven through the real handler. Split into a sibling file
# because this one crossed the 300-line WARN (rules/coding/file-split.md Pattern A); the
# axis is document-vs-behaviour, and it is sourced from here so EWO_ABS and the helpers
# above stay in scope. ---
E10_CASES="$AGENTS_DIR/tests/feature-2037-minimized-escape-hatches/marker-sequence.sh"
if [ -f "$E10_CASES" ]; then
    # shellcheck source=/dev/null
    . "$E10_CASES"
else
    fail "E10: case file missing: tests/feature-2037-minimized-escape-hatches/marker-sequence.sh"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
