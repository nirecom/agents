#!/usr/bin/env bash
# tests/feature-2339-sweep-plan-headings.sh
# Tests: bin/sweep-plan-headings.js
# Tags: scope:issue-specific, TL2
# lang-check: ignore -- CJK heading fixtures are built inside node here.
# TL2 CLI tests for the plan-heading sweep (#2339): dry-run is non-destructive;
# --fix normalizes localized H2 headings to canonical English (plan-schema SSOT),
# reorders ONLY known canonical outline sections, leaves non-outline and unknown
# H2 sections in place, and preserves H1/preamble/bodies. RED until the tool exists.

# TL3 gap: no --all sweep of a real plans dir with concurrent writers, and no
# PLAN_LANG variants beyond the LOCALIZED_TO_CANONICAL table.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="$AGENTS_ROOT/bin/sweep-plan-headings.js"
PLAN_SCHEMA="$AGENTS_ROOT/hooks/lib/plan-schema.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available"
    echo "Results: 0/0 passed, 0 failed"
    exit 0
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

to_node() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
SWEEP_NODE="$(to_node "$SWEEP")"
PLAN_SCHEMA_NODE="$(to_node "$PLAN_SCHEMA")"
TMP_NODE="$(to_node "$TMPDIR_BASE")"

# D1: dry-run (default, no --fix) must NOT modify the file. The whole
# localized-heading assertion is confined to node so CJK never crosses bash.
_d1="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const f = '$TMP_NODE/d1-outline.md';
const before = '# Plan\n\n## ' + k + '\n\nbody line\n';
fs.writeFileSync(f, before);
cp.execFileSync(process.execPath, ['$SWEEP_NODE', f], { stdio: 'pipe' });
const after = fs.readFileSync(f, 'utf8');
if (after !== before) { process.stderr.write('dry-run modified the file\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "D1: dry-run leaves the file unmodified"; else fail "D1: $_d1"; fi

# D2: --fix rewrites a localized H2 heading to its canonical English literal.
_d2="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = schema.LOCALIZED_TO_CANONICAL[k];
const f = '$TMP_NODE/d2-outline.md';
fs.writeFileSync(f, '# Plan\n\n## ' + k + '\n\nbody line\n');
cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', f], { stdio: 'pipe' });
const after = fs.readFileSync(f, 'utf8');
if (after.indexOf('## ' + v) === -1) { process.stderr.write('canonical heading missing after --fix\n'); process.exit(1); }
if (after.indexOf('## ' + k) !== -1) { process.stderr.write('localized heading still present after --fix\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "D2: --fix normalizes a localized H2 heading to canonical English"; else fail "D2: $_d2"; fi

# D3: --fix on an outline reorders canonical sections into canonical order.
# Fixture puts 'Delivery plan' before 'Adopted approach' (both canonical).
D3="$TMPDIR_BASE/d3-outline.md"
cat > "$D3" << 'EOF'
# Outline Plan

## Delivery plan

DP_BODY_MARKER

## Adopted approach

AA_BODY_MARKER
EOF
D3_RC=0; node "$SWEEP_NODE" --fix "$(to_node "$D3")" >/dev/null 2>&1 || D3_RC=$?
_pos_aa="$(grep -boF "## Adopted approach" "$D3" 2>/dev/null | head -1 | cut -d: -f1)"
_pos_dp="$(grep -boF "## Delivery plan" "$D3" 2>/dev/null | head -1 | cut -d: -f1)"
if [[ $D3_RC -eq 0 && -n "$_pos_aa" && -n "$_pos_dp" && "$_pos_aa" -lt "$_pos_dp" ]]; then
    pass "D3: --fix reorders outline canonical sections (Adopted approach before Delivery plan)"
else
    fail "D3: outline sections not reordered into canonical order (rc=$D3_RC aa=$_pos_aa dp=$_pos_dp)"
fi

# D7: content preservation — the section bodies survive the D3 reorder verbatim.
# Guarded on D3's successful --fix so an absent/failed tool cannot pass by no-op.
if [[ $D3_RC -eq 0 ]] && grep -qF "AA_BODY_MARKER" "$D3" 2>/dev/null && grep -qF "DP_BODY_MARKER" "$D3" 2>/dev/null; then
    pass "D7: reorder preserves both section bodies"
else
    fail "D7: reorder lost a section body or --fix failed (rc=$D3_RC)"
fi

# D4: a non-outline artifact (detail) must NOT be reordered. 'Steps' stays
# before 'Background' even though canonical detail order lists Background first.
D4="$TMPDIR_BASE/d4-detail.md"
cat > "$D4" << 'EOF'
# Detail Plan

## Steps

- step one

## Background

Some background.
EOF
D4_RC=0; node "$SWEEP_NODE" --fix "$(to_node "$D4")" >/dev/null 2>&1 || D4_RC=$?
_pos_steps="$(grep -boF "## Steps" "$D4" 2>/dev/null | head -1 | cut -d: -f1)"
_pos_bg="$(grep -boF "## Background" "$D4" 2>/dev/null | head -1 | cut -d: -f1)"
if [[ $D4_RC -eq 0 && -n "$_pos_steps" && -n "$_pos_bg" && "$_pos_steps" -lt "$_pos_bg" ]]; then
    pass "D4: non-outline (detail) artifact is not reordered"
else
    fail "D4: detail artifact was reordered or --fix failed (rc=$D4_RC steps=$_pos_steps background=$_pos_bg)"
fi

# D5: unknown H2 sections are a NO-OP under --fix (C4) — kept in place, never
# reordered away. 'Custom Notes' is not in CANONICAL_SECTIONS.outline.
D5="$TMPDIR_BASE/d5-outline.md"
cat > "$D5" << 'EOF'
# Outline Plan

## Adopted approach

AA body.

## Custom Notes

CUSTOM_NOTES_MARKER

## Delivery plan

DP body.
EOF
D5_RC=0; node "$SWEEP_NODE" --fix "$(to_node "$D5")" >/dev/null 2>&1 || D5_RC=$?
if [[ $D5_RC -eq 0 ]] && grep -qF "## Custom Notes" "$D5" 2>/dev/null && grep -qF "CUSTOM_NOTES_MARKER" "$D5" 2>/dev/null; then
    _pos_custom="$(grep -boF "## Custom Notes" "$D5" 2>/dev/null | head -1 | cut -d: -f1)"
    _pos_aa5="$(grep -boF "## Adopted approach" "$D5" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -n "$_pos_custom" && -n "$_pos_aa5" && "$_pos_custom" -gt "$_pos_aa5" ]]; then
        pass "D5: unknown H2 section kept in place under --fix (C4 NO-OP)"
    else
        fail "D5: unknown H2 section moved from its original position (custom=$_pos_custom aa=$_pos_aa5)"
    fi
else
    fail "D5: unknown H2 section/body dropped or --fix failed (rc=$D5_RC)"
fi

# D6: --fix preserves the H1 and the preamble text before the first H2.
D6="$TMPDIR_BASE/d6-outline.md"
cat > "$D6" << 'EOF'
# Outline Plan D6

PREAMBLE_MARKER before any section.

## Delivery plan

DP body.

## Adopted approach

AA body.
EOF
D6_RC=0; node "$SWEEP_NODE" --fix "$(to_node "$D6")" >/dev/null 2>&1 || D6_RC=$?
_pos_h1="$(grep -boF "# Outline Plan D6" "$D6" 2>/dev/null | head -1 | cut -d: -f1)"
_pos_pre="$(grep -boF "PREAMBLE_MARKER" "$D6" 2>/dev/null | head -1 | cut -d: -f1)"
_pos_firsth2="$(grep -boE "^## " "$D6" 2>/dev/null | head -1 | cut -d: -f1)"
if [[ $D6_RC -eq 0 && -n "$_pos_h1" && -n "$_pos_pre" && -n "$_pos_firsth2" \
      && "$_pos_h1" -lt "$_pos_pre" && "$_pos_pre" -lt "$_pos_firsth2" ]]; then
    pass "D6: --fix preserves H1 and preamble before the first H2"
else
    fail "D6: H1/preamble not preserved or --fix failed (rc=$D6_RC h1=$_pos_h1 pre=$_pos_pre firsth2=$_pos_firsth2)"
fi

# C7-dry: dry-run (no --fix) REPORTS the pending canonical rename on stdout while
# leaving the file byte-identical. CJK stays inside node.
_c7dry="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = schema.LOCALIZED_TO_CANONICAL[k];
const f = '$TMP_NODE/c7-dry-outline.md';
const before = '# Plan\n\n## ' + k + '\n\nbody line\n';
fs.writeFileSync(f, before);
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', f], { encoding: 'utf8' });
const after = fs.readFileSync(f, 'utf8');
if (after !== before) { process.stderr.write('dry-run modified the file\n'); process.exit(1); }
if (out.indexOf(v) === -1) { process.stderr.write('dry-run did not report the canonical target on stdout: ' + JSON.stringify(out) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C7-dry: dry-run reports the pending canonical rename on stdout, file unmodified"; else fail "C7-dry: $_c7dry"; fi

# C7-all: --fix --all normalizes EVERY outline artifact in the pinned plans dir
# (WORKFLOW_PLANS_DIR + CLAUDE_WORKFLOW_DIR pinned as a pair, per
# rules/test/fixture-isolation.md). Two outline files, both carrying a localized
# H2, must both come out canonical.
_c7all="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = schema.LOCALIZED_TO_CANONICAL[k];
const dir = '$TMP_NODE/c7-plans';
const wf = '$TMP_NODE/c7-wf';
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(wf, { recursive: true });
const files = ['a1b2c3d4-e5f6-7890-abcd-ef1234570001-outline.md', 'a1b2c3d4-e5f6-7890-abcd-ef1234570002-outline.md'];
files.forEach(function (name) { fs.writeFileSync(dir + '/' + name, '# Plan\n\n## ' + k + '\n\nbody line\n'); });
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', '--all'], {
  encoding: 'utf8',
  env: Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: dir, CLAUDE_WORKFLOW_DIR: wf }),
});
const bad = [];
files.forEach(function (name) {
  const t = fs.readFileSync(dir + '/' + name, 'utf8');
  if (t.indexOf('## ' + v) === -1 || t.indexOf('## ' + k) !== -1) { bad.push(name); }
});
if (bad.length !== 0) { process.stderr.write('files not normalized under --all: ' + JSON.stringify(bad) + '\n'); process.exit(1); }
// The --all run must REPORT that it scanned/changed BOTH files, not just touch
// them silently: each basename must appear in the sweep's stdout report.
const notReported = files.filter(function (name) { return out.indexOf(name) === -1; });
if (notReported.length !== 0) { process.stderr.write('files scanned but not reported in --all output: ' + JSON.stringify(notReported) + ' (stdout=' + JSON.stringify(out) + ')\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C7-all: --fix --all normalizes AND reports every outline artifact in the plans dir (both files)"; else fail "C7-all: $_c7all"; fi

# C7-all-dry: --all WITHOUT --fix scans the pinned plans dir and REPORTS both
# outline basenames on stdout, yet leaves EVERY file byte-identical (dry-run
# over a directory is non-destructive). Closes the D1 gap where the --all stdout
# was discarded and only single files were ever passed. CJK stays inside node.
_c7alldry="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const dir = '$TMP_NODE/c7-dry-plans';
const wf = '$TMP_NODE/c7-dry-wf';
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(wf, { recursive: true });
const files = ['a1b2c3d4-e5f6-7890-abcd-ef1234580001-outline.md', 'a1b2c3d4-e5f6-7890-abcd-ef1234580002-outline.md'];
const before = {};
files.forEach(function (name) { const c = '# Plan\n\n## ' + k + '\n\nbody line\n'; fs.writeFileSync(dir + '/' + name, c); before[name] = c; });
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--all'], {
  encoding: 'utf8',
  env: Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: dir, CLAUDE_WORKFLOW_DIR: wf }),
});
const changed = files.filter(function (name) { return fs.readFileSync(dir + '/' + name, 'utf8') !== before[name]; });
if (changed.length !== 0) { process.stderr.write('dry-run --all modified files: ' + JSON.stringify(changed) + '\n'); process.exit(1); }
const notReported = files.filter(function (name) { return out.indexOf(name) === -1; });
if (notReported.length !== 0) { process.stderr.write('dry-run --all did not report: ' + JSON.stringify(notReported) + ' (stdout=' + JSON.stringify(out) + ')\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C7-all-dry: --all dry-run reports both plans-dir basenames yet leaves every file byte-identical"; else fail "C7-all-dry: $_c7alldry"; fi

# C7-all-ineligible: --fix --all on a plans dir containing one eligible file (has a
# localized heading, needs rename) and one ineligible file (already canonical, no
# changes needed). After --all: (a) the eligible file is normalized; (b) the
# ineligible file is left byte-identical; (c) both filenames appear in stdout.
_c7ineligible="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = schema.LOCALIZED_TO_CANONICAL[k];
const dir = '$TMP_NODE/c7-inelig-plans';
const wf = '$TMP_NODE/c7-inelig-wf';
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(wf, { recursive: true });
const eligible = 'a1b2c3d4-e5f6-7890-abcd-ef1234590001-outline.md';
const ineligible = 'a1b2c3d4-e5f6-7890-abcd-ef1234590002-outline.md';
const eligibleContent = '# Plan\n\n## ' + k + '\n\nbody line\n';
const ineligibleContent = '# Plan\n\n## ' + v + '\n\nbody line\n';
fs.writeFileSync(dir + '/' + eligible, eligibleContent);
fs.writeFileSync(dir + '/' + ineligible, ineligibleContent);
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', '--all'], {
  encoding: 'utf8',
  env: Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: dir, CLAUDE_WORKFLOW_DIR: wf }),
});
// eligible file must now be canonical
const t = fs.readFileSync(dir + '/' + eligible, 'utf8');
if (t.indexOf('## ' + v) === -1 || t.indexOf('## ' + k) !== -1) {
  process.stderr.write('eligible file not normalized after --all --fix\n'); process.exit(1);
}
// ineligible file must be byte-identical to original
const t2 = fs.readFileSync(dir + '/' + ineligible, 'utf8');
if (t2 !== ineligibleContent) { process.stderr.write('ineligible (already canonical) file was modified by --all --fix\n'); process.exit(1); }
// both basenames must appear in stdout
if (out.indexOf(eligible) === -1 || out.indexOf(ineligible) === -1) {
  process.stderr.write('not both files reported in --all output (stdout=' + JSON.stringify(out) + ')\n'); process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C7-all-ineligible: --fix --all normalizes eligible file, leaves ineligible (already-canonical) file byte-identical, reports both"; else fail "C7-all-ineligible: $_c7ineligible"; fi

# C8: a full canonical outline with all 7 sections in WRONG order plus one unknown
# custom section. After --fix: (a) the 7 canonical sections are in the approved
# order; (b) the unknown section survives with its body; (c) every section body is
# preserved verbatim; (d) a second --fix is a byte-identical no-op (idempotent).
C8="$TMPDIR_BASE/c8-outline.md"
cat > "$C8" << 'EOF'
# Outline Plan C8

## Reused existing utilities / building blocks

BODY_REUSED

## Confirmed non-goals

BODY_NONGOALS

## Accepted Tradeoffs

BODY_TRADEOFFS

## Custom Notes

BODY_CUSTOM

## Considered alternatives (rejected)

BODY_ALTERNATIVES

## Delivery plan

BODY_DELIVERY

## Adopted approach

BODY_ADOPTED

## Issues

BODY_ISSUES
EOF
C8_RC=0; node "$SWEEP_NODE" --fix "$(to_node "$C8")" >/dev/null 2>&1 || C8_RC=$?

# C8a: canonical sections in the approved order (strictly increasing byte offsets).
C8_ORDER=(
    "## Issues"
    "## Adopted approach"
    "## Delivery plan"
    "## Considered alternatives (rejected)"
    "## Accepted Tradeoffs"
    "## Confirmed non-goals"
    "## Reused existing utilities / building blocks"
)
_c8_order_ok=1
_c8_prev=-1
for _h in "${C8_ORDER[@]}"; do
    _pos="$(grep -boF "$_h" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -z "$_pos" || "$_pos" -le "$_c8_prev" ]]; then _c8_order_ok=0; break; fi
    _c8_prev="$_pos"
done
if [[ $C8_RC -eq 0 && $_c8_order_ok -eq 1 ]]; then
    pass "C8a: --fix reorders all 7 canonical outline sections into the approved order"
else
    fail "C8a: canonical sections not in approved order after --fix (rc=$C8_RC order_ok=$_c8_order_ok)"
fi

# C8b: the unknown 'Custom Notes' section is preserved (heading + body).
if [[ $C8_RC -eq 0 ]] && grep -qF "## Custom Notes" "$C8" 2>/dev/null && grep -qF "BODY_CUSTOM" "$C8" 2>/dev/null; then
    pass "C8b: unknown custom section preserved after --fix"
else
    fail "C8b: unknown custom section dropped by --fix (rc=$C8_RC)"
fi

# C8e: the unknown 'Custom Notes' section keeps its position and is NOT relocated
# to the file tail. In the fixture Custom Notes sits in the interior (before the
# 'Considered alternatives (rejected)' / 'Delivery plan' / 'Issues' blocks). A
# reorder that only sorts the KNOWN canonical sections must leave the unknown
# anchored in the interior — so it must still precede the LAST canonical section
# ('Reused existing utilities / building blocks'). Asserting this catches the
# regression where unknowns are swept to the very end of the document. Content
# preservation is the softer fallback covered by C8b/C8c.
if [[ $C8_RC -eq 0 ]]; then
    _pos_custom8="$(grep -boF "## Custom Notes" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    _pos_reused8="$(grep -boF "## Reused existing utilities / building blocks" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -n "$_pos_custom8" && -n "$_pos_reused8" && "$_pos_custom8" -lt "$_pos_reused8" ]]; then
        pass "C8e: unknown 'Custom Notes' kept in the interior (precedes the last canonical section; not swept to the tail)"
    else
        fail "C8e: unknown section relocated to the file tail after --fix (custom=$_pos_custom8 last-canonical=$_pos_reused8)"
    fi
    # C8e-strong: the unknown section must stay at its ORIGINAL INTERLEAVING position.
    # In the fixture, Custom Notes occupies slot 3 (after Accepted Tradeoffs at
    # slot 2, before Considered alternatives at slot 4 in the input). The reorder
    # algorithm places known sections at known slots and leaves unknown slots
    # unchanged, so Custom Notes must end up between Delivery plan (now at slot 2)
    # and Considered alternatives (now at slot 4). Checking only custom < last-
    # canonical is insufficient — this check also requires custom < Considered.
    _pos_delivery8="$(grep -boF "## Delivery plan" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    _pos_considered8="$(grep -boF "## Considered alternatives (rejected)" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -n "$_pos_custom8" && -n "$_pos_delivery8" && -n "$_pos_considered8" \
          && "$_pos_delivery8" -lt "$_pos_custom8" && "$_pos_custom8" -lt "$_pos_considered8" ]]; then
        pass "C8e-strong: Custom Notes is between Delivery plan and Considered alternatives (original interleaving preserved, not just pre-tail)"
    else
        fail "C8e-strong: Custom Notes not at its original interleaving position (custom=$_pos_custom8 delivery=$_pos_delivery8 considered=$_pos_considered8)"
    fi
