# Shared fixture of the progress-nudge tests. Sourced by ../feat-progress-pressure.sh and
# ../feat-progress-nudge-acceptance.sh after they pin WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR
# and set $PP_TMP (a readonly temp root) and $SCRIPT_CHECKOUT_ROOT.
# Every hook runs as Claude Code runs it: the event envelope on stdin, the real clock. Time
# is advanced by ageing the session's own files (pp_age), never by injecting a clock, so no
# field name of progress-pressure.json is assumed here.

PP_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/progress-nudge.js"
PP_COMPACT="$SCRIPT_CHECKOUT_ROOT/hooks/post-compact.js"
PP_AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
PP_T="$(np "$PP_TMP")/t"
mkdir -p "$PP_TMP/t" "$PP_TMP/js" "$PP_TMP/cfg"
export AGENTS="$PP_AGENTS" PP_T

# The outline/detail completes the fixture marks pass the approval gate only when the config
# .env waives it; markStep reads that file (never process.env), so pin it to a fixture root
# with both gates off instead of the harness decoy, whose .env leaves them on (test-design.md
# "Config-dependent branches"). Requires still resolve through $AGENTS (this worktree).
printf 'CONFIRM_OUTLINE=off\nCONFIRM_DETAIL=off\n' > "$PP_TMP/cfg/.env"
export AGENTS_MAIN_ROOT="$(np "$PP_TMP/cfg")"

# pp-env.js <sid> <event> <tool|-> [subagent] [stop-active] — the hook envelope.
cat > "$PP_TMP/js/env.js" <<'JS'
const [sid, event, tool, ...flags] = process.argv.slice(2);
const e = { session_id: sid, transcript_path: process.env.PP_T + '/' + sid + '.jsonl', cwd: process.env.PP_T, hook_event_name: event };
if (event === 'PostToolUse') Object.assign(e, { tool_name: tool, tool_input: tool === 'Bash' ? { command: 'true' } : {}, tool_response: {} });
if (event === 'UserPromptSubmit') e.prompt = 'go';
if (event === 'Stop') e.stop_hook_active = flags.indexOf('stop-active') !== -1;
if (flags.indexOf('subagent') !== -1) { e.agent_id = 'agent-1'; e.agent_type = 'general-purpose'; }
process.stdout.write(JSON.stringify(e));
JS

# state.js seed|mark|backfill|pause|unpause|off|on|risk|grow|touch-progress <sid> [arg]
cat > "$PP_TMP/js/state.js" <<'JS'
const fs = require('fs');
const path = require('path');
const A = process.env.AGENTS;
const S = require(A + '/hooks/workflow-state/state-io');
const [op, sid, arg] = process.argv.slice(2);
const T = process.env.PP_T + '/' + sid + '.jsonl';
const stateDir = () => require(A + '/hooks/workflow-state').getSessionStateDir(sid);
switch (op) {
  case 'seed':
    S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
    S.markStep(sid, 'workflow_init', 'complete');
    if (!fs.existsSync(T)) fs.writeFileSync(T, Buffer.alloc(10 * 1024, 120));
    break;
  case 'mark': S.markStep(sid, arg, process.argv[5] || 'complete'); break;
  case 'backfill':
    S.appendEvents(sid, [{ kind: 'step_status', step: arg, status: 'complete', provenance: 'backfilled', origin: 'session-inheritance' }]);
    break;
  case 'pause': require(A + '/hooks/lib/next-step-pause-marker').writePauseMarker(sid, { reason: 'test pause' }); break;
  case 'unpause': require(A + '/hooks/lib/next-step-pause-marker').removePauseMarker(sid); break;
  case 'off': fs.mkdirSync(stateDir(), { recursive: true }); fs.writeFileSync(path.join(stateDir(), sid + '.workflow-off'), 'test'); break;
  case 'on': fs.rmSync(path.join(stateDir(), sid + '.workflow-off'), { force: true }); break;
  case 'risk': require(A + '/hooks/lib/handoff-risk-signal').recordRiskSignal(sid, 'gate-block'); break;
  case 'grow': fs.appendFileSync(T, Buffer.alloc(Number(arg), 121)); break;
  case 'touch-progress': {
    // session-progress.md written by the model just now (mtime a few seconds ahead of every baseline).
    const p = path.join(process.env.WORKFLOW_PLANS_DIR, sid + '-session-progress.md');
    fs.appendFileSync(p, '\n- updated\n');
    const t = new Date(Date.now() + 5000);
    fs.utimesSync(p, t, t);
    break;
  }
  default: throw new Error('state.js: unknown op ' + op);
}
JS

