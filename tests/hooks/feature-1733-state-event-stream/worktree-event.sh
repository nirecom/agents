#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/worktree-event.sh
# Tests: hooks/postuse-native-worktree-record.js, hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/events.js
# Tags: workflow-state, event-stream, worktree, path-source, provenance, fail-open, scope:issue-specific, pwsh-not-required, TL2
#
# The worktree recorder used to stamp two top-level timestamps, so entering the same
# worktree twice was indistinguishable from entering two different ones, and the path
# was never recorded at all. Under #1733 each transition is its own event carrying
# worktree_path plus `path_source` — the field that says HOW the path was determined.
# path_source is the part most likely to be silently wrong (a fallback that looks like a
# real reading), so every one of its four values is asserted, not just the happy one.
#
# FIXTURE REQUIREMENT: the happy path is resolved by `git -C <path> rev-parse`, so the
# fixtures are REAL git repositories on known branches (mk_git_repo), and the hook
# process runs in a DIFFERENT repo on a different branch. A mkdir'd directory would make
# every case take the fallback branch while still "passing" the assertions that matter.
#
# TL3 gap (what this test does NOT catch):
# - the real PostToolUse registration for EnterWorktree / ExitWorktree in settings.json.
#   The hook is fed JSON on stdin here, which proves the hook body but not that Claude
#   Code ever calls it.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="wt"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MKV1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mk-v1.js"

# run_hook <sid> <tool_name> <tool_input-json> — feeds the PostToolUse recorder on stdin,
# exactly as Claude Code does. Sets HOOK_OUT / HOOK_RC.
#
# The hook's PROCESS CWD is HOOK_CWD (default: the agents repo). It is a distinct axis
# from the path in tool_input, and the whole point of path_source: Claude Code fires
# PostToolUse from wherever the session started, NOT from the worktree that was just
# entered. Cases that assert path_source=tool_input therefore point HOOK_CWD at a
# different repository on a different branch, so a recorder that quietly ignored
# tool_input and probed its own cwd would report that other branch and fail.
run_hook() {
    local sid="$1" tool="$2" ti="$3" payload
    payload="$(printf '{"session_id":"%s","tool_name":"%s","tool_input":%s}' "$sid" "$tool" "$ti")"
    HOOK_RC=0
    HOOK_OUT="$(cd "${HOOK_CWD:-$AGENTS_DIR}" && printf '%s' "$payload" | env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node \
        "$AGENTS_DIR/hooks/postuse-native-worktree-record.js" 2>&1)" || HOOK_RC=$?
}

# Creates the state file the recorder needs (it fail-opens when there is none).
INIT_JS="$PRE"'S.markStep(sid, "workflow_init", "complete");'

# Two REAL repositories: the "session" repo the hook process runs in (branch main) and
# the worktree the tool entered (branch fix/x). Distinct branches make the two sources
# distinguishable in every assertion below.
HOST_REPO="$TMPROOT/repo-host"
WT_REPO="$TMPROOT/repo-wt"
mk_git_repo "$HOST_REPO" "main" || fail "fixture/host-repo" "git init failed"
mk_git_repo "$WT_REPO" "fix/x" || fail "fixture/wt-repo" "git init failed"
WT_REPO_JSON="$(json_path "$WT_REPO")"

echo "== W-a: EnterWorktree with tool_input.path reads the ENTERED repo, not the hook's cwd =="
if run_case "W-a/path-source-tool-input"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "$(printf '{"path":"%s"}' "$WT_REPO_JSON")"
    nodejs_env "WT_REPO=$(native_path "$WT_REPO")" "$SID" "$PRE"'
const ev = evs("worktree");
const e = ev[0] || {};
const same = (a, b) => String(a).replace(/\\/g, "/").toLowerCase().replace(/\/+$/, "") ===
                       String(b).replace(/\\/g, "/").toLowerCase().replace(/\/+$/, "");
console.log("n=" + ev.length + " transition=" + e.transition +
            " path_source=" + e.path_source +
            " git_branch=" + e.git_branch +
            " cwd_is_entered=" + same(e.cwd, process.env.WT_REPO) +
            " path_is_entered=" + same(e.worktree_path, process.env.WT_REPO) +
            " provenance=" + e.provenance +
            " is_bugfix=" + cur().is_bugfix);
'
    # git_branch=fix/x is the load-bearing assertion: the hook process was standing in a
    # `main` repo, so this value can only have come from tool_input.path. is_bugfix is
    # the downstream consequence (#1147 T0-A gate reads it).
    assert_eq "W-a/path-source-tool-input" \
        "n=1 transition=entered path_source=tool_input git_branch=fix/x cwd_is_entered=true path_is_entered=true provenance=observed is_bugfix=true" \
        "$NODE_OUT"
