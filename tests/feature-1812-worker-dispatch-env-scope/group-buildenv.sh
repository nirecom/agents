# Part of tests/feature-1812-worker-dispatch-env-scope.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, spawn, env-scope, credential-scope, security, TL2, scope:issue-specific
#
# Group A — the envScope PARAMETER of buildEnv, on the real registry entries.
# Membership only: which declared names reach the returned env. Value handling
# is one code path for every member and is already fenced by
# tests/feature-1643-worker-dispatch-script-anchor/group-env-branches.sh.
ENVSCOPE_PROBE="$TMPD/envscope-probe.js"
cat > "$ENVSCOPE_PROBE" <<'PROBEJS'
"use strict";
const path = require("path");
const [agentsDir, mainRoot] = process.argv.slice(2);
const spawnMod = require(path.join(agentsDir, "bin/worker-dispatch/spawn.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const anchors = anchorMod.resolveAnchors(mainRoot);
if (anchors.error) { out("anchors_error", anchors.error); process.exit(9); }

const workers = registry.workers || {};
const cp = workers["commit-push"];
const da = workers["doc-append"];
if (!cp || !da) { out("entries", "MISSING"); process.exit(0); }
const declared = (cp.envPassthrough || []).slice();
const daDeclared = (da.envPassthrough || []).slice();
out("declared", declared.slice().sort().join(","));
out("da_declared", daDeclared.slice().sort().join(","));

// Preconditions. Every declared name must really be in the parent env, or the
// "absent from the child" rows below would pass on an unset variable.
const OFF_LIST = "AWS_SECRET_ACCESS_KEY";
out("parent_missing", declared.filter((n) => typeof process.env[n] !== "string").join(","));
out("parent_has_offlist", typeof process.env[OFF_LIST] === "string" ? 1 : 0);

const present = (env, names) =>
  names.filter((n) => Object.prototype.hasOwnProperty.call(env, n)).sort().join(",");
const errOf = (fn) => { try { fn(); return "NO_THROW"; } catch (e) { return String(e && e.message ? e.message : e); } };

// A1 — a one-name scope admits exactly that name out of the nine declared.
let env = spawnMod.buildEnv(cp, anchors, null, ["SSH_AUTH_SOCK"]);
out("narrow_declared", present(env, declared));
out("narrow_value_identical", env.SSH_AUTH_SOCK === process.env.SSH_AUTH_SOCK ? 1 : 0);
// Non-vacuity: the base allowlist is untouched, so an empty env cannot pass.
out("narrow_path", typeof (env.PATH || env.Path) === "string" ? 1 : 0);
out("narrow_acd", env.AGENTS_CONFIG_DIR === anchors.acd ? 1 : 0);

// A2 — the default every commit-push helper uses when no scope is given.
env = spawnMod.buildEnv(cp, anchors, null, []);
out("empty_declared", present(env, declared));
out("empty_path", typeof (env.PATH || env.Path) === "string" ? 1 : 0);
out("empty_acd", env.AGENTS_CONFIG_DIR === anchors.acd ? 1 : 0);

// A3 — regression guard for the six workers that pass no scope at all: an
// omitted argument must still yield the FULL declared set.
out("omitted_declared", present(spawnMod.buildEnv(cp, anchors, null), declared));
out("undefined_declared", present(spawnMod.buildEnv(cp, anchors, null, undefined), declared));
// A non-array is not a scope, and it is REFUSED rather than treated as
// "omitted": falling back to the full declared set would silently re-widen the
// call to full credential passthrough at a call site that reads as if it were
// scoped (`envScope: "SSH_AUTH_SOCK"` — a typo away). Only omission means "no
// narrowing intended", so a present-but-malformed value fails closed.
out("null_scope_error", errOf(() => spawnMod.buildEnv(cp, anchors, null, null)));
out("string_scope_error", errOf(() => spawnMod.buildEnv(cp, anchors, null, "SSH_AUTH_SOCK")));

// A4 — envScope is an intersection, never a grant: a name the worker never
// declared cannot be smuggled in through the scope array.
env = spawnMod.buildEnv(cp, anchors, null, ["SSH_AUTH_SOCK", OFF_LIST]);
out("offlist_present", Object.prototype.hasOwnProperty.call(env, OFF_LIST) ? 1 : 0);
out("offlist_scope_declared", present(env, declared));

// A5 — extraEnv is validated against the NARROWED set. A var the worker
// declares but this call did not scope in must be refused, not merely one that
// is absent from envPassthrough entirely.
out("extra_declared_out_of_scope", errOf(() => spawnMod.buildEnv(cp, anchors, { GH_TOKEN: "x" }, ["SSH_AUTH_SOCK"])));
out("extra_empty_scope", errOf(() => spawnMod.buildEnv(cp, anchors, { GH_TOKEN: "x" }, [])));
out("extra_in_scope", errOf(() => spawnMod.buildEnv(cp, anchors, { GH_TOKEN: "x" }, ["GH_TOKEN"])));
out("extra_omitted_scope", errOf(() => spawnMod.buildEnv(cp, anchors, { GH_TOKEN: "x" })));
out("extra_in_scope_value", spawnMod.buildEnv(cp, anchors, { GH_TOKEN: "x" }, ["GH_TOKEN"]).GH_TOKEN);
out("extra_undeclared_scoped", errOf(() => spawnMod.buildEnv(cp, anchors, { [OFF_LIST]: "x" }, [OFF_LIST])));

// A6 — the gate call's own six-name scope, asserted as one set.
const GATE_SCOPE = ["CLAUDE_WORKFLOW_DIR", "WORKFLOW_PLANS_DIR", "WORKFLOW_SESSION_ID",
  "CLAUDE_PROJECT_DIR", "DEFAULT_BRANCHES", "ENFORCE_WORKTREE"];
out("gate_scope_declared", present(spawnMod.buildEnv(cp, anchors, null, GATE_SCOPE), declared));

// A7 — doc-append's two scopes, on its own two-name declaration.
out("da_compose_declared", present(spawnMod.buildEnv(da, anchors, null, ["GH_TOKEN", "GITHUB_TOKEN"]), daDeclared));
out("da_plain_declared", present(spawnMod.buildEnv(da, anchors, null, []), daDeclared));

// A8 — purity: a scoped call must not mutate either declaration array, or the
// next worker dispatched in the same process inherits this call's scope.
const beforePass = declared.join(",");
const beforeAllow = registry.CHILD_ENV_ALLOWLIST.join(",");
const snap = (e) => JSON.stringify(Object.keys(e).sort().map((k) => [k, e[k]]));
const s1 = snap(spawnMod.buildEnv(cp, anchors, null, ["SSH_AUTH_SOCK"]));
const s2 = snap(spawnMod.buildEnv(cp, anchors, null, ["SSH_AUTH_SOCK"]));
out("scoped_idempotent", s1 === s2 ? 1 : 0);
out("passthrough_unmutated", (cp.envPassthrough || []).join(",") === beforePass ? 1 : 0);
out("allowlist_unmutated", registry.CHILD_ENV_ALLOWLIST.join(",") === beforeAllow ? 1 : 0);
out("after_scoped_full_still_full", present(spawnMod.buildEnv(cp, anchors, null), declared));
process.exit(0);
PROBEJS

EPROBE_OUT=""
run_envscope_probe() {
    EPROBE_OUT="$(run_with_timeout 60 env \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "GH_TOKEN=$FAKE_GH_TOKEN" "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" \
        "SSH_AUTH_SOCK=$FAKE_SSH_SOCK" "AWS_SECRET_ACCESS_KEY=$FAKE_AWS_SECRET" \
        "ENFORCE_WORKTREE=on" "DEFAULT_BRANCHES=main,master" \
        "WORKFLOW_SESSION_ID=$SID" "CLAUDE_PROJECT_DIR=$CWD" \
        node "$(nodepath "$ENVSCOPE_PROBE")" "$(nodepath "$AGENTS_DIR")" "$MAIN" 2>&1)" || return 1
    return 0
}
epv() { printf '%s\n' "$EPROBE_OUT" | sed -n "s/^$1=//p" | head -1; }

ALL_DECLARED="CLAUDE_PROJECT_DIR,CLAUDE_WORKFLOW_DIR,DEFAULT_BRANCHES,ENFORCE_WORKTREE,GH_TOKEN,GITHUB_TOKEN,SSH_AUTH_SOCK,WORKFLOW_PLANS_DIR,WORKFLOW_SESSION_ID"
NO_DECL_ERR="does not declare the child env var"
NOT_ARRAY_ERR="child env scope must be an array of env var names"

group_a() {
    if ! run_envscope_probe; then
        fail "A/probe" "$EPROBE_OUT"
        return
    fi
    assert_eq "A/precondition-parent-holds-every-declared-var" "" "$(epv parent_missing)"
    assert_eq "A/precondition-parent-holds-offlist-var" "1" "$(epv parent_has_offlist)"
    assert_eq "A/precondition-declared-set" "$ALL_DECLARED" "$(epv declared)"
    assert_eq "A/precondition-doc-append-declared-set" "GH_TOKEN,GITHUB_TOKEN" "$(epv da_declared)"

    assert_eq "A1/scope-narrows-to-the-intersection" "SSH_AUTH_SOCK" "$(epv narrow_declared)"
    assert_eq "A1/scoped-value-identical" "1" "$(epv narrow_value_identical)"
    assert_eq "A1/base-allowlist-untouched" "1" "$(epv narrow_path)"
    assert_eq "A1/acd-still-pinned" "1" "$(epv narrow_acd)"

    assert_eq "A2/empty-scope-admits-no-declared-var" "" "$(epv empty_declared)"
    assert_eq "A2/empty-scope-keeps-base-allowlist" "1" "$(epv empty_path)"
    assert_eq "A2/empty-scope-keeps-acd" "1" "$(epv empty_acd)"

    assert_eq "A3/omitted-scope-keeps-full-set" "$ALL_DECLARED" "$(epv omitted_declared)"
    assert_eq "A3/explicit-undefined-keeps-full-set" "$ALL_DECLARED" "$(epv undefined_declared)"
    assert_eq "A3/null-is-not-a-scope" "$NOT_ARRAY_ERR" "$(epv null_scope_error)"
    assert_eq "A3/string-is-not-a-scope" "$NOT_ARRAY_ERR" "$(epv string_scope_error)"

    assert_eq "A4/undeclared-name-in-scope-does-not-leak" "0" "$(epv offlist_present)"
    assert_eq "A4/rest-of-that-scope-still-applies" "SSH_AUTH_SOCK" "$(epv offlist_scope_declared)"

    case "$(epv extra_declared_out_of_scope)" in
        *"$NO_DECL_ERR"*) pass "A5/extraEnv-checked-against-narrowed-set" ;;
        *) fail "A5/extraEnv-checked-against-narrowed-set" "got: $(epv extra_declared_out_of_scope)" ;;
    esac
    case "$(epv extra_empty_scope)" in
        *"$NO_DECL_ERR"*) pass "A5/extraEnv-refused-under-empty-scope" ;;
        *) fail "A5/extraEnv-refused-under-empty-scope" "got: $(epv extra_empty_scope)" ;;
    esac
    case "$(epv extra_undeclared_scoped)" in
        *"$NO_DECL_ERR"*) pass "A5/scope-cannot-authorize-an-undeclared-extraEnv" ;;
        *) fail "A5/scope-cannot-authorize-an-undeclared-extraEnv" "got: $(epv extra_undeclared_scoped)" ;;
    esac
    assert_eq "A5/extraEnv-in-scope-accepted" "NO_THROW" "$(epv extra_in_scope)"
    assert_eq "A5/extraEnv-in-scope-value-applied" "x" "$(epv extra_in_scope_value)"
    assert_eq "A5/extraEnv-with-omitted-scope-unchanged" "NO_THROW" "$(epv extra_omitted_scope)"

    assert_eq "A6/gate-scope-admits-its-six-and-no-credential" \
        "CLAUDE_PROJECT_DIR,CLAUDE_WORKFLOW_DIR,DEFAULT_BRANCHES,ENFORCE_WORKTREE,WORKFLOW_PLANS_DIR,WORKFLOW_SESSION_ID" \
        "$(epv gate_scope_declared)"

    assert_eq "A7/doc-append-compose-scope" "GH_TOKEN,GITHUB_TOKEN" "$(epv da_compose_declared)"
    assert_eq "A7/doc-append-plain-scope" "" "$(epv da_plain_declared)"

    assert_eq "A8/scoped-calls-are-idempotent" "1" "$(epv scoped_idempotent)"
    assert_eq "A8/envPassthrough-unmutated" "1" "$(epv passthrough_unmutated)"
    assert_eq "A8/allowlist-unmutated" "1" "$(epv allowlist_unmutated)"
    assert_eq "A8/no-scope-residue-in-the-next-call" "$ALL_DECLARED" "$(epv after_scoped_full_still_full)"
}
