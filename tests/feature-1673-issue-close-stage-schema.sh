#!/usr/bin/env bash
# tests/feature-1673-issue-close-stage-schema.sh
# Tests: hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/capability.js, skills/issue-close-stage/SKILL.md
# Tags: worker-dispatch, issue-close-stage, registry, capability, payload, status-vocabulary, TL1, scope:issue-specific
#
# Issue #1673 — the issue-close-stage LLM subagent (agents/issue-close-stage-worker.md)
# becomes a plain dispatcher worker. The whole point of the port is that the
# INPUT CONTRACT is preserved byte for byte: the same six payload field names the
# agent md declared, and the same three-token status vocabulary
# (phase1_done | blocked_sub_issue | error) that skills/issue-close-stage/SKILL.md
# branches on. This file pins both against the pure-data registry, plus the two
# capability edges the detail plan calls out by name:
#   - `issue_repo` must accept the bare `<repo>` form (repo-ref), not just owner/repo
#   - `agents_config_dir` is echo-only: any value other than the resolved ACD is rejected
#
# TL3 gap (what this TL1 test does NOT catch):
#   - A real /issue-close-stage turn writing the payload file and invoking the CLI.
#     tests/TL3-issue-close-stage-dispatch.sh (RUN_TL3-gated) covers that seam.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
CAPABILITY_JS="$AGENTS_DIR/bin/worker-dispatch/capability.js"
SKILL_MD="$AGENTS_DIR/skills/issue-close-stage/SKILL.md"
CHAIN_SH="$AGENTS_DIR/skills/issue-close-stage/scripts/run-stage-chain.sh"
AGENT_MD="$AGENTS_DIR/agents/issue-close-stage-worker.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if command -v timeout >/dev/null 2>&1 && [ -z "${_ICS1673_SCHEMA_INNER:-}" ]; then
    _ICS1673_SCHEMA_INNER=1 timeout 180 bash "$0" "$@"
    exit $?
fi

# ===========================================================================
# Group A — the registry entry (pure data; no worker module needed)
# ===========================================================================
REG_OUT=""
group_registry() {
    if [ ! -f "$REGISTRY_JS" ]; then
        fail "registry/entry-present" "missing $REGISTRY_JS"
        return
    fi
    REG_OUT="$(node -e '
      const reg = require(process.argv[1]);
      const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
      const w = (reg.workers || {})["issue-close-stage"];
      out("declared", reg.WORKER_NAMES.includes("issue-close-stage") ? 1 : 0);
      // No top-level `return` here: `node -e` compiles its argument as a plain
      // script, not a CommonJS module wrapper, so `return` is a SyntaxError that
      // would fail every assertion below for a reason unrelated to the registry.
      if (!w) { out("entry", 0); } else {
      out("entry", 1);
      const spec = w.payloadSpec || {};
      out("fields", Object.keys(spec).sort().join(","));
      for (const k of Object.keys(spec)) {
        out("f." + k, spec[k].type + ":" + (spec[k].required === true ? "req" : "opt"));
      }
      out("issue_number_min", spec.issue_number ? spec.issue_number.min : "(absent)");
      out("argspec", (w.argSpec || []).join(","));
      out("external", ((w.binaries || {}).external || []).slice().sort().join(","));
      const sc = (w.binaries || {}).scripts || {};
      out("script_keys", Object.keys(sc).sort().join(","));
      out("chain_anchor", sc.stageChain ? sc.stageChain.anchor : "(absent)");
      out("chain_rel", sc.stageChain ? sc.stageChain.rel : "(absent)");
      out("envpass", (w.envPassthrough || []).slice().sort().join(","));
      out("has_issue_close_skill", (w.envPassthrough || []).includes("ISSUE_CLOSE_SKILL") ? 1 : 0);
      out("writescopes", (w.writeScopes || []).join(","));
      out("renderer", w.renderer || "(absent)");
      }
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)" || REG_OUT="REQUIRE_FAILED"
    rv() { printf '%s\n' "$REG_OUT" | sed -n "s/^$1=//p" | head -1; }

    assert_eq "registry/name-in-enum" "1" "$(rv declared)"
    assert_eq "registry/entry-present" "1" "$(rv entry)"
    # The six fields of agents/issue-close-stage-worker.md — no more, no fewer.
    assert_eq "registry/payload-field-set" \
        "agents_config_dir,artifact_dir,issue_number,issue_repo,owner_repo,worktree_path" \
        "$(rv fields)"
    assert_eq "registry/issue_number" "int:req" "$(rv f.issue_number)"
    assert_eq "registry/issue_number-min-1" "1" "$(rv issue_number_min)"
    assert_eq "registry/worktree_path" "family-worktree:req" "$(rv f.worktree_path)"
    assert_eq "registry/owner_repo" "owner-repo:req" "$(rv f.owner_repo)"
    assert_eq "registry/agents_config_dir" "anchor-acd:opt" "$(rv f.agents_config_dir)"
    assert_eq "registry/artifact_dir" "path-under-plansdir:opt" "$(rv f.artifact_dir)"
    assert_eq "registry/issue_repo" "repo-ref:opt" "$(rv f.issue_repo)"
    assert_eq "registry/argspec-standard" "enum-worker,anchor-main-root,path-plansdir" "$(rv argspec)"
    # #1899: repo identity is resolved with `git remote get-url origin` instead of
    # `gh repo view`, so `git` joins the declared external binaries. The registry
    # is the SSOT the dispatcher allow-lists against — an undeclared `git` would
    # be refused at spawn time.
    assert_eq "registry/external-binaries" "bash,gh,git" "$(rv external)"
    assert_eq "registry/script-keys" "stageChain" "$(rv script_keys)"
    assert_eq "registry/chain-anchor-acd" "acd" "$(rv chain_anchor)"
    assert_eq "registry/chain-rel" "skills/issue-close-stage/scripts/run-stage-chain.sh" "$(rv chain_rel)"
    assert_eq "registry/envpassthrough-tokens-only" "GH_TOKEN,GITHUB_TOKEN" "$(rv envpass)"
    # run-stage-chain.sh exports ISSUE_CLOSE_SKILL=1 itself; the dispatcher must
    # not also hand it to every child of this worker.
    assert_eq "registry/no-issue-close-skill-passthrough" "0" "$(rv has_issue_close_skill)"
    assert_eq "registry/writescopes-plans-dir-only" "plans-dir" "$(rv writescopes)"
    assert_eq "registry/renderer" "status-triple-quoted" "$(rv renderer)"
}

