# shellcheck shell=bash
# TL3 body for the reserved-glob off-switch gate (detail plan 4-2 .. 4-4).
# Sourced by ../TL3-rules-injection-off-switch.sh after helpers.sh.
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js, hooks/lib/rules-injection-policy.js, rules/test.md
# Tags: rules-injection, on-demand-rules, off-switch, instructions-loaded, quiescence, claude-e2e, TL3, scope:common
#
# Asymmetry (fail-closed on G-PASS): a SINGLE observation of probe-target.md is
# enough for G-FAIL; G-PASS requires every condition (Q1, Q2, G4, Q3) to hold.

echo ""
echo "=== TL3: reserved-glob off-switch — RUN-BASE / RUN-JUDGE + quiescence ==="

RIL_NONCE_A1="RILNONCE-A1-6f21"
RIL_NONCE_A2="RILNONCE-A2-6f22"
RIL_NONCE_A3="RILNONCE-A3-6f23"
RIL_NONCE_B="RILNONCE-B-6f2b"

RIL_BASE="$(make_tmp_base)"
trap 'rm -rf "$RIL_BASE"' EXIT
RIL_WF="$RIL_BASE/workflow"; RIL_PLANS="$RIL_BASE/plans"
mkdir -p "$RIL_WF" "$RIL_PLANS"

SID_G0P="7b1c0a10-0000-0000-0000-0000000000a1"
SID_G0C="7b1c0a10-0000-0000-0000-0000000000a2"
SID_G0H="7b1c0a10-0000-0000-0000-0000000000a3"
SID_BASE="7b1c0a10-0000-0000-0000-000000000001"
SID_JUDGE="7b1c0a10-0000-0000-0000-000000000002"

RIL_STRATEGY=""
RIL_ABORT=0

# --- G0: config-root substitution exploration (project -> configdir -> home) ---
for attempt in "project:$SID_G0P" "configdir:$SID_G0C" "home:$SID_G0H"; do
    strategy="${attempt%%:*}"; g0sid="${attempt##*:}"
    ril_prepare "$strategy" "$RIL_BASE/g0-$strategy" base || continue
    g0rc="$(ril_run_claude "$g0sid" "$RIL_WF" "$RIL_PLANS")"
    if ril_entry_paths "$RIL_WF" "$g0sid" | grep -q 'probe-control-1.md'; then
        RIL_STRATEGY="$strategy"
        pass "G0. config-root substitution works via '$strategy' (nonce A1 receipt observed)"
        break
    fi
    echo "G0: strategy '$strategy' produced no A1 receipt (claude rc=$g0rc)"
done

if [ -z "$RIL_STRATEGY" ]; then
    echo "G-INCONCLUSIVE"
    fail "G0. no config-root substitution worked (project / CLAUDE_CONFIG_DIR / HOME all failed) — the gate cannot run; S3 must take the B route"
    RIL_ABORT=1
fi

# --- G1 RUN-BASE: every probe unconditional; measure EXPECTED_SET, S and W ---
RIL_EXPECTED=""; RIL_W=5; RIL_S=0
if [ "$RIL_ABORT" -eq 0 ]; then
    ril_prepare "$RIL_STRATEGY" "$RIL_BASE/base" base
    base_rc="$(ril_run_claude "$SID_BASE" "$RIL_WF" "$RIL_PLANS")"
    base_dir="$(ril_receipt_dir "$RIL_WF" "$SID_BASE")"
    RIL_EXPECTED="$(ril_entry_paths "$RIL_WF" "$SID_BASE")"
    base_n="$(printf '%s\n' "$RIL_EXPECTED" | grep -c '[^[:space:]]' || true)"

    # C4: the RUN-BASE decision table (subprocess rc first) lives in helpers.sh so the
    # same logic is exercised at TL2 by tests/cc-tl3-rules-injection-gate.sh.
    base_dir_exists=0; [ -d "$base_dir" ] && base_dir_exists=1
    base_target=0
    printf '%s\n' "$RIL_EXPECTED" | grep -q 'probe-target.md' && base_target=1
    base_status="$(ril_gate_base_status "$base_rc" "$base_dir_exists" "$base_n" "$base_target")"

    if [ "$base_status" != "OK" ]; then
        echo "G-INCONCLUSIVE"
        fail "G1. ${base_status#INCONCLUSIVE } (dir=$base_dir, claude rc=$base_rc)"
        RIL_ABORT=1
    else
        RIL_S="$(ril_span_seconds "$RIL_WF" "$SID_BASE")"
        RIL_W=$((2 * RIL_S))
        [ "$RIL_W" -lt 5 ] && RIL_W=5
        [ "$RIL_W" -gt 30 ] && RIL_W=30
        echo "G1: S=${RIL_S}s W=${RIL_W}s |EXPECTED_SET|=$base_n"
        pass "G1. RUN-BASE fired: |EXPECTED_SET|=$base_n including probe-target.md (S=${RIL_S}s, W=${RIL_W}s)"
    fi
