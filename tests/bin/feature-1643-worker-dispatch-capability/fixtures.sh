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
git -C "$MAIN_RAW" worktree add -q -b feature/cap-probe "$LINKED_RAW" >/dev/null 2>&1
ALT_LINKED_RAW="$TMPD/alt-linked-wt"
git -C "$ALT_RAW" worktree add -q -b feature/alt-probe "$ALT_LINKED_RAW" >/dev/null 2>&1

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WF_PIN="$(nodepath "$TMPD/wf")"; mkdir -p "$TMPD/wf"   # #2558: worker logs live under the workflow dir
EVIL_RAW="$TMPD/plans-evil"; mkdir -p "$EVIL_RAW"   # sibling-prefix bypass target
OUTSIDE_RAW="$TMPD/outside"; mkdir -p "$OUTSIDE_RAW"
FAKE_ACD_RAW="$TMPD/fake-acd"; mkdir -p "$FAKE_ACD_RAW/hooks" "$FAKE_ACD_RAW/bin"
touch "$FAKE_ACD_RAW/hooks/enforce-worktree.js" "$FAKE_ACD_RAW/bin/worker-dispatch.js"
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
FAKE_ACD="$(nodepath "$FAKE_ACD_RAW")"
NONGIT="$(nodepath "$NONGIT_RAW")"

# Symlink inside the family that escapes it (env-dependent on Windows).
SYMLINK_OK=0
SYMLINK_RAW="$LINKED_RAW/escape-link"
if ln -s "$OUTSIDE_RAW" "$SYMLINK_RAW" 2>/dev/null; then SYMLINK_OK=1; fi
SYMLINK="$(nodepath "$SYMLINK_RAW")"

# ---------------------------------------------------------------------------
# Observability: PATH shims record every external child process.
# Read-only anchor probes are the only permitted invocations.
# ---------------------------------------------------------------------------
SHIM_DIR="$TMPD/shims"; mkdir -p "$SHIM_DIR"
SPAWN_LOG="$TMPD/spawn.log"; : > "$SPAWN_LOG"
for real_bin in git gh uv docker bash; do
    real_path="$(command -v "$real_bin" 2>/dev/null || true)"
    [ -z "$real_path" ] && continue
    cat > "$SHIM_DIR/$real_bin" <<SHIM
#!/usr/bin/env bash
printf '%s %s\n' "$real_bin" "\$*" >> "$SPAWN_LOG"
exec "$real_path" "\$@"
SHIM
    chmod +x "$SHIM_DIR/$real_bin"
done
