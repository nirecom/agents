# s-sentinel-wiring.sh — S1-S2 + P1-P2: the wiring layer of the background-work
# primitive — the settings.json permission entries that let the sentinels be
# emitted at all, and table-driven match tests for the regexes added to
# hooks/lib/sentinel-patterns.js.
# Sourced by tests/feature-1794-stop-guard-exemptions.sh.

SETTINGS_JSON="$_AGENTS_DIR_NODE/settings.json"

# ---------------------------------------------------------------------------
# S1: settings.json carries a permission entry for every new sentinel, on the
#     correct list. START/declare sentinels open a quiet window and therefore
#     need user approval (`ask`); END sentinels only restore the loud default
#     and are auto-approved (`allow`). A missing entry means the sentinel is
#     unusable in practice even though every hook-side test passes.
# ---------------------------------------------------------------------------
run_S1() {
    local out
    out=$("$RWT" 15 node -e "
const s = require('$SETTINGS_JSON');
const allow = s.permissions.allow || [];
const ask = s.permissions.ask || [];
const rule = (n) => 'Bash(echo \"<<WORKFLOW_' + n + ': *>>\")';
const problems = [];
// START/declare -> ask, and never on allow
for (const n of ['BACKGROUND_WORK_START']) {
  if (!ask.includes(rule(n))) problems.push(n + ':missing-from-ask');
  if (allow.includes(rule(n))) problems.push(n + ':wrongly-on-allow');
}
// END -> allow, and never on ask
for (const n of ['BACKGROUND_WORK_END']) {
  if (!allow.includes(rule(n))) problems.push(n + ':missing-from-allow');
  if (ask.includes(rule(n))) problems.push(n + ':wrongly-on-ask');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "S1: settings.json asks for BACKGROUND_WORK_START and auto-allows the END form"
    else
        fail "S1: permission entries wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# S2: symmetry with the pre-existing quiet-layer siblings (CPR-5) — the new
#     rows follow the exact same START=ask / END=allow shape as
#     NEXT_STEP_PAUSE / NEXT_STEP_RESUME and ENFORCE_WORKFLOW_OFF / _ON, and
#     none of the four new rules is duplicated across lists.
# ---------------------------------------------------------------------------
run_S2() {
    local out
    out=$("$RWT" 15 node -e "
const s = require('$SETTINGS_JSON');
const allow = s.permissions.allow || [];
const ask = s.permissions.ask || [];
const deny = s.permissions.deny || [];
const rule = (n) => 'Bash(echo \"<<WORKFLOW_' + n + ': *>>\")';
const problems = [];
// the sibling quiet-layer pairs this feature was modelled on
if (!ask.includes(rule('NEXT_STEP_PAUSE'))) problems.push('sibling-pause-not-ask');
if (!allow.includes(rule('NEXT_STEP_RESUME'))) problems.push('sibling-resume-not-allow');
if (!ask.includes(rule('ENFORCE_WORKFLOW_OFF'))) problems.push('sibling-off-not-ask');
if (!allow.includes(rule('ENFORCE_WORKFLOW_ON'))) problems.push('sibling-on-not-allow');
// no duplicates, and nothing denied
for (const n of ['BACKGROUND_WORK_START', 'BACKGROUND_WORK_END']) {
  const r = rule(n);
  const hits = allow.filter((x) => x === r).length + ask.filter((x) => x === r).length;
  if (hits !== 1) problems.push(n + ':listed-' + hits + '-times');
  if (deny.includes(r)) problems.push(n + ':on-deny');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "S2: the new entries mirror the NEXT_STEP_PAUSE/RESUME and WORKFLOW_OFF/ON shape and are listed exactly once"
    else
        fail "S2: permission-entry symmetry broken; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# P1: table-driven match matrix for the new patterns
#     (test-design/parser-regex-tests.md). Each row is
#     [command, strict-expected, lookslike-expected] and is checked against the
#     named RE_DQ / LOOKSLIKE_RE pair directly, so a pattern that over-matches
#     (e.g. drops the trailing quote anchor) fails on the negative rows rather
#     than passing unnoticed on the positive ones.
# ---------------------------------------------------------------------------
run_P1() {
    local out
    out=$("$RWT" 20 node -e "
const p = require('$PATTERNS_NODE');
const groups = [
  ['BACKGROUND_WORK_START', p.BACKGROUND_WORK_START_RE_DQ, p.BACKGROUND_WORK_START_LOOKSLIKE_RE],
  ['BACKGROUND_WORK_END', p.BACKGROUND_WORK_END_RE_DQ, p.BACKGROUND_WORK_END_LOOKSLIKE_RE],
];
const problems = [];
for (const [name, strictRe, looseRe] of groups) {
  if (!strictRe || !looseRe) { problems.push(name + ':pattern-missing'); continue; }
  const e = (body) => 'echo \"<<WORKFLOW_' + name + body + '>>\"';
  const rows = [
    // [command, strict, lookslike]
    [e(': waiting on a long build'), true, true],
    [e(': ok'), true, true],
    [e(': multi word reason with 123 digits'), true, true],
    [e(''), false, true],                       // reasonless bare form
    [e(': '), false, true],                     // colon but empty reason (space only is [^>]+ ... see below)
    [e(' no colon'), false, true],              // space-separated, not the ': ' form
    ['echo \"<<WORKFLOW_' + name + ': x>>', false, false],        // missing closing quote
    ['echo \"<<WORKFLOW_' + name + ': x>>\" ', false, false],     // trailing space (anchors)
    [' echo \"<<WORKFLOW_' + name + ': x>>\"', false, false],     // leading space (anchors)
    ['echo \"<<WORKFLOW_' + name + 'X: x>>\"', false, false],     // name prefix, different sentinel
    ['echo \\'<<WORKFLOW_' + name + ': x>>\\'', false, false],    // single-quoted form is not the DQ form
    ['printf \"<<WORKFLOW_' + name + ': x>>\"', false, false],    // not an echo
    // '>' inside the reason: strict rejects it ([^>]+), LOOKSLIKE still reports it
    ['echo \"<<WORKFLOW_' + name + ': re>ason>>\"', false, true],
    ['# echo \"<<WORKFLOW_' + name + ': x>>\"', false, false],    // commented out
    ['', false, false],
  ];
  for (const [cmd, wantStrict, wantLoose] of rows) {
    const gotStrict = strictRe.test(cmd);
    const gotLoose = looseRe.test(cmd);
    if (gotStrict !== wantStrict) problems.push(name + ' strict[' + cmd + ']=' + gotStrict);
    if (gotLoose !== wantLoose) problems.push(name + ' loose[' + cmd + ']=' + gotLoose);
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "P1: the new sentinel patterns match the positive table and reject every negative row"
    else
        fail "P1: sentinel pattern match matrix wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# P2: the same table lifted to the public predicates. isSentinel() must cover
#     both strict and LOOKSLIKE forms (that is what makes a malformed sentinel
#     reportable at all), isStrictSentinel() only the strict ones, and neither
#     may fire on the negative rows. Also pins the sibling-name boundary:
#     BACKGROUND_WORK_END must not be swallowed by the START pattern.
# ---------------------------------------------------------------------------
run_P2() {
    local out
    out=$("$RWT" 20 node -e "
const p = require('$PATTERNS_NODE');
const problems = [];
const strictOk = [
  'echo \"<<WORKFLOW_BACKGROUND_WORK_START: monitoring a subagent>>\"',
  'echo \"<<WORKFLOW_BACKGROUND_WORK_END: dispatch finished>>\"',
];
const looseOnly = [
  'echo \"<<WORKFLOW_BACKGROUND_WORK_START>>\"',
  'echo \"<<WORKFLOW_BACKGROUND_WORK_END>>\"',
];
const neither = [
  'echo \"<<WORKFLOW_BACKGROUND_WORK: x>>\"',
  'echo \"<<BACKGROUND_WORK_START: x>>\"',
  'git commit -m \"background work start\"',
  'echo hello',
];
for (const c of strictOk) {
  if (!p.isSentinel(c)) problems.push('isSentinel-miss[' + c + ']');
  if (!p.isStrictSentinel(c)) problems.push('isStrict-miss[' + c + ']');
}
for (const c of looseOnly) {
  if (!p.isSentinel(c)) problems.push('isSentinel-miss-loose[' + c + ']');
  if (p.isStrictSentinel(c)) problems.push('isStrict-overmatch[' + c + ']');
}
for (const c of neither) {
  if (p.isSentinel(c)) problems.push('isSentinel-overmatch[' + c + ']');
  if (p.isStrictSentinel(c)) problems.push('isStrict-overmatch[' + c + ']');
}
// sibling-name boundary: the _END command must not match the START/declare pattern
if (p.BACKGROUND_WORK_START_RE_DQ.test('echo \"<<WORKFLOW_BACKGROUND_WORK_END: done>>\"')) {
  problems.push('BACKGROUND_WORK_START-swallows-END');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "P2: isSentinel/isStrictSentinel classify the new forms correctly and keep the sibling-name boundary"
    else
        fail "P2: sentinel predicate classification wrong; got '${out:-<err>}'"
    fi
}
