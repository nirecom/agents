#!/usr/bin/env bash
# tests/hooks/feature-2513-plan-sync-trigger-matcher.sh
# Tests: hooks/show-plan-link.js, settings.json
# Tags: plan-sync, show-plan-link, settings, matcher, hook-registration, static, TL1, scope:issue-specific, edit-write-tools, command-tools, sync-budget, unit, timeout-contract, additional-context
# #2513: the PostToolUse registration of show-plan-link.js must fire for every
# edit-write and command tool (hooks/lib/write-tools.js), or a plan revised by
# that tool never reaches the plan remote.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

SETTINGS="$(np "$SCRIPT_CHECKOUT_ROOT/settings.json")"
WRITE_TOOLS="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/write-tools.js")"

# spl_matchers — prints "<count>|<missing names, comma-separated>" for the PostToolUse
# entries whose hooks run show-plan-link.js; exits 1 when settings.json does not parse.
spl_matchers() {
  run_with_timeout 30 node -e '
const fs = require("fs");
const [settingsPath, writeToolsPath] = process.argv.slice(1);
let s;
try { s = JSON.parse(fs.readFileSync(settingsPath, "utf8")); } catch (e) { process.stdout.write("PARSE_ERROR: " + e.message); process.exit(1); }
const wt = require(writeToolsPath);
const entries = ((s.hooks || {}).PostToolUse || []).filter((e) =>
  (e.hooks || []).some((h) => typeof h.command === "string" && /hooks\/show-plan-link\.js/.test(h.command)));
const covered = new Set();
for (const e of entries) for (const m of String(e.matcher || "").split("|")) covered.add(m.trim());
const want = wt.EDIT_WRITE_TOOL_NAMES.concat(wt.COMMAND_TOOL_NAMES);
process.stdout.write(entries.length + "|" + want.filter((n) => !covered.has(n)).join(","));' \
    "$SETTINGS" "$WRITE_TOOLS"
}

case_begin "B0-show-plan-link-registered-posttooluse" "hooks/show-plan-link.js"
if [[ -f "$SCRIPT_CHECKOUT_ROOT/hooks/show-plan-link.js" ]]; then pass "B0 hooks/show-plan-link.js exists"
else fail "B0 hooks/show-plan-link.js exists"; fi
B_OUT="$(spl_matchers)" || B_OUT="ERROR: ${B_OUT:-node failed}"
B_COUNT="${B_OUT%%|*}"
if [[ "$B_COUNT" =~ ^[0-9]+$ && "$B_COUNT" -ge 1 ]]; then pass "B0 show-plan-link.js registered under PostToolUse ($B_COUNT entries)"
else fail "B0 show-plan-link.js registered under PostToolUse" "got=$B_OUT"; fi
case_end

case_begin "B1-matcher-covers-edit-write-and-command-tools" "settings.json"
B_MISSING="${B_OUT#*|}"
if [[ "$B_COUNT" =~ ^[0-9]+$ && -z "$B_MISSING" ]]; then
  pass "B1 show-plan-link PostToolUse matchers cover every EDIT_WRITE_TOOL_NAMES + COMMAND_TOOL_NAMES entry"
else
  fail "B1 show-plan-link PostToolUse matchers cover every EDIT_WRITE_TOOL_NAMES + COMMAND_TOOL_NAMES entry" "missing=$B_MISSING (raw=$B_OUT)"
fi
case_end

# ── C1-C7: one shared sync budget per hook invocation ─────────────────────────
# Seam: breadcrumbsForArtifacts(filePaths, input, { sync, now, budgetMs }) -> the joined
# systemMessage string; sync(absPath, { budgetMs }) is faked here, now() is a fake clock.
# Multi-plan end-to-end wiring (real hook subprocess, 2-plan editFiles) is covered by
# tests/hooks/feature-show-plan-link/plan-sync-breadcrumb.sh A3b/A3c.
SPL_JS="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/show-plan-link.js")"
SPL_TMP="$(make_tmp)"
trap 'rm -rf "$SPL_TMP"' EXIT
harness_isolate "$SPL_TMP/iso"
mkdir -p "$SPL_TMP/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$SPL_TMP/transcripts"
SPL_PLANS="$(np "$SPL_TMP/plans")"