fi

echo "== W-b: EnterWorktree with no path falls back to the process cwd, with a NULL path =="
if run_case "W-b/path-source-fallback"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "{}"
    nodejs "$SID" "$PRE"'
const e = evs("worktree")[0] || {};
console.log("path_source=" + e.path_source +
            " worktree_path=" + JSON.stringify(e.worktree_path) +
            " git_branch=" + e.git_branch +
            " entered_at_set=" + /^\d{4}-\d{2}-\d{2}T.*Z$/.test(cur().worktree_entered_at || ""));
'
    # worktree_path MUST be null. The fallback observed the hook process cwd, which is
    # NOT the worktree that was entered — writing that path into worktree_path would
    # record a confident-looking lie, and every downstream reader would believe it.
    # git_branch still carries the observed cwd's branch (labelled by path_source), and
    # the transition timestamp is still recorded: fallback ≠ no record.
    assert_eq "W-b/path-source-fallback" \
        "path_source=fallback-process-cwd worktree_path=null git_branch=main entered_at_set=true" "$NODE_OUT"
fi

echo "== W-c: an ExitWorktree with no path reuses the prior entry (path_source=prior-entry) =="
if run_case "W-c/path-source-prior-entry"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "$(printf '{"path":"%s"}' "$WT_REPO_JSON")"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "ExitWorktree" "{}"
    nodejs "$SID" "$PRE"'
const ev = evs("worktree");
const [a, b] = ev;
console.log("n=" + ev.length +
            " transitions=" + ev.map((e) => e.transition).join(",") +
            " exit_path_source=" + b.path_source +
            " paths_match=" + (a.worktree_path === b.worktree_path) +
            " path_nonnull=" + (b.worktree_path !== null));
'
    assert_eq "W-c/path-source-prior-entry" \
        "n=2 transitions=entered,exited exit_path_source=prior-entry paths_match=true path_nonnull=true" "$NODE_OUT"
fi

echo "== W-c2: a path that does not exist falls back (and does not invent a branch) =="
if run_case "W-c2/nonexistent-path-falls-back"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" \
        "$(printf '{"path":"%s"}' "$(json_path "$TMPROOT")/definitely-not-here-1733")"
    nodejs "$SID" "$PRE"'
const e = evs("worktree")[0] || {};
console.log("path_source=" + e.path_source + " worktree_path=" + JSON.stringify(e.worktree_path) +
            " git_branch=" + e.git_branch);
'
    assert_eq "W-c2/nonexistent-path-falls-back" \
        "path_source=fallback-process-cwd worktree_path=null git_branch=main" "$NODE_OUT"
fi

echo "== W-c3: a RELATIVE path falls back (only an absolute path is trustworthy) =="
if run_case "W-c3/relative-path-falls-back"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" '{"path":"../repo-wt"}'
    nodejs "$SID" "$PRE"'
const e = evs("worktree")[0] || {};
console.log("path_source=" + e.path_source + " worktree_path=" + JSON.stringify(e.worktree_path));
'
    # ../repo-wt resolves to a real repo from THIS process cwd, but the recorder must not
    # gamble that its cwd is the same as the tool caller's.
    assert_eq "W-c3/relative-path-falls-back" \
        "path_source=fallback-process-cwd worktree_path=null" "$NODE_OUT"
fi

echo "== W-c4: a non-repo directory falls back — an existing path is not enough =="
if run_case "W-c4/non-repo-falls-back"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    PLAIN_DIR="$TMPROOT/plain-dir"; mkdir -p "$PLAIN_DIR"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "$(printf '{"path":"%s"}' "$(json_path "$PLAIN_DIR")")"
    nodejs "$SID" "$PRE"'
const e = evs("worktree")[0] || {};
console.log("path_source=" + e.path_source + " worktree_path=" + JSON.stringify(e.worktree_path) +
            " git_branch=" + e.git_branch);
'
    # `git rev-parse` fails here, so there is no branch to record: fall back and say so.
    assert_eq "W-c4/non-repo-falls-back" \
        "path_source=fallback-process-cwd worktree_path=null git_branch=main" "$NODE_OUT"
fi