fi

# --- F1 fallback: only when the payload shape carries no file_path at all ---
if [ "$RIL_ABORT" -eq 1 ] && [ -n "$RIL_STRATEGY" ] && [ -d "$(ril_receipt_dir "$RIL_WF" "$SID_BASE")" ] \
   && [ -z "$(ril_entry_paths "$RIL_WF" "$SID_BASE")" ]; then
    echo "FALLBACK: F1 model-probe used"
    ril_prepare "$RIL_STRATEGY" "$RIL_BASE/f1" judge
    f1_rc=0
    f1_out="$(
        cd "$RIL_REPO" || exit 90
        unset CLAUDECODE; unset CLAUDE_SESSION_ID; unset CLAUDE_CODE_SESSION_ID
        export CLAUDE_WORKFLOW_DIR="$(node_path "$RIL_WF")"
        export WORKFLOW_PLANS_DIR="$(node_path "$RIL_PLANS")"
        [ -n "$RIL_ENV_KIND" ] && export "$RIL_ENV_KIND=$RIL_ENV_VALUE"
        run_with_timeout 180 claude -p \
            "For each of $RIL_NONCE_A1 and $RIL_NONCE_B, answer whether that exact string is present in your context. Reply with exactly two words: the A1 answer then the B answer, each present or absent." \
            --session-id "7b1c0a10-0000-0000-0000-0000000000f1" \
            --setting-sources project --dangerously-skip-permissions --output-format json 2>&1
    )" || f1_rc=$?

    # C2: the fallback's exit code is part of its answer, and the answer is parsed
    # strictly (see ril_f1_verdict). RIL_ABORT and the G1 failure are deliberately NOT
    # cleared here: a model self-report explains why the receipt route saw nothing, it
    # does not substitute for the filesystem observation the gate is built on.
    f1_res="$(ril_f1_verdict "$f1_rc" "$f1_out")"
    f1_verdict="${f1_res%% *}"
    f1_reason="${f1_res#* }"
    if [ "$f1_verdict" = "F1-PASS" ]; then
        pass "F1. $f1_reason (diagnostic only — the G1 failure above still stands)"
    elif [ "$f1_verdict" = "F1-FAIL" ]; then
        echo "G-FAIL"
        fail "F1. $f1_reason"
    else
        echo "G-INCONCLUSIVE"
        fail "F1. $f1_reason (answer: $(printf '%s' "$f1_out" | head -c 200))"
    fi
fi

# --- G2: shape recording only — no assertion (verdicts must not depend on load_reason) ---
if [ "$RIL_ABORT" -eq 0 ]; then
    echo "G2: load_reason presence rate (RUN-BASE) = $(ril_load_reason_rate "$RIL_WF" "$SID_BASE")"
fi

# --- G3 RUN-JUDGE: identical fixture, reserved glob on probe-target.md only ---
RIL_VERDICT=""
if [ "$RIL_ABORT" -eq 0 ]; then
    ril_prepare "$RIL_STRATEGY" "$RIL_BASE/judge" judge
    judge_rc="$(ril_run_claude "$SID_JUDGE" "$RIL_WF" "$RIL_PLANS")"

    # Positive observations never need to wait (asymmetry), so the pre-wait observation
    # is taken first; the quiescence wait only runs when nothing was seen.
    judge_seen=0
    ril_entry_paths "$RIL_WF" "$SID_JUDGE" | grep -q 'probe-target.md' && judge_seen=1

    q_out=""; q_status="NOT_RUN"; judge_seen_after=0
    if [ "$judge_seen" -eq 0 ] && [ "$judge_rc" = "0" ]; then
        expected_json="$(printf '%s\n' "$RIL_EXPECTED" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  const arr=d.split('\n').map(s=>s.trim()).filter(Boolean)
    .filter(p=>!p.endsWith('probe-target.md'));
  console.log(JSON.stringify(Array.from(new Set(arr))));});")"
        q_out="$(ril_quiesce "$RIL_WF" "$SID_JUDGE" "$expected_json" "$RIL_W")"
        q_status="$(printf '%s' "$q_out" | tr ' ' '\n' | grep '^STATUS=' | head -1 | cut -d= -f2-)"
        [ -z "$q_status" ] && q_status="NO_STATUS"
        ril_entry_paths "$RIL_WF" "$SID_JUDGE" | grep -q 'probe-target.md' && judge_seen_after=1
    fi

    # C4: same decision table as the TL2 sibling — absence may never be read out of a
    # run that crashed or timed out, since a killed subprocess leaves exactly the same
    # empty directory as a working off-switch.
    judge_out="$(ril_gate_judge_verdict "$judge_rc" "$judge_seen" "$q_status" "$judge_seen_after")"
    RIL_VERDICT="${judge_out%% *}"
    judge_reason="${judge_out#* }"
    if [ "$RIL_VERDICT" = "G-PASS-PENDING" ]; then
        pass "G3. $judge_reason ($q_out)"
    else
        echo "$RIL_VERDICT"
        fail "G3. $judge_reason (claude rc=$judge_rc, quiescence: ${q_out:-not run})"
    fi