# spl_budget <scenario> — prints "PASS|<name>" / "FAIL|<name>|<detail>" lines.
spl_budget() {
  (cd "$SPL_TMP" && run_with_timeout 30 node -e '
const path = require("path");
const [modPath, sc, dir] = process.argv.slice(1);
const out = [];
const ok = (n, c, d) => out.push(c ? `PASS|${sc} ${n}` : `FAIL|${sc} ${n}|${d}`);
const done = () => { process.stdout.write(out.join("\n") + "\n"); process.exit(0); };
let m;
try { m = require(modPath); } catch (e) { ok("require show-plan-link.js", false, e.message); done(); }
const fn = m.breadcrumbsForArtifacts;
if (typeof fn !== "function") { ok("breadcrumbsForArtifacts is exported", false, `typeof=${typeof fn}`); done(); }
const abs = (p) => { const r = path.resolve(p); return process.platform === "win32" ? r.replace(/\//g, "\\") : r; };
const p1 = path.join(dir, "s2513bud-intent.md"), p2 = path.join(dir, "s2513bud-outline.md");
const url = (p) => `Plan file: https://github.com/o/r/blob/main/${path.basename(p)}`;
function rig(advances, throwOn) {
  let t = 1000000, i = 0;
  const calls = [];
  const sync = (a, o) => {
    calls.push({ abs: a, budgetMs: o && o.budgetMs });
    t += advances[i++] || 0;
    if (throwOn === i) throw new Error("boom");
    return { status: "pushed", url: url(a).slice("Plan file: ".length) };
  };
  return { calls, sync, now: () => t };
}
function run(paths, r, budgetMs) {
  const opts = { sync: r.sync, now: r.now };
  if (budgetMs !== undefined) opts.budgetMs = budgetMs;
  let msg;
  try { msg = fn(paths, {}, opts); } catch (e) { ok("does not throw", false, e.message); done(); }
  ok("returns a string", typeof msg === "string", `typeof=${typeof msg}`);
  return String(msg);
}
const budgetLine = (msg) => /^\[plan-sync\][^\n]*budget/im.test(msg);
const count = (msg) => (msg.match(/^Plan file: /gm) || []).length;
const show = (x) => JSON.stringify(x);
let r, msg;
switch (sc) {
  case "C1":
    r = rig([0, 0]); msg = run([p1, p2], r, 20000);
    ok("sync called once per plan", r.calls.length === 2, `calls=${show(r.calls)}`);
    ok("sync receives the absolute plan path", r.calls[0] && r.calls[0].abs === abs(p1), `calls=${show(r.calls)}`);
    ok("both URL breadcrumbs in one message", msg.includes(url(p1)) && msg.includes(url(p2)) && count(msg) === 2, show(msg));
    break;
  case "C2":
    r = rig([12000, 0]); msg = run([p1, p2], r, 20000);
    ok("sync called for both plans", r.calls.length === 2, `calls=${show(r.calls)}`);
    ok("first sync budgetMs in (0, 20000]", r.calls[0] && r.calls[0].budgetMs > 0 && r.calls[0].budgetMs <= 20000, `calls=${show(r.calls)}`);
    ok("second sync budgetMs is the remainder in (0, 8000]", r.calls[1] && r.calls[1].budgetMs > 0 && r.calls[1].budgetMs <= 8000, `calls=${show(r.calls)}`);
    break;
  case "C3":
    r = rig([25000]); msg = run([p1, p2], r, 20000);
    ok("exhausted plan is not synced", r.calls.length === 1, `calls=${show(r.calls)}`);
    ok("synced plan keeps its URL breadcrumb", msg.includes(url(p1)), show(msg));
    ok("exhausted plan gets a local-path breadcrumb", msg.includes(`Plan file: ${abs(p2)}`) && !msg.includes(url(p2)), show(msg));
    ok("exhausted plan gets a [plan-sync] budget status line", budgetLine(msg), show(msg));
    break;
  case "C4a":
    r = rig([20000]); msg = run([p1, p2], r, 20000);
    ok("remaining exactly 0 -> second not synced", r.calls.length === 1, `calls=${show(r.calls)}`);
    ok("remaining exactly 0 -> [plan-sync] budget line + local path", budgetLine(msg) && msg.includes(`Plan file: ${abs(p2)}`), show(msg));
    break;
  case "C4b":
    r = rig([19999]); msg = run([p1, p2], r, 20000);
    ok("remaining 1 ms -> second synced with budgetMs 1", r.calls.length === 2 && r.calls[1].budgetMs === 1, `calls=${show(r.calls)}`);
    ok("remaining 1 ms -> no budget status line", !budgetLine(msg), show(msg));
    break;
  case "C5":
    r = rig([5000, 0], 1); msg = run([p1, p2], r, 20000);
    ok("throwing sync -> failed breadcrumb for first plan", msg.includes(`Plan file: ${abs(p1)}`) && /^\[plan-sync\] internal-error/m.test(msg), show(msg));
    ok("second plan still synced with the remainder in (0, 15000]", r.calls.length === 2 && r.calls[1].budgetMs > 0 && r.calls[1].budgetMs <= 15000, `calls=${show(r.calls)}`);
    ok("second plan keeps its URL breadcrumb", msg.includes(url(p2)), show(msg));
    break;
  case "C6":
    r = rig([0]); msg = run([p1], r);
    ok("default budget is 20000 ms", m.SHARED_SYNC_BUDGET_MS === 20000, `SHARED_SYNC_BUDGET_MS=${m.SHARED_SYNC_BUDGET_MS}`);
    ok("single plan gets the full default budget", r.calls.length === 1 && r.calls[0].budgetMs === 20000, `calls=${show(r.calls)}`);
    ok("single plan URL breadcrumb", msg === url(p1), show(msg));
    break;
  case "C6e":
    r = rig([]); msg = run([], r, 20000);
    ok("no plans -> no sync, empty message", r.calls.length === 0 && msg === "", `calls=${show(r.calls)} msg=${show(msg)}`);
    break;
}
done();' "$SPL_JS" "$1" "$SPL_PLANS") || printf 'FAIL|%s node harness|exit=%s\n' "$1" "$?"
}

# spl_report <output of spl_budget> — maps PASS|/FAIL| lines onto the harness.
spl_report() {
  local line name rest
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="${line#*|}"; name="${rest%%|*}"
    case "$line" in
      PASS\|*) pass "$name" ;;
      FAIL\|*) fail "$name" "${rest#*|}" ;;
      *) fail "unparsed harness line" "$line" ;;
    esac
  done <<< "$1"
}

