# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, rules/test.md, rules/docs.md, rules/github-issues.md
# Tags: rules-injection, on-demand-rules, skill-ownership, mention-axis, allowlist, mutation-probe, TL2, scope:common
#
# The independent (tree-first) mention axis. Sourced from cases-required.sh, which
# crossed the 300-line WARN of rules/coding/file-split.md Pattern A.
# Assumes REQUIRED_TABLE, csv_sorted(), BASE, READER, AGENTS_DIR, POLICY, node_path(),
# pass(), fail() from cases-required.sh and the entry file.

# =====================================================================================
# R: the independent detection axis (mentions, discovered from the tree)
# =====================================================================================
# Why this exists: N1-N4 above are anchored on REQUIRED_TABLE, and REQUIRED_TABLE is
# hand-written. That makes the whole C1 block circular in one specific direction — it
# can prove the tree matches the table, but it cannot notice that the TABLE is the thing
# that went stale. A skill that starts depending on a de-injected rule and never gets a
# Read step is invisible to N1: it is not in the table, so it is not in `want`; and it
# has no Read step, so it is not in `got` either. Both sides agree, and the skill runs
# without the rule that used to arrive automatically.
#
# So this axis starts from the TREE instead of the table: walk skills/*/SKILL.md and
# agents/**/*.md, find every file that MENTIONS an on-demand rule at all, and require
# each mentioning SKILL.md to be accounted for — either registered in REQUIRED_TABLE
# (with a Read step actually present) or named in the allowlist below with a reason.
#
# The scanner is a second, deliberately separate implementation from the entry file's
# owners.js: its Read window is WIDER (3 lines rather than 2), which biases it toward
# "this file does read the rule". That asymmetry is on purpose — a shared implementation
# would make the two axes fail together, and a wider window keeps this axis quiet unless
# no Read verb appears anywhere near any mention, which is the real failure shape.
#
# agents/**/*.md are scanned and reported but never required: the round-2 ruling stands
# that an agent doc is a consumer, not an owner. They appear here so a future mention in
# an agent doc is visible in the report rather than silently dropped.

echo ""
echo "=== R: independent mention axis (tree-first, not table-first) ==="

# doc | reason — a mentioning SKILL.md that is deliberately NOT a required reader.
# Every entry needs a reason, and R5 below re-checks that each entry is still telling
# the truth, so a stale suppression cannot quietly outlive the situation it describes.
MENTION_ALLOWLIST='skills/sweep-branches/SKILL.md|confirmed false positive: the file carries zero issue or label operations of its own (grep for github-issues returns 0 hits); it can only ever be flagged by a substring-shaped match, never by a real dependency, so requiring a Read step there would pin a dependency that does not exist'

cat > "$BASE/mentions.js" <<'MENTIONS_EOF'
"use strict";
// argv: <reader-path> <root> <policy-path>
// Emits: MENTION|<rule>|<doc>|<yes|no read step near a mention>
//        MENTION_COUNT=<n>
const fs = require("fs");
const path = require("path");
const { loadPolicyAsData } = require(process.argv[2]);
const root = process.argv[3];
const policy = loadPolicyAsData(process.argv[4]);

function walk(dir, acc) {
  let ents = [];
  try { ents = fs.readdirSync(path.join(root, dir), { withFileTypes: true }); }
  catch (_) { return acc; }
  for (const e of ents) {
    const rel = dir + "/" + e.name;
    if (e.isDirectory()) walk(rel, acc);
    else if (e.name.endsWith(".md")) acc.push(rel);
  }
  return acc;
}

const docs = [];
walk("skills", docs);
walk("agents", docs);
// skills/**/SKILL.md and agents/**/*.md only. Reference docs under skills/ are excluded
// here because this axis asks "which executable step depends on the rule", and a
// reference doc is not a step (the entry file's OTHER_READ bucket already covers them).
const scanned = docs.filter((d) => /^skills\/.+\/SKILL\.md$/.test(d) || /^agents\/.+\.md$/.test(d));