fi

# --- G4 + G5 (Q3): one sticky state machine (C5) ---
# These used to be two independent `if` blocks, each deciding on its own while
# RIL_VERDICT stayed at G-PASS-PENDING — so a failed G4 did not stop G5 from printing
# the pass token. The decision is now made once, in ril_post_quiescence() (decisions.sh,
# exercised branch-by-branch at TL2 by tests/cc-tl3-rules-injection-gate.sh), and this
# block only renders its output. The pass token reaches stdout solely as the value of
# VERDICT= below.
RIL_Q3_REQUIRED=30
if [ -n "$RIL_VERDICT" ]; then
    g4_ctrl="$(ril_verdict_for "$RIL_WF" "$SID_JUDGE" "probe-control-1.md")"
    g4_tgt="$(ril_verdict_for "$RIL_WF" "$SID_JUDGE" "probe-target.md")"

    # Q3 is a cumulative observation, not one stat call: the writer is asynchronous.
    q3_seen=0; q3_elapsed=0
    if [ "$RIL_VERDICT" = "G-PASS-PENDING" ]; then
        q3_out="$(ril_terminal_recheck "$RIL_WF" "$SID_JUDGE" 'probe-target.md' "$RIL_Q3_REQUIRED")"
        q3_seen="$(printf '%s' "$q3_out" | tr ' ' '\n' | grep '^SEEN=' | cut -d= -f2)"
        q3_elapsed="$(printf '%s' "$q3_out" | tr ' ' '\n' | grep '^ELAPSED=' | cut -d= -f2)"
    fi

    RIL_FINAL=""
    while IFS= read -r line; do
        case "$line" in
            "PASS "*)    pass "${line#PASS }" ;;
            "FAIL "*)    fail "${line#FAIL }" ;;
            "NOTE "*)    echo "${line#NOTE }" ;;
            "VERDICT="*) RIL_FINAL="${line#VERDICT=}" ;;
        esac
    done <<EOF
$(ril_post_quiescence "$RIL_VERDICT" "$g4_ctrl" "$g4_tgt" "${q3_seen:-0}" "${q3_elapsed:-0}" "$RIL_Q3_REQUIRED")
EOF
    echo "${RIL_FINAL:-G-INCONCLUSIVE}"
fi

# TL3 gap: this gate runs against a fixture config root, not against the real
# ~/.claude/rules symlink (which points at the agents MAIN worktree, so feature-branch
# frontmatter is invisible pre-merge). The post-merge visual confirmation is carried as
# a ManualReminders entry. When the F1 fallback is taken, its "absent" claim rests on
# the model's self-report and is not a filesystem observation.
#
# Division of labor (deliberate, not an oversight): this gate registers the
# InstructionsLoaded hook in its OWN fixture settings.json and never consults the real
# ~/.claude registration — doing so would break fixture isolation, and pre-merge the
# ~/.claude/rules symlink resolves to the agents MAIN worktree where this branch's
# frontmatter does not exist. Integrity of the PRODUCTION registration (settings.json
# key, command string, timeout, and the install/assemble-settings.js emitter) is
# therefore not this file's job: it is asserted against the repo's real files by
# tests/cc-instructions-loaded-registration.sh.
#
# Also out of scope for this tier, recorded so the omissions are deliberate:
# - Per-skill-family read behaviour (test / docs / issue): whether each owning skill
#   really performs its explicit Read once auto-injection is off is whole-pipeline
#   (TL4) territory — one live session per family against a de-injected config root.
#   This gate proves the MECHANISM (the reserved glob suppresses injection); the
#   per-family behaviour is carried as a post-merge WORKTREE_NOTES ManualReminders
#   confirmation.
# - Host honouring of `paths:`: no invocable seam exists for the loader, so the sibling
#   static assertion in tests/cc-rules-injection-scope-conventions.sh proves only that
#   the configuration is what we intended — never that the host obeys it.
