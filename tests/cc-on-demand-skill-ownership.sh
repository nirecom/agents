#!/usr/bin/env bash
# tests/cc-on-demand-skill-ownership.sh
# Tests: hooks/lib/rules-injection-policy.js, rules/test.md, rules/docs.md, rules/github-issues.md
# Tags: rules-injection, on-demand-rules, skill-ownership, mapping, real-tree, mutation-probe, TL2, scope:common
#
# The primary wiring of the on-demand mechanism is NOT the frontmatter token — it is
# the promise that some skill Reads the rule explicitly instead. A rule that is
# de-injected and then owned by nobody is silently gone from the agent's reach, and
# every notation-level check (bin/check-on-demand-rules.sh) still passes.
# This file asserts the mapping itself over the REAL tree, and pins the detector with
# synthetic mutation probes so the real-tree pass cannot be vacuous.
# Layer: TL2 (walks the real skills/ and agents/ trees; fixtures only for the probes).
#
# TL3 gap (what this test does NOT catch):
# - Whether the owning skill's Read step actually executes in a live session, and
#   whether the model honours it once the rule stops being auto-injected.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$AGENTS_DIR/hooks/lib/rules-injection-policy.js"
# The reader is agents-owned code, not contributor-editable declaration data, so the
# reporter require()s IT and hands it the policy PATH. See cases-require-safety.sh.
READER="$AGENTS_DIR/hooks/lib/rules-policy-reader.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

for f in "$POLICY" "$READER"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: IMPLEMENTATION MISSING: $f"
        echo ""
        echo "Results: 0 passed, 1 failed (target not yet implemented — detail plan S2-1 / S3-D)"
        exit 1
    fi
done

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# --- the reporter: for each ON_DEMAND_FILES entry, who owns it and how ---
cat > "$BASE/owners.js" <<'OWNERS_EOF'
"use strict";
const fs = require("fs");
const path = require("path");

const root = process.argv[2];
const POLICY_PATH = process.argv[3];
const READER_PATH = process.argv[4];

// The policy file is contributor-editable declaration DATA. require()-ing it would run
// whatever a pull request put in its module body, with the reviewer's privileges, on
// nothing more than a checkout + test run. So it is PARSED, never executed — the same
// contract bin/lib/check-on-demand-rules.js states and P11 in
// tests/bin-check-on-demand-rules/cases-policy.sh pins on the checker side.
const { loadPolicyAsData } = require(READER_PATH);
const policy = loadPolicyAsData(POLICY_PATH);

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

