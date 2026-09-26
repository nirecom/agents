# tests/bin/feature-2339-sweep-plan-headings/d-tests.sh
# Sourced by feature-2339-sweep-plan-headings.sh
# D1-D7: dry-run, --fix normalize, reorder, content preservation, non-outline, preamble.

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