# ===========================================================================
# Group B — capability edges: repo-ref and the echo-only ACD
# ===========================================================================
group_capability() {
    if [ ! -f "$CAPABILITY_JS" ]; then
        fail "capability/module-present" "missing $CAPABILITY_JS"
        return
    fi
    local probe="$AGENTS_DIR/tests/feature-1673-issue-close-stage-lib/checkfield-probe.js"
    if [ ! -f "$probe" ]; then
        fail "capability/probe-present" "missing $probe"
        return
    fi
    local name type value want got
    while IFS='|' read -r name type value want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; type="$(echo "$type" | xargs)"; want="$(echo "$want" | xargs)"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        got="$(node "$(nodepath "$probe")" "$(nodepath "$CAPABILITY_JS")" "$type" "$value" 2>&1)"
        assert_eq "capability/$name" "$want" "$got"
    done <<'TABLE'
repo-ref-bare            | repo-ref  | agents                     | ok
repo-ref-bare-dashes     | repo-ref  | my-specs-repo              | ok
repo-ref-owner-slash     | repo-ref  | example-owner/example-repo | ok
repo-ref-three-segments  | repo-ref  | a/b/c                      | reject
repo-ref-empty           | repo-ref  |                            | reject
repo-ref-dotdot          | repo-ref  | ../etc                     | reject
repo-ref-shell-meta      | repo-ref  | owner/repo;id              | reject
repo-ref-space           | repo-ref  | owner repo                 | reject
acd-exact                | anchor-acd | @ACD@                     | ok
acd-parent               | anchor-acd | @ACD_PARENT@              | reject
acd-sibling-lookalike    | anchor-acd | @ACD@-other                | reject
acd-empty                | anchor-acd |                            | reject
acd-non-string           | anchor-acd | @NUMBER@                   | reject
TABLE
}

# ===========================================================================
# Group C — status vocabulary and the caller-side contract
#
# The vocabulary is fixed at three tokens. `failed` (the dispatcher's own
# validation-rejection status) is NOT one of them and must not appear as a
# worker-produced branch in the SKILL.
# ===========================================================================
group_status_vocabulary() {
    if [ ! -f "$SKILL_MD" ]; then
        fail "skill/present" "missing $SKILL_MD"
        return
    fi
    local tok
    for tok in phase1_done blocked_sub_issue error; do
        if grep -q "$tok" "$SKILL_MD"; then
            pass "skill/branches-on-$tok"
        else
            fail "skill/branches-on-$tok" "SKILL.md never mentions $tok"
        fi
    done

    # TODO(#1673): the rewrite in write_code must move the SKILL from the Agent()
    # subagent call to the worker-dispatch CLI protocol.
    if grep -q 'issue-close-stage-worker' "$SKILL_MD"; then
        fail "skill/no-subagent-delegation" "SKILL.md still delegates to the LLM subagent"
    else
        pass "skill/no-subagent-delegation"
    fi
    if grep -q 'worker-dispatch' "$SKILL_MD"; then
        pass "skill/uses-worker-dispatch"
    else
        fail "skill/uses-worker-dispatch" "SKILL.md does not reference the dispatcher protocol"
    fi
    # Every payload field name the registry declares must be visible in the SKILL
    # that builds the payload — a rename on one side alone is the failure mode.
    local f
    for f in issue_number worktree_path owner_repo agents_config_dir artifact_dir issue_repo; do
        if grep -q "$f" "$SKILL_MD"; then
            pass "skill/payload-field-$f"
        else
            fail "skill/payload-field-$f" "$f absent from SKILL.md"
        fi
    done

    # TODO(#1673): agents/issue-close-stage-worker.md is deleted by the same commit.
    if [ -f "$AGENT_MD" ]; then
        fail "agent-md/retired" "agents/issue-close-stage-worker.md still exists"
    else
        pass "agent-md/retired"
    fi
}

# ===========================================================================
# Group D — the script the worker anchors to must exist and keep its KV contract
# (passes today; it is the input the worker parses)
# ===========================================================================
group_chain_script() {
    if [ ! -f "$CHAIN_SH" ]; then
        fail "chain/script-present" "missing $CHAIN_SH"
        return
    fi
    pass "chain/script-present"
    local key
    for key in STATUS SUMMARY COMMENT_ID; do
        if grep -q "${key}=" "$CHAIN_SH"; then
            pass "chain/emits-$key"
        else
            fail "chain/emits-$key" "run-stage-chain.sh never prints ${key}="
        fi
    done
    # Positional contract: <issue_number> <owner_repo>.
    if grep -q 'ISSUE_NUMBER="\${1' "$CHAIN_SH" && grep -q 'OWNER_REPO="\${2' "$CHAIN_SH"; then
        pass "chain/positional-args"
    else
        fail "chain/positional-args" "argv order of run-stage-chain.sh changed"
    fi
}

group_registry
group_capability
group_status_vocabulary
group_chain_script

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