const READ_RE = /\bRead\b/;
const ANTI_RE = /\b(?:do not|do NOT|don't|never|no need to)\s+(?:re-?)?read\b/i;
const WINDOW = 2;

// Only a SKILL.md can OWN a rule. An agent doc is a consumer: it is loaded when some
// skill delegates to it, so a rule referenced only from agents/ is reachable on that
// one delegation path and nowhere else. The on-demand promise is that the skill which
// needs the rule Reads it, so the two are counted separately and never conflated.
const isSkillMd = (rel) => /^skills\/.+\/SKILL\.md$/.test(rel);

const out = [];
out.push("OD_COUNT=" + (Array.isArray(policy.ON_DEMAND_FILES) ? policy.ON_DEMAND_FILES.length : -1));
out.push("EU_COUNT=" + (Array.isArray(policy.EXPECTED_UNCONDITIONAL) ? policy.EXPECTED_UNCONDITIONAL.length : -1));
for (const rule of (policy.ON_DEMAND_FILES || [])) {
  let owners = 0, readOwners = 0, skillRead = 0, agentRead = 0, otherRead = 0, anti = 0;
  const readBy = [];
  const skillBy = [];
  for (const doc of docs) {
    let text;
    try { text = fs.readFileSync(path.join(root, doc), "utf8"); } catch (_) { continue; }
    const lines = text.split(/\r?\n/);
    const hits = [];
    lines.forEach((l, i) => { if (l.includes(rule)) hits.push(i); });
    if (hits.length === 0) continue;
    owners += 1;
    let hasRead = false, hasAnti = false;
    for (const i of hits) {
      for (let j = Math.max(0, i - WINDOW); j <= Math.min(lines.length - 1, i + WINDOW); j++) {
        if (ANTI_RE.test(lines[j])) hasAnti = true;
        else if (READ_RE.test(lines[j])) hasRead = true;
      }
    }
    if (hasAnti) anti += 1;
    if (hasRead && !hasAnti) {
      readOwners += 1;
      readBy.push(doc);
      if (isSkillMd(doc)) { skillRead += 1; skillBy.push(doc); }
      else if (doc.startsWith("agents/")) agentRead += 1;
      else otherRead += 1;
    }
  }
  out.push([
    "RULE=" + rule,
    "OWNERS=" + owners,
    "READ_OWNERS=" + readOwners,
    "SKILL_READ=" + skillRead,
    "AGENT_READ=" + agentRead,
    "OTHER_READ=" + otherRead,
    "ANTI=" + anti,
    "SKILL_BY=" + (skillBy.join(",") || "-"),
    "READ_BY=" + (readBy.join(",") || "-"),
  ].join(" "));
}
console.log(out.join("\n"));
OWNERS_EOF

# run_owners <root> <policy-path> -> the reporter's stdout+stderr
run_owners() {
    node "$(node_path "$BASE/owners.js")" "$(node_path "$1")" "$(node_path "$2")" \
        "$(node_path "$READER")" 2>&1
}

REPORT="$(run_owners "$AGENTS_DIR" "$POLICY")"
OD_COUNT="$(printf '%s\n' "$REPORT" | grep '^OD_COUNT=' | head -1 | cut -d= -f2)"

# --- M0: the allowlist must not be empty. An empty ON_DEMAND_FILES makes every
# per-rule assertion below vacuously true, which is exactly the false-green this
# file exists to prevent. The session's end state (detail plan S3-D) is 3 entries. ---
if [ "${OD_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    pass "M0: ON_DEMAND_FILES is non-empty ($OD_COUNT entries) so the mapping assertions are live"
else
    fail "M0: ON_DEMAND_FILES has $OD_COUNT entries — the ownership assertions below would be vacuous (detail plan S3-D expects 3)"
fi

# --- M1 (C4): every on-demand rule must be owned by a SKILL.md with an explicit Read
# step. An agent doc reading the rule is NOT ownership: agent docs load only when some
# skill delegates to that agent, so a rule owned only from agents/ is unreachable on
# every other path — which is precisely the silent-loss failure this file exists to
# catch. The agent count is reported so the diagnostic can say "referenced, but from
# the wrong kind of document" instead of a bare "unowned". ---
printf '%s\n' "$REPORT" | grep '^RULE=' | while IFS= read -r line; do
    rule="$(printf '%s' "$line" | tr ' ' '\n' | grep '^RULE=' | cut -d= -f2-)"
    owners="$(printf '%s' "$line" | tr ' ' '\n' | grep '^OWNERS=' | cut -d= -f2-)"
    skillread="$(printf '%s' "$line" | tr ' ' '\n' | grep '^SKILL_READ=' | cut -d= -f2-)"
    agentread="$(printf '%s' "$line" | tr ' ' '\n' | grep '^AGENT_READ=' | cut -d= -f2-)"
    otherread="$(printf '%s' "$line" | tr ' ' '\n' | grep '^OTHER_READ=' | cut -d= -f2-)"
    anti="$(printf '%s' "$line" | tr ' ' '\n' | grep '^ANTI=' | cut -d= -f2-)"
    skillby="$(printf '%s' "$line" | tr ' ' '\n' | grep '^SKILL_BY=' | cut -d= -f2-)"
    if [ "$owners" = "0" ]; then
        echo "FAIL: M1 [$rule]: no skill or agent doc references it at all — de-injected and unowned"
    elif [ "$skillread" = "0" ] && [ "$agentread" != "0" ]; then
        echo "FAIL: M1 [$rule]: read only from $agentread agent doc(s) and no SKILL.md — reachable only when that agent is delegated to"
    elif [ "$skillread" = "0" ] && [ "$otherread" != "0" ]; then
        echo "FAIL: M1 [$rule]: read only from $otherread non-SKILL.md file(s) under skills/ — a reference doc is not an executed step"
    elif [ "$skillread" = "0" ]; then
        echo "FAIL: M1 [$rule]: referenced by $owners doc(s) but no SKILL.md carries an explicit Read step"
    elif [ "$anti" != "0" ]; then
        echo "FAIL: M1 [$rule]: $anti owner(s) instruct NOT to read it — the on-demand promise is contradicted"
    else
        echo "PASS: M1 [$rule]: owned by $skillread SKILL.md with an explicit Read step ($skillby)"
    fi
done > "$BASE/m1.txt"
M1_PASS="$(grep -c '^PASS:' "$BASE/m1.txt" || true)"
M1_FAIL="$(grep -c '^FAIL:' "$BASE/m1.txt" || true)"
cat "$BASE/m1.txt"
PASS=$((PASS + M1_PASS)); FAIL=$((FAIL + M1_FAIL))

# --- mutation probes: prove the detector above can actually fail ------------------
# A synthetic tree per probe, each differing from the mapped-ok baseline by exactly
# one edit. Without these, M1 passing over the real tree proves nothing about the
# detector, only about the tree.
probe() {
    local label="$1" variant="$2"
    local field="$3" want="$4"
    local d="$BASE/probe-$variant"
    mkdir -p "$d/hooks/lib" "$d/skills/owner" "$d/agents" "$d/rules"
    # Written in the one-line `const NAME = <literal>;` shape the policy file is
    # required to keep (hooks/lib/rules-injection-policy.js header) — that shape is
    # the whole reason the file can be read as data instead of require()d.
    cat > "$d/hooks/lib/rules-injection-policy.js" <<'PROBE_POLICY'
"use strict";
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only\b/;
const ON_DEMAND_FILES = ["rules/owned.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
PROBE_POLICY
    printf '# the owned rule\n' > "$d/rules/owned.md"
    case "$variant" in
        mapped-ok)
            printf '# Owner skill\n\n## Step 1\n\nRead `rules/owned.md` before continuing.\n' > "$d/skills/owner/SKILL.md" ;;
        no-owner)
            printf '# Owner skill\n\n## Step 1\n\nDo the work.\n' > "$d/skills/owner/SKILL.md" ;;
        mentioned-no-read)
            printf '# Owner skill\n\n## Step 1\n\nThe conventions in `rules/owned.md` apply here.\n' > "$d/skills/owner/SKILL.md" ;;
        anti-instruction)
            printf '# Owner skill\n\n## Step 1\n\nDo NOT re-read `rules/owned.md`; it is already injected.\n' > "$d/skills/owner/SKILL.md" ;;
        agent-owner)
            printf '# Owner skill\n\n## Step 1\n\nDo the work.\n' > "$d/skills/owner/SKILL.md"
            printf '# Reviewer agent\n\nRead `rules/owned.md` first.\n' > "$d/agents/reviewer.md" ;;
        skill-and-agent)
            printf '# Owner skill\n\n## Step 1\n\nRead `rules/owned.md` before continuing.\n' > "$d/skills/owner/SKILL.md"
            printf '# Reviewer agent\n\nRead `rules/owned.md` first.\n' > "$d/agents/reviewer.md" ;;
        skills-reference-doc)
            # a reference doc under skills/ is not an executed step; only SKILL.md is
            printf '# Owner skill\n\n## Step 1\n\nDo the work.\n' > "$d/skills/owner/SKILL.md"
            printf '# Reference\n\nRead `rules/owned.md` for background.\n' > "$d/skills/owner/reference.md" ;;
        far-read)
            # a Read verb far away from the reference must NOT count as ownership
            printf '# Owner skill\n\nRead the plan artifact.\n\n\n\n\n\nThe file `rules/owned.md` exists.\n' > "$d/skills/owner/SKILL.md" ;;
    esac
    local rep got
    rep="$(run_owners "$d" "$d/hooks/lib/rules-injection-policy.js")"
    got="$(printf '%s\n' "$rep" | grep '^RULE=' | tr ' ' '\n' | grep "^$field=" | cut -d= -f2-)"
    if [ "$got" = "$want" ]; then
        pass "$label ($field=$got)"
    else
        fail "$label: want $field=$want, got '$got' — reporter said: $(printf '%s' "$rep" | tr '\n' ' ')"
    fi
}