for SPL_SC in C1 C2 C3 C4a C4b C5 C6 C6e; do
  case_begin "${SPL_SC}-shared-sync-budget" "hooks/show-plan-link.js"
  SPL_OUT="$(spl_budget "$SPL_SC")"
  if [[ -z "$SPL_OUT" ]]; then fail "$SPL_SC produced no assertions"; else spl_report "$SPL_OUT"; fi
  case_end
done

case_begin "C7-shared-budget-below-hook-timeout" "hooks/show-plan-link.js"
SPL_C7="$(cd "$SPL_TMP" && run_with_timeout 30 node -e '
const fs = require("fs");
const [settingsPath, modPath] = process.argv.slice(1);
const s = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
const budget = require(modPath).SHARED_SYNC_BUDGET_MS;
if (typeof budget !== "number" || !(budget > 0)) { process.stdout.write(`NO_CONSTANT:${budget}`); process.exit(0); }
const hooks = [];
for (const e of ((s.hooks || {}).PostToolUse || []))
  for (const h of (e.hooks || [])) if (typeof h.command === "string" && /hooks\/show-plan-link\.js/.test(h.command)) hooks.push(h);
const bad = hooks.filter((h) => !(typeof h.timeout === "number" && budget < h.timeout * 1000));
process.stdout.write(hooks.length === 0 ? "NO_HOOKS" : bad.length === 0 ? `OK:${hooks.length}` : `BAD:${JSON.stringify(bad)}`);' "$SETTINGS" "$SPL_JS")" || SPL_C7="ERROR: node failed"
if [[ "$SPL_C7" == OK:* ]]; then pass "C7 SHARED_SYNC_BUDGET_MS < every show-plan-link PostToolUse timeout ($SPL_C7)"
else fail "C7 SHARED_SYNC_BUDGET_MS < every show-plan-link PostToolUse timeout" "got=$SPL_C7"; fi
case_end

