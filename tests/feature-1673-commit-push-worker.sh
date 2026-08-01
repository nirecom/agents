#!/usr/bin/env bash
# tests/feature-1673-commit-push-worker.sh
# Tests: hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/commit-push.js, bin/worker-dispatch/capability.js, skills/commit-push/SKILL.md
# Tags: worker-dispatch, commit-push, registry, capability, payload, status-vocabulary, env-passthrough, TL1, scope:issue-specific
#
# Issue #1673 — the commit-push worker's declared capability surface.
#
# The registry entry is the only thing standing between a payload field and a
# forge call (git push / gh pr create). Every assertion here is on the DECLARED
# contract, evaluated through the real capability validator, so a widened type or
# a dropped `required` shows up as a want!=got rather than as a runtime surprise
# on someone's main branch.
#
# Three properties are asserted that no behavioural test can reach:
#   - `gate_blocked` (D1) exists in BOTH the worker and the SKILL branch table;
#     a status the caller cannot branch on is a silently swallowed block.
#   - ISSUE_CLOSE_SKILL is absent from envPassthrough — structurally, not by
#     grepping for the string, so the explanatory comment stays legal.
#   - the five D1 env vars appear as extraEnv keys in the worker source. They are
#     declared in envPassthrough, which also permits silent inheritance; an
#     inherited CLAUDE_WORKFLOW_DIR points the gate child at another session's
#     state and it answers "approve" to everything.
#
# TL3 gap (what this TL1 test does NOT catch):
#   - Whether the real hooks/workflow-gate.js accepts the synthetic PreToolUse
#     payload the worker builds (tests/TL3-worker-dispatch-commit-push.sh).
#   - Whether the declared binaries exist and accept the assembled argv.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_CP1673_TL1_INNER:-}" ]; then
    _CP1673_TL1_INNER=1 timeout 180 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
CAPABILITY_JS="$AGENTS_DIR/bin/worker-dispatch/capability.js"
ANCHOR_JS="$AGENTS_DIR/bin/worker-dispatch/anchor.js"
WORKER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/commit-push.js"
SKILL_MD="$AGENTS_DIR/skills/commit-push/SKILL.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

for f in "$REGISTRY_JS" "$CAPABILITY_JS" "$ANCHOR_JS"; do
    if [ ! -f "$f" ]; then
        fail "0/prerequisite" "missing $f"
        echo ""
        echo "Total: PASS=$PASS FAIL=$FAIL"
        exit 1
    fi
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/cp1673-tl1-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main >/dev/null 2>&1
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"

# ---------------------------------------------------------------------------
# Probe: validate a payload against the declared commit-push entry using the
# REAL capability validator. Prints `ok=1` / `ok=0` plus `err=<joined errors>`.
# ---------------------------------------------------------------------------
PROBE="$TMPD/validate-probe.js"
cat > "$PROBE" <<'PROBEJS'
"use strict";
const reg = require(process.argv[2]);
const cap = require(process.argv[3]);
const anchorMod = require(process.argv[4]);
const entry = (reg.workers || {})["commit-push"];
// `MISSING`, not `0`: a missing entry must not be mistaken for a rejection, or
// every negative row below would go green on an empty registry.
if (!entry) { process.stdout.write("ok=MISSING\nerr=ENTRY_MISSING\n"); process.exit(0); }
const anchors = anchorMod.resolveAnchors(process.argv[5]);
if (anchors.error) { process.stdout.write("ok=0\nerr=ANCHORS:" + anchors.error + "\n"); process.exit(0); }
let payload;
try { payload = JSON.parse(process.argv[6]); }
catch (e) { process.stdout.write("ok=0\nerr=BAD_CASE_JSON\n"); process.exit(0); }
const res = cap.validate(payload, entry, anchors);
process.stdout.write("ok=" + (res.ok ? "1" : "0") + "\n");
process.stdout.write("err=" + (res.errors || []).join(" | ") + "\n");
PROBEJS

