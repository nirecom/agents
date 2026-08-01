#!/usr/bin/env bash
# tests/feature-1673-finalize-worker-schema.sh
# Tests: hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/issue-close-finalize.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, issue-close-finalize, registry, capability, payload-spec, phase-required, TL1, scope:issue-specific
#
# Issue #1673 — the issue-close-finalize registry entry and its phase-specific
# required-field table.
#
# The payloadSpec is flat (capability.js has no notion of "required only when
# phase=X"), so the phase differences live in the worker module's checkRequired.
# Both halves are asserted here: the flat declaration against the SSOT registry,
# and the per-phase refusal against the real dispatcher with the process seam
# canned. A refusal must happen BEFORE any child starts — the spawn counter is
# what makes that observable rather than assumed.
#
# TL3 gap (what this TL1 test does NOT catch):
#   - Whether skills/issue-close-finalize/SKILL.md actually writes payloads
#     carrying these fields for each of its three call sites.
#   - Real PLANS_DIR / ACD anchor resolution on the operator's machine
#     (this test pins WORKFLOW_PLANS_DIR and uses a temp main-root).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_F1673_SCHEMA_INNER:-}" ]; then
    _F1673_SCHEMA_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
WORKER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/issue-close-finalize.js"
STATE_JS="$AGENTS_DIR/bin/worker-dispatch/workers/issue-close-finalize/state.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_has() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in *"$needle"*) pass "$name" ;; *) fail "$name" "want substring '$needle' in '$hay'" ;; esac
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/f1673-schema-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# ===========================================================================
# Group A — the SSOT registry entry
# ===========================================================================
group_registry() {
    if [ ! -f "$REGISTRY_JS" ]; then
        fail "registry/entry-present" "missing: hooks/lib/worker-dispatch-registry.js"
        return
    fi
    local out
    out="$(node -e '
      const reg = require(process.argv[1]);
      const o = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
      o("in_enum", (reg.WORKER_NAMES || []).includes("issue-close-finalize") ? 1 : 0);
      const e = (reg.workers || {})["issue-close-finalize"];
      // No top-level `return` here: `node -e` compiles its argument as a plain
      // script, not a CommonJS module wrapper, so `return` is a SyntaxError that
      // would fail every assertion below for a reason unrelated to the registry.
      if (!e) { o("entry", "ABSENT"); } else {
      o("entry", "PRESENT");
      const s = e.payloadSpec || {};
      const t = (k) => (s[k] ? s[k].type : "(absent)");
      for (const k of ["phase","issue_number","root_issue_number","owner_repo","state_file_path",
                       "main_worktree_path","issue_repo","g5_decision","session_id",
                       "outcome_file_path","agents_config_dir","finalize_scripts_dir","artifact_dir"]) {
        o("type_" + k, t(k));
      }
      o("unknown_fields", Object.keys(s).filter((k) => ![
        "phase","issue_number","root_issue_number","owner_repo","state_file_path","main_worktree_path",
        "issue_repo","g5_decision","session_id","outcome_file_path","agents_config_dir",
        "finalize_scripts_dir","artifact_dir"].includes(k)).sort().join(","));
      o("renderer", e.renderer);
      o("write_scopes", (e.writeScopes || []).slice().sort().join(","));
      o("external", (((e.binaries || {}).external) || []).slice().sort().join(","));
      o("scripts", Object.keys(((e.binaries || {}).scripts) || {}).sort().join(","));
      o("script_rels", Object.values(((e.binaries || {}).scripts) || {}).map((v) => v.rel).sort().join(","));
      o("script_anchors", Array.from(new Set(Object.values(((e.binaries || {}).scripts) || {}).map((v) => v.anchor))).sort().join(","));
      o("envpass", (e.envPassthrough || []).slice().sort().join(","));
      o("envpass_has_issue_close_skill", (e.envPassthrough || []).includes("ISSUE_CLOSE_SKILL") ? 1 : 0);
      }
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)" || out="require_failed=1"
    ev() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

    assert_eq "registry/entry-present" "PRESENT" "$(ev entry)"
    assert_eq "registry/in-worker-names" "1" "$(ev in_enum)"
    assert_eq "registry/type-phase" "enum:initial|loop_step|finalize_terminal" "$(ev type_phase)"
    assert_eq "registry/type-issue-number" "int" "$(ev type_issue_number)"
    assert_eq "registry/type-root-issue-number" "int" "$(ev type_root_issue_number)"
    assert_eq "registry/type-owner-repo" "owner-repo" "$(ev type_owner_repo)"
    assert_eq "registry/type-state-file-path" "state-file-for-session" "$(ev type_state_file_path)"
    assert_eq "registry/type-main-worktree-path" "anchor-main-root" "$(ev type_main_worktree_path)"
    assert_eq "registry/type-issue-repo" "repo-ref" "$(ev type_issue_repo)"
    assert_eq "registry/type-g5-decision" "enum:accept|decline|llm_declined|recurse_done" "$(ev type_g5_decision)"
    assert_eq "registry/type-session-id" "session-id" "$(ev type_session_id)"
    assert_eq "registry/type-outcome-file-path" "path-under-plansdir" "$(ev type_outcome_file_path)"
    assert_eq "registry/type-agents-config-dir" "anchor-acd" "$(ev type_agents_config_dir)"
    assert_eq "registry/type-finalize-scripts-dir" "derived-finalize-scripts-dir" "$(ev type_finalize_scripts_dir)"
    assert_eq "registry/type-artifact-dir" "path-under-plansdir" "$(ev type_artifact_dir)"
    assert_eq "registry/no-invented-fields" "" "$(ev unknown_fields)"
    assert_eq "registry/renderer" "status-triple-quoted" "$(ev renderer)"
    assert_eq "registry/write-scopes" "plans-dir" "$(ev write_scopes)"
    assert_eq "registry/external-binaries" "bash,gh,node" "$(ev external)"
    assert_eq "registry/script-keys" "runInitial,runLoopStep,runTerminal" "$(ev scripts)"
    assert_eq "registry/script-anchor-is-acd" "acd" "$(ev script_anchors)"
    assert_has "registry/script-run-initial" "skills/issue-close-finalize/scripts/run-initial.sh" "$(ev script_rels)"
    assert_has "registry/script-run-loop-step" "skills/issue-close-finalize/scripts/run-loop-step.js" "$(ev script_rels)"
    assert_has "registry/script-run-terminal" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh" "$(ev script_rels)"
    assert_eq "registry/envpass" "FINALIZE_SCRIPTS_DIR,GH_TOKEN,GITHUB_TOKEN,MAIN_WORKTREE_PATH" "$(ev envpass)"
    # ISSUE_CLOSE_SKILL is exported by run-finalize-terminal.sh itself; passing it
    # through the dispatcher would widen the bypass to every child of this worker.
    assert_eq "registry/no-issue-close-skill-passthrough" "0" "$(ev envpass_has_issue_close_skill)"
}