# ── D2: real hook output shape for one multi-plan call (sync off) ─────────
# D2: no URL -> the reason rides PostToolUse additionalContext next to the plan's local path
# AND a systemMessage stays; markTurn still runs for every plan (order unchanged).
case_begin "D2-multi-plan-sync-off-context-and-message" "hooks/show-plan-link.js"
SPL_D_PLANS="$(np "$SPL_TMP/iso/plans")"
mkdir -p "$SPL_D_PLANS" "$SPL_TMP/d-cfg"
printf 'i\n' > "$SPL_D_PLANS/s2513d-intent.md"; printf 'o\n' > "$SPL_D_PLANS/s2513d-outline.md"
SPL_D_JSON="$(run_with_timeout 30 node -e '
const [d] = process.argv.slice(1);
process.stdout.write(JSON.stringify({ tool_name: "editFiles", session_id: "test-sid-d2", tool_response: { success: true },
  tool_input: { edits: [{ path: d + "/s2513d-intent.md" }, { path: d + "/s2513d-outline.md" }] } }));' "$SPL_D_PLANS")"
SPL_D_OUT="$(cd "$SPL_TMP" && printf '%s' "$SPL_D_JSON" \
  | WORKFLOW_PLANS_DIR="$SPL_D_PLANS" AGENTS_MAIN_ROOT="$(np "$SPL_TMP/d-cfg")" PLAN_SYNC_REMOTE_URL="" run_with_timeout 60 node "$SPL_JS" 2>/dev/null)" || true