const READ_RE = /\bRead\b/;
const ANTI_RE = /\b(?:do not|do NOT|don't|never|no need to)\s+(?:re-?)?read\b/i;
const WINDOW = 3;

const out = [];
let n = 0;
for (const rule of (policy.ON_DEMAND_FILES || [])) {
  for (const doc of scanned) {
    let text;
    try { text = fs.readFileSync(path.join(root, doc), "utf8"); } catch (_) { continue; }
    const lines = text.split(/\r?\n/);
    const hits = [];
    lines.forEach((l, i) => { if (l.includes(rule)) hits.push(i); });
    if (hits.length === 0) continue;
    let hasRead = false, hasAnti = false;
    for (const i of hits) {
      for (let j = Math.max(0, i - WINDOW); j <= Math.min(lines.length - 1, i + WINDOW); j++) {
        if (ANTI_RE.test(lines[j])) hasAnti = true;
        else if (READ_RE.test(lines[j])) hasRead = true;
      }
    }
    n += 1;
    out.push(["MENTION", rule, doc, (hasRead && !hasAnti) ? "yes" : "no"].join("|"));
  }
}
out.push("MENTION_COUNT=" + n);
console.log(out.join("\n"));
MENTIONS_EOF

# mention_scan <root> <policy-path> -> scanner stdout+stderr
mention_scan() {
    node "$(node_path "$BASE/mentions.js")" "$(node_path "$READER")" \
        "$(node_path "$1")" "$(node_path "$2")" 2>&1
}

# required_csv_for <rule> -> the REQUIRED_TABLE csv for that rule (empty when unlisted)
required_csv_for() {
    printf '%s\n' "$REQUIRED_TABLE" | grep "^$1|" | head -1 | cut -d'|' -f2-
}

# allowlist_reason <doc> -> the reason text, empty when the doc is not allowlisted
allowlist_reason() {
    printf '%s\n' "$MENTION_ALLOWLIST" | grep "^$1|" | head -1 | cut -d'|' -f2-
}

# mention_verdict <rule> <doc> <has-read> -> OK | UNREGISTERED | NO_READ | ALLOWED | SKIPPED
# Split out as a function so R4 can drive it with synthetic rows: an axis whose verdict
# logic is only ever exercised by a clean tree is an axis nobody has seen fail.
mention_verdict() {
    local rule="$1" doc="$2" hasread="$3"
    case "$doc" in skills/*/SKILL.md) ;; *) printf 'SKIPPED'; return ;; esac
    if [ -n "$(allowlist_reason "$doc")" ]; then printf 'ALLOWED'; return; fi
    if ! printf '%s' "$(required_csv_for "$rule")" | tr ',' '\n' | grep -qx "$doc"; then
        printf 'UNREGISTERED'; return
    fi
    if [ "$hasread" != "yes" ]; then printf 'NO_READ'; return; fi
    printf 'OK'
}

MENTION_REPORT="$(mention_scan "$AGENTS_DIR" "$POLICY")"
R_ROWS=0; R_SKILL_ROWS=0; R_BAD=0
while IFS='|' read -r tag m_rule m_doc m_read; do
    [ "$tag" = "MENTION" ] || continue
    R_ROWS=$((R_ROWS + 1))
    case "$m_doc" in skills/*/SKILL.md) R_SKILL_ROWS=$((R_SKILL_ROWS + 1)) ;; esac
    case "$(mention_verdict "$m_rule" "$m_doc" "$m_read")" in
        OK|ALLOWED|SKIPPED) ;;
        UNREGISTERED)
            R_BAD=$((R_BAD + 1))
            fail "R1 [$m_doc]: mentions $m_rule but is absent from REQUIRED_TABLE — either it depends on the rule (add a Read step AND a table row) or the mention is incidental (add it to MENTION_ALLOWLIST with a reason)" ;;
        NO_READ)
            R_BAD=$((R_BAD + 1))
            fail "R2 [$m_doc]: registered as a required reader of $m_rule, but no Read step appears near any mention — the rule is de-injected, so this skill now runs without it" ;;
    esac
done <<EOF
$MENTION_REPORT
EOF

# R3 guards R1/R2: with zero scanned mentions both loops above are vacuously clean.
# 15 is the count of required readers N2 enumerates; the real tree also has agent-doc
# mentions on top, so the floor is deliberately the table size and not the observed total.
if [ "$R_SKILL_ROWS" -ge 15 ]; then
    pass "R3: the mention scan found $R_ROWS mentioning doc(s), $R_SKILL_ROWS of them SKILL.md — R1/R2 are live"
else
    fail "R3: only $R_SKILL_ROWS mentioning SKILL.md found (want >= 15) — the scanner did not walk the tree, so R1/R2 proved nothing; report: $(printf '%s' "$MENTION_REPORT" | tr '\n' ' ' | cut -c1-300)"
fi
if [ "$R_BAD" = "0" ]; then
    pass "R1/R2: every SKILL.md mentioning a de-injected rule is registered and carries a Read step"
fi