# ===========================================================================
# Group B — worker source: env resolved explicitly, never inherited
# ===========================================================================
group_source() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "source/module-present" "missing: bin/worker-dispatch/workers/issue-close-finalize.js"
    else
        pass "source/module-present"
        local keys
        keys="$(node -e '
          const fs = require("fs");
          const src = fs.readFileSync(process.argv[1], "utf8");
          const re = /extraEnv\s*:\s*\{([\s\S]*?)\}/g;
          const found = new Set();
          let m;
          while ((m = re.exec(src)) !== null) {
            for (const k of m[1].matchAll(/([A-Z][A-Z0-9_]*)\s*:/g)) found.add(k[1]);
          }
          process.stdout.write(Array.from(found).sort().join(","));
        ' "$WORKER_JS" 2>/dev/null)"
        assert_has "source/extraenv-finalize-scripts-dir" "FINALIZE_SCRIPTS_DIR" "$keys"
        assert_has "source/extraenv-main-worktree-path" "MAIN_WORKTREE_PATH" "$keys"
        case "$keys" in
            *ISSUE_CLOSE_SKILL*) fail "source/extraenv-no-issue-close-skill" "keys=$keys" ;;
            *) pass "source/extraenv-no-issue-close-skill" ;;
        esac
        # The child stdout is KEY=VALUE; parsing it with eval would execute
        # attacker-controlled issue text. A KV parser is the only accepted form.
        if grep -nE '(^|[^A-Za-z_])eval\s*\(' "$WORKER_JS" >/dev/null 2>&1; then
            fail "source/no-eval" "issue-close-finalize.js calls eval()"
        else
            pass "source/no-eval"
        fi
    fi
    if [ -f "$STATE_JS" ]; then
        pass "source/state-module-present"
        if grep -q 'renameWithin' "$STATE_JS"; then
            pass "source/state-uses-fsguard-renamewithin"
        else
            fail "source/state-uses-fsguard-renamewithin" "state.js does not use fsguard.renameWithin"
        fi
        if grep -q 'checkField' "$STATE_JS"; then
            pass "source/state-reuses-capability-checkfield"
        else
            fail "source/state-reuses-capability-checkfield" "state.js does not reuse capability.checkField"
        fi
    else
        fail "source/state-module-present" "missing: bin/worker-dispatch/workers/issue-close-finalize/state.js"
    fi
}

# ===========================================================================
# Group C — phase-specific required fields refuse BEFORE any child starts
# ===========================================================================
MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
MAIN="$(nodepath "$MAIN_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
SID="f1673schema"
STATE="$PLANS/$SID-finalize-state-1673.json"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"
DOUT=""; DRC=0

write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}
dispatch_icf() {
    printf '%s' '[{"stdout":"STATUS=init_done\nOWNER_REPO=nirecom/agents\nTRIAGE_ACTION=resume_e\nNEXT_STEPS=G\nSUMMARY=ok\n"}]' > "$CANNED"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
        issue-close-finalize "$MAIN" "$1" 2>/dev/null)" || DRC=$?
}
call_count() { grep -c '' "$CALLLOG" 2>/dev/null | tr -d ' '; }

