#!/usr/bin/env bash
# tests/feat-2218-handoff-artifact.sh
# Tests: hooks/lib/handoff-artifact.js, bin/workflow/handoff-append
# Tags: handoff, handoff-artifact, plans-dir, append-only, latest-wins, regression-2218, scope:issue-specific, pwsh-not-required, TL2

# Issue #2218 Steps 1-2 — the handoff artifact is the writer/reader contract for step micro-state. Real files under a pinned PLANS_DIR, real CLI subprocess: a unit test with a mocked fs cannot catch an append that lands in the wrong file, an overflow that deletes history, or a CLI default that resolves wsid instead of sid (detail.md round1-fix C1/C6).

# TL3 gap: the three real writer call sites (workflow-gate block(), post-compact, skill-issued CLI) firing inside a live Claude Code session are not exercised here — only the shared appendHandoffEntry seam they all pass through. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

# TDD (write_code has not run): every case is expected to FAIL with "MODULE NOT FOUND: hooks/lib/handoff-artifact.js" until Step 2 is implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

TARGET="hooks/lib/handoff-artifact.js"
CLI="bin/workflow/handoff-append"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218, not yet implemented (write_code has not run)"
    return 1
}

# Every node case runs against a private PLANS_DIR. WORKFLOW_PLANS_DIR and
# CLAUDE_WORKFLOW_DIR are dual-pinned per rules/test/fixture-isolation.md.
run_node() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "$1" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# H1 — getHandoffPath: <PLANS_DIR>/<sid>-handoff.md, and an sid that would
# escape PLANS_DIR is rejected by assertValidSessionId (path-traversal guard).
run_H1() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const path = require('path');
const { getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const { getWorkflowPlansDir } = require('$AGENTS_DIR_NODE/hooks/lib/workflow-plans-dir');
const problems = [];
const got = getHandoffPath('sess-h1');
const want = path.join(getWorkflowPlansDir(), 'sess-h1-handoff.md');
if (got !== want) problems.push('path:want=' + want + ',got=' + String(got));
for (const bad of ['../escape', 'a/b', '', null]) {
  let threw = false;
  try { getHandoffPath(bad); } catch (e) { threw = true; }
  if (!threw) problems.push('accepted-invalid-sid:' + JSON.stringify(bad));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H1: getHandoffPath resolves <PLANS_DIR>/<sid>-handoff.md and rejects traversal-shaped sids"
    else
        fail "H1: expected 'OK', got '${out:-<err>}'"
    fi
}

# H2 — the three writer origins land in one file under their class heading, and
# each line parses as the 6-field entry grammar from detail.md Step 1.
run_H2() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const { appendHandoffEntry, getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const sid = 'sess-h2';
const problems = [];
const origins = ['step-end', 'gate-block', 'flush'];
origins.forEach((origin, i) => {
  const r = appendHandoffEntry(sid, { cls: 'D', step: 'write_tests', key: 'k' + i, summary: 'observation ' + i, pointer: '-', origin });
  if (!r || r.written !== true || r.reason !== 'ok') problems.push(origin + ':' + JSON.stringify(r));
});
const raw = fs.readFileSync(getHandoffPath(sid), 'utf8');
const lines = raw.split('\n');
const entryLines = lines.filter((l) => l.startsWith('- '));
if (entryLines.length !== 3) problems.push('entry-line-count:' + entryLines.length);
if (lines.filter((l) => l.trim() === '## D').length !== 1) problems.push('missing-or-duplicated-class-heading');
if (raw.indexOf('handoff_schema_version: 1') === -1) problems.push('missing-schema-version-meta');
entryLines.forEach((line, i) => {
  const fields = line.split('|').map((s) => s.trim());
  if (fields.length !== 6) { problems.push('field-count[' + i + ']:' + fields.length); return; }
  const at = fields[0].replace(/^- /, '');
  if (at.indexOf('T') === -1 || isNaN(Date.parse(at))) problems.push('at-not-iso8601[' + i + ']:' + at);
  if (origins.indexOf(fields[1]) === -1) problems.push('origin-not-in-vocabulary[' + i + ']:' + fields[1]);
  if (fields[2] !== 'write_tests') problems.push('step[' + i + ']:' + fields[2]);
  if (fields[5] !== '-') problems.push('pointer[' + i + ']:' + fields[5]);
});
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H2: step-end / gate-block / flush all append 6-field entry lines under the class heading"
    else
        fail "H2: expected 'OK', got '${out:-<err>}'"
    fi
}

# H3 — latest-wins (round1-fix C6). Same (class, step, key) appended twice with
# DIFFERENT content keeps both lines (append-only audit history), while
# renderHandoffForResume shows only the newest observation.
run_H3() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const { appendHandoffEntry, readHandoff, renderHandoffForResume, getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const sid = 'sess-h3';
const problems = [];
const base = { cls: 'D', step: 'run_tests', key: 'run-tests:flaky', pointer: '-', origin: 'step-end' };
const r1 = appendHandoffEntry(sid, Object.assign({}, base, { summary: 'first reason' }));
const r2 = appendHandoffEntry(sid, Object.assign({}, base, { summary: 'second reason' }));
if (!r1.written || r1.reason !== 'ok') problems.push('first:' + JSON.stringify(r1));
if (!r2.written || r2.reason !== 'ok') problems.push('second-not-appended:' + JSON.stringify(r2));
const raw = fs.readFileSync(getHandoffPath(sid), 'utf8');
if (raw.indexOf('first reason') === -1) problems.push('older-line-deleted');
if (raw.indexOf('second reason') === -1) problems.push('newer-line-missing');
const parsed = readHandoff(sid);
const entries = (parsed.entriesByClass && parsed.entriesByClass.D) || [];
if (entries.length !== 2) problems.push('entriesByClass-history:' + entries.length);
else if (entries[0].summary !== 'first reason' || entries[1].summary !== 'second reason') {
  problems.push('history-order:' + entries.map((e) => e.summary).join('/'));
} else {
  // Finding 4: the reader's full field vocabulary (class/step/key/pointer/origin),
  // not just summary, must round-trip — feat-2218-post-compact-writer.sh reads
  // all four of e.class/e.step/e.pointer/e.origin off exactly this shape.
  const newest = entries[1];
  if (newest.class !== base.cls) problems.push('roundtrip-class:' + JSON.stringify(newest.class));
  if (newest.step !== base.step) problems.push('roundtrip-step:' + JSON.stringify(newest.step));
  if (newest.key !== base.key) problems.push('roundtrip-key:' + JSON.stringify(newest.key));
  if (newest.pointer !== base.pointer) problems.push('roundtrip-pointer:' + JSON.stringify(newest.pointer));
  if (newest.origin !== base.origin) problems.push('roundtrip-origin:' + JSON.stringify(newest.origin));
}
const rendered = renderHandoffForResume(parsed, { maxEntries: 50 });
if (rendered.indexOf('second reason') === -1) problems.push('render-missing-newest');
if (rendered.indexOf('first reason') !== -1) problems.push('render-shows-superseded-observation');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H3: latest-wins — both observations kept in entriesByClass, only the newest rendered"
    else
        fail "H3: expected 'OK', got '${out:-<err>}'"
    fi
}

# H4 — noop-identical: a repeat of the LAST appended line with identical
# (class, step, key, summary, pointer) is skipped, so a repeatedly-firing writer
# does not inflate the artifact. A non-adjacent identical repeat is NOT a noop.
run_H4() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const { appendHandoffEntry, getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const sid = 'sess-h4';
const problems = [];
const e = { cls: 'C', step: 'review_tests', key: 'gate:block', summary: 'same reason', pointer: '-', origin: 'gate-block' };
appendHandoffEntry(sid, e);
const again = appendHandoffEntry(sid, e);
if (again.written !== false || again.reason !== 'noop-identical') problems.push('repeat:' + JSON.stringify(again));
const countAfter = fs.readFileSync(getHandoffPath(sid), 'utf8').split('\n').filter((l) => l.indexOf('same reason') !== -1).length;
if (countAfter !== 1) problems.push('duplicate-written:' + countAfter);
const other = appendHandoffEntry(sid, Object.assign({}, e, { summary: 'different reason' }));
if (!other.written) problems.push('changed-content-suppressed:' + JSON.stringify(other));
const back = appendHandoffEntry(sid, e);
if (back.written !== true) problems.push('non-adjacent-identical-suppressed:' + JSON.stringify(back));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H4: only an identical repeat of the last line is noop-identical; changed content always appends"
    else
        fail "H4: expected 'OK', got '${out:-<err>}'"
    fi
}

# H5 — overflow. At the 400-line / 64KB cap the writer refuses further appends
# and writes '## Overflow' exactly once; append-only means no earlier line is
# removed to make room.
run_H5() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const { appendHandoffEntry, getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const sid = 'sess-h5';
const problems = [];
let overflowSeen = 0;
let writtenCount = 0;
for (let i = 0; i < 600; i++) {
  const r = appendHandoffEntry(sid, { cls: 'A', step: 'write_code', key: 'k' + i, summary: 'entry number ' + i, pointer: '-', origin: 'flush' });
  if (r.written) writtenCount++;
  else if (r.reason === 'overflow') overflowSeen++;
  else problems.push('unexpected-reason[' + i + ']:' + JSON.stringify(r));
}
if (overflowSeen === 0) problems.push('cap-never-enforced:written=' + writtenCount);
if (writtenCount === 0) problems.push('nothing-written');
const raw = fs.readFileSync(getHandoffPath(sid), 'utf8');
const lines = raw.split('\n');
const overflowMarkers = lines.filter((l) => l.trim().indexOf('## Overflow') === 0);
if (overflowMarkers.length !== 1) problems.push('overflow-marker-count:' + overflowMarkers.length);
if (raw.indexOf('entry number 0') === -1) problems.push('oldest-entry-deleted');
if (lines.filter((l) => l.startsWith('- ')).length !== writtenCount) problems.push('line-count-drift:' + writtenCount);
if (Buffer.byteLength(raw, 'utf8') > 64 * 1024) problems.push('byte-cap-exceeded:' + Buffer.byteLength(raw, 'utf8'));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H5: overflow refuses appends, marks '## Overflow' once, and deletes nothing"
    else
        fail "H5: expected 'OK', got '${out:-<err>}'"
    fi
}

# H6 — the escaper's whole delimiter/structure-forgery class (finding 5), not
# just a lone '|'; table-driven per parser-regex-tests.md, covering newline/CR,
# heading/list forgery, double-escape, and empty fields, each checked for both
# a 6-field raw line and a byte-exact summary/pointer round-trip via readHandoff.
# Manual mutation probe: an identity (no-op) escaper fails 'pipe-in-summary'
# (unescapedFieldCount reads 8, not 6) and 'newline-in-summary' (an extra
# bare '- ' line appears) below — both are asserted, so the table is discriminating.
run_H6() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const { appendHandoffEntry, readHandoff, getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const BS = String.fromCharCode(92);
const NL = String.fromCharCode(10);
const CR = String.fromCharCode(13);
const sid = 'sess-h6';
const problems = [];
const cases = [
  { name: 'pipe-in-summary', summary: 'blocked by a | b | c', pointer: '-' },
  { name: 'newline-in-summary', summary: 'line one' + NL + 'line two', pointer: '-' },
  { name: 'cr-in-summary', summary: 'line one' + CR + 'line two', pointer: '-' },
  { name: 'newline-in-pointer', summary: 'ok', pointer: 'path/one' + NL + 'path/two' },
  { name: 'summary-forges-list-item', summary: '- forged entry line', pointer: '-' },
  { name: 'summary-forges-heading', summary: '## D forged heading', pointer: '-' },
  { name: 'already-escaped-pipe', summary: 'literal backslash-pipe: ' + BS + '|', pointer: '-' },
  { name: 'empty-summary', summary: '', pointer: '-' },
  { name: 'empty-pointer', summary: 'ok', pointer: '' },
];
cases.forEach((c, i) => {
  const key = 'esc-' + i;
  appendHandoffEntry(sid, { cls: 'E', step: 'commit_push', key, summary: c.summary, pointer: c.pointer, origin: 'step-end' });
  const raw = fs.readFileSync(getHandoffPath(sid), 'utf8');
  const entryLines = raw.split(NL).filter((l) => l.startsWith('- '));
  if (entryLines.length !== i + 1) problems.push(c.name + ':entry-line-count:' + entryLines.length + '(want ' + (i + 1) + ')');
  const line = entryLines[entryLines.length - 1] || '';
  const unescapedFieldCount = line.split(BS + '|').join('').split('|').length;
  if (unescapedFieldCount !== 6) problems.push(c.name + ':forged-field-boundary:' + unescapedFieldCount + ':' + line);
  const entries = (readHandoff(sid).entriesByClass || {}).E || [];
  const entry = entries.find((e) => e.key === key);
  if (!entry) problems.push(c.name + ':entry-not-found-on-readback');
  else {
    if (entry.summary !== c.summary) problems.push(c.name + ':roundtrip-summary:' + JSON.stringify(entry.summary) + '!=' + JSON.stringify(c.summary));
    if (entry.pointer !== c.pointer) problems.push(c.name + ':roundtrip-pointer:' + JSON.stringify(entry.pointer) + '!=' + JSON.stringify(c.pointer));
  }
});
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H6: the delimiter/structure-forgery class (pipes, newlines, CR, heading/list forgery, double-escape, empty fields) is escaped on write and round-trips through readHandoff"
    else
        fail "H6: expected 'OK', got '${out:-<err>}'"
    fi
}

# H7 — unknown handoff_schema_version: the reader never fails. It surfaces the
# raw document plus exactly one warning line, so a newer writer's artifact stays
# readable by an older reader.
run_H7() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const path = require('path');
const { readHandoff, renderHandoffForResume, getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const sid = 'sess-h7';
const problems = [];
const p = getHandoffPath(sid);
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, ['# Handoff — ' + sid, '', 'handoff_schema_version: 999', '', '## B', '- 2026-01-01T00:00:00.000Z | flush | detail | future:key | from a newer writer | -', ''].join('\n'), 'utf8');
let parsed;
try { parsed = readHandoff(sid); } catch (e) { process.stdout.write('BAD:reader-threw:' + e.message); return; }
if (parsed.exists !== true) problems.push('exists:' + String(parsed.exists));
if (String(parsed.schemaVersion) !== '999') problems.push('schemaVersion:' + String(parsed.schemaVersion));
if (!parsed.raw || parsed.raw.indexOf('from a newer writer') === -1) problems.push('raw-not-preserved');
let rendered;
try { rendered = renderHandoffForResume(parsed, { maxEntries: 50 }); } catch (e) { process.stdout.write('BAD:render-threw:' + e.message); return; }
if (rendered.indexOf('from a newer writer') === -1) problems.push('render-dropped-raw');
const warnLines = rendered.split('\n').filter((l) => l.toLowerCase().indexOf('schema') !== -1);
if (warnLines.length !== 1) problems.push('warning-line-count:' + warnLines.length);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H7: unknown handoff_schema_version presents raw content with exactly one warning line"
    else
        fail "H7: expected 'OK', got '${out:-<err>}'"
    fi
}

