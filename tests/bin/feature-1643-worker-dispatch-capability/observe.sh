#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability/observe.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-capability.sh after fixtures.sh — spawn counting, tree snapshot, dispatch runner.

# An invocation is "read-only anchor probe" when it is git rev-parse / git
# worktree list. Anything else counts as an effectful spawn.
# Same pattern the `grep -v … | grep -c .` form used, evaluated in-process: two
# more process starts saved per matrix row. The log is normally empty, so the
# loop body rarely runs at all.
SPAWN_PROBE_RE='^git (-C [^ ]+ )?(rev-parse|worktree list)'
count_effectful_spawns() {
    local line
    EFFECTFUL_SPAWNS=0
    [ -f "$SPAWN_LOG" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ $line =~ $SPAWN_PROBE_RE ]]; then continue; fi
        EFFECTFUL_SPAWNS=$((EFFECTFUL_SPAWNS + 1))
    done < "$SPAWN_LOG"
    return 0
}

# Byte snapshot of every protected surface (payload files excluded — the test
# itself writes those, and PLANS_DIR is the one sanctioned write scope).
# One node process walks all nine roots (the last is the pinned workflow dir, where worker logs land) (a per-file node start outran the guard on
# Windows). Output is byte-identical to the old find form: `<root>|<./relpath> <sha256>`,
# roots in listed order, paths byte-sorted, regular files only, only a top-level
# `.git/` pruned (a linked worktree's `.git` *file* stays in).
# Roots arrive on stdin as `label<TAB>path` pairs, not argv: MSYS rewrites path-shaped
# argv into node.exe. The label is the raw bash path; the path is the cygpath -m form.
SNAP_JS="$TMPD/snapshot-all.js"
cat > "$SNAP_JS" <<'SNAPJS'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const roots = fs.readFileSync(0, "utf8").split("\n")
  .filter((l) => l !== "")
  .map((l) => { const i = l.indexOf("\t"); return { label: l.slice(0, i), dir: l.slice(i + 1) }; });

const out = [];
for (const { label, dir: root } of roots) {
  let st;
  try { st = fs.statSync(root); } catch { continue; }   // cd failed => no output
  if (!st.isDirectory()) continue;

  const files = [];
  const walk = (dir, rel) => {
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const r = rel ? rel + "/" + e.name : e.name;
      if (r === ".git" && e.isDirectory()) continue;    // matches -not -path './.git/*'
      if (e.isDirectory()) walk(path.join(dir, e.name), r);
      else if (e.isFile()) files.push(r);               // isFile() is lstat-based: symlinks excluded, as -type f
    }
  };
  walk(root, "");

  files.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  for (const r of files) {
    let hash;
    try {
      hash = crypto.createHash("sha256").update(fs.readFileSync(path.join(root, r))).digest("hex");
    } catch { hash = "ERR"; }
    out.push(label + "|./" + r + " " + hash);
  }
}
process.stdout.write(out.length ? out.join("\n") + "\n" : "");
SNAPJS
SNAP_JS_N="$(nodepath "$SNAP_JS")"

# The control-dir migration cursor is bookkeeping the first session-scoped dispatch may create, not a worker write; it is filtered out.
snapshot_all() {
    printf '%s\t%s\n' \
        "$MAIN_RAW"       "$MAIN" \
        "$ALT_RAW"        "$ALT" \
        "$LINKED_RAW"     "$LINKED" \
        "$ALT_LINKED_RAW" "$ALT_LINKED" \
        "$EVIL_RAW"       "$EVIL" \
        "$OUTSIDE_RAW"    "$OUTSIDE" \
        "$NONGIT_RAW"     "$NONGIT" \
        "$FAKE_ACD_RAW"   "$FAKE_ACD" \
        "$WF_PIN"         "$WF_PIN" \
        | node "$SNAP_JS_N" 2>/dev/null \
        | grep -v '/\.control-migration-cursor\.json '
}

DOUT=""
DRC=0
run_dispatch() {
    DRC=0
    DOUT="$(cd "$MAIN_RAW" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID \
        "PATH=$SHIM_DIR:$PATH" \
        "WORKFLOW_PLANS_DIR=$PLANS" "WORKFLOW_STATE_DIR=$WF_PIN" \
        node "$DISPATCH_JS" "$@" 2>&1)" || DRC=$?
}

# First `status: <value>` line of the dispatcher output, matched in-process for
# the same reason as trim(): the pipe-to-sed form is three process starts, and
# this runs once per matrix row.
status_of() {
    local line
    STATUS_LINE=""
    while IFS= read -r line; do
        case "$line" in
            status:*)
                line="${line#status:}"
                trim "$line"
                STATUS_LINE="$TRIMMED"
                return 0
                ;;
        esac
    done <<< "$DOUT"
}

# The rejection status is renderer-dependent, and the renderer is a property of
# the worker (hooks/lib/worker-dispatch-registry.js). The status-triple families
# say `failed`; the test-runner YAML renderer has its own four-value vocabulary
# — pass | fail | timeout | runner-error — which skills/run-tests/SKILL.md RNT-9
# branches on, and `failed` is in none of those branches. Kept as an explicit
# test-owned table rather than read back out of the registry, so a registry that
# silently re-rendered a worker would fail here instead of agreeing with itself.
expected_reject_status() {
    case "$1" in
        test-runner) echo "runner-error" ;;
        *)           echo "failed" ;;
    esac
}
