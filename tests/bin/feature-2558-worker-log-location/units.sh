# Part of tests/bin/feature-2558-worker-log-location.sh — sourced.
# Tests: hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/worker-log.js
# Tags: worker-dispatch, worker-log, fsguard, unit, TL1, scope:issue-specific
# C2 registry scopes, C3 fsguard log-dir containment, C4 the worker-log.js contract.
# Each driver (a heredoc on node's stdin) prints one "<case>=<value>" line per probe.

# kv <output> <key> — the value of one "<key>=<value>" line.
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

group_registry() {
    local out w
    out="$(node - "$(np "$REGISTRY_JS")" 2>&1 <<'JS'
const reg = require(process.argv.slice(-1)[0]);
const want = {
  "worktree-copy": ["family-worktree", "log-dir"], "worktree-backup": ["backup-dir", "log-dir"],
  "doc-append": ["family-worktree", "log-dir"], "issue-reconcile": ["plans-dir", "log-dir"],
  "session-close-gate": ["control-dir", "log-dir"], "commit-push": ["family-worktree", "log-dir"],
  "issue-close-stage": ["log-dir"], "issue-close-finalize": ["control-dir", "log-dir"],
};
const norm = (a) => JSON.stringify((Array.isArray(a) ? a.slice() : []).sort());
console.log("vocab=" + (reg.WRITE_SCOPES.includes("log-dir") ? "has-log-dir" : "missing"));
for (const [w, s] of Object.entries(want)) {
  const got = reg.workers[w] ? reg.workers[w].writeScopes : null;
  console.log(w + "=" + (norm(got) === norm(s) ? "ok" : "got " + JSON.stringify(got)));
}
const plans = Object.entries(reg.workers).filter(([, e]) => (e.writeScopes || []).includes("plans-dir")).map(([n]) => n);
console.log("plans-holders=" + plans.sort().join(","));
JS
)"
    assert_eq "c2/WRITE_SCOPES-has-log-dir" "has-log-dir" "$(kv "$out" vocab)"
    for w in worktree-copy worktree-backup doc-append issue-reconcile session-close-gate commit-push issue-close-stage issue-close-finalize; do
        assert_eq "c2/$w-writeScopes" "ok" "$(kv "$out" "$w")"
    done
    assert_eq "c2/only-issue-reconcile-keeps-plans-dir" "issue-reconcile" "$(kv "$out" plans-holders)"
}

group_fsguard() {
    local logd="$TMPD/unit-logdir" plansd="$TMPD/unit-plans" out
    mkdir -p "$logd" "$plansd"
    out="$(node - "$(np "$FSGUARD_JS")" "$(np "$logd")" "$(np "$plansd")" 2>&1 <<'JS'
const fs = require("fs"); const path = require("path");
const [lib, l, p] = process.argv.slice(-3);
const g = require(lib);
const logDir = fs.realpathSync.native(l); const plansDir = fs.realpathSync.native(p);
const probe = (k, target, ctx) => {
  try { g.assertWritable("issue-close-stage", target, ctx); console.log(k + "=allowed"); }
  catch (e) { console.log(k + "=refused:" + e.message); }
};
probe("in-log", path.join(logDir, "2026-x-issue-close-stage-worker-1.log"), { logDir, plansDir });
probe("in-plans", path.join(plansDir, "2026-x-issue-close-stage-worker-1.log"), { logDir, plansDir });
probe("no-logdir", path.join(plansDir, "2026-x-issue-close-stage-worker-1.log"), { logDir: null, plansDir });
JS
)"
    assert_eq "c3/issue-close-stage-may-write-log-dir" "allowed" "$(kv "$out" in-log)"
    case "$(kv "$out" in-plans)" in
        refused:*"outside every declared write scope"*) pass "c3/issue-close-stage-refused-in-plans" ;;
        *) fail "c3/issue-close-stage-refused-in-plans" "$(kv "$out" in-plans)" ;;
    esac
    case "$(kv "$out" no-logdir)" in
        refused:*"could be anchored"*) pass "c3/null-log-dir-anchors-nothing" ;;
        *) fail "c3/null-log-dir-anchors-nothing" "$(kv "$out" no-logdir)" ;;
    esac
}