else
    fail "C8e: cannot check unknown-section position — first --fix failed (rc=$C8_RC)"
fi

# C8c: every section body survives the reorder verbatim (no content lost).
_c8_bodies_ok=1
for _m in BODY_REUSED BODY_NONGOALS BODY_TRADEOFFS BODY_CUSTOM BODY_ALTERNATIVES BODY_DELIVERY BODY_ADOPTED BODY_ISSUES; do
    grep -qF "$_m" "$C8" 2>/dev/null || _c8_bodies_ok=0
done
if [[ $C8_RC -eq 0 && $_c8_bodies_ok -eq 1 ]]; then
    pass "C8c: --fix preserves every section body verbatim (8/8 markers present)"
else
    fail "C8c: a section body was lost in the reorder (rc=$C8_RC bodies_ok=$_c8_bodies_ok)"
fi

# C8d: a second --fix over the already-canonical file is a byte-identical no-op.
if [[ $C8_RC -eq 0 ]]; then
    _c8_sha1="$(sha1sum "$C8" 2>/dev/null | cut -d' ' -f1)"
    node "$SWEEP_NODE" --fix "$(to_node "$C8")" >/dev/null 2>&1
    _c8_sha2="$(sha1sum "$C8" 2>/dev/null | cut -d' ' -f1)"
    if [[ -n "$_c8_sha1" && "$_c8_sha1" == "$_c8_sha2" ]]; then
        pass "C8d: --fix is idempotent (second run leaves the file byte-identical)"
    else
        fail "C8d: second --fix changed the file (sha1 before=$_c8_sha1 after=$_c8_sha2)"
    fi