SPL_D_RES="$(printf '%s' "$SPL_D_OUT" | run_with_timeout 30 node -e '
let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (e) { process.stdout.write("NOT_JSON"); process.exit(0); }
const h = d.hookSpecificOutput || {}; const ctx = String(h.additionalContext || "");
const dir = process.argv[1]; const bs = dir.replace(/\//g, "\\");
const shown = ["s2513d-intent.md", "s2513d-outline.md"].every((n) =>
  ctx.split("\n").some((l) => [dir, bs].some((p) => l.includes(p)) && l.includes(n)));
process.stdout.write([h.hookEventName || "-", ctx.includes("plan-sync-off") ? "reason" : "no-reason",
  shown ? "paths" : "no-paths", d.systemMessage ? "msg" : "no-msg"].join("|"));' "$SPL_D_PLANS")" || SPL_D_RES="ERROR"
if [[ "$SPL_D_RES" == "PostToolUse|reason|paths|msg" ]]; then
  pass "D2 sync off -> PostToolUse additionalContext names plan-sync-off with each plan's local path, systemMessage kept"
else fail "D2 sync off -> PostToolUse additionalContext names plan-sync-off with each plan's local path, systemMessage kept" "got=$SPL_D_RES out=$SPL_D_OUT"; fi
SPL_D_MARKS=("$WORKFLOW_STATE_DIR"/test-sid-d2.confirm-plan-turn-*.json)
if [[ -f "${SPL_D_MARKS[0]}" ]]; then pass "D2 turn marker still written for the plans"
else fail "D2 turn marker still written for the plans" "no test-sid-d2.confirm-plan-turn-*.json"; fi
case_end

# ── E1-E2: the project-host record is written before sync; sync-off lines carry the path ──
# Seam: breadcrumbsForArtifacts(paths, input, { sync }) runs the hook's record -> marker -> sync
# order with a fake sync; the fake notes whether the record file exists when sync starts, and
# readProjectHostState (hooks/lib/plan-sync.js) then reads its verdict against a github.com remote.
SPL_E_PLANS="$(np "$SPL_TMP/e-plans")"
SPL_E_PROJ="$(np "$SPL_TMP/e-project")"
mkdir -p "$SPL_E_PLANS" "$SPL_E_PROJ" "$SPL_TMP/e-cfg"
git init -q "$SPL_E_PROJ"
git -C "$SPL_E_PROJ" config core.hooksPath /dev/null
git -C "$SPL_E_PROJ" remote add origin "git@github.com:test-owner/test-project.git"
SPL_PS_LIB="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync.js")"