# H8 — absent artifact and unwritable PLANS_DIR are both normal (detail.md
# Risks #9/#10): the reader reports exists:false and the writer refuses without
# throwing, so a side-effect writer can never break its caller.
run_H8() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const path = require('path');
const { readHandoff, appendHandoffEntry, getHandoffPath } = require('$AGENTS_DIR_NODE/$TARGET');
const problems = [];
let missing;
try { missing = readHandoff('sess-h8-absent'); } catch (e) { process.stdout.write('BAD:reader-threw-on-absent:' + e.message); return; }
if (missing.exists !== false) problems.push('absent-exists:' + String(missing.exists));
const sid = 'sess-h8';
const p = getHandoffPath(sid);
fs.mkdirSync(p, { recursive: true });
let r;
try { r = appendHandoffEntry(sid, { cls: 'A', step: '-', key: 'k', summary: 's', pointer: '-', origin: 'flush' }); }
catch (e) { process.stdout.write('BAD:writer-threw:' + e.message); return; }
if (r.written !== false) problems.push('claimed-written-on-unwritable-target:' + JSON.stringify(r));
for (const bad of [{ cls: 'Z', step: 'detail', key: 'k', summary: 's', pointer: '-', origin: 'flush' },
                   { cls: 'A', step: 'not_a_step', key: 'k', summary: 's', pointer: '-', origin: 'flush' },
                   { cls: 'A', step: 'detail', key: 'BAD KEY', summary: 's', pointer: '-', origin: 'flush' },
                   { cls: 'A', step: 'detail', key: 'k', summary: 's', pointer: '-', origin: 'not-an-origin' }]) {
  let rr;
  try { rr = appendHandoffEntry('sess-h8-valid', bad); } catch (e) { problems.push('threw-on-invalid:' + e.message); continue; }
  if (rr.written !== false || rr.reason !== 'invalid') problems.push('invalid-accepted:' + JSON.stringify(bad) + '->' + JSON.stringify(rr));
}
// H8b (finding 2, CWE-22): a hostile session id must never let
// appendHandoffEntry compose a path outside PLANS_DIR. Every other
// sid-keyed path builder in hooks/workflow-state/state-io/core.js goes
// through SESSION_ID_VALID_RE (/^[A-Za-z0-9_-]+\$/) — this writer is a
// sibling path builder and must reject the same shapes (CPR-ORTH).
const plansDir = path.dirname(getHandoffPath('sess-h8-plansdir-probe'));
const escapeCandidate = path.join(plansDir, '..', '..', 'evil-handoff.md');
for (const badSid of ['../../evil', 'a/b', '..', '', 'C:\\\\tmp\\\\x', 42]) {
  let rr;
  let threw = false;
  try { rr = appendHandoffEntry(badSid, { cls: 'A', step: 'detail', key: 'k', summary: 's', pointer: '-', origin: 'flush' }); }
  catch (e) { threw = true; }
  if (!threw && (!rr || rr.written !== false || rr.reason !== 'invalid')) {
    problems.push('hostile-sid-accepted:' + JSON.stringify(badSid) + '->' + JSON.stringify(rr));
  }
  if (fs.existsSync(escapeCandidate)) problems.push('hostile-sid-escaped-plans-dir:' + JSON.stringify(badSid));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "H8: absent artifact reads exists:false; unwritable target, invalid fields, and hostile session ids all refuse without escaping PLANS_DIR"
    else
        fail "H8: expected 'OK', got '${out:-<err>}'"
    fi
}

