#!/bin/bash
# tests/feature-1071-tier3-session-close-worker.sh
# Tests: bin/worker-dispatch/workers/session-close-gate.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/emit.js, skills/session-close/SKILL.md
# Tags: static, worker, worker-dispatch, session-close, gate-action, TL2, scope:issue-specific
#
# Tier 3 contract test for the session-close gate (originally issue #1071).
# #1643 replaced the LLM subagent agents/session-close-worker.md with the plain
# script bin/worker-dispatch/workers/session-close-gate.js, dispatched by
# skills/session-close/SKILL.md steps SC-4+SC-5 through
# skills/_shared/worker-dispatch.md. Each case keeps its original intent; the
# subject moved from prose to code, so gate_action cases now EXECUTE the decision
# functions and the output contract is checked through the real renderer.
#
# TL3 gap (what this TL2 test does NOT catch):
# - a real /session-close run dispatching the worker through the Claude Code Bash tool
# - runtime sentinel ordering from a real Stop event
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
WORKER_JS="${AGENTS_DIR}/bin/worker-dispatch/workers/session-close-gate.js"
REGISTRY_JS="${AGENTS_DIR}/hooks/lib/worker-dispatch-registry.js"
EMIT_JS="${AGENTS_DIR}/bin/worker-dispatch/emit.js"
SC_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"
SHARED_MD="skills/_shared/worker-dispatch.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sc-gate-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Extract the SC-4+SC-5 gate block: everything between its heading and the next
# `## ` heading. Gate-scoped greps must never see unrelated sections (see T13).
extract_gate_block() {
    awk '/^## Steps SC-4\+SC-5/ { inb = 1; print; next }
         inb && /^## / { exit }
         inb { print }' "$1"
}

GATE_BLOCK="$TMPD/gate-block.md"

# ── Test 1: worker module exists ──────────────────────────────────────────────
test_worker_exists() {
    if [ -f "$WORKER_JS" ]; then
        pass "1: bin/worker-dispatch/workers/session-close-gate.js exists"
    else
        fail "1: bin/worker-dispatch/workers/session-close-gate.js missing"
    fi
}

# ── Test 2: output contract is the status/summary/artifact_path triple ────────
test_output_contract() {
    if [ ! -f "$REGISTRY_JS" ] || [ ! -f "$EMIT_JS" ]; then
        fail "2: registry or emit module missing — cannot check output contract"
        return
    fi
    local out
    out=$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      const emit = require(process.argv[2]);
      const entry = reg.workers["session-close-gate"];
      if (!entry) { process.stdout.write("NO-ENTRY"); process.exit(0); }
      if (entry.renderer !== "status-triple") {
        process.stdout.write("RENDERER:" + entry.renderer); process.exit(0);
      }
      const text = emit.render(entry, {
        status: "complete",
        summary: "gate_action=proceed; SC-4 findings: 0",
        artifactPath: "/tmp/gate.json",
      });
      const lines = text.split("\n").filter((l) => l !== "");
      // Unquoted triple: keys in order, and no value may be double-quoted.
      const keys = lines.map((l) => l.split(":")[0]).join(",");
      const quoted = lines.some((l) => /^[a-z_]+: "/.test(l));
      process.stdout.write(quoted ? "QUOTED:" + keys : keys);
    ' "$(nodepath "$REGISTRY_JS")" "$(nodepath "$EMIT_JS")" 2>&1)
    if [ "$out" = "status,summary,artifact_path" ]; then
        pass "2: rendered output contract is the unquoted status/summary/artifact_path triple"
    else
        fail "2: output contract incorrect" "rendered keys='$out'"
    fi
}

# ── Test 3: gate_action proceed is produced ───────────────────────────────────
test_gate_action_proceed() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "3: worker module missing — cannot evaluate gate_action"
        return
    fi
    local out
    out=$(run_with_timeout 30 node -e '
      const w = require(process.argv[1]);
      const now = Date.now();
      // Settled alert phase: nothing to wait for.
      const a = w.evaluateAlert({ alert: { alert_phase: "done" } }, now);
      // Stale pending alert (armed well beyond the phase timeout): proceed anyway.
      const stale = new Date(now - 3600 * 1000).toISOString();
      const b = w.evaluateAlert(
        { alert: { alert_phase: "pending", alert_armed_at: stale, last_run_at: null } }, now);
      process.stdout.write(a.gateAction + "," + b.gateAction);
    ' "$(nodepath "$WORKER_JS")" 2>&1)
    if [ "$out" = "proceed,proceed" ]; then
        pass "3: worker yields gate_action=proceed for settled and timed-out alert phases"
    else
        fail "3: gate_action proceed not produced" "got='$out' (want 'proceed,proceed')"
    fi
}

# ── Test 4: gate_action yield is produced ─────────────────────────────────────
test_gate_action_yield() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "4: worker module missing — cannot evaluate gate_action"
        return
    fi
    local out
    out=$(run_with_timeout 30 node -e '
      const w = require(process.argv[1]);
      const now = Date.now();
      const fresh = new Date(now).toISOString();
      const a = w.evaluateAlert(
        { alert: { alert_phase: "pending", alert_armed_at: fresh, last_run_at: null } }, now);
      const b = w.evaluateAudit(
        { audit: { audit_phase: "pending", audit_armed_at: fresh, audit_last_run_at: null } }, now);
      process.stdout.write(String(a.gateAction) + "," + String(b.gateAction));
    ' "$(nodepath "$WORKER_JS")" 2>&1)
    if [ "$out" = "yield,yield" ]; then
        pass "4: worker yields gate_action=yield for a fresh pending alert and audit phase"
    else
        fail "4: gate_action yield not produced" "got='$out' (want 'yield,yield')"
    fi
}

# ── Test 5: yield semantics — caller STOPs, SC-6 does not run ────────────────
# A plain script cannot stop its caller, so the yield contract now lives entirely
# in the SC-4+SC-5 gate block. Scoped so an unrelated section cannot satisfy it.
test_yield_stops_sc6() {
    if [ ! -s "$GATE_BLOCK" ]; then
        fail "5: SC-4+SC-5 gate block not found in $SC_MD"
        return
    fi
    if grep -qE 'yield.*(STOP|stop|halt)' "$GATE_BLOCK" && grep -qE 'SC-6 does not run' "$GATE_BLOCK"; then
        pass "5: gate block documents yield = STOP / SC-6 does not run"
    else
        fail "5: gate block missing yield→STOP semantics" "$(cat "$GATE_BLOCK")"
    fi
}

# ── Test 6: no workflow sentinels emitted by the worker ──────────────────────
# Sentinel emission stays in the caller's context. The worker cannot mark a
# workflow step complete, and emit.js neutralizes sentinel-like bytes on top.
test_no_sentinels() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "6: worker module missing — cannot check sentinels"
        return
    fi
    if grep -qE '<<[[:space:]]*WORKFLOW_' "$WORKER_JS"; then
        fail "6: worker contains workflow sentinels (prohibited in worker context)"
        return
    fi
    # Symmetric positive: the gate sentinel is emitted by the SKILL, not the worker.
    if [ -s "$GATE_BLOCK" ] && grep -qE '<<WORKFLOW_MARK_STEP_' "$GATE_BLOCK"; then
        pass "6: worker emits no sentinel; the gate block owns the sentinel emission"
    else
        fail "6: gate block no longer emits a WORKFLOW_MARK_STEP sentinel"
    fi
}

