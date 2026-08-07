#!/usr/bin/env bash
# tests/harden-1319-session-id-central-validation.sh
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/session-id.js, hooks/lib/session-markers.js, hooks/stop-final-report-guard.js, hooks/stop-l2-findings-display.js, hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js
# Tags: session-id, validation, path-traversal, hardening, scope:issue-specific, pwsh-not-required, TL1, TL2
#
# Issue #1319 — session-id validation is centralised in
# hooks/workflow-state/state-io/core.js (SESSION_ID_VALID_RE) and enforced on
# every resolveSessionId() return path, so the four Stop-hook consumers no
# longer carry their own redundant regex guard.
# U1-U6 are TL1 (pure function, real fixture files). I1-I4 are TL2 (real spawned
# hook process) and cover ALL FOUR consumers whose local regex guard was dropped.
#
# L3 gap (what this test does NOT catch):
# - The consumers receiving a malformed session_id from a real Claude Code Stop
#   hook payload (settings.json wiring + live transcript resolution)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
CORE_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io/core.js"
SESSION_ID_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/session-id.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'sid1319'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Evaluate SESSION_ID_VALID_RE + resolveSessionId for one candidate sid.
# Env is scrubbed of every other resolution source (env sid, env file, project
# dir, transcript base) and CWD is a throwaway dir, so the only input that can
# influence the answer is sessionIdFromInput itself.
# $1=candidate  -> prints "<re-result> <resolve-result>"
probe_sid() {
    local cand="$1" tmp out
    tmp="$(make_tmp)"
    out=$(cd "$tmp" && CAND="$cand" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
        -u CLAUDE_ENV_FILE -u CLAUDE_PROJECT_DIR \
        CLAUDE_TRANSCRIPT_BASE_DIR="$(node_path "$tmp")/no-transcripts" \
        "$RWT" 15 node -e "
const { SESSION_ID_VALID_RE } = require('$CORE_NODE');
const { resolveSessionId } = require('$SESSION_ID_NODE');
const cand = process.env.CAND;
const re = SESSION_ID_VALID_RE.test(cand) ? 'valid' : 'invalid';
const got = resolveSessionId({ sessionIdFromInput: cand });
process.stdout.write(re + ' ' + (got === cand ? 'accepted' : 'rejected'));" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# U1: canonical CC UUID form is accepted by the central validator
# ---------------------------------------------------------------------------
run_U1() {
    local out
    out="$(probe_sid '3f2a1b4c-5d6e-7f80-9a1b-2c3d4e5f6071')"
    if [ "$out" = "valid accepted" ]; then
        pass "U1: UUID session id passes SESSION_ID_VALID_RE and resolveSessionId returns it"
    else
        fail "U1: expected 'valid accepted', got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# U2: YYYYMMDD-HHMMSS fallback form is accepted
# ---------------------------------------------------------------------------
run_U2() {
    local out
    out="$(probe_sid '20260509-123045')"
    if [ "$out" = "valid accepted" ]; then
        pass "U2: YYYYMMDD-HHMMSS session id accepted"
    else
        fail "U2: expected 'valid accepted', got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# U3: the test-sid forms named in core.js's own comment are accepted
#     (core.js: 'test sids ("test-sid-bash-9", "20260509-bundle-a")')
# ---------------------------------------------------------------------------
run_U3() {
    local a b
    a="$(probe_sid 'test-sid-bash-9')"
    b="$(probe_sid '20260509-bundle-a')"
    if [ "$a" = "valid accepted" ] && [ "$b" = "valid accepted" ]; then
        pass "U3: documented test-sid forms accepted (test-sid-bash-9, 20260509-bundle-a)"
    else
        fail "U3: expected both 'valid accepted', got a='${a:-<err>}' b='${b:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# U4: malformed / path-traversal sids are rejected — SESSION_ID_VALID_RE says
#     invalid AND resolveSessionId never returns the supplied string
# ---------------------------------------------------------------------------
run_U4() {
    local bad out failures=""
    for bad in '../../etc/passwd' 'a/b' '..' 'has space' 'semi;colon'; do
        out="$(probe_sid "$bad")"
        if [ "$out" != "invalid rejected" ]; then
            failures="$failures [$bad -> ${out:-<err>}]"
        fi
    done
    if [ -z "$failures" ]; then
        pass "U4: malformed sids rejected by the central validator and never echoed back"
    else
        fail "U4: expected 'invalid rejected' for every malformed sid; got$failures"
    fi
}

# ---------------------------------------------------------------------------
# I1/I2: two of the four consumers whose redundant regex guard was removed.
# Feeding a malformed session_id through real stdin must still fail-open
# (exit 0, no decision:block) — the externally observable behaviour is
# unchanged by the removal, which is the whole point of #1319.
# $1=case-id $2=hook-relative-path
# ---------------------------------------------------------------------------
run_consumer_case() {
    local id="$1" rel="$2" tmp tn rc out hook
    hook="$AGENTS_DIR/$rel"
    if [ ! -f "$hook" ]; then skip "$id: $rel not present"; return; fi
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(echo '{"stop_hook_active":false,"session_id":"../../etc/passwd","transcript_path":""}' \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 20 node "$(node_path "$hook")" 2>&1)
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" -eq 0 ] && ! echo "$out" | grep -q '"decision"'; then
        pass "$id: $rel fail-opens on a malformed session_id (exit 0, no decision)"
    else
        fail "$id: expected clean exit 0 with no decision from $rel (rc=$rc, out=$out)"
    fi
}

run_I1() { run_consumer_case "I1" "hooks/stop-final-report-guard.js"; }
run_I2() { run_consumer_case "I2" "hooks/stop-l2-findings-display.js"; }
# I3/I4 complete the set: all FOUR consumers whose redundant regex guard was
# removed are driven with the same malformed session_id. Covering only two left
# the other half of the class untested (CPR-5).
run_I3() { run_consumer_case "I3" "hooks/stop-premature-stop-guard.js"; }
run_I4() { run_consumer_case "I4" "hooks/supervisor-guard.js"; }

# ---------------------------------------------------------------------------
# U5: the fallback chain's SUCCESS paths. U1-U4 only prove that a bad
#     sessionIdFromInput is refused; without these rows a resolveSessionId that
#     always returned null would pass the whole file. Each row disables every
#     source ABOVE the one under test, so the returned value can only have come
#     from that source.
#     Rows: 2 CLAUDE_CODE_SESSION_ID, 3 CLAUDE_ENV_FILE, 4 CLAUDE_SESSION_ID,
#           5 transcriptPath basename, 6 WORKTREE_NOTES.md in CWD.
#     Plus the precedence pair (input beats env; env beats env-file) and the
#     "invalid value in a fallback source is skipped, not returned" row.
# ---------------------------------------------------------------------------
run_U5() {
    local tmp tnode out
    tmp="$(make_tmp)"; tnode="$(node_path "$tmp")"
    printf 'CLAUDE_SESSION_ID=envfile-sid-3\n' > "$tmp/env-file"
    printf 'Session-ID: notes-sid-6\n' > "$tmp/WORKTREE_NOTES.md"
    printf 'BAD_KEY=x\nCLAUDE_SESSION_ID=../../escape\n' > "$tmp/env-file-bad"
    out=$(cd "$tmp" && TMPD="$tnode" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
        -u CLAUDE_ENV_FILE -u CLAUDE_PROJECT_DIR \
        CLAUDE_TRANSCRIPT_BASE_DIR="$tnode/no-transcripts" \
        "$RWT" 20 node -e "
const path = require('path');
const { resolveSessionId } = require('$SESSION_ID_NODE');
const dir = process.env.TMPD;
const problems = [];
const clear = () => {
  delete process.env.CLAUDE_CODE_SESSION_ID;
  delete process.env.CLAUDE_SESSION_ID;
  delete process.env.CLAUDE_ENV_FILE;
};
const check = (label, want, fn) => {
  clear();
  let got;
  try { got = fn(); } catch (e) { problems.push(label + ':threw(' + e.message + ')'); clear(); return; }
  if (got !== want) problems.push(label + ':want=' + want + ' got=' + got);
  clear();
};
// P1 input (control: the top of the chain still works)
check('p1-input', 'input-sid-1', () => resolveSessionId({ sessionIdFromInput: 'input-sid-1' }));
// P2 CLAUDE_CODE_SESSION_ID — reached when input is absent/invalid
check('p2-code-env', 'code-sid-2', () => {
  process.env.CLAUDE_CODE_SESSION_ID = 'code-sid-2';
  return resolveSessionId({});
});
check('p2-trims', 'code-sid-2', () => {
  process.env.CLAUDE_CODE_SESSION_ID = '  code-sid-2  ';
  return resolveSessionId({});
});
// P3 CLAUDE_ENV_FILE — reached only with P2 unset
check('p3-env-file', 'envfile-sid-3', () => {
  process.env.CLAUDE_ENV_FILE = path.join(dir, 'env-file');
  return resolveSessionId({});
});
// P4 CLAUDE_SESSION_ID
check('p4-session-env', 'legacy-sid-4', () => {
  process.env.CLAUDE_SESSION_ID = 'legacy-sid-4';
  return resolveSessionId({});
});
// P5 transcript basename
check('p5-transcript', 'transcript-sid-5', () =>
  resolveSessionId({ transcriptPath: path.join(dir, 'transcript-sid-5.jsonl') }));
// P6 WORKTREE_NOTES.md in CWD (the test chdir'd into the fixture dir)
check('p6-notes', 'notes-sid-6', () => resolveSessionId({}));
// precedence: a valid higher source wins over a valid lower one
check('prec-input-over-env', 'input-sid-1', () => {
  process.env.CLAUDE_CODE_SESSION_ID = 'code-sid-2';
  process.env.CLAUDE_SESSION_ID = 'legacy-sid-4';
  return resolveSessionId({ sessionIdFromInput: 'input-sid-1' });
});
check('prec-code-over-envfile', 'code-sid-2', () => {
  process.env.CLAUDE_CODE_SESSION_ID = 'code-sid-2';
  process.env.CLAUDE_ENV_FILE = path.join(dir, 'env-file');
  return resolveSessionId({});
});
// an INVALID value in a fallback source is skipped, and resolution continues
check('skip-bad-code-env', 'legacy-sid-4', () => {
  process.env.CLAUDE_CODE_SESSION_ID = '../../escape';
  process.env.CLAUDE_SESSION_ID = 'legacy-sid-4';
  return resolveSessionId({});
});
check('skip-bad-env-file', 'notes-sid-6', () => {
  process.env.CLAUDE_ENV_FILE = path.join(dir, 'env-file-bad');
  return resolveSessionId({});
});
check('skip-bad-transcript', 'notes-sid-6', () =>
  resolveSessionId({ transcriptPath: '/tmp/bad name.jsonl' }));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "U5: every fallback source resolves when reached, higher sources win, and an invalid value is skipped rather than returned"
    else
        fail "U5: fallback-chain success path wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# U6: the session-marker readers are the other family that turns a session id
#     into a path (<workflowDir>/<sid>.<suffix>). Every reader must refuse a
#     hostile id rather than stat/read outside the workflow dir — proven
#     by planting a real marker in the PARENT directory and confirming a
#     traversal id cannot see it.
# ---------------------------------------------------------------------------
run_U6() {
    local tmp tnode out
    tmp="$(make_tmp)"; tnode="$(node_path "$tmp")"
    mkdir -p "$tmp/wf"
    printf '{}' > "$tmp/outside.workflow-off"
    printf '{}' > "$tmp/outside.next-step-paused"
    printf '{"expires_at":"2999-01-01T00:00:00.000Z"}' > "$tmp/outside.background-work"
    out=$(TMPD="$tnode" CLAUDE_WORKFLOW_DIR="$tnode/wf" WORKFLOW_PLANS_DIR="$tnode/wf" "$RWT" 20 node -e "
const fs = require('fs'), path = require('path');
const sm = require('$_AGENTS_DIR_NODE/hooks/lib/session-markers.js');
const dir = process.env.TMPD;
const hostile = ['../outside', '..\\\\outside', '/outside', 'a/b', '..', '', '   ', 'x\\u0000y', '*'];
const readers = [
  ['isWorkflowOff', sm.isWorkflowOff],
  ['isWorktreeOff', sm.isWorktreeOff],
  ['isIssueCloseVerified', sm.isIssueCloseVerified],
  ['isNextStepPaused', sm.isNextStepPaused],
  ['isBackgroundWorkInFlight', sm.isBackgroundWorkInFlight],
];
const problems = [];
for (const [name, fn] of readers) {
  for (const sid of hostile) {
    let got;
    try { got = fn(sid); } catch (e) { problems.push(name + '[' + sid + ']:threw'); continue; }
    if (got !== false) problems.push(name + '[' + JSON.stringify(sid) + ']=' + got);
  }
}
// readOffClearance is the object-returning reader of the same family
for (const sid of hostile) {
  let got;
  try { got = sm.readOffClearance(sid); } catch (e) { problems.push('readOffClearance:threw'); continue; }
  if (got !== null) problems.push('readOffClearance[' + JSON.stringify(sid) + ']-not-null');
}
for (const f of ['outside.workflow-off', 'outside.next-step-paused', 'outside.background-work']) {
  if (!fs.existsSync(path.join(dir, f))) problems.push('deleted-outside:' + f);
}
// positive anchor: the same readers DO see a marker inside the workflow dir
const wf = path.join(dir, 'wf');
fs.writeFileSync(path.join(wf, 'good.background-work'), '{\"expires_at\":\"2999-01-01T00:00:00.000Z\"}');
fs.writeFileSync(path.join(wf, 'good.workflow-off'), '');
if (sm.isBackgroundWorkInFlight('good') !== true) problems.push('positive-anchor:background-work');
if (sm.isWorkflowOff('good') !== true) problems.push('positive-anchor:workflow-off');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "U6: every session-marker reader refuses hostile session ids and cannot read outside the workflow dir"
    else
        fail "U6: marker-reader path containment broken; got '${out:-<err>}'"
    fi
}

run_U1
run_U2
run_U3
run_U4
run_U5
run_U6
run_I1
run_I2
run_I3
run_I4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