VOUT=""
validate_payload() {
    VOUT="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$(nodepath "$PROBE")" "$(nodepath "$REGISTRY_JS")" "$(nodepath "$CAPABILITY_JS")" \
        "$(nodepath "$ANCHOR_JS")" "$MAIN" "$1" 2>&1)" || VOUT="ok=0
err=PROBE_CRASHED"
}
vfield() { printf '%s\n' "$VOUT" | sed -n "s/^$1=//p" | head -1; }

BASE_OK="\"commit_message\":\"feat: something\",\"branch\":\"feature/1673\",\"worktree_path\":\"$MAIN\",\"session_id\":\"df594809-a1cc-4035\""

# ===========================================================================
# Group A — the entry exists and declares the fields the caller sends
# ===========================================================================
group_a() {
    local out
    out="$(node -e '
      const reg = require(process.argv[1]);
      const w = (reg.workers || {})["commit-push"];
      const p = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
      if (!w) { p("present", 0); process.exit(0); }
      p("present", 1);
      p("in_enum", (reg.WORKER_NAMES || []).includes("commit-push") ? 1 : 0);
      p("renderer", w.renderer);
      const spec = w.payloadSpec || {};
      const t = (k) => (spec[k] ? String(spec[k].type) : "(absent)");
      const r = (k) => (spec[k] ? (spec[k].required === true ? "req" : "opt") : "(absent)");
      for (const k of ["commit_message","branch","closes_issues","pr_body_template","wip_mode",
                       "enforce_worktree","agents_config_dir","artifact_dir","worktree_path","session_id"]) {
        p("type_" + k, t(k));
        p("req_" + k, r(k));
      }
      p("unknown_fields", Object.keys(spec).filter((k) => ![
        "commit_message","branch","closes_issues","pr_body_template","wip_mode",
        "enforce_worktree","agents_config_dir","artifact_dir","worktree_path","session_id",
      ].includes(k)).sort().join(","));
      p("write_scopes", (w.writeScopes || []).slice().sort().join(","));
      p("external", ((w.binaries || {}).external || []).slice().sort().join(","));
      p("scripts", Object.keys((w.binaries || {}).scripts || {}).sort().join(","));
      p("gate_script_rel", (((w.binaries || {}).scripts || {}).workflowGate || {}).rel || "(absent)");
      p("gate_script_anchor", (((w.binaries || {}).scripts || {}).workflowGate || {}).anchor || "(absent)");
    ' "$REGISTRY_JS" 2>&1)" || out="present=REQUIRE_FAILED"
    ev() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

    assert_eq "registry/entry-present" "1" "$(ev present)"
    assert_eq "registry/name-in-enum" "1" "$(ev in_enum)"
    assert_eq "registry/renderer" "status-triple-quoted" "$(ev renderer)"

    assert_eq "spec/commit_message-type" "text" "$(ev type_commit_message)"
    assert_eq "spec/commit_message-required" "req" "$(ev req_commit_message)"
    assert_eq "spec/branch-type" "branch" "$(ev type_branch)"
    assert_eq "spec/branch-required" "req" "$(ev req_branch)"
    # Deviation #3: cwd can only reach the dispatcher as a family-validated path.
    assert_eq "spec/worktree_path-type" "family-worktree" "$(ev type_worktree_path)"
    assert_eq "spec/worktree_path-required" "req" "$(ev req_worktree_path)"
    # Deviation #2: without it the merge gate blocks by design (fail-closed).
    assert_eq "spec/session_id-type" "session-id" "$(ev type_session_id)"
    assert_eq "spec/session_id-required" "req" "$(ev req_session_id)"
    # Typed, not text[]: each element becomes `Closes #<N>` in a PR body.
    # issue-ref[], not int[]: hooks/lib/parse-closes-issues.js — the canonical
    # `## Issues` parser the skill tells callers to use — returns { number, repo? }
    # records. An int[] schema rejected that documented payload, and mapping it down
    # to bare numbers dropped the repo half of each issue's identity, collapsing two
    # repositories' #42 into one `Closes #42`.
    assert_eq "spec/closes_issues-type" "issue-ref[]" "$(ev type_closes_issues)"
    assert_eq "spec/closes_issues-optional" "opt" "$(ev req_closes_issues)"
    assert_eq "spec/pr_body_template-type" "text" "$(ev type_pr_body_template)"
    assert_eq "spec/pr_body_template-optional" "opt" "$(ev req_pr_body_template)"
    assert_eq "spec/wip_mode-type" "bool" "$(ev type_wip_mode)"
    assert_eq "spec/enforce_worktree-type" "enum:on|off" "$(ev type_enforce_worktree)"
    assert_eq "spec/agents_config_dir-type" "anchor-acd" "$(ev type_agents_config_dir)"
    assert_eq "spec/artifact_dir-type" "path-under-plansdir" "$(ev type_artifact_dir)"
    assert_eq "spec/no-invented-fields" "" "$(ev unknown_fields)"

    assert_eq "registry/write-scopes" "family-worktree,plans-dir" "$(ev write_scopes)"
    assert_eq "registry/external-binaries" "bash,gh,git,node" "$(ev external)"
    assert_eq "registry/script-keys" "bootstrapProbe,isGithubRemote,scanOutbound,unstagedCheck,workflowGate" "$(ev scripts)"
    # D1: the gate must be the reviewed, merged copy — never the branch's own.
    assert_eq "registry/gate-script-rel" "hooks/workflow-gate.js" "$(ev gate_script_rel)"
    assert_eq "registry/gate-script-anchor" "acd" "$(ev gate_script_anchor)"
}