else
    fail "C8d: cannot check idempotency — first --fix failed (rc=$C8_RC)"
fi

# C9-missing: sweep on a non-existent file path (but with a recognized artifact
# suffix) must exit non-zero. The tool cannot silently report success when the
# file it was asked to inspect does not exist.
C9_MISSING="$(to_node "$TMPDIR_BASE/nonexistent-outline.md")"
C9_MISSING_RC=0; node "$SWEEP_NODE" "$C9_MISSING" >/dev/null 2>&1 || C9_MISSING_RC=$?
if [[ $C9_MISSING_RC -ne 0 ]]; then
    pass "C9-missing: sweep on a non-existent file exits non-zero (rc=$C9_MISSING_RC)"
else
    fail "C9-missing: sweep on a non-existent file should exit non-zero but got 0"
fi

# C9-clean-report: an already-canonical file (no changes needed) is reported with
# "no changes" on stdout and exits 0 (clean run). This verifies that the tool
# distinguishes "clean" from "error" and that ineligible files are not silently skipped.
C9_CLEAN_FILE="$TMPDIR_BASE/c9-canonical-outline.md"
printf '# Plan\n\n## Issues\n\nbody\n' > "$C9_CLEAN_FILE"
C9_CLEAN_OUT=""; C9_CLEAN_RC=0
C9_CLEAN_OUT="$(node "$SWEEP_NODE" "$(to_node "$C9_CLEAN_FILE")" 2>&1)" || C9_CLEAN_RC=$?
if [[ $C9_CLEAN_RC -eq 0 ]] && echo "$C9_CLEAN_OUT" | grep -qF "no changes"; then
    pass "C9-clean-report: already-canonical file exits 0 and reports 'no changes'"
