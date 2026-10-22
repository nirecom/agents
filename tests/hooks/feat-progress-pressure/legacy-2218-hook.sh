# #2218 hook-level cases P3-P6 (request wording, fail-open, registration, inactive session).
# Sourced by ../feat-progress-pressure.sh after legacy-2218-lib.sh; each run_* is called inside
# its own case block.

# l2218_hook_fixture <tmp> — a 3MiB transcript and a baseline at 0 one minute ago:
# enough to fire whenever the session is inside its active period.
l2218_hook_fixture() {
    local tmp="$1"
    cat > "$tmp/fx.js" <<'JS'
const fs = require('fs');
const D = process.env.TMPD;
fs.writeFileSync(D + '/transcript.jsonl', Buffer.alloc(3 * 1024 * 1024, 120));
for (const sid of ['sid-p3', 'sid-p6']) {
  fs.mkdirSync(D + '/wf/' + sid + '.control', { recursive: true });
  fs.writeFileSync(D + '/wf/' + sid + '.control/progress-pressure.json', JSON.stringify({ baseline_bytes: 0, baseline_at: Date.now() - 60000 }));
}
if (process.env.ACTIVE_SID) {
  const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
  S.writeState(process.env.ACTIVE_SID, S.createInitialState(process.env.ACTIVE_SID, { cwd: '/x', git_branch: 'feature/x' }));
  S.markStep(process.env.ACTIVE_SID, 'workflow_init', 'complete');
}
JS
    l2218_run_js "$tmp" "$(np "$tmp")/fx.js" >/dev/null
}

l2218_run_hook() {
    local tmp="$1" sid="$2" tn; tn="$(np "$tmp")"
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"go"}' \
        "$sid" "$tn/transcript.jsonl" "$tn" \
        | env WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
            HOME="$tn/home" USERPROFILE="$tn/home" \
            "$L2218_RWT" 60 node "$SCRIPT_CHECKOUT_ROOT/$L2218_HOOK" 2>&1
}