# ===========================================================================
# Group B — payload validation through the real capability validator
# ===========================================================================
group_b() {
    local name json want
    while IFS='|' read -r name json want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        validate_payload "$json"
        if [ "$(vfield ok)" != "$want" ]; then
            fail "validate/$name" "want ok=$want got ok=$(vfield ok) errors=$(vfield err)"
        else
            pass "validate/$name"
        fi
    done <<TABLE
full-valid                  | {$BASE_OK,"closes_issues":[{"number":1673}],"pr_body_template":"Closes #1673","wip_mode":false,"enforce_worktree":"on","artifact_dir":"$PLANS"} | 1
minimal-valid               | {$BASE_OK} | 1
missing-commit-message      | {"branch":"feature/1673","worktree_path":"$MAIN","session_id":"df594809-a1cc-4035"} | 0
missing-branch              | {"commit_message":"m","worktree_path":"$MAIN","session_id":"df594809-a1cc-4035"} | 0
missing-worktree-path       | {"commit_message":"m","branch":"feature/1673","session_id":"df594809-a1cc-4035"} | 0
missing-session-id          | {"commit_message":"m","branch":"feature/1673","worktree_path":"$MAIN"} | 0
enforce-worktree-out-of-enum| {$BASE_OK,"enforce_worktree":"maybe"} | 0
enforce-worktree-empty      | {$BASE_OK,"enforce_worktree":""} | 0
enforce-worktree-on         | {$BASE_OK,"enforce_worktree":"on"} | 1
enforce-worktree-off        | {$BASE_OK,"enforce_worktree":"off"} | 1
closes-issues-string-elem   | {$BASE_OK,"closes_issues":["1673"]} | 0
closes-issues-not-array     | {$BASE_OK,"closes_issues":1673} | 0
closes-issues-nested        | {$BASE_OK,"closes_issues":[[1673]]} | 0
closes-issues-empty-ok      | {$BASE_OK,"closes_issues":[]} | 1
closes-issues-refs-ok       | {$BASE_OK,"closes_issues":[{"number":1673},{"number":42,"repo":"owner/other"}]} | 1
closes-issues-bare-int-elem | {$BASE_OK,"closes_issues":[1673]} | 0
pr-body-template-accepted   | {$BASE_OK,"pr_body_template":"## Summary\ntext with \$(id) and \`backticks\`"} | 1
pr-body-template-not-string | {$BASE_OK,"pr_body_template":42} | 0
worktree-path-outside-family| {$BASE_OK,"worktree_path":"$PLANS"} | 0
session-id-with-separator   | {"commit_message":"m","branch":"feature/1673","worktree_path":"$MAIN","session_id":"../../etc"} | 0
unknown-field               | {$BASE_OK,"force_push":true} | 0
TABLE
}