else
    fail "C9-clean-report: expected exit 0 + 'no changes' (rc=$C9_CLEAN_RC out='$C9_CLEAN_OUT')"
fi

# C5-all-detail: --all normalizes localized heading in a detail artifact (no reorder).
# Detail artifacts use the same heading-rename logic but are NOT reordered.
# Verifies: exit 0, stdout mentions the file, the heading is canonical, body/order unchanged.
_c5alld="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = schema.LOCALIZED_TO_CANONICAL[k];
const dir = '$TMP_NODE/c5-detail-plans';
const wf = '$TMP_NODE/c5-detail-wf';
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(wf, { recursive: true });
const fname = 'a1b2c3d4-e5f6-7890-abcd-ef1234600001-detail.md';
const content = '# Detail Plan\n\n## Steps\n\nstep one\n\n## ' + k + '\n\nsome background\n';
fs.writeFileSync(dir + '/' + fname, content);
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', '--all'], {
  encoding: 'utf8',
  env: Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: dir, CLAUDE_WORKFLOW_DIR: wf }),
});
const after = fs.readFileSync(dir + '/' + fname, 'utf8');
// heading renamed
if (after.indexOf('## ' + v) === -1) { process.stderr.write('canonical heading missing after --fix --all (detail)\n'); process.exit(1); }
if (after.indexOf('## ' + k) !== -1) { process.stderr.write('localized heading still present after --fix --all (detail)\n'); process.exit(1); }
// file reported in stdout
if (out.indexOf(fname) === -1) { process.stderr.write('file not reported in --all output: ' + JSON.stringify(out) + '\n'); process.exit(1); }
// Steps section still before the renamed section (no reorder — Steps is not a canonical outline section)
const posSteps = after.indexOf('## Steps');
const posCanon = after.indexOf('## ' + v);
if (posSteps === -1 || posCanon === -1 || posSteps >= posCanon) {
  process.stderr.write('Steps section was reordered after --fix --all (detail artifact must not be reordered)\n'); process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C5-all-detail: --fix --all normalizes localized heading in a detail artifact and reports the file (no reorder)"; else fail "C5-all-detail: $_c5alld"; fi

# C5-all-intent: --all normalizes localized heading in an intent artifact (no reorder).
# Uses a localized key that does NOT map to 'Issues' to avoid heading collision in the
# fixture (the fixture already has an '## Issues' section).
_c5alli="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const schema = require('$PLAN_SCHEMA_NODE');
const map = schema.LOCALIZED_TO_CANONICAL || {};
// Pick a localized key whose canonical target is not 'Issues' to avoid a name collision
// with the existing '## Issues' section in the fixture.
const entry = Object.entries(map).find(function (e) { return e[1] !== 'Issues'; });
if (!entry) { process.stderr.write('no localized variant available that maps to non-Issues\n'); process.exit(1); }
const k = entry[0], v = entry[1];
const dir = '$TMP_NODE/c5-intent-plans';
const wf = '$TMP_NODE/c5-intent-wf';
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(wf, { recursive: true });
const fname = 'a1b2c3d4-e5f6-7890-abcd-ef1234610001-intent.md';
const content = '# Intent\n\n## Issues\n\n- #1234\n\n## ' + k + '\n\nbody text\n';
fs.writeFileSync(dir + '/' + fname, content);
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', '--all'], {
  encoding: 'utf8',
  env: Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: dir, CLAUDE_WORKFLOW_DIR: wf }),
});
const after = fs.readFileSync(dir + '/' + fname, 'utf8');
// heading renamed
if (after.indexOf('## ' + v) === -1) { process.stderr.write('canonical heading missing after --fix --all (intent)\n'); process.exit(1); }
if (after.indexOf('## ' + k) !== -1) { process.stderr.write('localized heading still present after --fix --all (intent)\n'); process.exit(1); }
// file reported in stdout
if (out.indexOf(fname) === -1) { process.stderr.write('file not reported in --all output: ' + JSON.stringify(out) + '\n'); process.exit(1); }
// Issues section still before the renamed section (original order: Issues, then renamed section).
// Intent artifacts are NOT reordered by sweep — the original insertion order is preserved.
const posIssues = after.indexOf('## Issues');
const posCanon = after.indexOf('## ' + v);
if (posIssues === -1 || posCanon === -1 || posIssues >= posCanon) {
  process.stderr.write('Issues section was reordered after --fix --all (intent artifact must not be reordered; posIssues=' + posIssues + ' posCanon=' + posCanon + ')\n'); process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C5-all-intent: --fix --all normalizes localized heading in an intent artifact and reports the file (no reorder)"; else fail "C5-all-intent: $_c5alli"; fi

# C6-duplicate-canonical: outline with two identical canonical sections (e.g., two
# '## Adopted approach') — sweep --fix must exit 0 and not crash (idempotent/no-crash
# on duplicate headings). The file's headings must still be present after the run.
_c6dup="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const f = '$TMP_NODE/c6-dup-outline.md';
const content = '# Outline Plan\n\n## Adopted approach\n\nfirst body\n\n## Adopted approach\n\nsecond body\n';
fs.writeFileSync(f, content);
let rc = 0;
try {
  cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', f], { stdio: 'pipe' });
} catch (e) {
  rc = (e.status || 1);
}
if (rc !== 0) { process.stderr.write('sweep --fix exited non-zero on duplicate canonical heading (rc=' + rc + ')\n'); process.exit(1); }
const after = fs.readFileSync(f, 'utf8');
// At least one '## Adopted approach' must still be present — no silent deletion
const count = (after.match(/^## Adopted approach/mg) || []).length;
if (count === 0) { process.stderr.write('all ## Adopted approach sections were dropped (file=' + JSON.stringify(after) + ')\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C6-duplicate-canonical: sweep --fix on duplicate canonical heading exits 0 and preserves at least one copy (no crash)"; else fail "C6-duplicate-canonical: $_c6dup"; fi

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
