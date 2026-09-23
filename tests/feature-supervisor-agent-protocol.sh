#!/usr/bin/env bash
# tests/feature-supervisor-agent-protocol.sh
# Tests: agents/supervisor.md, agents/supervisor-audit.md
# Tags: scope:issue-specific, pwsh-not-required, supervisor, em-supervisor, findings-codex
# L3 gap (NOT caught): the real supervisor / supervisor-audit subagents following the new
#   protocol at runtime. Mitigation: WORKFLOW_USER_VERIFIED preflight via
#   bin/check-verification-gate.sh category skill-orchestration. Protocol SSOT: detail.md Step 8.
# C9 [LOW] static checks: (a) supervisor.md has no standalone Phase N labels; (b-g) both
#   prompts drive bin/supervisor-findings-codex via the STATUS/OUTFILE single-shot protocol.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"
AUDIT_MD="$AGENTS_DIR/agents/supervisor-audit.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

if [ ! -f "$SUPERVISOR_MD" ]; then
    skip "C9-all: agents/supervisor.md not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- C9a: supervisor.md must NOT contain standalone Phase N labels ---
# After implementation, "### Phase 1/2/3" should be removed. RED-EXPECTED until write-code.
run_c9a() {
    local found
    found=$(grep -iE "^#{1,4} Phase [123]( |$|:)" "$SUPERVISOR_MD" 2>/dev/null || true)
    if [ -n "$found" ]; then
        fail "C9a [RED-EXPECTED]: supervisor.md still contains Phase N section labels (not yet removed):"$'\n'"$found"
    else
        pass "C9a: no standalone 'Phase N' section labels found in supervisor.md"
    fi
}

# NOTE: RED until write-code retires bin/supervisor-review-codex for the shared
#   bin/supervisor-findings-codex engine (#929). Both prompts must name the new bin
#   and neither may name the deleted one.
run_c9b() {
    local ok=1
    grep -qF "bin/supervisor-findings-codex" "$SUPERVISOR_MD" || { ok=0; echo "  supervisor.md: missing bin/supervisor-findings-codex"; }
    grep -qF "bin/supervisor-findings-codex" "$AUDIT_MD" 2>/dev/null || { ok=0; echo "  supervisor-audit.md: missing bin/supervisor-findings-codex"; }
    if grep -qF "supervisor-review-codex" "$SUPERVISOR_MD" 2>/dev/null; then ok=0; echo "  supervisor.md: still names retired supervisor-review-codex"; fi
    if grep -qF "supervisor-review-codex" "$AUDIT_MD" 2>/dev/null; then ok=0; echo "  supervisor-audit.md: still names retired supervisor-review-codex"; fi
    if [ "$ok" -eq 1 ]; then
        pass "C9b: both prompts reference bin/supervisor-findings-codex and neither references supervisor-review-codex"
    else
        fail "C9b [RED-EXPECTED]: findings-codex reference / review-codex removal incomplete"
    fi
}

# NOTE: RED until write-code documents the STATUS single-shot protocol (#929): each prompt
#   must describe the non-SUCCESS branch (SKIPPED/FAILED → fallback / manual review).
run_c9c() {
    local ok=1 f label
    for f in "$SUPERVISOR_MD" "$AUDIT_MD"; do
        label="$(basename "$f")"
        if ! grep -qF "STATUS" "$f" 2>/dev/null; then ok=0; echo "  $label: missing STATUS protocol line"; continue; fi
        if ! grep -qF "SUCCESS" "$f" 2>/dev/null; then ok=0; echo "  $label: missing SUCCESS status token"; fi
        if ! grep -qiE "fall ?back|manual review" "$f" 2>/dev/null; then ok=0; echo "  $label: missing non-SUCCESS fallback instruction"; fi
    done
    if [ "$ok" -eq 1 ]; then
        pass "C9c: both prompts describe STATUS branching (non-SUCCESS → fallback)"
    else
        fail "C9c [RED-EXPECTED]: STATUS-branch fallback description incomplete"
    fi
}

# NOTE: RED until write-code wires the mode-specific OUTFILE handoff (#929):
#   alert ingests via --ingest-generated-jsonl, audit consumes via --findings-jsonl.
run_c9d() {
    local ok=1
    grep -qF -- "--ingest-generated-jsonl" "$SUPERVISOR_MD" || { ok=0; echo "  supervisor.md: missing --ingest-generated-jsonl handoff"; }
    grep -qF -- "--findings-jsonl" "$AUDIT_MD" 2>/dev/null || { ok=0; echo "  supervisor-audit.md: missing --findings-jsonl handoff"; }
    if [ "$ok" -eq 1 ]; then
        pass "C9d: alert prompt hands off via --ingest-generated-jsonl, audit via --findings-jsonl"
    else
        fail "C9d [RED-EXPECTED]: OUTFILE handoff flags incomplete"
    fi
}

# NOTE: RED until write-code has the audit prompt pass audit-only inputs (#929):
#   --subcheck (which stage-boundary check) and --state-snapshot.
run_c9e() {
    local ok=1
    grep -qF -- "--subcheck" "$AUDIT_MD" 2>/dev/null || { ok=0; echo "  supervisor-audit.md: missing --subcheck"; }
    grep -qF -- "--state-snapshot" "$AUDIT_MD" 2>/dev/null || { ok=0; echo "  supervisor-audit.md: missing --state-snapshot"; }
    if [ "$ok" -eq 1 ]; then
        pass "C9e: audit prompt passes --subcheck and --state-snapshot"
    else
        fail "C9e [RED-EXPECTED]: audit-only inputs incomplete"
    fi
}

# NOTE: RED until write-code drops the shell redirect from supervisor.md (#929): the engine
#   emits OUTFILE itself (os.tmpdir), so no prompt may instruct `> /tmp/...` (R3-C4).
run_c9f() {
    local ok=1 f label found
    for f in "$SUPERVISOR_MD" "$AUDIT_MD"; do
        [ -f "$f" ] || continue
        label="$(basename "$f")"
        found=$(grep -nE ">[[:space:]]*/tmp/" "$f" 2>/dev/null || true)
        if [ -n "$found" ]; then ok=0; echo "  $label: carries a shell redirect to /tmp: $found"; fi
    done
    if [ "$ok" -eq 1 ]; then
        pass "C9f: neither prompt instructs a '> /tmp/...' shell redirect (R3-C4)"
    else
        fail "C9f [RED-EXPECTED]: a prompt still carries a '> /tmp/...' redirect"
    fi
}

# --- C9g: both prompts stay under the file-split HARD limit (200 lines) ---
# GREEN with current sources; guards against write-code growing either past the cap.
run_c9g() {
    local ok=1 f label n
    for f in "$SUPERVISOR_MD" "$AUDIT_MD"; do
        [ -f "$f" ] || { ok=0; echo "  $(basename "$f"): missing"; continue; }
        label="$(basename "$f")"
        n=$(wc -l < "$f")
        if [ "$n" -ge 200 ]; then ok=0; echo "  $label: $n lines >= 200 HARD limit"; fi
    done
    if [ "$ok" -eq 1 ]; then
        pass "C9g: both prompts are under the 200-line file-split HARD limit"
    else
        fail "C9g: a prompt is at/over the 200-line HARD limit"
    fi
}

run_c9a
run_c9b
run_c9c
run_c9d
run_c9e
run_c9f
run_c9g

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