# ===========================================================================
# Group C — env surface. Two independent halves of the same contract.
# ===========================================================================
group_c() {
    local out
    out="$(node -e '
      const reg = require(process.argv[1]);
      const w = (reg.workers || {})["commit-push"];
      const p = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
      const D1 = ["CLAUDE_WORKFLOW_DIR","WORKFLOW_PLANS_DIR","WORKFLOW_SESSION_ID","CLAUDE_PROJECT_DIR","DEFAULT_BRANCHES"];
      // No early exit on a missing entry: "no ISSUE_CLOSE_SKILL" and "no missing
      // D1 var" are both trivially true of an absent entry, so the absence is
      // reported as a distinct value instead of as a pass.
      const pass_ = w ? (w.envPassthrough || []) : null;
      p("declared", pass_ ? pass_.slice().sort().join(",") : "ENTRY_MISSING");
      p("has_issue_close_skill", pass_ ? (pass_.includes("ISSUE_CLOSE_SKILL") ? 1 : 0) : "ENTRY_MISSING");
      p("missing_d1", pass_ ? D1.filter((v) => !pass_.includes(v)).join(",") : "ENTRY_MISSING");
      // Non-vacuity: the global allowlist must not be smuggling these in.
      const allow = reg.CHILD_ENV_ALLOWLIST || [];
      p("d1_in_global_allowlist", D1.filter((v) => allow.includes(v)).join(","));
    ' "$REGISTRY_JS" 2>&1)" || out="declared=REQUIRE_FAILED"
    ev() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

    assert_eq "env/declared-set" \
        "CLAUDE_PROJECT_DIR,CLAUDE_WORKFLOW_DIR,DEFAULT_BRANCHES,ENFORCE_WORKTREE,GH_TOKEN,GITHUB_TOKEN,WORKFLOW_PLANS_DIR,WORKFLOW_SESSION_ID" \
        "$(ev declared)"
    # run-stage-chain.sh / run-finalize-terminal.sh export it themselves; the
    # dispatcher must not be the one handing it out.
    assert_eq "env/no-issue-close-skill-passthrough" "0" "$(ev has_issue_close_skill)"
    assert_eq "env/all-five-d1-vars-declared" "" "$(ev missing_d1)"
    assert_eq "env/d1-vars-not-global" "" "$(ev d1_in_global_allowlist)"
}