# age.js <sid> <minutes> — move every timestamp the session owns <minutes> into the past:
# epoch-ms numbers and ISO strings in <sid>.control/*.json, and the mtimes of session-progress.md
# and the transcript. This is "time passes" without knowing any field name.
cat > "$PP_TMP/js/age.js" <<'JS'
const fs = require('fs');
const path = require('path');
const [sid, minutes] = process.argv.slice(2);
const d = Number(minutes) * 60000;
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/;
const shift = (v) => {
  if (typeof v === 'number' && v > 1e12 && v < 1e13) return v - d;
  if (typeof v === 'string' && ISO.test(v)) return new Date(Date.parse(v) - d).toISOString();
  if (Array.isArray(v)) return v.map(shift);
  if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v)) o[k] = shift(v[k]); return o; }
  return v;
};
const ctl = path.join(process.env.WORKFLOW_STATE_DIR, sid + '.control');
let names = [];
try { names = fs.readdirSync(ctl); } catch (e) { names = []; }
for (const n of names.filter((x) => x.endsWith('.json'))) {
  const p = path.join(ctl, n);
  try { fs.writeFileSync(p, JSON.stringify(shift(JSON.parse(fs.readFileSync(p, 'utf8'))))); } catch (e) { /* not ours */ }
}
for (const p of [path.join(process.env.WORKFLOW_PLANS_DIR, sid + '-session-progress.md'), process.env.PP_T + '/' + sid + '.jsonl']) {
  try { const st = fs.statSync(p); const t = new Date(st.mtimeMs - d); fs.utimesSync(p, t, t); } catch (e) { /* absent */ }
}
JS

# ctx.js — reads a hook stdout on stdin; prints "<hookEventName>\t<additionalContext>" or "".
cat > "$PP_TMP/js/ctx.js" <<'JS'
let s = '';
process.stdin.on('data', (c) => { s += c; });
process.stdin.on('end', () => {
  let j; try { j = JSON.parse(s.trim() || '{}'); } catch (e) { process.stdout.write('NOT-JSON:' + s.slice(0, 200)); return; }
  const h = j && j.hookSpecificOutput;
  if (h && typeof h.additionalContext === 'string' && h.additionalContext) process.stdout.write(String(h.hookEventName) + '\t' + h.additionalContext);
});
JS

# pressure.js <sid> <dotted.key> — prints one value of progress-pressure.json as read by
# hooks/lib/progress-file.js (keys documented in docs/architecture/claude-code/progress-file.md);
# prints "" when the file or the key is absent.
cat > "$PP_TMP/js/pressure.js" <<'JS'
const [sid, key] = process.argv.slice(2);
let v = require(process.env.AGENTS + '/hooks/lib/progress-file').readPressure(sid) || {};
for (const k of key.split('.')) v = v === null || v === undefined ? undefined : v[k];
process.stdout.write(v === undefined || v === null ? '' : String(v));
JS

pp_node() { run_with_timeout 60 node "$(np "$PP_TMP/js/$1")" "${@:2}"; }
pp_pressure() { pp_node pressure.js "$@" 2>/dev/null; }
pp_state() { pp_node state.js "$@" >/dev/null 2>&1; }
pp_age() { pp_node age.js "$@" >/dev/null 2>&1; }

# pp_hook <sid> <event> [tool|-] [flags...] — runs progress-nudge; sets PP_OUT (raw stdout),
# PP_EVT (hookEventName) and PP_CTX (additionalContext; empty when the hook was silent).
pp_hook() {
  local sid="$1" ev="$2" tool="${3:--}" parsed
  PP_OUT="$(pp_node env.js "$sid" "$ev" "$tool" "${@:4}" | run_with_timeout 60 node "$PP_HOOK" 2>/dev/null)"
  parsed="$(printf '%s' "$PP_OUT" | run_with_timeout 30 node "$(np "$PP_TMP/js/ctx.js")" 2>&1)"
  PP_EVT="${parsed%%$'\t'*}"
  PP_CTX=""
  case "$parsed" in *$'\t'*) PP_CTX="${parsed#*$'\t'}" ;; NOT-JSON:*) PP_CTX="$parsed" ;; esac
}

# pp_compact <sid> — one compaction as Claude Code reports it (hooks/post-compact.js).
pp_compact() {
  printf '{"session_id":"%s"}' "$1" | run_with_timeout 60 node "$PP_COMPACT" >/dev/null 2>&1
}

# pp_prime <sid> — an active session whose first evaluation has happened: the first one
# initialises the baseline and reports any past completes (workflow_init) at once.
pp_prime() {
  pp_state seed "$1"
  pp_hook "$1" PostToolUse Bash
  pp_hook "$1" PostToolUse Bash
}

pp_fired() { case "$PP_CTX" in '[progress check]'*) return 0 ;; *) return 1 ;; esac; }

# pp_expect_fire <label> [needle...] — the last hook asked for an update (and names each needle).
pp_expect_fire() {
  local label="$1" n miss=""
  shift
  if ! pp_fired; then fail "$label" "no [progress check]; stdout=${PP_OUT:0:300}"; return; fi
  for n in "$@"; do case "$PP_CTX" in *"$n"*) : ;; *) miss="$miss $n" ;; esac; done
  if [ -z "$miss" ]; then pass "$label"; else fail "$label" "missing:$miss ctx=${PP_CTX:0:300}"; fi
}

# pp_expect_silent <label> — the last hook printed nothing or {}.
pp_expect_silent() {
  local t
  t="$(printf '%s' "$PP_OUT" | tr -d ' \r\n')"
  case "$t" in ''|'{}') pass "$1" ;; *) fail "$1" "stdout=${PP_OUT:0:300}" ;; esac
}

MiB=$((1024 * 1024))
