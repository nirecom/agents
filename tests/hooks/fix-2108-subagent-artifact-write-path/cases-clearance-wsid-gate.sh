#!/usr/bin/env bash
# Tests: hooks/supervisor-off-proposal-shim.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/protected-basenames.js, hooks/lib/resolve-workflow-session-id.js
# Tags: off-clearance, fallback-wsid, session-marker, classifier, boundary, security, scope:issue-specific, pwsh-not-required, TL2
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).
SHIM_HOOK="$AGENTS_NODE/hooks/supervisor-off-proposal-shim.js"
OFFCLR_NODE="$AGENTS_NODE/hooks/workflow-mark/enforce-override-handlers/off-clearance.js"
RESOLVER_NODE="$AGENTS_NODE/hooks/lib/resolve-workflow-session-id.js"
SHIM_SH="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
OFFCLR_SH="$AGENTS_DIR/hooks/workflow-mark/enforce-override-handlers/off-clearance.js"

# Section A (clearance-wsid-gate) — the READ-side hole that #2108's write-gate
# narrowing opened. WRITE side: protected-basenames.js `isClearanceBearingStem` is
# true on CANONICAL SHAPE ALONE, observation-free — so a canonically-named clearance
# file is one no agent could have created under the post-#2108 gate, whereas a
# NON-canonical stem is exactly the class that gate now permits anyone to write.
# READ side: two OFF-clearance readers resolve a FALLBACK session id through
# resolve-workflow-session-id.js, whose Priority 4 derives it from `*-context.md`
# filename prefixes in the agent-writable WORKFLOW_PLANS_DIR. `20260827-evilx-context.md`
# yields wsid `20260827-evilx` — non-canonical, hence writable as
# `20260827-evilx.off-clearance`, and today honoured as the OFF authorization.
CWG_ROOT="$TMPBASE_SH/clearance-wsid-gate"

# THE PIN: the FALLBACK wsid — and only the fallback — must match
# SID_CANONICAL_EXACT_RE, imported from hooks/lib/protected-basenames.js and never
# re-spelled locally (CPR-SSOT; A-9 pins that statically).
# SCOPE BOUNDARY, pinned on purpose (A-5): the PRIMARY candidate — the stdin
# `session_id` — is NOT gated. It comes from the Claude Code host, not from anything an
# agent can write, and real host ids are not always canonical. A future implementer who
# "tidies" the gate onto the primary breaks every such session; A-5 fails when they do.
CWG_UUID="0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6"

# TL3 gap (what this section does NOT catch):
# - The shim firing as a REAL PreToolUse hook in a live `claude -p` session: here it is
#   a node subprocess on synthetic stdin, so settings.json routing is out of frame.
# - A real Claude Code session_id, so A-5's premise is argued, not observed.
# - workflow-mark.js's real activation sequence around consumeOffClearance() (A-6/A-7
#   call it directly), so ordering against marker-write is not exercised.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
_cwg_now_iso() { node -e "process.stdout.write(new Date().toISOString())" 2>/dev/null; }
_cwg_today()   { node -e "const d=new Date();process.stdout.write(String(d.getFullYear())+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'))" 2>/dev/null; }

# _cwg_mkcase <name> -> case root. Every case gets its OWN workflow dir, plans dir and
# CWD so no case can read another's tokens (rules/test/fixture-isolation.md).
_cwg_mkcase() {
    local root="$CWG_ROOT/$1"
    rm -rf "$root" 2>/dev/null || true
    mkdir -p "$root/wf" "$root/plans" "$root/cwd"
    printf '%s' "$root"
}

# _cwg_write_token <wfdir> <sid> — a BARE token evaluateOffClearance() accepts:
# unexpired, target=workflow, category=maintenance (the sentinel reason below carries
# `[maintenance]` as its bracketed prefix — that is the reason-binding contract).
_cwg_write_token() {
    local wf="$1" sid="$2" exp
    exp="$(node -e "process.stdout.write(new Date(Date.now()+3600000).toISOString())" 2>/dev/null)"
    printf '{"target":"workflow","category":"maintenance","granted_at":"%s","expires_at":"%s"}' \
        "$(_cwg_now_iso)" "$exp" > "$wf/$sid.off-clearance"
}