# spl_record_order — prints "PASS|<name>" / "FAIL|<name>|<detail>" lines.
spl_record_order() {
  (cd "$SPL_TMP" && WORKFLOW_PLANS_DIR="$SPL_E_PLANS" AGENTS_MAIN_ROOT="$(np "$SPL_TMP/e-cfg")" PLAN_SYNC_REMOTE_URL="" GITLAB_HOSTNAME="" GITLAB_SSH_HOSTNAME="" \
    env -u CLAUDE_PROJECT_DIR bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 node -e '
const fs = require("fs"); const path = require("path");
const [modPath, psPath, dir, proj] = process.argv.slice(1);
const out = [];
const ok = (n, c, d) => out.push(c ? "PASS|E1 " + n : "FAIL|E1 " + n + "|" + d);
const show = (x) => JSON.stringify(x);
const m = require(modPath);
let ps = null; try { ps = require(psPath); } catch (e) { ps = null; }
const DEST = "ssh://git@github.com/test-owner/test-repo.git";
const rec = (name) => path.join(dir, name.replace(/-(intent|outline|detail)\.md$/, "-note-project-host-$1.json"));
const isFile = (f) => { try { return fs.statSync(f).isFile(); } catch (e) { return false; } };
const state = (p) => (ps && typeof ps.readProjectHostState === "function")
  ? Promise.resolve(ps.readProjectHostState(p, DEST)).then(String, (e) => "threw:" + e.message)
  : Promise.resolve("NOT_IMPLEMENTED: readProjectHostState");
const run = (name, input, block) => {
  const p = path.join(dir, name); fs.writeFileSync(p, "body\n");
  const seen = [];
  if (block) fs.mkdirSync(path.join(rec(name), "keep"), { recursive: true });
  let msg;
  try { msg = m.breadcrumbsForArtifacts([p], input, { sync: () => { seen.push(isFile(rec(name))); return { status: "off" }; } }); }
  catch (e) { msg = "threw:" + e.message; }
  return Promise.resolve(msg).then((v) => state(p).then((st) => ({ seen, msg: String(v), st })));
};
(async () => {
  let r = await run("s2513e1a-intent.md", { session_id: "s2513e1a", cwd: proj });
  ok("cwd in a github.com project: the record exists when sync starts", r.seen.length === 1 && r.seen[0] === true, show(r));
  ok("cwd in a github.com project: the record matches a github.com destination", r.st === "match", show(r));
  r = await run("s2513e1b-intent.md", { session_id: "s2513e1b" });
  ok("no cwd in the input: a record exists when sync starts", r.seen.length === 1 && r.seen[0] === true, show(r));
  ok("no cwd in the input: the record reads as no-project-host", r.st === "no-project-host", show(r));
  r = await run("s2513e1c-intent.md", { session_id: "s2513e1c", cwd: proj }, true);
  ok("record write fails: sync is not called", r.seen.length === 0, show(r));
  ok("record write fails: breadcrumb reports internal-error with the local path",
    /^Plan file: .*s2513e1c-intent\.md$/m.test(r.msg) && /^\[plan-sync\] internal-error/m.test(r.msg), show(r.msg));
  process.stdout.write(out.join("\n") + "\n");
})();' "$SPL_JS" "$SPL_PS_LIB" "$SPL_E_PLANS" "$SPL_E_PROJ") || printf 'FAIL|E1 node harness|exit=%s\n' "$?"
}

case_begin "E1-record-written-before-sync" "hooks/show-plan-link.js"
SPL_OUT="$(spl_record_order)"
if [[ -z "$SPL_OUT" ]]; then fail "E1 produced no assertions"; else spl_report "$SPL_OUT"; fi
case_end

case_begin "E2-multi-plan-sync-off-lines-carry-local-path" "hooks/show-plan-link.js"
printf 'i\n' > "$SPL_E_PLANS/s2513e2-intent.md"; printf 'o\n' > "$SPL_E_PLANS/s2513e2-outline.md"
SPL_E_JSON="$(run_with_timeout 30 node -e '
const [d, cwd] = process.argv.slice(1);
process.stdout.write(JSON.stringify({ tool_name: "editFiles", session_id: "s2513e2", cwd, tool_response: { success: true },
  tool_input: { edits: [{ path: d + "/s2513e2-intent.md" }, { path: d + "/s2513e2-outline.md" }] } }));' "$SPL_E_PLANS" "$SPL_E_PROJ")"
SPL_E_OUT="$(cd "$SPL_TMP" && printf '%s' "$SPL_E_JSON" \
  | WORKFLOW_PLANS_DIR="$SPL_E_PLANS" AGENTS_MAIN_ROOT="$(np "$SPL_TMP/e-cfg")" PLAN_SYNC_REMOTE_URL="" GITLAB_HOSTNAME="" GITLAB_SSH_HOSTNAME="" \
    env -u CLAUDE_PROJECT_DIR bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 node "$SPL_JS" 2>/dev/null)" || SPL_E_OUT="HOOK_EXIT_$?"
SPL_E_RES="$(printf '%s' "$SPL_E_OUT" | run_with_timeout 30 node -e '
let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (e) { process.stdout.write("NOT_JSON"); process.exit(0); }
const h = d.hookSpecificOutput || {}; const ctx = String(h.additionalContext || "");
const dir = process.argv[1]; const bs = dir.replace(/\//g, "\\");
const lines = ctx.split(/\r?\n/).filter((l) => l.includes("plan-sync-off"));
const withPath = lines.filter((l) => ["intent", "outline"].some((st) => [dir, bs].some((f) => l.includes(f) && l.includes("s2513e2-" + st + ".md"))));
process.stdout.write([h.hookEventName || "-", "reason-lines=" + lines.length, "with-path=" + withPath.length,
  /never show a local/i.test(ctx) ? "forbids-path" : "path-allowed", d.systemMessage ? "msg" : "no-msg"].join("|"));' "$SPL_E_PLANS")" || SPL_E_RES="ERROR"
if [[ "$SPL_E_RES" == "PostToolUse|reason-lines=2|with-path=2|path-allowed|msg" ]]; then
  pass "E2 sync off, two plans -> each plan-sync-off line carries its local path, systemMessage kept"
else fail "E2 sync off, two plans -> each plan-sync-off line carries its local path, systemMessage kept" "got=$SPL_E_RES out=$SPL_E_OUT"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
