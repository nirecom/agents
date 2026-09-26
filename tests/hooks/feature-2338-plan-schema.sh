#!/usr/bin/env bash
# tests/hooks/feature-2338-plan-schema.sh
# Tests: hooks/lib/plan-schema.js
# Tags: scope:issue-specific
# TL1 unit tests for the canonical plan-schema SSOT (#2338/#2228/#2339).
# Pins: CANONICAL_SECTIONS order (outline/detail), canonicalizeHeading (canonical
# self-map, localized->canonical, unknown->null), firstBodySection, and the
# node CLI bridge (--first-body-section / --order) used by assemble-mandatory.sh.
# RED until hooks/lib/plan-schema.js exists — node require throws and each case fails.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN_SCHEMA="$AGENTS_ROOT/hooks/lib/plan-schema.js"
if command -v cygpath >/dev/null 2>&1; then
    PLAN_SCHEMA_NODE="$(cygpath -m "$PLAN_SCHEMA")"
else
    PLAN_SCHEMA_NODE="$PLAN_SCHEMA"
fi

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Prereq (RED marker): the SSOT module must exist and load.
if [[ -f "$PLAN_SCHEMA" ]]; then
    pass "prereq: hooks/lib/plan-schema.js exists"
else
    fail "prereq: hooks/lib/plan-schema.js not found (RED phase — implementation pending): $PLAN_SCHEMA"
fi