echo "== W-c5: a POSIX drive-form path (/c/...) is normalized, not rejected =="
if run_case "W-c5/posix-drive-form-normalized"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    # Platform-specific INPUT, identical EXPECTATION (CPR-UNV): on win32 the MSYS/Git-Bash
    # form `/c/...` must be normalized by normalizeCwd before the isAbsolute/stat checks;
    # on POSIX the same string IS the native form. Either way the entered repo resolves.
    # This is the shape a Git-Bash-launched session actually hands the hook.
    #
    # `pwd` inside WT_REPO is NOT used to derive this: `mktemp -d` (common.sh TMPROOT)
    # does not reliably land under a drive-letter-rooted path on every host — on MSYS it
    # can resolve under MSYS's own internal /tmp mount instead, where `pwd` never
    # produces the /c/... form at all. Converting the native (drive-letter) path
    # deterministically exercises the POSIX-drive-form branch regardless of where the
    # host happens to have mounted /tmp.
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            WIN_PATH="$(native_path "$WT_REPO")"                          # C:/Users/.../repo-wt
            WT_DRIVE="${WIN_PATH%%:*}"
            WT_REST="${WIN_PATH#*:}"
            WT_DRIVE_LC="$(printf '%s' "$WT_DRIVE" | tr '[:upper:]' '[:lower:]')"
            WT_POSIX="/${WT_DRIVE_LC}${WT_REST}" ;;                       # /c/Users/... form
        *)
            WT_POSIX="$WT_REPO" ;;
    esac
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "$(printf '{"path":"%s"}' "$WT_POSIX")"
    nodejs "$SID" "$PRE"'
const e = evs("worktree")[0] || {};
console.log("path_source=" + e.path_source + " git_branch=" + e.git_branch +
            " path_nonnull=" + (e.worktree_path !== null));
'
    assert_eq "W-c5/posix-drive-form-normalized" \
        "path_source=tool_input git_branch=fix/x path_nonnull=true" "$NODE_OUT"
fi