# _cwg_write_claim <wfdir> <sid> — the CLAIMED token consumeOffClearance() looks for.
_cwg_write_claim() {
    local wf="$1" sid="$2"
    printf '{"target":"workflow","category":"maintenance","claimed_at":"%s","claimed_by_sid":"%s","claimed_target":"workflow","claimed_reason":"[maintenance] cwg fixture"}' \
        "$(_cwg_now_iso)" "$sid" > "$wf/$sid.off-clearance.claimed"
}

# _cwg_write_provenance <wfdir> <sid> — a fresh, valid EMERGENCY provenance marker.
_cwg_write_provenance() {
    local wf="$1" sid="$2"
    printf '{"invoked_at":"%s","source":"user_skill_invocation","skill":"enforce-workflow-off","targets":["workflow","worktree"]}' \
        "$(_cwg_now_iso)" > "$wf/$sid.off-emergency-invoked"
}

_cwg_exists() { if [ -e "$1" ]; then printf 'yes'; else printf 'no'; fi; }

# _cwg_env_run <caseroot> <cmd...> — run in the case's CWD with the case's dirs pinned.
# Dual-pin is mandatory: CLAUDE_WORKFLOW_DIR alone leaks supervisor appends into the
# real ~/.workflow-plans AND leaves the resolver scanning the REAL plans dir, which
# would make every fallback assertion below meaningless.
_cwg_env_run() {
    local root="$1"; shift
    (
        cd "$root/cwd" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_WORKFLOW_DIR="$(node_path "$root/wf")"
        export WORKFLOW_PLANS_DIR="$(node_path "$root/plans")"
        "$@"
    )
}

# _cwg_resolve_wsid <caseroot> -> what resolveWorkflowSessionId() answers HERE. Every
# case asserts this first: a fixture that resolved to nothing would pass for the wrong
# reason once the gate lands, because it would block/skip regardless.
_cwg_resolve_wsid() {
    _cwg_env_run "$1" "$RWT" 25 node \
        -e "const {resolveWorkflowSessionId}=require(process.argv[1]);process.stdout.write(String(resolveWorkflowSessionId()||''))" \
        "$RESOLVER_NODE" 2>/dev/null
}

# _cwg_run_shim <caseroot> <stdin-sid> -> raw shim stdout (+ <<HOOK_EXIT_n>>).
_cwg_run_shim() {
    local root="$1" sid="$2" input cmd
    cmd='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [maintenance] cwg fixture>>"'
    input="$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' \
        "$sid" "$(json_esc "$cmd")")"
    _cwg_env_run "$root" run_hook_capture "$input" "$RWT" 25 node "$SHIM_HOOK"
}

# The shim exits 2 on block (payload on stdout) and 0 on allow, so the block probe must
# be read BEFORE the exit marker — otherwise every block would read as `crash`.
_cwg_decision() {
    case "$1" in
        *'"decision":"block"'*) printf 'block'; return ;;
        *'<<HOOK_EXIT_124>>'*|*'<<HOOK_EXIT_142>>'*|*'<<HOOK_EXIT_137>>'*) printf 'timeout'; return ;;
        *'<<HOOK_EXIT_'*) printf 'crash'; return ;;
    esac
    [ -z "$(printf '%s' "$1" | tr -d '\r\n')" ] && { printf 'approve'; return; }
    printf 'unrecognized'
}

_cwg_write_probes() {
    cat > "$PROBE_DIR/cwg-consume-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <off-clearance.js> <target> <sessionId>
require(process.argv[2]).consumeOffClearance(process.argv[3], process.argv[4]);
process.stdout.write("done");
PROBE_EOF
    cat > "$PROBE_DIR/cwg-provenance-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <off-clearance.js> <target> <sessionId>
// resolveEmergencyProvenance() is resolveEmergencyProvenanceDetail()'s only exported
// caller and returns its `provenance` field verbatim, so this reaches the same
// candidate loop the fix gates.
const { resolveEmergencyProvenance } = require(process.argv[2]);
process.stdout.write(String(resolveEmergencyProvenance(process.argv[4], process.argv[3])));
PROBE_EOF
}