# ── Test 7: no AskUserQuestion anywhere in the worker ────────────────────────
test_no_ask() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "7: worker module missing — cannot check AskUserQuestion"
        return
    fi
    if grep -qF 'AskUserQuestion' "$WORKER_JS"; then
        fail "7: worker references AskUserQuestion (a plain script cannot ask the user)"
    else
        pass "7: worker contains no AskUserQuestion"
    fi
}

# ── Test 8: worker invokes no skills ──────────────────────────────────────────
# Source scan plus the structural guarantee: the registry caps this worker's
# external binaries and named scripts, so no skill dispatch surface exists.
test_no_skill_invocations() {
    if [ ! -f "$WORKER_JS" ] || [ ! -f "$REGISTRY_JS" ]; then
        fail "8: worker module or registry missing — cannot check skill invocations"
        return
    fi
    if grep -qE '`/[a-z]|Skill tool|subagent_type' "$WORKER_JS"; then
        fail "8: worker contains skill invocations (prohibited)"
        return
    fi
    local caps
    caps=$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      const e = reg.workers["session-close-gate"];
      const ext = (e.binaries.external || []).slice().sort().join("|");
      const scripts = Object.keys(e.binaries.scripts || {}).sort().join("|");
      process.stdout.write(ext + " :: " + scripts);
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)
    if [ "$caps" = "node :: report|writeAlert|writeAudit" ]; then
        pass "8: worker invokes no skills; capability surface is node + 3 supervisor CLIs"
    else
        fail "8: unexpected capability surface" "got='$caps'"
    fi
}

# ── Test 9: gate block emits the workflow sentinel on the success path ───────
test_sc_skill_sentinel_on_success() {
    if [ ! -s "$GATE_BLOCK" ]; then
        fail "9: SC-4+SC-5 gate block not found in $SC_MD"
        return
    fi
    if grep -qE '<<WORKFLOW_MARK_STEP_' "$GATE_BLOCK"; then
        pass "9: gate block emits a WORKFLOW_MARK_STEP sentinel on success"
    else
        fail "9: gate block missing WORKFLOW_MARK_STEP sentinel"
    fi
}

# ── Test 10: gate block: yield → STOP after sentinel ─────────────────────────
test_sc_skill_yield_stop() {
    if [ ! -s "$GATE_BLOCK" ]; then
        fail "10: SC-4+SC-5 gate block not found in $SC_MD"
        return
    fi
    if grep -qE 'yield.*(stop|STOP|halt|do not.*SC-6|SC-6.*not)' "$GATE_BLOCK" || \
       grep -qE '(stop|STOP|halt).*yield' "$GATE_BLOCK"; then
        pass "10: gate block documents yield → STOP (SC-6 skipped)"
    else
        fail "10: gate block missing yield→STOP semantics"
    fi
}