echo ""
echo "=== mutation probes (the detector must be able to fail) ==="
probe "M2: a SKILL.md with an explicit Read step owns the rule"          mapped-ok         SKILL_READ 1
probe "M3: removing the only reference leaves the rule unowned"          no-owner          SKILL_READ 0
probe "M4: a mention without a Read step does not count as ownership"    mentioned-no-read SKILL_READ 0
probe "M5: a 'do NOT re-read' instruction cancels ownership"             anti-instruction  SKILL_READ 0
probe "M6: an agent-only Read does NOT satisfy SKILL.md ownership"       agent-owner       SKILL_READ 0
probe "M6b: that agent reference is still visible as an agent read"      agent-owner       AGENT_READ 1
probe "M7: a Read verb far from the reference does not count"            far-read          SKILL_READ 0
probe "M8: a non-SKILL.md doc under skills/ is not an owner"             skills-reference-doc SKILL_READ 0
probe "M8b: that reference doc is counted separately, not as ownership"  skills-reference-doc OTHER_READ 1
probe "M9: a skill owner is unaffected by an additional agent reference" skill-and-agent   SKILL_READ 1

# --- M10: the classification must be exclusive. READ_OWNERS is the sum of the three
# buckets, so a doc can never be counted as both a skill owner and something else —
# without this, widening isSkillMd() to match agents/ would go unnoticed. ---
M10_REP="$(run_owners "$BASE/probe-skill-and-agent" \
    "$BASE/probe-skill-and-agent/hooks/lib/rules-injection-policy.js")"