# --- A-1 / A-2 / A-3 / A-4 / A-5 : the SHIM reader --------------------------------
run_A_clearance_wsid_shim() {
    local today root wsid got label want stdin_sid

    _cwg_write_probes
    today="$(_cwg_today)"
    if [ ! -f "$SHIM_SH" ]; then
        fail "A-0 supervisor-off-proposal-shim.js MISSING at $SHIM_SH - Section A would be vacuous"
        return
    fi
    if [ -z "$today" ]; then fail "A-0 could not compute today's YYYYMMDD"; return; fi

    # --- A-1 ATTACK: agent-planted plans-dir artifact + agent-writable token -------
    root="$(_cwg_mkcase a1-attack)"
    printf '# planted\n' > "$root/plans/$today-evilx-context.md"
    _cwg_write_token "$root/wf" "$today-evilx"
    assert_eq "A-1 precondition: plans-dir prefix resolves as the fallback wsid" \
        "$today-evilx" "$(_cwg_resolve_wsid "$root")"
    got="$(_cwg_decision "$(_cwg_run_shim "$root" "cwgvictim1")")"
    assert_eq "A-1 non-canonical fallback wsid must NOT authorize the OFF proposal" "block" "$got"
    # Pattern 1 — negative assertion on the protected resource itself: a token merely
    # "not honoured" but still claimed/unlinked would be a spent forgery, and the next
    # honest proposal would see `already-claimed` instead of `no-clearance`.
    assert_eq "A-1 forged token was NOT claimed" "no" \
        "$(_cwg_exists "$root/wf/$today-evilx.off-clearance.claimed")"
    assert_eq "A-1 forged token was NOT consumed" "yes" \
        "$(_cwg_exists "$root/wf/$today-evilx.off-clearance")"

    # --- A-2 CONTROL: canonical UUID fallback, differing from the stdin sid --------
    # Priority 4 cannot produce a UUID (it demands a date prefix), so the canonical
    # controls arrive through Priority 1 — WORKTREE_NOTES.md `Session-ID:` — which is
    # the resolver path a real worktree session actually takes.
    root="$(_cwg_mkcase a2-canonical-uuid)"
    printf 'Session-ID: %s\n' "$CWG_UUID" > "$root/cwd/WORKTREE_NOTES.md"
    _cwg_write_token "$root/wf" "$CWG_UUID"
    assert_eq "A-2 precondition: notes Session-ID resolves as the fallback wsid" \
        "$CWG_UUID" "$(_cwg_resolve_wsid "$root")"
    assert_eq "A-2 canonical UUID fallback wsid is still honoured" "approve" \
        "$(_cwg_decision "$(_cwg_run_shim "$root" "cwgvictim2")")"
    assert_eq "A-2 canonical fallback token was claimed" "yes" \
        "$(_cwg_exists "$root/wf/$CWG_UUID.off-clearance.claimed")"

    # --- A-3 CONTROL: canonical YYYYMMDD-HHMMSS through the SAME vector as A-1 -----
    # Same plants, same writer; only the SHAPE of the stem differs (CPR-ORTH).
    root="$(_cwg_mkcase a3-canonical-ts)"
    printf '# clarify-intent fallback id\n' > "$root/plans/$today-143012-context.md"
    _cwg_write_token "$root/wf" "$today-143012"
    assert_eq "A-3 precondition: timestamp prefix resolves as the fallback wsid" \
        "$today-143012" "$(_cwg_resolve_wsid "$root")"
    assert_eq "A-3 canonical YYYYMMDD-HHMMSS fallback wsid is still honoured" "approve" \
        "$(_cwg_decision "$(_cwg_run_shim "$root" "cwgvictim3")")"

    # --- A-4 BOUNDARY TABLE (parser-regex-tests.md): an anchored regex fails at its
    # EDGES, one character either side. Both directions share ONE table so an
    # over-narrowed gate (rejecting real ids) is as visible as an under-narrowed one
    # (protection-fix-tests.md Pattern 4).
    # Columns: label | fallback wsid planted in WORKTREE_NOTES.md | expected verdict.
    stdin_sid="cwgvictim4"
    while IFS='|' read -r label wsid want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; wsid="${wsid//[[:space:]]/}"; want="${want//[[:space:]]/}"
        root="$(_cwg_mkcase "a4-$label")"
        printf 'Session-ID: %s\n' "$wsid" > "$root/cwd/WORKTREE_NOTES.md"
        _cwg_write_token "$root/wf" "$wsid"
        # Per-row precondition: without it a row that merely failed to resolve would
        # score as a correct reject.
        assert_eq "A-4 $label resolves as the fallback wsid" "$wsid" "$(_cwg_resolve_wsid "$root")"
        assert_eq "A-4 $label" "$want" "$(_cwg_decision "$(_cwg_run_shim "$root" "$stdin_sid")")"
    done <<'WSID_SHAPE_TABLE'
# --- ACCEPT: the two canonical shapes, plus a case variant (the regex carries /i)
accept-uuid-lower     | 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6 | approve
accept-uuid-upper     | 0F3D9A21-4B6C-4D7E-8F90-A1B2C3D4E5F6 | approve
accept-ts             | 20260825-143012                      | approve
# --- REJECT: one character either side of the timestamp shape
reject-ts-one-short   | 20260825-14301                       | block
reject-ts-one-long    | 20260825-1430123                     | block
# --- REJECT: a UUID group of the wrong length, and a non-hex character in one
reject-uuid-short-grp | 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f  | block
reject-uuid-nonhex    | 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5fg | block
# --- REJECT: the #2108 attack shape itself, and a bare word
reject-ts-word        | 20260825-evilx                       | block
reject-plain-word     | evilsession                          | block
WSID_SHAPE_TABLE

    # --- A-5 NON-REGRESSION: the PRIMARY candidate is deliberately UNGATED ---------
    # A host-supplied session_id is not agent-writable and is not always canonical. No
    # fallback resolves here, so only the primary path can produce an approve.
    root="$(_cwg_mkcase a5-primary-ungated)"
    _cwg_write_token "$root/wf" "cwg-noncanonical-primary"
    assert_eq "A-5 precondition: no fallback wsid resolves in this fixture" "" \
        "$(_cwg_resolve_wsid "$root")"
    assert_eq "A-5 non-canonical stdin session_id keys its OWN token (primary ungated)" "approve" \
        "$(_cwg_decision "$(_cwg_run_shim "$root" "cwg-noncanonical-primary")")"
    assert_eq "A-5 the primary token was claimed" "yes" \
        "$(_cwg_exists "$root/wf/cwg-noncanonical-primary.off-clearance.claimed")"
}

