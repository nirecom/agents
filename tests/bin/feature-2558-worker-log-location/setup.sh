# Part of tests/bin/feature-2558-worker-log-location.sh — sourced.
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, worker-log, fixture, TL2, scope:issue-specific
# Shared fixture: one main repo plus one linked worktree that every C1 row reuses,
# the dual-pinned PLANS/WF dirs, and the dispatch / listing helpers.

DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
SPAWN_JS="$AGENTS_DIR/bin/worker-dispatch/spawn.js"
WORKER_LOG_JS="$AGENTS_DIR/bin/worker-dispatch/worker-log.js"
FSGUARD_JS="$AGENTS_DIR/bin/worker-dispatch/fsguard.js"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WF_RAW="$TMPD/wf"; mkdir -p "$WF_RAW"
PLANS="$(np "$PLANS_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"
BRANCH="feature/2558-probe"

# build_repo — main repo + linked worktree. `.env` is the worktree-copy include,
# keep.txt the gitignored file worktree-backup has to find in the linked tree.
build_repo() {
    MAIN_RAW="$TMPD/mainrepo"; LINKED_RAW="$TMPD/linked-wt"
    mkdir -p "$MAIN_RAW"
    harness_git_init "$MAIN_RAW"
    git -C "$MAIN_RAW" checkout -q -b main 2>/dev/null
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    printf '.env\nkeep.txt\n.worktree-backup/\n' > "$MAIN_RAW/.gitignore"
    printf '.env\n' > "$MAIN_RAW/.worktreeinclude"
    echo init > "$MAIN_RAW/README.md"
    git -C "$MAIN_RAW" add .gitignore .worktreeinclude README.md >/dev/null 2>&1
    git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
    printf 'LOCAL_FLAG=1\n' > "$MAIN_RAW/.env"
    git -C "$MAIN_RAW" worktree add -q -b "$BRANCH" "$LINKED_RAW" >/dev/null 2>&1
    printf 'KEEP\n' > "$LINKED_RAW/keep.txt"
    printf '## BugsFound\n- (none)\n' > "$LINKED_RAW/WORKTREE_NOTES.md"
    MAIN="$(np "$MAIN_RAW")"; LINKED="$(np "$LINKED_RAW")"
    [ -d "$LINKED_RAW/.git" ] || [ -f "$LINKED_RAW/.git" ]
}

# write_canned <json> — the rules array for spawn-stub.js, written verbatim.
write_canned() { printf '%s' "$1" > "$CANNED"; }

# sid_payload <sid> <worker-name> <json> — the dispatcher's canonical location:
# <WF>/<sid>.control/worker-<name>.json inside a real control directory.
sid_payload() {
    mkdir -p "$WF_RAW/$1.control"
    printf '%s' "$3" > "$WF_RAW/$1.control/worker-$2.json"
    np "$WF_RAW/$1.control/worker-$2.json"
}
# plans_payload <stem> <json> — a sid-less legacy payload (no <sid>-worker- name).
plans_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; np "$PLANS_RAW/$1.json"; }

DOUT=""; DRC=0
# dispatch <worker> <payload-path> <stubbed:1|0> — WF_RAW selects the workflow dir.
dispatch() {
    local wf; wf="$(np "$WF_RAW")"
    : > "$CALLLOG"
    DRC=0
    if [ "$3" = "1" ]; then
        DOUT="$(run_with_timeout 120 env -u CLAUDE_CODE_SESSION_ID "WORKFLOW_PLANS_DIR=$PLANS" "WORKFLOW_STATE_DIR=$wf" \
            "WD_SPAWN_MODULE=$(np "$SPAWN_JS")" "WD_CANNED=$(np "$CANNED")" "WD_CALL_LOG=$(np "$CALLLOG")" \
            node -r "$(np "$PRELOAD")" "$(np "$DISPATCH_JS")" "$1" "$MAIN" "$2" 2>/dev/null)" || DRC=$?
    else
        DOUT="$(run_with_timeout 120 env -u CLAUDE_CODE_SESSION_ID "WORKFLOW_PLANS_DIR=$PLANS" "WORKFLOW_STATE_DIR=$wf" \
            node "$(np "$DISPATCH_JS")" "$1" "$MAIN" "$2" 2>/dev/null)" || DRC=$?
    fi
}
# field_of <key> — renderers differ in quoting; the surrounding quotes are dropped.
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# plans_listing — every file and dir under PLANS_DIR, relative, sorted.
plans_listing() { (cd "$PLANS_RAW" && find . -mindepth 1 | LC_ALL=C sort); }
# plans_added <before-listing> — entries present now that were not before.
plans_added() {
    local before="$TMPD/plans.before" after="$TMPD/plans.after"
    printf '%s\n' "$1" | sed '/^$/d' > "$before"
    plans_listing > "$after"
    LC_ALL=C comm -13 "$before" "$after"
}
# logs_matching <dir> <label> — files named <stamp>-<label> directly in <dir>.
logs_matching() {
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 1 -type f -name "*-$2" 2>/dev/null | LC_ALL=C sort
}
count_lines() { if [ -z "$1" ]; then printf '0'; else printf '%s\n' "$1" | grep -c ''; fi; }
file_count() { if [ -d "$1" ]; then find "$1" -type f 2>/dev/null | grep -c ''; else printf '0'; fi; }

# same_path <a> <b> — "same" when both name one existing file (realpath, case-folded on win32).
same_path() {
    node -e '
const fs = require("fs");
const n = (p) => { try { const r = fs.realpathSync.native(p); return process.platform === "win32" ? r.toLowerCase() : r; } catch (e) { return "(missing:" + p + ")"; } };
process.stdout.write(n(process.argv[1]) === n(process.argv[2]) ? "same" : "differ: " + n(process.argv[1]) + " vs " + n(process.argv[2]));
' "$1" "$2"
}

# can_symlink — native symlinks (Windows needs MSYS nativestrict or the link is a copy).
can_symlink() {
    mkdir -p "$TMPD/.lp-target"
    MSYS=winsymlinks:nativestrict ln -s "$TMPD/.lp-target" "$TMPD/.lp-link" 2>/dev/null || true
    local ok=1
    [ -L "$TMPD/.lp-link" ] && ok=0
    rm -f "$TMPD/.lp-link"; rm -rf "$TMPD/.lp-target"
    return "$ok"
}
