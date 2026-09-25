# tests/feature-2339-sweep-plan-headings/c7-tests.sh
# Sourced by feature-2339-sweep-plan-headings.sh
# C7: dry-run stdout reporting, --all directory sweep (fix and dry), ineligible-file handling.

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