# --- R4: the verdict logic must fire on the shapes it exists to catch. Driven with
# synthetic rows so it is exercised even while the real tree is clean. ---
R4_BAD=""
r4() {
    local label="$1" want="$2" got
    got="$(mention_verdict "$3" "$4" "$5")"
    [ "$got" = "$want" ] || R4_BAD="$R4_BAD [$label: want $want got $got]"
}
r4 unregistered-no-read  UNREGISTERED "rules/test.md" "skills/not-in-table/SKILL.md" "no"
r4 unregistered-with-read UNREGISTERED "rules/test.md" "skills/not-in-table/SKILL.md" "yes"
r4 registered-no-read    NO_READ      "rules/test.md" "skills/write-tests/SKILL.md"  "no"
r4 registered-with-read  OK           "rules/test.md" "skills/write-tests/SKILL.md"  "yes"
r4 wrong-rule-for-reader UNREGISTERED "rules/docs.md" "skills/write-tests/SKILL.md"  "yes"
r4 allowlisted-no-read   ALLOWED      "rules/github-issues.md" "skills/sweep-branches/SKILL.md" "no"
r4 agent-doc-not-required SKIPPED     "rules/test.md" "agents/test-reviewer.md"      "no"
if [ -z "$R4_BAD" ]; then
    pass "R4: the mention verdict distinguishes unregistered / missing-Read / registered / allowlisted / agent-doc (7 synthetic rows)"
else
    fail "R4: the verdict logic misclassified a synthetic row —$R4_BAD"
fi

# --- R5: the scanner itself must be able to tell a mention-with-Read from a
# mention-without-Read on a real tree. Without this, every R1/R2 row could be reading
# "no" for structural reasons and the axis would be noise. The two fixtures differ by
# exactly one sentence. ---
R5_BAD=""
r5() {
    local variant="$1" want="$2" rep got d
    d="$BASE/mention-$variant"
    mkdir -p "$d/hooks/lib" "$d/skills/owner" "$d/agents" "$d/rules"
    cat > "$d/hooks/lib/rules-injection-policy.js" <<'R5_POLICY'
"use strict";
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only\b/;
const ON_DEMAND_FILES = ["rules/owned.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
R5_POLICY
    printf '# the owned rule\n' > "$d/rules/owned.md"
    case "$variant" in
        with-read) printf '# Owner\n\n## Step 1\n\nRead `rules/owned.md` before continuing.\n' > "$d/skills/owner/SKILL.md" ;;
        no-read)   printf '# Owner\n\n## Step 1\n\nThe conventions in `rules/owned.md` apply here.\n' > "$d/skills/owner/SKILL.md" ;;
        anti)      printf '# Owner\n\n## Step 1\n\nDo NOT re-read `rules/owned.md`; it is already injected.\n' > "$d/skills/owner/SKILL.md" ;;
        silent)    printf '# Owner\n\n## Step 1\n\nDo the work.\n' > "$d/skills/owner/SKILL.md" ;;
    esac
    rep="$(mention_scan "$d" "$d/hooks/lib/rules-injection-policy.js")"
    got="$(printf '%s\n' "$rep" | grep '^MENTION|rules/owned.md|skills/owner/SKILL.md|' | head -1 | cut -d'|' -f4)"
    [ -z "$got" ] && got="NONE"
    [ "$got" = "$want" ] || R5_BAD="$R5_BAD [$variant: want $want got $got]"
}
r5 with-read yes
r5 no-read   no
r5 anti      no
r5 silent    NONE
if [ -z "$R5_BAD" ]; then
    pass "R5: the mention scanner separates Read / no-Read / anti-instruction / no-mention on synthetic trees"
else
    fail "R5: the mention scanner cannot tell those cases apart —$R5_BAD"
fi

# --- R6: every allowlist entry must still describe reality. An entry that has become
# inert (the file no longer mentions any on-demand rule) is reported as inert rather
# than left to look like an active suppression; an entry that has started carrying a
# real Read step must be promoted into REQUIRED_TABLE instead of staying suppressed. ---
R6_BAD=""; R6_INERT=""
while IFS='|' read -r al_doc al_reason; do
    [ -z "${al_doc// /}" ] && continue
    if [ -z "${al_reason// /}" ]; then
        R6_BAD="$R6_BAD [$al_doc: no reason recorded]"
        continue
    fi
    al_rows="$(printf '%s\n' "$MENTION_REPORT" | grep -c "^MENTION|[^|]*|$al_doc|" || true)"
    if [ "$al_rows" = "0" ]; then
        R6_INERT="$R6_INERT $al_doc"
    elif printf '%s\n' "$MENTION_REPORT" | grep -q "^MENTION|[^|]*|$al_doc|yes$"; then
        R6_BAD="$R6_BAD [$al_doc: now carries a Read step near its mention — promote it to REQUIRED_TABLE instead of suppressing it]"
    fi
done <<EOF
$MENTION_ALLOWLIST
EOF
if [ -n "$R6_BAD" ]; then
    fail "R6: the mention allowlist no longer describes reality —$R6_BAD"
else
    pass "R6: every allowlist entry carries a reason and none has silently become a real dependency (currently inert:${R6_INERT:- none})"
fi