group_required() {
    if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$PRELOAD" ]; then
        fail "required/fixtures" "dispatcher or spawn-stub missing"
        return
    fi
    local name payload want p
    while IFS='|' read -r name payload want; do
        [ -z "${name// /}" ] && continue
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        payload="${payload#"${payload%%[![:space:]]*}"}"; payload="${payload%"${payload##*[![:space:]]}"}"
        p="$(write_payload "req-$name" "$payload")"
        dispatch_icf "$p"
        assert_eq "required/$name/status" "failed" "$(field_of status)"
        assert_eq "required/$name/summary" "1" "$(case "$(field_of summary)" in *"$want"*) echo 1 ;; *) echo 0 ;; esac)"
        assert_eq "required/$name/no-child-spawned" "0" "$(call_count)"
        assert_eq "required/$name/exit0" "0" "$DRC"
    done <<TABLE
initial-missing-issue-number     | {"phase":"initial","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","main_worktree_path":"$MAIN","session_id":"$SID"}                                    | issue_number
initial-missing-main-worktree    | {"phase":"initial","issue_number":1673,"root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","session_id":"$SID"}                                            | main_worktree_path
initial-missing-state-file       | {"phase":"initial","issue_number":1673,"root_issue_number":1673,"owner_repo":"nirecom/agents","main_worktree_path":"$MAIN","session_id":"$SID"}                                             | state_file_path
loop-missing-g5-decision         | {"phase":"loop_step","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","session_id":"$SID"}                                                                     | g5_decision
loop-missing-owner-repo          | {"phase":"loop_step","root_issue_number":1673,"state_file_path":"$STATE","g5_decision":"accept","session_id":"$SID"}                                                                      | owner_repo
loop-missing-root-issue-number   | {"phase":"loop_step","owner_repo":"nirecom/agents","state_file_path":"$STATE","g5_decision":"accept","session_id":"$SID"}                                                                 | root_issue_number
terminal-missing-session-id      | {"phase":"finalize_terminal","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","outcome_file_path":"$PLANS/oc.json"}                                       | session_id
terminal-missing-outcome-file    | {"phase":"finalize_terminal","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","session_id":"$SID"}                                                        | outcome_file_path
phase-unknown-value              | {"phase":"cleanup","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","session_id":"$SID"}                                                                  | phase
g5-decision-unknown-value        | {"phase":"loop_step","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","g5_decision":"maybe","session_id":"$SID"}                                          | g5_decision
state-file-other-session         | {"phase":"loop_step","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$PLANS/othersession-finalize-state-1673.json","g5_decision":"accept","session_id":"$SID"}   | state_file_path
state-file-other-root            | {"phase":"loop_step","root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$PLANS/$SID-finalize-state-99.json","g5_decision":"accept","session_id":"$SID"}             | state_file_path
scripts-dir-mismatch             | {"phase":"initial","issue_number":1673,"root_issue_number":1673,"owner_repo":"nirecom/agents","state_file_path":"$STATE","main_worktree_path":"$MAIN","session_id":"$SID","finalize_scripts_dir":"$MAIN/skills/issue-close-finalize/scripts"} | finalize_scripts_dir
TABLE
}

# ===========================================================================
# Group D — caller contract, ported from feature-644-agent-delegation/
# phase3-finalize-multipass.sh, which asserted it against the retired prompt.
# The loop, the LLM judgement and the AskUserQuestion stay in main.
# ===========================================================================
group_caller() {
    local skill="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"
    if [ ! -f "$skill" ]; then
        fail "caller/skill-present" "missing: skills/issue-close-finalize/SKILL.md"
        return
    fi
    pass "caller/skill-present"
    if grep -q 'AskUserQuestion' "$skill"; then
        pass "caller/askuserquestion-stays-in-main"
    else
        fail "caller/askuserquestion-stays-in-main" "G.5-2 must remain in SKILL.md"
    fi
    if grep -q 'worker-dispatch' "$skill"; then
        pass "caller/uses-worker-dispatch-protocol"
    else
        fail "caller/uses-worker-dispatch-protocol" "SKILL.md does not dispatch through worker-dispatch"
    fi
    if grep -q 'issue-close-finalize-worker' "$skill"; then
        fail "caller/no-llm-subagent-reference" "SKILL.md still names the retired LLM subagent"
    else
        pass "caller/no-llm-subagent-reference"
    fi
    if [ -e "$AGENTS_DIR/agents/issue-close-finalize-worker.md" ]; then
        fail "caller/agent-md-retired" "agents/issue-close-finalize-worker.md still exists"
    else
        pass "caller/agent-md-retired"
    fi
    if [ -e "$AGENTS_DIR/agents/issue-close-finalize-worker" ]; then
        fail "caller/state-schema-md-relocated" "agents/issue-close-finalize-worker/ still exists"
    else
        pass "caller/state-schema-md-relocated"
    fi
}

group_registry
group_source
group_required
group_caller

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