# --- A-6 / A-7 / A-8 : the CONSUMPTION + PROVENANCE reader ------------------------
run_A_clearance_wsid_consume() {
    local today root

    _cwg_write_probes
    today="$(_cwg_today)"
    if [ ! -f "$OFFCLR_SH" ]; then
        fail "A-0 off-clearance.js MISSING at $OFFCLR_SH - A-6..A-8 would be vacuous"
        return
    fi

    # --- A-6 ATTACK: a non-canonical wsid candidate must not have its claim consumed.
    # Pattern 1 — the assertion is on the FILE, not a return value: consumeOffClearance
    # returns undefined either way, so only the survivor proves the candidate was skipped.
    root="$(_cwg_mkcase a6-consume-attack)"
    printf '# planted\n' > "$root/plans/$today-evilc-context.md"
    _cwg_write_claim "$root/wf" "$today-evilc"
    assert_eq "A-6 precondition: plans-dir prefix resolves as the consume candidate" \
        "$today-evilc" "$(_cwg_resolve_wsid "$root")"
    _cwg_env_run "$root" "$RWT" 25 node "$PROBE_DIR/cwg-consume-probe.js" \
        "$OFFCLR_NODE" workflow cwgconsumer6 >/dev/null 2>&1
    assert_eq "A-6 non-canonical wsid candidate's .claimed file still EXISTS" "yes" \
        "$(_cwg_exists "$root/wf/$today-evilc.off-clearance.claimed")"

    # --- A-7 CONTROL: a canonical wsid differing from sessionId is still consumed ---
    root="$(_cwg_mkcase a7-consume-canonical)"
    printf 'Session-ID: %s\n' "$CWG_UUID" > "$root/cwd/WORKTREE_NOTES.md"
    _cwg_write_claim "$root/wf" "$CWG_UUID"
    assert_eq "A-7 precondition: notes Session-ID resolves as the consume candidate" \
        "$CWG_UUID" "$(_cwg_resolve_wsid "$root")"
    _cwg_env_run "$root" "$RWT" 25 node "$PROBE_DIR/cwg-consume-probe.js" \
        "$OFFCLR_NODE" workflow cwgconsumer7 >/dev/null 2>&1
    assert_eq "A-7 canonical wsid candidate's .claimed file WAS consumed" "no" \
        "$(_cwg_exists "$root/wf/$CWG_UUID.off-clearance.claimed")"

    # --- A-8 PROVENANCE, both directions (CPR-ORTH) -------------------------------
    root="$(_cwg_mkcase a8-prov-attack)"
    printf '# planted\n' > "$root/plans/$today-evilp-context.md"
    _cwg_write_provenance "$root/wf" "$today-evilp"
    assert_eq "A-8 precondition: plans-dir prefix resolves as the provenance candidate" \
        "$today-evilp" "$(_cwg_resolve_wsid "$root")"
    assert_eq "A-8 non-canonical wsid yields NO attribution" "unattributed" \
        "$(_cwg_env_run "$root" "$RWT" 25 node "$PROBE_DIR/cwg-provenance-probe.js" "$OFFCLR_NODE" workflow cwgprov8 2>/dev/null)"
    assert_eq "A-8 non-canonical wsid's provenance marker was NOT consumed" "yes" \
        "$(_cwg_exists "$root/wf/$today-evilp.off-emergency-invoked")"

    root="$(_cwg_mkcase a8-prov-canonical)"
    printf 'Session-ID: %s\n' "$CWG_UUID" > "$root/cwd/WORKTREE_NOTES.md"
    _cwg_write_provenance "$root/wf" "$CWG_UUID"
    assert_eq "A-8 precondition: notes Session-ID resolves as the provenance candidate" \
        "$CWG_UUID" "$(_cwg_resolve_wsid "$root")"
    assert_eq "A-8 canonical wsid still attributes" "user_skill_invocation" \
        "$(_cwg_env_run "$root" "$RWT" 25 node "$PROBE_DIR/cwg-provenance-probe.js" "$OFFCLR_NODE" workflow cwgprov8c 2>/dev/null)"

    # SKIPPED: the same forgery driven through the REAL workflow-mark.js activation, so
    # that "the OFF marker was never written" is asserted instead of "the claim survived".
    # Because: workflow-mark.js gates the sentinel behind settings.json `ask` routing and
    # a live PreToolUse payload, neither of which exists at TL2.
    # L3 gap: whether a forged fallback claim could still reach marker-write through a
    # code path that bypasses consumeOffClearance() entirely.
}