# ===========================================================================
# Group D — the worker sets the five D1 vars EXPLICITLY via extraEnv.
#
# Declaring them in envPassthrough also permits inheritance. An inherited
# CLAUDE_WORKFLOW_DIR sends the gate child at a different session's state file,
# where every step reads "missing" and the gate answers approve — the quiet
# failure mode this group exists to make loud.
# ===========================================================================
group_d() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "extraEnv/five-d1-vars" "implementation missing: bin/worker-dispatch/workers/commit-push.js"
        fail "extraEnv/no-issue-close-skill" "implementation missing: bin/worker-dispatch/workers/commit-push.js"
        return
    fi
    local out
    out="$(node -e '
      const fs = require("fs");
      const src = fs.readFileSync(process.argv[1], "utf8");
      // Collect the key names of every `extraEnv: { ... }` object literal.
      const keys = new Set();
      let blocks = 0;
      const re = /extraEnv\s*:\s*\{/g;
      let m;
      while ((m = re.exec(src)) !== null) {
        let depth = 1;
        let i = m.index + m[0].length;
        const start = i;
        while (i < src.length && depth > 0) {
          if (src[i] === "{") depth++;
          else if (src[i] === "}") depth--;
          i++;
        }
        blocks++;
        const body = src.slice(start, i - 1);
        const kre = /(?:^|[{,\s])["\x27]?([A-Za-z_][A-Za-z0-9_]*)["\x27]?\s*:/g;
        let km;
        while ((km = kre.exec(body)) !== null) keys.add(km[1]);
      }
      process.stdout.write("blocks=" + blocks + "\n");
      process.stdout.write("keys=" + Array.from(keys).sort().join(",") + "\n");
    ' "$WORKER_JS" 2>&1)" || out="blocks=0
keys=SCAN_FAILED"
    local blocks keys missing
    blocks="$(printf '%s\n' "$out" | sed -n 's/^blocks=//p' | head -1)"
    keys="$(printf '%s\n' "$out" | sed -n 's/^keys=//p' | head -1)"
    if [ "${blocks:-0}" -lt 1 ]; then
        # TODO(#1673): the scan requires an `extraEnv: { ... }` object literal.
        # If write_code assembles extraEnv into a variable first, extend the scan
        # rather than relaxing the assertion.
        fail "extraEnv/five-d1-vars" "no 'extraEnv: {' object literal found in the worker source"
        fail "extraEnv/no-issue-close-skill" "no 'extraEnv: {' object literal found in the worker source"
        return
    fi
    missing=""
    for v in CLAUDE_WORKFLOW_DIR WORKFLOW_PLANS_DIR WORKFLOW_SESSION_ID CLAUDE_PROJECT_DIR DEFAULT_BRANCHES; do
        case ",$keys," in
            *",$v,"*) ;;
            *) missing="$missing $v" ;;
        esac
    done
    assert_eq "extraEnv/five-d1-vars" "" "$(echo "$missing" | xargs)"
    case ",$keys," in
        *",ISSUE_CLOSE_SKILL,"*) fail "extraEnv/no-issue-close-skill" "ISSUE_CLOSE_SKILL set as an extraEnv key" ;;
        *) pass "extraEnv/no-issue-close-skill" ;;
    esac
}

# ===========================================================================
# Group E — status vocabulary. The worker's statuses and the SKILL branch table
# are two halves of one contract: a status the SKILL cannot branch on is a
# block or a failure the caller silently treats as success.
# ===========================================================================
STATUSES="staging_incomplete staging_check_failed gate_blocked bootstrap_pending pushed pr_created pr_reused push_failed conflict"

group_e() {
    local s
    for s in $STATUSES; do
        if [ ! -f "$SKILL_MD" ]; then
            fail "skill-vocab/$s" "missing skills/commit-push/SKILL.md"
        elif grep -qF -- "\`$s\`" "$SKILL_MD"; then
            pass "skill-vocab/$s"
        else
            fail "skill-vocab/$s" "status not present in the SKILL.md branch table"
        fi
        if [ ! -f "$WORKER_JS" ]; then
            fail "worker-vocab/$s" "implementation missing: bin/worker-dispatch/workers/commit-push.js"
        elif grep -qF -- "$s" "$WORKER_JS"; then
            pass "worker-vocab/$s"
        else
            fail "worker-vocab/$s" "status never produced by the worker source"
        fi
    done
    # Non-vacuity guard: a status the plan does NOT define must not appear, or
    # the grep above would pass for any string at all.
    if [ -f "$SKILL_MD" ] && grep -qF -- '`force_pushed`' "$SKILL_MD"; then
        fail "skill-vocab/no-undeclared-status" "'force_pushed' present in SKILL.md"
    else
        pass "skill-vocab/no-undeclared-status"
    fi
}

group_a
group_b
group_c
group_d
group_e

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