echo "== W-d: a v1-migrated transition is labelled migration-unknown with a null path =="
if run_case "W-d/path-source-migration-unknown"; then
    next_sid
    (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$MKV1" toplevel) > "$WF/$SID.json"
    nodejs "$SID" "$PRE"'
const ev = S.readState(sid).events.filter((e) => e.kind === "worktree");
console.log("n=" + ev.length +
            " sources=" + ev.map((e) => e.path_source).join(",") +
            " paths=" + ev.map((e) => JSON.stringify(e.worktree_path)).join(",") +
            " provenance=" + ev.map((e) => e.provenance).join(","));
'
    # v1 stored no path at all, so inventing one would be a lie; null + a distinct
    # path_source is the honest record.
    assert_eq "W-d/path-source-migration-unknown" \
        "n=2 sources=migration-unknown,migration-unknown paths=null,null provenance=backfilled,backfilled" "$NODE_OUT"
fi

echo "== W-e: resolveWorktreeContext returns the full four-field contract =="
if run_case "W-e/resolve-contract"; then
    next_sid
    nodejs_env "WT_REPO=$(native_path "$WT_REPO")" "$SID" '
const S = require("./hooks/workflow-state/state-io");
const r = S.resolveWorktreeContext(process.env.WT_REPO);
const same = (a, b) => String(a).replace(/\\/g, "/").toLowerCase().replace(/\/+$/, "") ===
                       String(b).replace(/\\/g, "/").toLowerCase().replace(/\/+$/, "");
console.log("keys=" + Object.keys(r).sort().join(",") +
            " path_source=" + r.path_source +
            " git_branch=" + r.git_branch +
            " worktree_path_kept=" + same(r.worktree_path, process.env.WT_REPO) +
            " cwd_kept=" + same(r.cwd, process.env.WT_REPO));
'
    assert_eq "W-e/resolve-contract" \
        "keys=cwd,git_branch,path_source,worktree_path path_source=tool_input git_branch=fix/x worktree_path_kept=true cwd_kept=true" "$NODE_OUT"
fi

echo "== W-e2: resolveWorktreeContext(null/undefined) reports the fallback source =="
if run_case "W-e2/resolve-fallback"; then
    next_sid
    nodejs "$SID" '
const S = require("./hooks/workflow-state/state-io");
const out = [null, undefined, "", 42, {}].map((v) => {
  const r = S.resolveWorktreeContext(v);
  return r.path_source + "/" + JSON.stringify(r.worktree_path);
});
console.log(out.join(" "));
'
    # Every fallback carries worktree_path: null — including the non-string inputs, which
    # must not reach String(v) and become a path-shaped lie like "[object Object]".
    assert_eq "W-e2/resolve-fallback" \
        "fallback-process-cwd/null fallback-process-cwd/null fallback-process-cwd/null fallback-process-cwd/null fallback-process-cwd/null" \
        "$NODE_OUT"
fi

echo "== W-e3: getCurrentContext() with no argument is byte-identical to before =="
if run_case "W-e3/get-current-context-noarg"; then
    next_sid
    nodejs "$SID" '
const S = require("./hooks/workflow-state/state-io");
const noArg = S.getCurrentContext();
const explicit = S.getCurrentContext(process.cwd());
// The pre-#1733 contract is exactly {cwd, git_branch}; a new optional arg
// must not change the no-arg shape or values (CPR-UNV: no environment-dependent drift).
console.log("keys=" + Object.keys(noArg).sort().join(",") +
            " same_as_explicit=" + (JSON.stringify(noArg) === JSON.stringify(explicit)));
'
    assert_eq "W-e3/get-current-context-noarg" \
        "keys=cwd,git_branch same_as_explicit=true" "$NODE_OUT"
fi

echo "== W-f: the projection still exposes worktree_entered_at / worktree_exited_at =="
if run_case "W-f/projection-timestamps"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "$(printf '{"path":"%s"}' "$WT_REPO_JSON")"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "ExitWorktree" "{}"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const c = cur();
const iso = (v) => /^\d{4}-\d{2}-\d{2}T.*Z$/.test(v || "");
console.log("entered=" + iso(st.worktree_entered_at) + " exited=" + iso(st.worktree_exited_at) +
            " in_current=" + (iso(c.worktree_entered_at) && iso(c.worktree_exited_at)) +
            " not_top_level=" + !("worktree_entered_at" in JSON.parse(raw())));
'
    # Downstream consumers (stop-exit-worktree-warn.js, worktree-entry-gate.js) read
    # these two fields; they must keep resolving through readState even though the
    # persisted file no longer carries them at the top level.
    assert_eq "W-f/projection-timestamps" \
        "entered=true exited=true in_current=true not_top_level=true" "$NODE_OUT"
fi

echo "== W-f2: re-entering the same worktree keeps BOTH events (the #1610 blind spot) =="
if run_case "W-f2/repeat-entry-both-kept"; then
    next_sid
    nodejs "$SID" "$INIT_JS"
    A="$TMPROOT/wt-f2-a"; B="$TMPROOT/wt-f2-b"
    mk_git_repo "$A" "fix/aaa" || fail "W-f2/fixture-a" "git init failed"
    mk_git_repo "$B" "feature/bbb" || fail "W-f2/fixture-b" "git init failed"
    A_JSON="$(json_path "$A")"; B_JSON="$(json_path "$B")"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "$(printf '{"path":"%s"}' "$A_JSON")"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "ExitWorktree" "$(printf '{"path":"%s"}' "$A_JSON")"
    HOOK_CWD="$HOST_REPO" run_hook "$SID" "EnterWorktree" "$(printf '{"path":"%s"}' "$B_JSON")"
    nodejs "$SID" "$PRE"'
const ev = evs("worktree");
const distinct = new Set(ev.map((e) => e.worktree_path)).size;
console.log("n=" + ev.length + " transitions=" + ev.map((e) => e.transition).join(",") +
            " distinct_paths=" + distinct +
            " branches=" + ev.map((e) => e.git_branch).join(",") +
            " last_is_entered=" + (ev[ev.length - 1].transition === "entered") +
            " is_bugfix=" + cur().is_bugfix +
            " seq_contiguous=" + rd().events.every((e, i) => e.seq === i + 1));
'
    # is_bugfix follows the LAST worktree event (feature/bbb), not the first (fix/aaa):
    # the projection derives it, so re-entry changes it. Pre-#1733 it was frozen at init.
    assert_eq "W-f2/repeat-entry-both-kept" \
        "n=3 transitions=entered,exited,entered distinct_paths=2 branches=fix/aaa,fix/aaa,feature/bbb last_is_entered=true is_bugfix=false seq_contiguous=true" "$NODE_OUT"
fi

echo "== W-g: the recorder stays fail-open — no state file, unknown tool, bad stdin =="
next_sid
NOSTATE_SID="$SID"
run_hook "$NOSTATE_SID" "EnterWorktree" "{}"
RC_NOSTATE="$HOOK_RC"
run_hook "$NOSTATE_SID" "Bash" '{"command":"ls"}'
RC_OTHERTOOL="$HOOK_RC"
RC_BADJSON=0
BAD_OUT="$(cd "$AGENTS_DIR" && printf 'not-json' | env \
    CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
    HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
    "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node hooks/postuse-native-worktree-record.js 2>&1)" || RC_BADJSON=$?
FILE_CREATED="no"; [ -f "$WF/$NOSTATE_SID.json" ] && FILE_CREATED="yes"
assert_eq "W-g/fail-open" "0 0 0 no " \
    "$RC_NOSTATE $RC_OTHERTOOL $RC_BADJSON $FILE_CREATED $BAD_OUT"

finish "worktree-event"
