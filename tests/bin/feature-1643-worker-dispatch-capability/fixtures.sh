#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability/fixtures.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-capability.sh after helpers.sh — fixture tree and PATH shims.

# ---------------------------------------------------------------------------
# Fixtures — every protected surface gets a file whose bytes we watch.
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
ALT_RAW="$TMPD/altrepo";   mk_repo "$ALT_RAW"
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/cap-probe "$LINKED_RAW" >/dev/null ||
    fixture_abort "git worktree add failed for the linked worktree"
ALT_LINKED_RAW="$TMPD/alt-linked-wt"
git -C "$ALT_RAW" worktree add -q -b feature/alt-probe "$ALT_LINKED_RAW" >/dev/null ||
    fixture_abort "git worktree add failed for the other repository's linked worktree"
# The suite the accepted test-runner control row names; never run (its bash child is held).
mkdir -p "$LINKED_RAW/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LINKED_RAW/tests/run-all.sh"

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WF_PIN="$(nodepath "$TMPD/wf")"; mkdir -p "$TMPD/wf"   # #2558: worker logs live under the workflow dir
EVIL_RAW="$TMPD/plans-evil"; mkdir -p "$EVIL_RAW"   # sibling-prefix bypass target
OUTSIDE_RAW="$TMPD/outside"; mkdir -p "$OUTSIDE_RAW"
OTHER_CHECKOUT_RAW="$TMPD/other-checkout"; mkdir -p "$OTHER_CHECKOUT_RAW/hooks" "$OTHER_CHECKOUT_RAW/bin"
touch "$OTHER_CHECKOUT_RAW/hooks/enforce-worktree.js" "$OTHER_CHECKOUT_RAW/bin/worker-dispatch.js"
NONGIT_RAW="$TMPD/plain-dir"; mkdir -p "$NONGIT_RAW"

echo "canary" > "$EVIL_RAW/WORKTREE_NOTES.md"
echo "canary" > "$OUTSIDE_RAW/history.md"
echo "canary" > "$NONGIT_RAW/canary.txt"

MAIN="$(nodepath "$MAIN_RAW")"
ALT="$(nodepath "$ALT_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
ALT_LINKED="$(nodepath "$ALT_LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
EVIL="$(nodepath "$EVIL_RAW")"
OUTSIDE="$(nodepath "$OUTSIDE_RAW")"
OTHER_CHECKOUT="$(nodepath "$OTHER_CHECKOUT_RAW")"
THIS_CHECKOUT="$(nodepath "$SCRIPT_CHECKOUT_ROOT")"
NONGIT="$(nodepath "$NONGIT_RAW")"

# Symlink inside the family that escapes it (env-dependent on Windows).
SYMLINK_OK=0
SYMLINK_RAW="$LINKED_RAW/escape-link"
if ln -s "$OUTSIDE_RAW" "$SYMLINK_RAW" 2>/dev/null; then SYMLINK_OK=1; fi
SYMLINK="$(nodepath "$SYMLINK_RAW")"

# ---------------------------------------------------------------------------
# Observability and containment. The dispatcher runs under the spawn-record preload, which
# writes one JSONL record per child it starts and, with SPAWN_RECORD_ALLOW=git, runs git
# alone. A bash PATH shim cannot do either job: a shell-less spawnSync never resolves an
# extensionless script on Windows. Behind the preload, gh/glab/uv/docker resolve to stubs
# that answer with exit 97 and forward nothing, for every process of this suite.
# ---------------------------------------------------------------------------
SPAWN_LOG="$TMPD/spawn.jsonl"; : > "$SPAWN_LOG"
SPAWN_LOG_N="$(nodepath "$SPAWN_LOG")"
SPAWN_PRELOAD_N="$(nodepath "$SCRIPT_CHECKOUT_ROOT/tests/fixtures/spawn-record-preload.js")"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"
cli_stub_make "$TMPD/stubs" gh glab uv docker || fixture_abort "the non-forwarding CLI stubs could not be built"
export PATH="$CLI_STUB_DIR:$PATH"
export NODE_OPTIONS="--require \"$CLI_STUB_PRELOAD\"" CLI_STUB_RC=97