# --- A-9 : STATIC SSOT pin --------------------------------------------------------
# The gate must IMPORT the shape rule, never restate it: a local copy would drift the
# moment protected-basenames.js changes, and the readers would then disagree with the
# write gate about what "canonical" means — the very basis of this file's rationale.
run_A_clearance_wsid_ssot() {
    local f name
    for f in "$SHIM_SH" "$OFFCLR_SH"; do
        name="$(basename "$f")"
        if [ ! -f "$f" ]; then fail "A-9 $name missing - SSOT pin vacuous"; continue; fi
        assert_eq "A-9 $name obtains SID_CANONICAL_EXACT_RE by name" "yes" \
            "$(if grep -qF 'SID_CANONICAL_EXACT_RE' "$f"; then printf yes; else printf no; fi)"
        assert_eq "A-9 $name requires hooks/lib/protected-basenames" "yes" \
            "$(if grep -qF 'protected-basenames' "$f"; then printf yes; else printf no; fi)"
        # Neither half of the canonical pattern may be spelled out locally.
        assert_eq "A-9 $name defines no local UUID-body pattern" "no" \
            "$(if grep -qF '[0-9a-f]{8}-' "$f"; then printf yes; else printf no; fi)"
        assert_eq "A-9 $name defines no local timestamp-body pattern" "no" \
            "$(if grep -qF '[0-9]{8}-[0-9]{6}' "$f"; then printf yes; else printf no; fi)"
    done
}

# Single entry point so the aggregator gains one source line and one call line.
run_A_clearance_wsid_gate() {
    run_A_clearance_wsid_shim
    run_A_clearance_wsid_consume
    run_A_clearance_wsid_ssot
    rm -rf "$CWG_ROOT" 2>/dev/null || true
    return 0
}
