# f-skill-name.sh — F1/F2: the skillNameOf / isMetaOpDispatch boundary tables.
# Sourced by tests/hooks/feature-2013-step-in-flight-automark.sh.
# Tests: hooks/lib/step-in-flight-policy.js
# Tags: step-in-flight, skill-dispatch, resume-session, policy, table-driven, malformed-input, regression-2279, scope:issue-specific, pwsh-not-required, TL1

# skillNameOf is the seam between a payload Claude Code owns and a policy
# decision that must not fire by accident. B13-B21 exercise it through the hook
# for a handful of spellings; these tables exercise the function itself over the
# whole input domain (CPR-UNV), because a total function that silently returns
# the WRONG name is how a non-meta skill would get excluded from #2013's mark.

# `<null>` in the want column means the function returned null.
_f_name_rows() {
    cat <<'EOF'
# label             | input expression                | skillNameOf
bare                | 'resume-session'                | resume-session
namespaced          | 'ns:resume-session'             | resume-session
path                | 'skills/resume-session'         | resume-session
path-and-namespace  | 'a/b:resume-session'            | resume-session
leading-colon       | ':resume-session'               | resume-session
surrounding-space   | '  resume-session  '            | resume-session
mixed-case          | 'Resume-Session'                | Resume-Session
trailing-slash      | 'resume-session/'               | <null>
trailing-colon      | 'resume-session:'               | <null>
empty-string        | ''                              | <null>
whitespace-only     | '   '                           | <null>
null                | null                            | <null>
undefined           | undefined                       | <null>
number              | 42                              | <null>
array               | ['resume-session']              | <null>
tool-input-object   | ({ skill: 'ns:resume-session' }) | resume-session
tool-input-no-skill | ({ description: 'x' })          | <null>
tool-input-bad-type | ({ skill: 7 })                  | <null>
tab-and-newline     | '\tresume-session\n'            | resume-session
inner-space         | 'resume session'                | resume session
double-colon        | 'a:b:resume-session'            | resume-session
deep-path           | 'x/y/z/resume-session'          | resume-session
space-after-colon   | 'ns:  resume-session'           | resume-session
windows-separator   | 'skills\\resume-session'        | resume-session
tool-input-array2   | ([{ skill: 'resume-session' }]) | <null>
EOF
}

