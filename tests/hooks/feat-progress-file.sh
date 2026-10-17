#!/usr/bin/env bash
# tests/hooks/feat-progress-file.sh
# Tests: hooks/lib/progress-file.js, bin/progress-file
# Tags: progress-file, root-sid, inheritance, template, idempotent, cli, scope:issue-specific, pwsh-not-required, TL1

# Issue #2594 stage 1 — one session-progress.md is written across every generation of a handed-off session, so its name carries the first generation's sid. Each generation copies the root sid its donor saved (so neither chain length nor an expired middle state can split the file); chain walking is only the fallback. ensure must never overwrite what the model already wrote.

# Assumed contract (named here so a different spelling fails loudly, not silently): the saved root sid is the `root_sid` key of <sid>.control/progress-pressure.json; the update-progress count is a numeric key of that file whose name matches /update.?progress/i; the template's "Plan files" section carries the real absolute paths that ensureProgressFile fills in from the plans dir and the sid — `<plans dir>/<sid>-intent.md`, `-outline.md`, `-detail.md`, never a `<sid>` placeholder (user decision) — and says the step list is in `next-step --list`. For a later generation the sid in those paths is the one whose plan files exist: the root sid (the fixture plants them under it).

# TDD (write_code has not run): every case is expected to FAIL with the module and CLI absent.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP="$(make_tmp)"
readonly TMP
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/home" "$TMP/transcripts" "$TMP/neutral"
harness_isolate "$(np "$TMP")"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP/neutral" || exit 1
CLI="$SCRIPT_CHECKOUT_ROOT/bin/progress-file"

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:400}"; fi; }

# seed.js <sid> [donor] — a session state; with a donor, the backfilled
# session-inheritance event that names it (the record /resume-session --from writes).
# seed.js --root <sid> <root> — plant the root sid saved in <sid>'s control file.
# seed.js --drop <sid> — delete <sid>'s state file (an expired middle generation).
cat > "$TMP/seed.js" <<'JS'
const fs = require('fs');
const path = require('path');
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const a = process.argv.slice(2);
if (a[0] === '--root') {
  const dir = path.join(process.env.WORKFLOW_STATE_DIR, a[1] + '.control');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'progress-pressure.json'), JSON.stringify({ root_sid: a[2] }));
} else if (a[0] === '--drop') {
  fs.rmSync(S.getStatePath(a[1]), { force: true });
} else {
  S.writeState(a[0], S.createInitialState(a[0], { cwd: '/x', git_branch: 'feature/x' }));
  if (a[1]) S.appendEvents(a[0], [{ kind: 'step_status', step: 'workflow_init', status: 'complete',
    provenance: 'backfilled', origin: 'session-inheritance', inherited_from: a[1] }]);
  else S.markStep(a[0], 'workflow_init', 'complete');
}
process.stdout.write('ok');
JS
seed() { nj seed.js "$@" >/dev/null; }

cat > "$TMP/root.js" <<'JS'
const P = require(process.env.AGENTS + '/hooks/lib/progress-file.js');
process.stdout.write(String(P.resolveRootSid(process.argv[2])));
JS
root_of() { nj root.js "$1"; }

case_begin "root-sid-resolution" "hooks/lib/progress-file.js"
seed solo
expect "B1: no inheritance -> the session's own sid" "$(root_of solo)" "solo"
seed g1; seed g2 g1
expect "B2: two generations -> the donor's sid" "$(root_of g2)" "g1"
seed h1; seed h2 h1; seed h3 h2; seed --root h2 h-first
expect "B3: three generations -> the root sid the donor saved is copied (not the chain's end)" "$(root_of h3)" "h-first"
seed k1; seed k2 k1; seed k3 k2; seed k4 k3; seed --root k3 k1; seed --drop k2
expect "B4: a middle generation's state expired -> the donor's saved value still names the first generation" "$(root_of k4)" "k1"
seed m2 m-gone
expect "B5: the chain breaks at once and nothing was saved -> the oldest sid reached" "$(root_of m2)" "m-gone"
seed own; seed --root own own-saved
expect "B6: the session's own saved value wins over everything" "$(root_of own)" "own-saved"
case_end

