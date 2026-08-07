#!/usr/bin/env bash
# Part of tests/fix-1780-round14-mint-lock.sh (rules/coding/file-split.md).
# A WORKFLOW_DIR RESOLUTION FAILURE IS AUDITED, NOT SILENT — round-14 MEDIUM.
#
# bin/request-off-clearance runs under `set -euo pipefail` and used to define
# append_audit / emergency_hint AFTER resolving the workflow directory. So the
# ONE failure that is most likely when the environment is broken — node missing,
# the state-io module failing to load, getWorkflowDir() throwing — killed the
# script before either helper existed. The operator got an empty exit status and
# nothing else: no UNAVAILABLE record in the audit trail (which is half of this
# feature's trust model, the token being explicitly NOT a security primitive),
# and no pointer to the EMERGENCY sentinel that is the sanctioned way out.
#
# That is worse here than in any other command, because request-off-clearance IS
# the documented recovery path when enforcement is in trouble. A silent failure
# of the recovery path is a dead end.
#
# HOW THE FAILURE IS INDUCED: a synthetic AGENTS_CONFIG_DIR that provides
# hooks/lib/supervisor-state-writer (so the audit path is intact and can be
# observed) but OMITS hooks/workflow-state/state-io/core.js (so the resolution
# node -e cannot load its module). That isolates the resolution step precisely —
# no other step is perturbed — which a broad "break node itself" fixture could
# not do, since it would break the audit write too.
#
# R3 covers the opposite corner: the audit write ITSELF failing. It must stay
# NON-blocking (announced on stderr, script continues to the same exit path),
# because an unwritable audit trail must not also deny the operator the
# emergency guidance.

# _r_fake_acd <dir> <with_core> — build a synthetic AGENTS_CONFIG_DIR.
#   with_core=yes → include a working state-io/core.js re-export
#   with_writer=$3 (yes|no) → include the supervisor-state-writer re-export
# Re-exports point at the REAL modules by absolute path, so their own relative
# requires still resolve; only the PRESENCE of each module is what varies.
_r_fake_acd() {
    local root="$1" with_core="$2" with_writer="$3"
    mkdir -p "$root/hooks/lib" "$root/hooks/workflow-state/state-io"
    if [ "$with_writer" = "yes" ]; then
        printf 'module.exports = require(%s);\n' "\"$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js\"" \
            > "$root/hooks/lib/supervisor-state-writer.js"
    fi
    if [ "$with_core" = "yes" ]; then
        printf 'module.exports = require(%s);\n' "\"$_AGENTS_DIR_NODE/hooks/workflow-state/state-io/core.js\"" \
            > "$root/hooks/workflow-state/state-io/core.js"
    fi
}