# `new Function` rather than JSON, because `undefined` and a bare identifier are
# part of the input domain and JSON cannot express them.
run_F1() {
    local out
    out=$(ROWS="$(_f_name_rows)" "$RWT" 20 node -e "
const P = require('$POLICY_NODE');
const bad = [];
let seen = 0;
for (const line of String(process.env.ROWS).split(/\r?\n/)) {
  const t = line.trim();
  if (!t || t.charAt(0) === '#') continue;
  const [label, expr, want] = t.split('|').map((x) => x.trim());
  let input;
  try { input = new Function('return (' + expr + ');')(); }
  catch (e) { bad.push(label + ':unusable-fixture-expression'); continue; }
  let got;
  try { got = P.skillNameOf(input); }
  catch (e) { bad.push(label + ':threw:' + e.message); continue; }
  const norm = got === null ? '<null>' : (typeof got === 'string' ? got : '<' + typeof got + '>');
  if (norm !== want) bad.push(label + ':' + JSON.stringify(got) + '(want ' + want + ')');
  seen++;
}
// The OK token, not silence, is the pass signal: a require that throws would
// print nothing and an emptiness test would read that as a clean table.
if (seen !== 25) bad.push('rows-evaluated=' + seen + '(want 25)');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "F1: skillNameOf normalizes every namespaced/path/whitespace spelling — POSIX and Windows separators, never a throw, never a partial string — and returns null for all 9 unusable input classes"
    else
        fail "F1: skillNameOf disagrees with the boundary table; $out"
    fi
}

# F2 is the consumer's side of the same table. skillNameOf deliberately does NOT
# lowercase (F1's mixed-case row), so the case-insensitive comparison lives in
# isMetaOpDispatch alone — and a fix that moved the .toLowerCase() into
# skillNameOf would pass F2 while quietly changing what F1 returns to callers.
_f_dispatch_rows() {
    cat <<'EOF'
# label             | tool     | input expression                | meta-op?
skill-bare          | Skill    | 'resume-session'                | true
skill-namespaced    | Skill    | 'personal:resume-session'       | true
skill-path          | Skill    | 'skills/resume-session'         | true
skill-mixed-case    | Skill    | 'Resume-Session'                | true
skill-upper-ns      | Skill    | 'NS:RESUME-SESSION'             | true
skill-object        | Skill    | ({ skill: 'resume-session' })   | true
skill-other         | Skill    | 'review-tests'                  | false
skill-substring     | Skill    | 'resume-session-helper'         | false
skill-trailing      | Skill    | 'resume-session:'               | false
skill-empty         | Skill    | ''                              | false
skill-null          | Skill    | null                            | false
agent-tool          | Agent    | 'resume-session'                | false
task-tool           | Task     | 'resume-session'                | false
bash-tool           | Bash     | 'resume-session'                | false
no-tool-name        | -        | 'resume-session'                | false
EOF
}

run_F2() {
    local out
    out=$(ROWS="$(_f_dispatch_rows)" "$RWT" 20 node -e "
const P = require('$POLICY_NODE');
const bad = [];
let seen = 0;
for (const line of String(process.env.ROWS).split(/\r?\n/)) {
  const t = line.trim();
  if (!t || t.charAt(0) === '#') continue;
  const [label, tool, expr, want] = t.split('|').map((x) => x.trim());
  let input;
  try { input = new Function('return (' + expr + ');')(); }
  catch (e) { bad.push(label + ':unusable-fixture-expression'); continue; }
  let got;
  try { got = P.isMetaOpDispatch(tool === '-' ? undefined : tool, input); }
  catch (e) { bad.push(label + ':threw:' + e.message); continue; }
  if (String(got) !== want) bad.push(label + ':' + String(got) + '(want ' + want + ')');
  seen++;
}
if (seen !== 15) bad.push('rows-evaluated=' + seen + '(want 15)');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "F2: isMetaOpDispatch matches resume-session case-insensitively for the Skill tool only — never on a substring, never on another dispatch tool"
    else
        fail "F2: isMetaOpDispatch disagrees with the boundary table; $out"
    fi
}

# F3 is the TOOL-NAME axis of the same seam. F2 varies the skill name over a
# fixed set of well-formed tool names; the tool name is the other half Claude
# Code owns, and the exclusion is deliberately case-SENSITIVE there (the exact
# tool identifier) while the skill name is not. Nothing pinned that asymmetry,
# so a normalizing .toLowerCase() on the tool name would pass F1/F2 and start
# excluding a tool the policy never named.

# The skill is always exactly 'resume-session', so a row can only turn on the
# tool. isLookaheadDispatchTool / isDispatchTool ride the same row: all three
# read a caller-supplied tool name, and a non-string must not throw in any.
_f_tool_rows() {
    cat <<'EOF'
# label            | tool expression | meta-op? | lookahead? | dispatch?
exact              | 'Skill'         | true     | false      | true
lowercase          | 'skill'         | false    | false      | false
uppercase          | 'SKILL'         | false    | false      | false
padded             | ' Skill '       | false    | false      | false
newline-padded     | 'Skill\n'       | false    | false      | false
agent              | 'Agent'         | false    | true       | true
task               | 'Task'          | false    | true       | true
task-lowercase     | 'task'          | false    | false      | false
empty              | ''              | false    | false      | false
number             | 42              | false    | false      | false
null               | null            | false    | false      | false
undefined          | undefined       | false    | false      | false
array              | ['Skill']       | false    | false      | false
object             | ({ name: 'Skill' }) | false | false     | false
EOF
}

run_F3() {
    local out
    out=$(ROWS="$(_f_tool_rows)" "$RWT" 20 node -e "
const P = require('$POLICY_NODE');
const bad = [];
let seen = 0;
for (const line of String(process.env.ROWS).split(/\r?\n/)) {
  const t = line.trim();
  if (!t || t.charAt(0) === '#') continue;
  const [label, expr, meta, look, disp] = t.split('|').map((x) => x.trim());
  let tool;
  try { tool = new Function('return (' + expr + ');')(); }
  catch (e) { bad.push(label + ':unusable-fixture-expression'); continue; }
  const checks = [
    ['isMetaOpDispatch', () => P.isMetaOpDispatch(tool, 'resume-session'), meta],
    ['isLookaheadDispatchTool', () => P.isLookaheadDispatchTool(tool), look],
    ['isDispatchTool', () => P.isDispatchTool(tool), disp],
  ];
  for (const [name, fn, want] of checks) {
    let got;
    try { got = fn(); }
    catch (e) { bad.push(label + ':' + name + ':threw:' + e.message); continue; }
    if (typeof got !== 'boolean') bad.push(label + ':' + name + ':non-boolean:' + typeof got);
    else if (String(got) !== want) bad.push(label + ':' + name + '=' + String(got) + '(want ' + want + ')');
  }
  seen++;
}
if (seen !== 14) bad.push('rows-evaluated=' + seen + '(want 14)');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "F3: every tool-name predicate matches the exact identifier only — a case variant, a padded spelling or a non-string returns false rather than throwing, and only Agent/Task earn the lookahead"
    else
        fail "F3: the tool-name boundary table disagrees; $out"
    fi
}