cat > "$TMP/ensure.js" <<'JS'
const fs = require('fs');
const path = require('path');
const P = require(process.env.AGENTS + '/hooks/lib/progress-file.js');
const bad = [];
const want = path.join(process.env.WORKFLOW_PLANS_DIR, 'g1-session-progress.md');
// g2 inherits from g1: the plan files exist under the root sid, so the template must name those.
const slash = (s) => String(s).replace(/\\/g, '/');
const planPaths = ['intent', 'outline', 'detail'].map((k) => path.join(process.env.WORKFLOW_PLANS_DIR, 'g1-' + k + '.md'));
fs.mkdirSync(process.env.WORKFLOW_PLANS_DIR, { recursive: true });
for (const p of planPaths) fs.writeFileSync(p, '# plan\n');
P.ensureProgressFile('g2');
let body = '';
try { body = fs.readFileSync(want, 'utf8'); } catch (e) { bad.push('not-created-at-root-path:' + want); }
if (fs.existsSync(path.join(process.env.WORKFLOW_PLANS_DIR, 'g2-session-progress.md'))) bad.push('created-under-heir-sid');
// Unconditional: an empty or missing body fails every template check below, never skips them.
if (!body.trim()) bad.push('generated-body-empty');
const need = {
  'section-current-state': /^#+\s*Current state/m,
  'section-plan-files': /^#+\s*Plan files/m,
  'section-facts-to-carry-over': /^#+\s*Facts to carry over/m,
  'pointer-next-step-list': /next-step --list/,
  'fact-user-decisions': /User decisions/, 'fact-deviations': /Deviations/,
  'fact-rejected-approaches': /Rejected approaches/, 'fact-open-questions': /Open questions/,
};
for (const [k, re] of Object.entries(need)) if (!re.test(body)) bad.push('template-lacks-' + k);
// Exact absolute paths, separators normalized on both sides (path.join yields '\' on Windows).
for (const p of planPaths) if (!slash(body).includes(slash(p))) bad.push('template-lacks-absolute-path:' + slash(p));
if (/<\w*sid>/i.test(body)) bad.push('template-keeps-sid-placeholder');
if (body) {
  fs.writeFileSync(want, '## Current state\nmodel wrote this\n');
  P.ensureProgressFile('g2');
  P.ensureProgressFile('g1');
  if (fs.readFileSync(want, 'utf8') !== '## Current state\nmodel wrote this\n') bad.push('ensure-overwrote');
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS

case_begin "ensure-is-idempotent" "hooks/lib/progress-file.js"
expect "B7: ensure creates <rootSid>-session-progress.md from the template once and never overwrites it" "$(nj ensure.js)" "OK"
case_end

# update_count <sid> — the update-progress count in <sid>'s control file, or "none".
cat > "$TMP/count.js" <<'JS'
const fs = require('fs');
const path = require('path');
let j = {};
try { j = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, process.argv[2] + '.control', 'progress-pressure.json'), 'utf8')); } catch (e) { /* none */ }
const walk = (o) => { for (const [k, v] of Object.entries(o || {})) {
  if (/update.?progress/i.test(k) && typeof v === 'number') return v;
  if (v && typeof v === 'object') { const r = walk(v); if (r !== null) return r; } } return null; };
const n = walk(j);
process.stdout.write(n === null ? 'none' : String(n));
JS

case_begin "cli-path-and-ensure" "bin/progress-file"
seed c1; seed c2 c1
C_PATH="$(run_with_timeout 30 node "$CLI" path --session c2 2>&1)"
expect "B8: path exits 0" "$?" "0"
expect "B8: path prints the root generation's session-progress.md" "$(np "$C_PATH")" "$(np "$WORKFLOW_PLANS_DIR/c1-session-progress.md")"
expect "B8: path does not create the file" "$([ -e "$WORKFLOW_PLANS_DIR/c1-session-progress.md" ] && echo created || echo absent)" "absent"
run_with_timeout 30 node "$CLI" ensure --session c2 >/dev/null 2>&1
expect "B9: ensure exits 0" "$?" "0"
expect "B9: ensure creates the file" "$([ -f "$WORKFLOW_PLANS_DIR/c1-session-progress.md" ] && echo created || echo absent)" "created"
printf '## Current state\nkept\n' > "$WORKFLOW_PLANS_DIR/c1-session-progress.md"
run_with_timeout 30 node "$CLI" ensure --session c2 >/dev/null 2>&1
expect "B9: a second ensure keeps the content" "$(cat "$WORKFLOW_PLANS_DIR/c1-session-progress.md")" "$(printf '## Current state\nkept')"
run_with_timeout 30 node "$CLI" ensure --session c2 --reason update-progress >/dev/null 2>&1
B10_A="$(nj count.js c2)"
run_with_timeout 30 node "$CLI" ensure --session c2 --reason update-progress >/dev/null 2>&1
B10_B="$(nj count.js c2)"
expect "B10: --reason update-progress counts one run each time" "$B10_A>$B10_B" "1>2"
run_with_timeout 30 node "$CLI" path --session 'bad/sid' >/dev/null 2>&1
B11_RC=$?
expect "B11: an invalid sid is a usage error, not a path" "$([ "$B11_RC" -ne 0 ] && echo refused || echo accepted)" "refused"
case_end

# ensure_refuses <label> <sid> [plans dir] — ensure must exit nonzero and print no path on stdout
# (stdout carrying a path is the success report the skill trusts).
ensure_refuses() {
  local out rc
  out="$(env WORKFLOW_PLANS_DIR="${3:-$WORKFLOW_PLANS_DIR}" bash "$RWT" 30 node "$CLI" ensure --session "$2" 2>/dev/null)"
  rc=$?
  expect "$1: ensure exits nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo "zero")" "nonzero"
  expect "$1: ensure prints no success path" "${out:-<none>}" "<none>"
}

case_begin "cli-ensure-refuses-unwritable-target" "bin/progress-file"
seed d1
mkdir -p "$WORKFLOW_PLANS_DIR/d1-session-progress.md"
ensure_refuses "B12: the target path is a directory" d1
expect "B12: the directory is left as it was" "$([ -d "$WORKFLOW_PLANS_DIR/d1-session-progress.md" ] && echo dir || echo changed)" "dir"
seed u1
RO_PLANS="$TMP/ro-plans"
mkdir -p "$RO_PLANS"
chmod a-w "$RO_PLANS"
if ( : > "$RO_PLANS/.probe" ) 2>/dev/null; then
  rm -f "$RO_PLANS/.probe"
  skip "B13: the plans dir is unwritable — chmod a-w has no effect on this host (Windows ACLs)"
else
  ensure_refuses "B13: the plans dir is unwritable" u1 "$(np "$RO_PLANS")"
  expect "B13: nothing is created in the unwritable dir" "$(ls -A "$RO_PLANS")" ""
fi
chmod u+w "$RO_PLANS"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