# _r_run <acd_node> <plans_node> <target> [stub_bin_dir] → sets _R_RC/_R_OUT/_R_ERR
# When <stub_bin_dir> is given it is PREPENDED to PATH, so the run picks up the
# fake `codex` examiner from tests/lib/examiner-stub.sh instead of a real one.
_r_run() {
    local acd="$1" plans="$2" target="$3" stubdir="${4-}" errfile runpath
    errfile=$(mktemp 2>/dev/null || mktemp -t offclrerr)
    runpath="$PATH"
    [ -n "$stubdir" ] && runpath="$stubdir:$PATH"
    _R_OUT=$(PATH="$runpath" SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" CLAUDE_CODE_SESSION_ID="$SID" \
        CLAUDE_WORKFLOW_DIR="$plans" WORKFLOW_PLANS_DIR="$plans" AGENTS_CONFIG_DIR="$acd" \
        "$RWT" 90 bash "$REQ" --target "$target" --category workflow-bug \
        --detail "next-step is wedged and blocks all progress" 2>"$errfile")
    _R_RC=$?
    _R_ERR=$(cat "$errfile" 2>/dev/null)
    rm -f "$errfile"
}

# _r_audit_text <plans_dir> — the supervisor state file's raw text, or ABSENT
_r_audit_text() {
    local f="$1/$SID-supervisor-state.json"
    [ -f "$f" ] || { printf 'ABSENT'; return; }
    tr -d '\r\n' < "$f"
}

run_R_cli_wfdir_failure() {
    local tmp tn acd

    # ---- R1: the regression itself, workflow target.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    acd="$tmp/fake-acd"; _r_fake_acd "$acd" "no" "yes"
    _r_run "$(node_path "$acd")" "$tn" "workflow"

    assert_eq  "R1 a WORKFLOW_DIR failure exits 1 (not a silent set -e death)" "1" "$_R_RC"
    assert_has "R1 the failure is NAMED on stderr" \
        "could not resolve the workflow directory" "$_R_ERR"
    assert_has "R1 the underlying node error is passed through, not swallowed" \
        "--- resolution stderr ---" "$_R_ERR"
    assert_has "R1 the operator is pointed at the EMERGENCY sentinel" \
        "WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY" "$_R_OUT"
    assert_has "R1 and told plainly that no token was minted" \
        "No clearance token was minted." "$_R_OUT"

    local audit; audit=$(_r_audit_text "$tmp")
    assert_has "R1 an off_examination record reached the audit trail" "off_examination" "$audit"
    assert_has "R1 recorded with verdict=UNAVAILABLE" "verdict=UNAVAILABLE" "$audit"
    assert_has "R1 recorded with the SPECIFIC reason (not a generic failure)" \
        "workflow dir resolution failed" "$audit"
    assert_has "R1 the audit keeps the requested target/category" "target=workflow" "$audit"
    assert_eq  "R1 no clearance token was minted" "no" "$(exists_str "$tmp/$SID.off-clearance")"
    assert_eq  "R1 no stray mint lock left behind" "no" "$(exists_str "$tmp/$SID.off-clearance.mint.lock.tmp")"
    rm -rf "$tmp"

    # ---- R1b: CPR-ORTH symmetry. The worktree target is the other half of this
    # command's domain and must get the CORRECT emergency sentinel name — a hint
    # naming the wrong sentinel is worse than none, since the operator would emit
    # a sentinel that does not clear their block.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    acd="$tmp/fake-acd"; _r_fake_acd "$acd" "no" "yes"
    _r_run "$(node_path "$acd")" "$tn" "worktree"
    assert_eq  "R1b worktree target also exits 1" "1" "$_R_RC"
    assert_has "R1b hint names the WORKTREE emergency sentinel" \
        "WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY" "$_R_OUT"
    assert_has "R1b audit records the worktree target" "target=worktree" "$(_r_audit_text "$tmp")"
    rm -rf "$tmp"

    # ---- R2: CONTROL. The same command, with the resolution able to succeed,
    # must run the examination THROUGH to a verdict. Without this, every R1
    # assertion could be satisfied by a command that always exits 1 early, and
    # the "audit trail reached" assertions could be satisfied by an audit written
    # on some unrelated path.
    #
    # The examiner is the shared nonce-echoing stub (tests/lib/examiner-stub.sh),
    # not a real codex: the verdict must be decided by the fixture, not by a live
    # model, or the case is neither hermetic nor repeatable.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    mkdir -p "$tmp/bin"; write_examiner_stub "$tmp/bin/codex" "REJECT" "not legitimate under the rubric"
    _r_run "$_AGENTS_DIR_NODE" "$tn" "workflow" "$tmp/bin"
    assert_not_has "R2 resolution step is passed when the module loads" \
        "could not resolve the workflow directory" "$_R_ERR"
    assert_has "R2 the examination runs through to the examiner's verdict" \
        "REJECT" "$_R_OUT$_R_ERR"
    assert_has "R2 the REJECT verdict is audited (audit path is genuinely live)" \
        "verdict=REJECT" "$(_r_audit_text "$tmp")"
    assert_eq  "R2 a REJECT mints no token" "no" "$(exists_str "$tmp/$SID.off-clearance")"
    rm -rf "$tmp"

    # ---- R4: the ALLOW path, which is the only one that reaches the MINT and
    # therefore the only one that takes the mint lock. It must leave no lock
    # behind: a leaked lock wedges every later mint AND every later shim claim
    # for this SID until the 24h transient sweep.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    mkdir -p "$tmp/bin"; write_examiner_stub "$tmp/bin/codex" "ALLOW" "workflow-bug blocks all progress"
    _r_run "$_AGENTS_DIR_NODE" "$tn" "workflow" "$tmp/bin"
    assert_eq  "R4 an ALLOW examination succeeds (exit 0)" "0" "$_R_RC"
    assert_eq  "R4 the clearance token is minted" "yes" "$(exists_str "$tmp/$SID.off-clearance")"
    assert_eq  "R4 the mint released its lock" "no" "$(exists_str "$tmp/$SID.off-clearance.mint.lock.tmp")"
    assert_has "R4 the ALLOW is audited" "verdict=ALLOW" "$(_r_audit_text "$tmp")"
    rm -rf "$tmp"

    # ---- R5: the mint side of the SAME lock the shim takes (CPR-ORTH — both
    # participants, same mutex, same fail-closed direction). With the lock
    # already held the mint must NOT proceed: an ALLOW verdict that cannot be
    # safely published is an UNAVAILABLE examination, not a token.
    #
    # This is also the case that shows why the lock file must be protected state
    # (see ./cases-lock-protected.sh): one pre-created file denies clearance for
    # the whole SID, and here that is done with a single `: >`.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    mkdir -p "$tmp/bin"; write_examiner_stub "$tmp/bin/codex" "ALLOW" "workflow-bug blocks all progress"
    : > "$tmp/$SID.off-clearance.mint.lock.tmp"
    _r_run "$_AGENTS_DIR_NODE" "$tn" "workflow" "$tmp/bin"
    assert_eq  "R5 a held mint lock fails the run closed (exit 1)" "1" "$_R_RC"
    assert_has "R5 the operator is told another run holds the lock" \
        "holds the mint lock for this session" "$_R_ERR"
    assert_has "R5 with the stale-lock recovery route named" \
        "24h transient sweep" "$_R_ERR"
    assert_has "R5 the emergency guidance is still offered" \
        "WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY" "$_R_OUT"
    assert_has "R5 audited as UNAVAILABLE with the lock-specific reason" \
        "mint lock for this session could not be acquired within 5s" "$(_r_audit_text "$tmp")"
    assert_eq  "R5 NO token was published despite an ALLOW verdict" "no" \
        "$(exists_str "$tmp/$SID.off-clearance")"
    assert_eq  "R5 the foreign lock was not stolen or deleted" "yes" \
        "$(exists_str "$tmp/$SID.off-clearance.mint.lock.tmp")"
    rm -rf "$tmp"

    # ---- R3: the audit write itself fails (writer module absent). Auditing is
    # explicitly NON-blocking: the operator must still get the diagnosis and the
    # emergency guidance, and the exit status must not change.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    acd="$tmp/fake-acd"; _r_fake_acd "$acd" "no" "no"
    _r_run "$(node_path "$acd")" "$tn" "workflow"
    assert_eq  "R3 a failed audit does not change the exit status" "1" "$_R_RC"
    assert_has "R3 the dropped audit entry is ANNOUNCED, not hidden" \
        "OFF-clearance audit write failed" "$_R_ERR"
    assert_has "R3 and declared non-blocking" "audit failure is non-blocking" "$_R_ERR"
    assert_has "R3 the resolution failure is still reported" \
        "could not resolve the workflow directory" "$_R_ERR"
    assert_has "R3 the emergency guidance still reaches the operator" \
        "WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY" "$_R_OUT"
    rm -rf "$tmp"
}
