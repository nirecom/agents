#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/postuse-decide.sh
# Tests: hooks/postuse-shell-snapshot-repair/session-check.js
# Tags: hook, shell-snapshot, posttooluse, decide, scope:issue-specific, TL1
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# The decide table row by row (with the failedCommandExit127 column), isExit127Failure's true and
# false rows, the session-id guard, and that decide never loads the repair lib.

snap_js "decide" <<'JS'
const S = () => load('hooks/postuse-shell-snapshot-repair/session-check.js');
let n = 0;
const sid = () => 'decide-sid-' + (++n);
function withMarker(id) {
  const p = S().markerPathFor(id);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify({ version: 1, checked_at: new Date().toISOString(), trigger: 'first', results: [] }));
  return id;
}
const ev = (event, id, extra = {}) => Object.assign({ hook_event_name: event, session_id: id, tool_name: 'Bash', tool_input: { command: 'true' } }, extra);
const fail127 = { error: 'Exit code 127\n/usr/bin/bash: line 1: foo: command not found' };
const fail1 = { error: 'Exit code 1\nboom' };
const dec = (input) => S().decide(input, { now: Date.now() });
const expectRow = (input, action, f127) => {
  const r = dec(input);
  assert.equal(r.action, action, JSON.stringify(r));
  if (action !== 'skip') {
    assert.equal(r.failedCommandExit127, f127);
    assert.equal(r.event, input.hook_event_name);
  }
};

T('row: session_id missing -> skip', () => expectRow(ev('PostToolUse', undefined), 'skip'));
for (const bad of ['..', '../x', 'a/b', 'a\\b', '.hidden', '']) {
  T('row: session_id ' + JSON.stringify(bad) + ' -> skip', () => expectRow(ev('PostToolUseFailure', bad, fail127), 'skip'));
}
for (const tool of ['runInTerminal', 'runCommands', 'Edit']) {
  T('row: tool_name ' + tool + ' -> skip', () => expectRow(ev('PostToolUseFailure', sid(), Object.assign({ tool_name: tool }, fail127)), 'skip'));
}
T('row: PostToolUse, marker present -> skip', () => expectRow(ev('PostToolUse', withMarker(sid())), 'skip'));
T('row: PostToolUse, marker absent -> first (false)', () => expectRow(ev('PostToolUse', sid()), 'first', false));
T('row: PostToolUseFailure interrupted -> skip', () => expectRow(ev('PostToolUseFailure', sid(), Object.assign({ is_interrupt: true }, fail127)), 'skip'));
T('row: PostToolUseFailure exit 127, marker absent -> first (true)', () => expectRow(ev('PostToolUseFailure', sid(), fail127), 'first', true));
T('row: PostToolUseFailure other error, marker absent -> first (false)', () => expectRow(ev('PostToolUseFailure', sid(), fail1), 'first', false));
T('row: PostToolUseFailure exit 127, marker present -> recheck (true)', () => expectRow(ev('PostToolUseFailure', withMarker(sid()), fail127), 'recheck', true));
T('row: PostToolUseFailure other error, marker present -> skip', () => expectRow(ev('PostToolUseFailure', withMarker(sid()), fail1), 'skip'));
for (const other of ['PreToolUse', 'SessionStart', 'Stop']) {
  T('row: event ' + other + ' -> skip', () => expectRow(ev(other, sid(), fail127), 'skip'));
}

const X = (input) => S().isExit127Failure(input);
const F = (extra) => Object.assign({ hook_event_name: 'PostToolUseFailure', session_id: 's', tool_name: 'Bash' }, extra);
T('isExit127Failure true: Exit code 127 first line', () => assert.equal(X(F(fail127)), true));
T('isExit127Failure true: CRLF first line', () => assert.equal(X(F({ error: 'Exit code 127\r\nx' })), true));
T('isExit127Failure true: exactly "Exit code 127"', () => assert.equal(X(F({ error: 'Exit code 127' })), true));
const FALSE_ROWS = [
  ['PostToolUse event', { hook_event_name: 'PostToolUse', error: 'Exit code 127' }],
  ['is_interrupt true', { is_interrupt: true, error: 'Exit code 127' }],
  ['error not a string', { error: { code: 127 } }],
  ['error missing', {}],
  ['Exit code 1', { error: 'Exit code 1' }],
  ['Exit code 126', { error: 'Exit code 126' }],
  ['Exit code 1270', { error: 'Exit code 1270' }],
  ['no Exit code on first line', { error: 'command not found: 127' }],
  ['Exit code 127 on the second line', { error: 'boom\nExit code 127' }],
];
for (const [label, extra] of FALSE_ROWS) T('isExit127Failure false: ' + label, () => assert.equal(X(F(extra)), false));

T('constants: MAIN_PATH_MAX_REPAIRS 5, FALLBACK_WINDOW_MS 15 min', () => {
  assert.equal(S().MAIN_PATH_MAX_REPAIRS, 5);
  assert.equal(S().FALLBACK_WINDOW_MS, 900000);
});
T('exports: selectFirstCandidate and RECHECK_MAX_REPAIRS are gone (first and recheck share scanAndRepair)', () => {
  assert.equal(S().selectFirstCandidate, undefined);
  assert.equal(S().RECHECK_MAX_REPAIRS, undefined);
});
T('markerPathFor lands under WORKFLOW_STATE_DIR and ends with <sid>.shell-snapshot-checked', () => {
  const p = S().markerPathFor('abc-1');
  assert.equal(path.basename(p), 'abc-1.shell-snapshot-checked');
  const rel = path.relative(path.resolve(process.env.WORKFLOW_STATE_DIR), path.resolve(p));
  assert.ok(rel && !rel.startsWith('..') && !path.isAbsolute(rel), p);
});
JS

snap_js "decide-no-repair-lib" <<'JS'
T('decide does not load shell-snapshot-repair.js', () => {
  const S = load('hooks/postuse-shell-snapshot-repair/session-check.js');
  S.decide({ hook_event_name: 'PostToolUse', session_id: 'nolib-1', tool_name: 'Bash', tool_input: { command: 'true' } }, { now: Date.now() });
  const loaded = Object.keys(require.cache).filter((k) => /\/lib\/shell-snapshot-repair\.js$/.test(k.replace(/\\/g, '/')));
  assert.deepEqual(loaded, []);
});
JS