group_worker_log() {
    if [ ! -f "$WORKER_LOG_JS" ]; then
        fail "c4/worker-log-module" "implementation missing: bin/worker-dispatch/worker-log.js"
        return
    fi
    local logd="$TMPD/unit-wl" out k
    mkdir -p "$logd"
    out="$(node - "$(np "$WORKER_LOG_JS")" "$(np "$logd")" 2>&1 <<'JS'
const fs = require("fs"); const path = require("path");
const [lib, logDir] = process.argv.slice(-2);
const wl = require(lib);
const okFs = { writeFile: (p, b) => { fs.writeFileSync(p, b); return p; } };
const badFs = { writeFile: () => { throw new Error("denied"); } };
const ctx = { logDir, fsguard: okFs };
const tries = (k, fn) => { try { console.log(k + "=returned:" + fn()); } catch (e) { console.log(k + "=threw"); } };
console.log("stamp=" + (/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z$/.test(wl.stamp()) ? "ok" : wl.stamp()));
tries("label-traversal", () => wl.logPath(ctx, "../x"));
tries("label-empty", () => wl.logPath(ctx, ""));
tries("label-upper", () => wl.logPath(ctx, "Upper.log"));
tries("no-logdir", () => wl.logPath({ fsguard: okFs }, "a.log"));
const p = wl.logPath(ctx, "probe.log", { stamp: "STAMPX" });
console.log("opt-stamp=" + (p === path.join(logDir, "STAMPX-probe.log") ? "ok" : p));
const w = wl.writeLog(ctx, "w.log", "body", { stamp: "S1" });
console.log("write=" + (w === path.join(logDir, "S1-w.log") && fs.readFileSync(w, "utf8") === "body" ? "ok" : w));
tries("write-fails", () => wl.writeLog({ logDir, fsguard: badFs }, "w.log", "b"));
tries("try-fs-fails", () => wl.tryWriteLog({ logDir, fsguard: badFs }, "w.log", "b"));
tries("try-no-logdir", () => wl.tryWriteLog({ fsguard: okFs }, "w.log", "b"));
tries("try-bad-label", () => wl.tryWriteLog(ctx, "../w.log", "b"));
JS
)"
    assert_eq "c4/stamp-format" "ok" "$(kv "$out" stamp)"
    for k in label-traversal label-empty label-upper no-logdir write-fails; do
        assert_eq "c4/$k-throws" "threw" "$(kv "$out" "$k")"
    done
    assert_eq "c4/opt-stamp-names-the-file" "ok" "$(kv "$out" opt-stamp)"
    assert_eq "c4/writeLog-returns-written-path" "ok" "$(kv "$out" write)"
    for k in try-fs-fails try-no-logdir try-bad-label; do
        assert_eq "c4/$k-returns-none" "returned:(none)" "$(kv "$out" "$k")"
    done
    if grep -Eq 'artifact_dir|plansDir' "$WORKER_LOG_JS"; then
        fail "c4/module-never-picks-a-destination" "worker-log.js references artifact_dir/plansDir"
    else
        pass "c4/module-never-picks-a-destination"
    fi
}

# Run at source time so the case markers sit at column 0, depth 0 (retire parser).
case_begin "c2-registry-log-dir-scope" "hooks/lib/worker-dispatch-registry.js"
group_registry
case_end

case_begin "c3-fsguard-log-dir-containment" "bin/worker-dispatch/fsguard.js"
group_fsguard
case_end

case_begin "c4-worker-log-module" "bin/worker-dispatch/worker-log.js"
group_worker_log
case_end
