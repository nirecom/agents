# tests/feature-2339-sweep-plan-headings/c9-c5-c6-tests.sh
# Sourced by feature-2339-sweep-plan-headings.sh
# C9: edge cases (missing plans dir, already-clean report); C5: --all skips non-outline artifacts; C6: duplicate-canonical no-op.

# C9-missing: --all when WORKFLOW_PLANS_DIR points at a directory that does not
# exist must exit non-zero (the tool cannot sweep what it cannot read). This
# prevents silent no-ops when the env var is misconfigured.
C9_MISSING_RC=0
node "$SWEEP_NODE" --all >/dev/null 2>&1 \
    WORKFLOW_PLANS_DIR="$TMPDIR_BASE/does-not-exist-c9" \
    CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/does-not-exist-c9-wf" || C9_MISSING_RC=$?
# The env-var prefix form is not available here (forbidden literal in Bash commands);
# use a node -e wrapper instead so the vars are injected cleanly.
_c9missing="$(node -e "
const cp = require('child_process');
try {
  cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--all'], {
    encoding: 'utf8',
    env: Object.assign({}, process.env, {
      WORKFLOW_PLANS_DIR: '$TMP_NODE/does-not-exist-c9',
      CLAUDE_WORKFLOW_DIR: '$TMP_NODE/does-not-exist-c9-wf',
    }),
  });
  process.stderr.write('expected non-zero exit but tool exited 0\n');
  process.exit(1);
} catch (e) {
  if (e.status && e.status > 0) { process.exit(0); }
  process.stderr.write('unexpected error: ' + String(e) + '\n');
  process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then
    pass "C9-missing: --all over a non-existent plans dir exits non-zero"
else
    fail "C9-missing: unexpected exit behavior for missing plans dir: $_c9missing"
fi

# C9-clean-report: dry-run over a file that is ALREADY canonical (canonical
# heading, sections already in canonical order) must print "no changes" in its
# stdout report. The file must be left byte-identical by both dry-run and
# --fix (i.e., the "no changes" path is exercised, not just the rename path).
C9_CLEAN="$TMPDIR_BASE/c9-clean-outline.md"
cat > "$C9_CLEAN" << 'EOF'
# Outline Plan C9

## Issues

## Adopted approach

AA body.

## Delivery plan

DP body.
EOF
_c9clean_sha_before="$(sha1sum "$C9_CLEAN" 2>/dev/null | cut -d' ' -f1)"
_c9clean_out="$(node "$SWEEP_NODE" "$(to_node "$C9_CLEAN")" 2>/dev/null)"
_c9clean_sha_after="$(sha1sum "$C9_CLEAN" 2>/dev/null | cut -d' ' -f1)"
if printf '%s\n' "$_c9clean_out" | grep -qF "no changes" 2>/dev/null \
   && [[ "$_c9clean_sha_before" == "$_c9clean_sha_after" ]]; then
    pass "C9-clean-report: dry-run on an already-canonical file reports 'no changes' and leaves the file byte-identical"
else
    fail "C9-clean-report: expected 'no changes' in stdout and byte-identical file (out=$(printf '%s' "$_c9clean_out" | head -3) sha_match=$([ "$_c9clean_sha_before" = "$_c9clean_sha_after" ] && echo yes || echo no))"
fi
# Also verify --fix on the already-canonical file is a no-op.
node "$SWEEP_NODE" --fix "$(to_node "$C9_CLEAN")" >/dev/null 2>&1
_c9clean_sha_fix="$(sha1sum "$C9_CLEAN" 2>/dev/null | cut -d' ' -f1)"
if [[ "$_c9clean_sha_before" == "$_c9clean_sha_fix" ]]; then
    pass "C9-clean-report-fix: --fix on an already-canonical file is a no-op"
else
    fail "C9-clean-report-fix: --fix changed an already-canonical file (sha_before=$_c9clean_sha_before sha_fix=$_c9clean_sha_fix)"
fi

# C5-all-detail: --all over a plans dir containing ONLY detail artifacts (no
# outline). The detail artifacts must NOT be reordered: the sweep normalizes
# localized headings in all artifact types, but section reorder applies to
# outline only. Verify: (a) the files are included in the scan (reported in
# stdout), (b) the section order in each detail file is left unchanged.
_c5detail="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const dir = '$TMP_NODE/c5-detail-plans';
const wf = '$TMP_NODE/c5-detail-wf';
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(wf, { recursive: true });
const name = 'a1b2c3d4-e5f6-7890-abcd-ef1234600001-detail.md';
// 'Steps' before 'Background' — opposite of any hypothetical canonical order
const body = '# Detail Plan\n\n## Steps\n\n- step\n\n## Background\n\nbg\n';
fs.writeFileSync(dir + '/' + name, body);
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', '--all'], {
  encoding: 'utf8',
  env: Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: dir, CLAUDE_WORKFLOW_DIR: wf }),
});
// (a) file must appear in the stdout report
if (out.indexOf(name) === -1) {
  process.stderr.write('detail artifact not included in --all report (stdout=' + JSON.stringify(out) + ')\n');
  process.exit(1);
}
// (b) section order must be unchanged
const after = fs.readFileSync(dir + '/' + name, 'utf8');
const posSteps = after.indexOf('## Steps');
const posBg = after.indexOf('## Background');
if (posSteps < 0 || posBg < 0 || posSteps >= posBg) {
  process.stderr.write('detail artifact was reordered by --all --fix (Steps=' + posSteps + ' Background=' + posBg + ')\n');
  process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C5-all-detail: --all reports detail artifact and does NOT reorder its sections"; else fail "C5-all-detail: $_c5detail"; fi

# C5-all-intent: --all over a plans dir containing ONLY intent artifacts.
# Same contract as C5-all-detail: included in scan, section order untouched.
_c5intent="$(node -e "
const fs = require('fs');
const cp = require('child_process');
const dir = '$TMP_NODE/c5-intent-plans';
const wf = '$TMP_NODE/c5-intent-wf';
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(wf, { recursive: true });
const name = 'a1b2c3d4-e5f6-7890-abcd-ef1234610001-intent.md';
const body = '# Intent\n\n## Motivation\n\nbody\n\n## Class members\n\n- M1\n';
fs.writeFileSync(dir + '/' + name, body);
const out = cp.execFileSync(process.execPath, ['$SWEEP_NODE', '--fix', '--all'], {
  encoding: 'utf8',
  env: Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: dir, CLAUDE_WORKFLOW_DIR: wf }),
});
// file must appear in the report
if (out.indexOf(name) === -1) {
  process.stderr.write('intent artifact not included in --all report (stdout=' + JSON.stringify(out) + ')\n');
  process.exit(1);
}
// section order must be unchanged
const after = fs.readFileSync(dir + '/' + name, 'utf8');
const posMotiv = after.indexOf('## Motivation');
const posClass = after.indexOf('## Class members');
if (posMotiv < 0 || posClass < 0 || posMotiv >= posClass) {
  process.stderr.write('intent artifact was reordered by --all --fix (Motivation=' + posMotiv + ' Class=' + posClass + ')\n');
  process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "C5-all-intent: --all reports intent artifact and does NOT reorder its sections"; else fail "C5-all-intent: $_c5intent"; fi

# C6-duplicate-canonical: an outline that already has every canonical heading
# spelled exactly right. No rename needed, no reorder needed. Both dry-run and
# --fix must be byte-identical no-ops, and stdout must contain "no changes".
C6="$TMPDIR_BASE/c6-canonical-outline.md"
cat > "$C6" << 'EOF'
# Outline Plan C6

## Issues

ISS body.

## Adopted approach

AA body.

## Delivery plan

DP body.

## Considered alternatives (rejected)

CA body.

## Accepted Tradeoffs

AT body.

## Confirmed non-goals

CNG body.

## Reused existing utilities / building blocks

REUSE body.
EOF
_c6_sha_before="$(sha1sum "$C6" 2>/dev/null | cut -d' ' -f1)"
# dry-run
_c6_dry_out="$(node "$SWEEP_NODE" "$(to_node "$C6")" 2>/dev/null)"
_c6_sha_dry="$(sha1sum "$C6" 2>/dev/null | cut -d' ' -f1)"
if printf '%s\n' "$_c6_dry_out" | grep -qF "no changes" 2>/dev/null \
   && [[ "$_c6_sha_before" == "$_c6_sha_dry" ]]; then
    pass "C6-duplicate-canonical: dry-run on a fully-canonical outline reports 'no changes' and leaves the file byte-identical"
else
    fail "C6-duplicate-canonical: dry-run changed or misreported an already-canonical outline (out=$(printf '%s' "$_c6_dry_out" | head -3) sha_match=$([ "$_c6_sha_before" = "$_c6_sha_dry" ] && echo yes || echo no))"
fi
# --fix
node "$SWEEP_NODE" --fix "$(to_node "$C6")" >/dev/null 2>&1
_c6_sha_fix="$(sha1sum "$C6" 2>/dev/null | cut -d' ' -f1)"
if [[ "$_c6_sha_before" == "$_c6_sha_fix" ]]; then
    pass "C6-duplicate-canonical: --fix on a fully-canonical outline is a byte-identical no-op"
else
    fail "C6-duplicate-canonical: --fix altered a fully-canonical outline (sha_before=$_c6_sha_before sha_fix=$_c6_sha_fix)"
fi