# A1: CANONICAL_SECTIONS.outline has the exact canonical order.
_a1="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const expected = ['Issues','Adopted approach','Delivery plan','Considered alternatives (rejected)','Accepted Tradeoffs','Confirmed non-goals','Reused existing utilities / building blocks'];
const got = s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.outline;
if (JSON.stringify(got) !== JSON.stringify(expected)) { process.stderr.write('outline order mismatch: got=' + JSON.stringify(got) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "A1: CANONICAL_SECTIONS.outline canonical order"; else fail "A1: $_a1"; fi

# A2: CANONICAL_SECTIONS.detail includes the required detail sections.
_a2="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const need = ['Delivery plan','Background','Files to modify','Steps','Risks & edge cases','Out of scope'];
const got = (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.detail) || [];
const missing = need.filter(function (x) { return got.indexOf(x) === -1; });
if (missing.length !== 0) { process.stderr.write('detail missing: ' + JSON.stringify(missing) + ' (got=' + JSON.stringify(got) + ')\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "A2: CANONICAL_SECTIONS.detail includes required sections"; else fail "A2: $_a2"; fi

# A3: canonicalizeHeading of a canonical English H2 line returns that name.
_a3="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = s.canonicalizeHeading('## Adopted approach');
if (got !== 'Adopted approach') { process.stderr.write('expected Adopted approach, got ' + JSON.stringify(got) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "A3: canonicalizeHeading('## Adopted approach') -> 'Adopted approach'"; else fail "A3: $_a3"; fi

# A4: a known Japanese localized variant resolves to its canonical English name.
# CJK is confined to the node process (no CJK through bash vars).
_a4="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const map = s.LOCALIZED_TO_CANONICAL || {};
const keys = Object.keys(map);
if (keys.length === 0) { process.stderr.write('LOCALIZED_TO_CANONICAL is empty\n'); process.exit(1); }
const k = keys[0];
if (!/[^\x00-\x7F]/.test(k)) { process.stderr.write('first localized key is ASCII, expected a non-ASCII variant: ' + k + '\n'); process.exit(1); }
const got = s.canonicalizeHeading('## ' + k);
if (got !== map[k]) { process.stderr.write('canonicalizeHeading(localized)=' + JSON.stringify(got) + ' expected ' + JSON.stringify(map[k]) + '\n'); process.exit(1); }
const all = [].concat(s.CANONICAL_SECTIONS.intent || [], s.CANONICAL_SECTIONS.outline || [], s.CANONICAL_SECTIONS.detail || []);
if (all.indexOf(map[k]) === -1) { process.stderr.write('mapped canonical name is not a real canonical section: ' + map[k] + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "A4: localized Japanese H2 -> canonical English name"; else fail "A4: $_a4"; fi

# A5: an unknown heading returns null (only known variants resolve).
_a5="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = s.canonicalizeHeading('## Some Completely Unknown Heading XYZ');
if (got !== null) { process.stderr.write('expected null, got ' + JSON.stringify(got) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "A5: canonicalizeHeading(unknown) -> null"; else fail "A5: $_a5"; fi

# A6: firstBodySection('outline') -> 'Adopted approach'.
_a6="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = s.firstBodySection('outline');
if (got !== 'Adopted approach') { process.stderr.write('expected Adopted approach, got ' + JSON.stringify(got) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "A6: firstBodySection('outline') -> 'Adopted approach'"; else fail "A6: $_a6"; fi

# A7: firstBodySection('detail') -> 'Delivery plan'.
_a7="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = s.firstBodySection('detail');
if (got !== 'Delivery plan') { process.stderr.write('expected Delivery plan, got ' + JSON.stringify(got) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "A7: firstBodySection('detail') -> 'Delivery plan'"; else fail "A7: $_a7"; fi

# A8: CLI --first-body-section outline prints exactly 'Adopted approach'.
_a8="$(node "$PLAN_SCHEMA_NODE" --first-body-section outline 2>/dev/null)"
if [[ "$(printf '%s' "$_a8" | tr -d '[:space:]')" == "Adoptedapproach" ]]; then
    pass "A8: CLI --first-body-section outline -> 'Adopted approach'"
else
    fail "A8: CLI --first-body-section outline expected 'Adopted approach', got '$_a8'"
fi

# A9: CLI --first-body-section detail prints exactly 'Delivery plan'.
_a9="$(node "$PLAN_SCHEMA_NODE" --first-body-section detail 2>/dev/null)"
if [[ "$(printf '%s' "$_a9" | tr -d '[:space:]')" == "Deliveryplan" ]]; then
    pass "A9: CLI --first-body-section detail -> 'Delivery plan'"
else
    fail "A9: CLI --first-body-section detail expected 'Delivery plan', got '$_a9'"
fi

# A10: CLI --order outline prints the canonical outline order.
# Verify presence of the boundary sections and that 'Adopted approach' precedes
# 'Accepted Tradeoffs' in the emitted order (delimiter-agnostic byte-offset check).
_a10="$(node "$PLAN_SCHEMA_NODE" --order outline 2>/dev/null)"
_a10_ok=1
echo "$_a10" | grep -qF "Issues" || _a10_ok=0
echo "$_a10" | grep -qF "Adopted approach" || _a10_ok=0
echo "$_a10" | grep -qF "Reused existing utilities / building blocks" || _a10_ok=0
# order: Adopted approach must come before Accepted Tradeoffs
_pos_adopt="$(printf '%s' "$_a10" | grep -boF "Adopted approach" | head -1 | cut -d: -f1)"
_pos_trade="$(printf '%s' "$_a10" | grep -boF "Accepted Tradeoffs" | head -1 | cut -d: -f1)"
if [[ -z "$_pos_adopt" || -z "$_pos_trade" || "$_pos_adopt" -ge "$_pos_trade" ]]; then _a10_ok=0; fi
if [[ "$_a10_ok" -eq 1 ]]; then
    pass "A10: CLI --order outline prints canonical order (Adopted approach before Accepted Tradeoffs)"
else
    fail "A10: CLI --order outline did not print expected canonical order (got: $_a10)"
fi

# C2: EVERY LOCALIZED_TO_CANONICAL entry round-trips through canonicalizeHeading.
# The whole map is walked inside node so no CJK key crosses bash; a single failing
# entry names itself. Also asserts the map is non-empty (no vacuous pass).
_c2="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const map = s.LOCALIZED_TO_CANONICAL || {};
const keys = Object.keys(map);
if (keys.length === 0) { process.stderr.write('LOCALIZED_TO_CANONICAL is empty\n'); process.exit(1); }
const canonicalAll = [].concat(
  (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.intent) || [],
  (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.outline) || [],
  (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.detail) || []
);
const bad = [];
keys.forEach(function (k) {
  const expected = map[k];
  const got = s.canonicalizeHeading('## ' + k);
  if (got !== expected) { bad.push(JSON.stringify(k) + ' -> got ' + JSON.stringify(got) + ' expected ' + JSON.stringify(expected)); return; }
  if (canonicalAll.indexOf(expected) === -1) { bad.push(JSON.stringify(k) + ' maps to non-canonical ' + JSON.stringify(expected)); }
});
if (bad.length !== 0) { process.stderr.write('mapping failures (' + keys.length + ' entries):\n' + bad.join('\n') + '\n'); process.exit(1); }
process.stdout.write('checked ' + keys.length + ' localized mappings\n');
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C2: every LOCALIZED_TO_CANONICAL entry canonicalizes to its canonical section ($_c2)"; else fail "C2: $_c2"; fi

# C2-cli: table-driven over the CLI enumeration surface. The map is obtained from
# an INDEPENDENT surface — `node plan-schema.js --localized-to-canonical` emitting
# a JSON object — so the enumeration does not rely on the same module export the
# assertion checks (no circular / vacuous pass). Every entry is asserted
# individually and the map is required non-empty; a single bad pair names itself.
_c2cli="$(node -e "
const cp = require('child_process');
const s = require('$PLAN_SCHEMA_NODE');
let raw;
try {
  raw = cp.execFileSync(process.execPath, ['$PLAN_SCHEMA_NODE', '--localized-to-canonical'], { encoding: 'utf8' });
} catch (e) {
  process.stderr.write('CLI --localized-to-canonical failed: ' + (e && e.message) + '\n'); process.exit(1);
}
let map;
try { map = JSON.parse(raw); } catch (e) { process.stderr.write('CLI output is not valid JSON: ' + JSON.stringify(raw) + '\n'); process.exit(1); }
const keys = Object.keys(map || {});
if (keys.length === 0) { process.stderr.write('CLI --localized-to-canonical returned an empty map\n'); process.exit(1); }
const canonicalAll = [].concat(
  (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.intent) || [],
  (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.outline) || [],
  (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.detail) || []
);
const bad = [];
keys.forEach(function (k) {
  const expected = map[k];
  const got = s.canonicalizeHeading('## ' + k);
  if (got !== expected) { bad.push(JSON.stringify(k) + ' -> canonicalizeHeading gave ' + JSON.stringify(got) + ' expected ' + JSON.stringify(expected)); return; }
  if (canonicalAll.indexOf(expected) === -1) { bad.push(JSON.stringify(k) + ' maps to non-canonical ' + JSON.stringify(expected)); }
});
if (bad.length !== 0) { process.stderr.write('CLI-enumerated mapping failures (' + keys.length + ' entries):\n' + bad.join('\n') + '\n'); process.exit(1); }
process.stdout.write('CLI-enumerated ' + keys.length + ' localized mappings\n');
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C2-cli: CLI --localized-to-canonical enumerates every localized pair; each canonicalizes correctly ($_c2cli)"; else fail "C2-cli: $_c2cli"; fi

# C3a: CANONICAL_SECTIONS.detail contains the COMPLETE canonical detail set
# (exact membership, order-independent) per the detail schema.
_c3a="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const expected = ['Delivery plan','Background','Files to modify','Steps','Risks & edge cases','Out of scope'];
const got = (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.detail) || [];
const missing = expected.filter(function (x) { return got.indexOf(x) === -1; });
const extra = got.filter(function (x) { return expected.indexOf(x) === -1; });
if (missing.length !== 0 || extra.length !== 0) {
  process.stderr.write('detail membership mismatch: missing=' + JSON.stringify(missing) + ' extra=' + JSON.stringify(extra) + ' (got=' + JSON.stringify(got) + ')\n');
  process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C3a: CANONICAL_SECTIONS.detail has the exact canonical member set"; else fail "C3a: $_c3a"; fi

# C3a-N: beyond C3a's combined membership check, assert each canonical detail
# section INDIVIDUALLY (one PASS/FAIL line per member) so a single missing detail
# section names exactly which one. The section name is passed as argv (ASCII
# canonical names; no CJK) to keep each assertion isolated.
c3a_has() {
    node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.detail) || [];
if (got.length === 0) { process.stderr.write('detail array is empty\n'); process.exit(1); }
if (got.indexOf(process.argv[1]) === -1) { process.stderr.write('detail array is missing ' + JSON.stringify(process.argv[1]) + ' (got=' + JSON.stringify(got) + ')\n'); process.exit(1); }
" "$1" 2>&1
}
_c3a1="$(c3a_has 'Delivery plan')"
if [[ $? -eq 0 ]]; then pass "C3a-1: CANONICAL_SECTIONS.detail contains 'Delivery plan'"; else fail "C3a-1: $_c3a1"; fi
_c3a2="$(c3a_has 'Background')"
if [[ $? -eq 0 ]]; then pass "C3a-2: CANONICAL_SECTIONS.detail contains 'Background'"; else fail "C3a-2: $_c3a2"; fi
_c3a3="$(c3a_has 'Files to modify')"
if [[ $? -eq 0 ]]; then pass "C3a-3: CANONICAL_SECTIONS.detail contains 'Files to modify'"; else fail "C3a-3: $_c3a3"; fi
_c3a4="$(c3a_has 'Steps')"
if [[ $? -eq 0 ]]; then pass "C3a-4: CANONICAL_SECTIONS.detail contains 'Steps'"; else fail "C3a-4: $_c3a4"; fi
_c3a5="$(c3a_has 'Risks & edge cases')"
if [[ $? -eq 0 ]]; then pass "C3a-5: CANONICAL_SECTIONS.detail contains 'Risks & edge cases'"; else fail "C3a-5: $_c3a5"; fi
_c3a6="$(c3a_has 'Out of scope')"
if [[ $? -eq 0 ]]; then pass "C3a-6: CANONICAL_SECTIONS.detail contains 'Out of scope'"; else fail "C3a-6: $_c3a6"; fi

# C3b: CANONICAL_SECTIONS.intent exists AND is an array.
_c3b="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.intent;
if (!Array.isArray(got)) { process.stderr.write('CANONICAL_SECTIONS.intent is not an array: ' + JSON.stringify(got) + '\n'); process.exit(1); }
if (got.length === 0) { process.stderr.write('CANONICAL_SECTIONS.intent is empty\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C3b: CANONICAL_SECTIONS.intent exists as a non-empty array"; else fail "C3b: $_c3b"; fi

# C3b-1 / C3b-2 / C3b-3: each mandatory intent H2 section is asserted INDIVIDUALLY
# (one PASS/FAIL line per member) per skills/clarify-intent/reference/intent-md-schema.md,
# so a single missing section names exactly which one. The section name is passed
# to node as argv (no CJK; ASCII canonical names) to keep each assertion isolated.
c3b_has() {
    node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.intent) || [];
if (got.indexOf(process.argv[1]) === -1) { process.stderr.write('intent array is missing ' + JSON.stringify(process.argv[1]) + ' (got=' + JSON.stringify(got) + ')\n'); process.exit(1); }
" "$1" 2>&1
}
_c3b1="$(c3b_has 'Issues')"
if [[ $? -eq 0 ]]; then pass "C3b-1: CANONICAL_SECTIONS.intent contains 'Issues'"; else fail "C3b-1: $_c3b1"; fi
_c3b2="$(c3b_has 'Class members')"
if [[ $? -eq 0 ]]; then pass "C3b-2: CANONICAL_SECTIONS.intent contains 'Class members'"; else fail "C3b-2: $_c3b2"; fi
_c3b3="$(c3b_has 'Accepted Tradeoffs')"
if [[ $? -eq 0 ]]; then pass "C3b-3: CANONICAL_SECTIONS.intent contains 'Accepted Tradeoffs'"; else fail "C3b-3: $_c3b3"; fi
_c3b4="$(c3b_has 'Background/Motivation')"
if [[ $? -eq 0 ]]; then pass "C3b-4: CANONICAL_SECTIONS.intent contains 'Background/Motivation'"; else fail "C3b-4: $_c3b4"; fi
_c3b5="$(c3b_has 'Scope')"
if [[ $? -eq 0 ]]; then pass "C3b-5: CANONICAL_SECTIONS.intent contains 'Scope'"; else fail "C3b-5: $_c3b5"; fi
_c3b6="$(c3b_has 'Constraints')"
if [[ $? -eq 0 ]]; then pass "C3b-6: CANONICAL_SECTIONS.intent contains 'Constraints'"; else fail "C3b-6: $_c3b6"; fi
_c3b7="$(c3b_has 'Interview Log')"
if [[ $? -eq 0 ]]; then pass "C3b-7: CANONICAL_SECTIONS.intent contains 'Interview Log'"; else fail "C3b-7: $_c3b7"; fi
_c3b8="$(c3b_has 'worktrees')"
if [[ $? -eq 0 ]]; then pass "C3b-8: CANONICAL_SECTIONS.intent contains 'worktrees'"; else fail "C3b-8: $_c3b8"; fi

# C3c: CANONICAL_SECTIONS.intent has exactly 8 members (no more, no less).
_c3c="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const got = (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.intent) || [];
if (got.length !== 8) { process.stderr.write('intent array has ' + got.length + ' members, expected 8: ' + JSON.stringify(got) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C3c: CANONICAL_SECTIONS.intent has exactly 8 members"; else fail "C3c: $_c3c"; fi

# C3a-self: every canonical detail heading canonicalizes to itself.
_c3a_self="$(node -e "
const s = require('$PLAN_SCHEMA_NODE');
const detail = (s.CANONICAL_SECTIONS && s.CANONICAL_SECTIONS.detail) || [];
const bad = [];
detail.forEach(function (h) {
  const got = s.canonicalizeHeading('## ' + h);
  if (got !== h) { bad.push(JSON.stringify(h) + ' -> ' + JSON.stringify(got)); }
});
if (bad.length !== 0) { process.stderr.write('canonical detail sections not self-mapped:\n' + bad.join('\n') + '\n'); process.exit(1); }
process.stdout.write('checked ' + detail.length + ' detail canonical self-maps\n');
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C3a-self: every canonical detail section self-maps through canonicalizeHeading ($_c3a_self)"; else fail "C3a-self: $_c3a_self"; fi

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