# H9 — the CLI wrapper. --session defaults to resolveSessionId() (CC-native
# sid), NOT resolveWorkflowSessionId(): when the two diverge, a wsid default
# makes writer and reader look at different files (round1-fix C1).
run_H9() {
    require_module "$CLI" || return 0
    local tmp tn out rc
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/wf" "$tmp/home"
    # A decoy wsid-shaped artifact: if the CLI defaulted to the PLANS_DIR file
    # prefix heuristic it would append here instead of to the CC-native sid.
    printf '# decoy\n' > "$tmp/wf/wsid-decoy-intent.md"
    out=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="cli-sid-h9" \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node "$AGENTS_DIR/$CLI" --class E --step write_tests --key write-tests:not-needed --summary "no test surface" --pointer - --origin step-end 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "H9: CLI exited $rc (expected 0). Output: ${out:-<empty>}"
    elif [ ! -f "$tmp/wf/cli-sid-h9-handoff.md" ]; then
        fail "H9: expected $tmp/wf/cli-sid-h9-handoff.md (--session default must be resolveSessionId(), not wsid)"
    elif ! grep -q "no test surface" "$tmp/wf/cli-sid-h9-handoff.md"; then
        fail "H9: entry not appended to the sid-named artifact"
    elif [ -f "$tmp/wf/wsid-decoy-handoff.md" ]; then
        fail "H9: CLI wrote to a wsid-derived artifact — --session default resolved the wrong session id"
    else
        pass "H9: handoff-append defaults --session to the CC-native sid and appends there"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# H10 — the CLI validates before it writes: an unknown --origin is rejected with
# a non-zero exit and no artifact is created.
run_H10() {
    require_module "$CLI" || return 0
    local tmp tn out rc
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/wf" "$tmp/home"
    out=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="cli-sid-h10" \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node "$AGENTS_DIR/$CLI" --class E --step write_tests --key k --summary s --pointer - --origin bogus-origin 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "H10: CLI accepted --origin bogus-origin (expected non-zero exit). Output: ${out:-<empty>}"
    elif [ -f "$tmp/wf/cli-sid-h10-handoff.md" ]; then
        fail "H10: CLI created an artifact despite rejecting the arguments"
    else
        pass "H10: handoff-append rejects an out-of-vocabulary --origin without writing"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# H11 — CLI-level path traversal (finding 2, CWE-22): a hostile --session
# value must be rejected before any artifact write, exactly like an unknown
# --origin (H10). No file may appear either at the hostile-composed path or
# escaping PLANS_DIR.
run_H11() {
    require_module "$CLI" || return 0
    local tmp tn out rc
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/wf" "$tmp/home"
    out=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="unused-h11" \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node "$AGENTS_DIR/$CLI" --session "../../evil" --class E --step write_tests --key k --summary s --pointer - --origin step-end 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "H11: CLI accepted a path-traversal --session (expected non-zero exit). Output: ${out:-<empty>}"
    elif [ -f "$tmp/evil-handoff.md" ]; then
        fail "H11: CLI escaped PLANS_DIR and wrote $tmp/evil-handoff.md"
    elif [ -n "$(find "$tmp/wf" -name '*handoff.md' 2>/dev/null)" ]; then
        fail "H11: CLI created an artifact inside PLANS_DIR despite the hostile --session"
    else
        pass "H11: handoff-append rejects a path-traversal --session without writing anywhere"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

run_H1
run_H2
run_H3
run_H4
run_H5
run_H6
run_H7
run_H8
run_H9
run_H10
run_H11

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