# ── Test 11: gate block: proceed → SC-6 runs ─────────────────────────────────
test_sc_skill_proceed_continues() {
    if [ ! -s "$GATE_BLOCK" ]; then
        fail "11: SC-4+SC-5 gate block not found in $SC_MD"
        return
    fi
    if grep -qE 'proceed.*(SC-6|continue)|(SC-6|continue).*proceed' "$GATE_BLOCK"; then
        pass "11: gate block documents proceed → SC-6 continues"
    else
        fail "11: gate block missing proceed→SC-6 semantics"
    fi
}

# ── Test 12: gate block: worker failed → STOP (fail-closed) ──────────────────
test_sc_skill_failed_stop() {
    if [ ! -s "$GATE_BLOCK" ]; then
        fail "12: SC-4+SC-5 gate block not found in $SC_MD"
        return
    fi
    if grep -qE 'failed.*(stop|STOP|halt|abort)|(stop|STOP|halt|abort).*failed' "$GATE_BLOCK"; then
        pass "12: gate block documents worker failed → STOP (fail-closed)"
    else
        fail "12: gate block missing fail-closed (worker failed → STOP)"
    fi
}

# ── Test 13: the GATE BLOCK has no fail-open path ────────────────────────────
# Was a whole-file grep and therefore a false positive: SC-6a's unrelated
# "Fail-open." about cc-session-title matched and the case could never pass.
# Scoped to the gate block, which is the only place the wording would be a defect.
test_sc_skill_no_fail_open() {
    if [ ! -s "$GATE_BLOCK" ]; then
        fail "13: SC-4+SC-5 gate block not found in $SC_MD"
        return
    fi
    if grep -qiE 'fail.open|fail open' "$GATE_BLOCK"; then
        fail "13: SC-4+SC-5 gate block has 'fail-open' text (the gate must be fail-closed)"
    else
        pass "13: SC-4+SC-5 gate block has no 'fail-open' text (correctly fail-closed)"
    fi
}

# ── Test 13b: mutation probe for the T13 extractor ───────────────────────────
# Proves the scoping is not a blanket pass: on a synthetic SKILL the extractor
# must SEE fail-open inside the gate block and must NOT see it outside.
test_extractor_mutation_probe() {
    local synth="$TMPD/synthetic-skill.md" blk="$TMPD/synthetic-block.md"
    local inside outside

    printf '%s\n' \
        '## Step SC-3 — before' \
        'Fail-open. unrelated preamble' \
        '## Steps SC-4+SC-5 — gate' \
        'On failure: Fail-open and continue.' \
        '## Step SC-6 — after' \
        'Fail-open. cc-session-title' > "$synth"
    extract_gate_block "$synth" > "$blk"
    inside=0
    grep -qiE 'fail.open|fail open' "$blk" && inside=1

    printf '%s\n' \
        '## Step SC-3 — before' \
        'Fail-open. unrelated preamble' \
        '## Steps SC-4+SC-5 — gate' \
        'On status failed: STOP. This path is fail-closed.' \
        '## Step SC-6 — after' \
        'Fail-open. cc-session-title' > "$synth"
    extract_gate_block "$synth" > "$blk"
    outside=0
    grep -qiE 'fail.open|fail open' "$blk" && outside=1

    if [ "$inside" -eq 1 ] && [ "$outside" -eq 0 ]; then
        pass "13b: extractor sees fail-open inside the gate block only (mutation probe)"
    else
        fail "13b: extractor scoping wrong" "inside=$inside (want 1) outside=$outside (want 0)"
    fi
}

# ── Test 14: gate block dispatches via the shared worker-dispatch protocol ───
test_sc_skill_shared_protocol() {
    if [ ! -s "$GATE_BLOCK" ]; then
        fail "14: SC-4+SC-5 gate block not found in $SC_MD"
        return
    fi
    local has_worker has_shared
    has_worker=0; has_shared=0
    grep -qF 'session-close-gate' "$GATE_BLOCK" && has_worker=1
    grep -qF "$SHARED_MD" "$GATE_BLOCK" && has_shared=1
    if [ "$has_worker" -eq 1 ] && [ "$has_shared" -eq 1 ]; then
        pass "14: gate block dispatches session-close-gate per $SHARED_MD"
    else
        fail "14: gate block dispatch reference incomplete" "worker=$has_worker shared=$has_shared"
    fi
}

if [ -f "$SC_MD" ]; then
    extract_gate_block "$SC_MD" > "$GATE_BLOCK"
else
    : > "$GATE_BLOCK"
    fail "0: skills/session-close/SKILL.md missing"
fi

test_worker_exists
test_output_contract
test_gate_action_proceed
test_gate_action_yield
test_yield_stops_sc6
test_no_sentinels
test_no_ask
test_no_skill_invocations
test_sc_skill_sentinel_on_success
test_sc_skill_yield_stop
test_sc_skill_proceed_continues
test_sc_skill_failed_stop
test_sc_skill_no_fail_open
test_extractor_mutation_probe
test_sc_skill_shared_protocol

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