m10_line="$(printf '%s\n' "$M10_REP" | grep '^RULE=' | head -1)"
m10f() { printf '%s' "$m10_line" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2-; }
M10_SUM=$(( $(m10f SKILL_READ) + $(m10f AGENT_READ) + $(m10f OTHER_READ) ))
if [ "$M10_SUM" = "$(m10f READ_OWNERS)" ] && [ "$(m10f READ_OWNERS)" = "2" ]; then
    pass "M10: skill / agent / other buckets partition READ_OWNERS exactly (2 = 1+1+0)"
else
    fail "M10: buckets do not partition READ_OWNERS — sum=$M10_SUM READ_OWNERS=$(m10f READ_OWNERS); line: $m10_line"
fi

# --- A: require-safety for the reporter itself (sibling folder, file-split Pattern A) ---
RS_CASES="$AGENTS_DIR/tests/cc-on-demand-skill-ownership/cases-require-safety.sh"
if [ -f "$RS_CASES" ]; then
    # shellcheck source=./cc-on-demand-skill-ownership/cases-require-safety.sh
    . "$RS_CASES"
else
    fail "IMPLEMENTATION MISSING: $RS_CASES (policy require-safety cases)"
fi

# --- C3: reject-context — whether a mention inside a fence / HTML comment / #-line may
# count as ownership. Runs before C1 so the mapping is read against a stated detector. ---
RC_CASES="$AGENTS_DIR/tests/cc-on-demand-skill-ownership/cases-reject-context.sh"
if [ -f "$RC_CASES" ]; then
    # shellcheck source=/dev/null
    . "$RC_CASES"
else
    fail "IMPLEMENTATION MISSING: $RC_CASES (reject-context cases)"
fi

# --- C1: the exact rule -> required-consumer mapping. In the sibling folder to keep
# this entry file under the 300-line WARN (rules/coding/file-split.md Pattern A). ---
REQ_CASES="$AGENTS_DIR/tests/cc-on-demand-skill-ownership/cases-required.sh"
if [ -f "$REQ_CASES" ]; then
    # shellcheck source=/dev/null
    . "$REQ_CASES"
else
    fail "IMPLEMENTATION MISSING: $REQ_CASES (exact rule -> consumer mapping cases)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