# P3 — output shape and wording. The envelope must match hooks/lang-inject.js
# (a different one is silently dropped). The text is a [progress check] that
# points at rules/progress-update.md; none of the retired flush wording is left.
run_P3() {
    l2218_require_module "$L2218_HOOK" || return 0
    local tmp out verdict
    tmp="$(make_tmp)"; mkdir -p "$tmp/wf"
    ACTIVE_SID="sid-p3" l2218_hook_fixture "$tmp"
    out="$(l2218_run_hook "$tmp" "sid-p3")"
    verdict=$(env HOOK_OUT="$out" "$L2218_RWT" 30 node -e "
const problems = [];
let parsed;
try { parsed = JSON.parse(process.env.HOOK_OUT); } catch (e) { problems.push('not-json:' + JSON.stringify(process.env.HOOK_OUT).slice(0, 200)); }
if (parsed) {
  const o = parsed.hookSpecificOutput;
  if (!o) problems.push('no-hookSpecificOutput:' + JSON.stringify(parsed));
  else {
    if (o.hookEventName !== 'UserPromptSubmit') problems.push('hookEventName:' + String(o.hookEventName));
    const c = typeof o.additionalContext === 'string' ? o.additionalContext : '';
    if (c.indexOf('[progress check]') !== 0) problems.push('not-headed-[progress check]');
    for (const need of ['rules/progress-update.md', 'sid-p3-session-progress.md']) {
      if (c.indexOf(need) === -1) problems.push('missing:' + need);
    }
    for (const gone of ['[handoff check]', 'handoff-emergency-flush', 'C/D/F']) {
      if (c.indexOf(gone) !== -1) problems.push('retired-wording:' + gone);
    }
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$verdict" = "OK" ]; then
        pass "P3: the request keeps the lang-inject envelope, is a [progress check] naming rules/progress-update.md and the session-progress.md path"
    else
        fail "P3: expected 'OK', got '${verdict:-<err>}' (hook stdout: ${out:0:200})"
    fi
}

# P4 — fail-open. A UserPromptSubmit hook that dies takes the user's turn with
# it, so every unreadable input must still print exactly `{}`.
run_P4() {
    l2218_require_module "$L2218_HOOK" || return 0
    local tmp bad1 bad2 bad3 problems
    tmp="$(make_tmp)"
    problems=""
    bad1=$(printf 'not json at all' | env \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$L2218_RWT" 30 node "$SCRIPT_CHECKOUT_ROOT/$L2218_HOOK" 2>/dev/null)
    bad2=$(printf '{"session_id":"sid-p4"}' | env \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$L2218_RWT" 30 node "$SCRIPT_CHECKOUT_ROOT/$L2218_HOOK" 2>/dev/null)
    bad3=$(printf '{"session_id":"sid-p4","transcript_path":"%s/nope.jsonl"}' "$(np "$tmp")" \
        | env \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$L2218_RWT" 30 node "$SCRIPT_CHECKOUT_ROOT/$L2218_HOOK" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    [ "$(printf '%s' "$bad1" | tr -d ' \n\r')" = "{}" ] || problems="$problems malformed-stdin:'${bad1}'"
    [ "$(printf '%s' "$bad2" | tr -d ' \n\r')" = "{}" ] || problems="$problems no-transcript_path:'${bad2}'"
    [ "$(printf '%s' "$bad3" | tr -d ' \n\r')" = "{}" ] || problems="$problems unreadable-transcript:'${bad3}'"
    if [ -z "$problems" ]; then
        pass "P4: the request hook fails open with '{}' on malformed, incomplete and unreadable input"
    else
        fail "P4: expected '{}' in every degraded case —$problems"
    fi
}

# P5 — registration (#2594): one hook on UserPromptSubmit, PostToolUse (matcher "")
# and Stop; the retired handoff-pressure-nudge is registered nowhere; no new event
# kind (PreCompact / SessionEnd) is added.
run_P5() {
    local out
    out="$(l2218_run_node "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$L2218_ROOT_NODE/settings.json', 'utf8'));
const problems = [];
const hooks = (s && s.hooks) || {};
const registeredIn = [];
for (const evt of Object.keys(hooks)) {
  for (const m of hooks[evt] || []) {
    for (const h of (m && m.hooks) || []) {
      const cmd = String(h.command || '');
      if (cmd.indexOf('handoff-pressure-nudge') !== -1) problems.push('retired-hook-registered:' + evt);
      if (/hooks\/progress-nudge\.js/.test(cmd)) registeredIn.push(evt + (evt === 'PostToolUse' ? '[' + String(m.matcher) + ']' : ''));
    }
  }
}
const want = ['PostToolUse[]', 'Stop', 'UserPromptSubmit'];
if (registeredIn.slice().sort().join(',') !== want.join(',')) problems.push('registered-in:' + registeredIn.join(',') + ',want=' + want.join(','));
for (const forbidden of ['PreCompact', 'SessionEnd']) {
  if (hooks[forbidden] !== undefined) problems.push('new-event-key-added:' + forbidden);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "P5: progress-nudge is registered once each on UserPromptSubmit, PostToolUse (matcher \"\") and Stop; handoff-pressure-nudge nowhere"
    else
        fail "P5: expected 'OK', got '${out:-<err>}'"
    fi
}

# P6 — outside the workflow active period (no state for this sid) the same
# firing fixture must print `{}`: there is no workflow to resume, so nothing to
# check for.
run_P6() {
    l2218_require_module "$L2218_HOOK" || return 0
    local tmp out
    tmp="$(make_tmp)"; mkdir -p "$tmp/wf"
    l2218_hook_fixture "$tmp"
    out="$(l2218_run_hook "$tmp" "sid-p6")"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$(printf '%s' "$out" | tr -d ' \n\r')" = "{}" ]; then
        pass "P6: outside the workflow active period the request hook prints '{}' even past the threshold"
    else
        fail "P6: expected '{}' for an inactive session, got '${out:0:200}'"
    fi
}
