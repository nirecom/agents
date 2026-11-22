"use strict";
// Writes of the Projects v2 `pm` text field (#2942).
//   writePmField(ref, value|null, {timeoutMs, resolveCard}) -> {result: "ok"|"failed"|"unknown", reason?}
// resolveCard(ref) -> {ok, itemId, projectId?, fieldId?}; a card that cannot be resolved is "failed" with no
// edit. A gh edit that outlives timeoutMs is killed and reads "unknown": it may or may not have landed,
// so the caller settles it with a re-read. null clears the field (--clear).
//   createPmField({deadlineAt, repoOfCwd?}) -> {prepare(refs), write(ref, value), read(refs)}: the writer's
//     default field I/O; prepare resolves every card in one read and adds a missing card with
//     ensure-board-card.sh (bounded) before one re-read.

const path = require("path");
const { spawnSync } = require("child_process");
const { buildGhSpawn, buildBashScriptSpawn } = require("../../workflow/lib/workflow-init/spawn-env");
const { refKey } = require("../forge-issue-links");
const R = require("./read");

const DEFAULT_TIMEOUT_MS = 5000;
// One gh edit's share of the writer's 5 s write budget; the rest is the re-read of an unknown write.
const WRITE_TIMEOUT_MS = 3500;
const ENSURE_CARD = path.join(__dirname, "..", "..", "github-issues", "ensure-board-card.sh");

function writePmField(ref, value, opts) {
  const o = opts || {};
  const timeoutMs = Number.isFinite(o.timeoutMs) ? o.timeoutMs : DEFAULT_TIMEOUT_MS;
  if (timeoutMs <= 0) return { result: "failed", reason: "timeout before the write" };
  let card;
  try { card = typeof o.resolveCard === "function" ? o.resolveCard(ref) : null; } catch (e) { card = { ok: false, reason: e.message }; }
  if (!card || !card.ok || typeof card.itemId !== "string") return { result: "failed", reason: (card && card.reason) || "no-card" };
  const args = ["project", "item-edit", "--id", card.itemId];
  if (card.projectId) args.push("--project-id", card.projectId);
  if (card.fieldId) args.push("--field-id", card.fieldId);
  if (value === null || value === undefined) args.push("--clear");
  else args.push("--text", String(value));
  const [cmd, argv, spawnOpts] = buildGhSpawn(args);
  // stdio is ignored: a pipe held open by a grandchild would keep spawnSync waiting past the kill.
  const r = spawnSync(cmd, argv, Object.assign({}, spawnOpts, { stdio: "ignore", timeout: timeoutMs, killSignal: "SIGKILL", windowsHide: true }));
  if (r.error && r.error.code === "ETIMEDOUT") return { result: "unknown", reason: "timeout" };
  if (r.signal) return { result: "unknown", reason: `killed by ${r.signal}` };
  if (r.error) return { result: "failed", reason: r.error.message };
  return r.status === 0 ? { result: "ok" } : { result: "failed", reason: `gh project item-edit exited ${r.status}` };
}

const left = (deadlineAt) => Math.max(0, deadlineAt - Date.now());

// A budgetMs (instead of deadlineAt) starts the deadline at the first prepare/write/read.
function createPmField(opts) {
  const o = opts || {};
  let deadlineAt = Number.isFinite(o.deadlineAt) ? o.deadlineAt : null;
  const start = () => {
    if (deadlineAt === null) deadlineAt = Date.now() + (Number.isFinite(o.budgetMs) ? o.budgetMs : DEFAULT_TIMEOUT_MS);
    return deadlineAt;
  };
  const cards = new Map();
  function prepare(refs) {
    start();
    const r = R.readCards(refs, { deadlineAt });
    if (!r.ok) return r;
    const missing = [];
    for (const ref of refs) {
      const c = r.results[refKey(ref.repo, ref.number)];
      if (c && c.ok) cards.set(refKey(ref.repo, ref.number), c);
      else if (c && c.reason === "no-card") missing.push(ref);
      else if (c && c.reason === "pm-field-ambiguous") cards.set(refKey(ref.repo, ref.number), c);
    }
    if (missing.length === 0) return { ok: true };
    for (const ref of missing) {
      if (left(deadlineAt) <= 0) break;
      const [cmd, argv, spawnOpts] = buildBashScriptSpawn(ENSURE_CARD, ["--repo", ref.repo, String(ref.number)]);
      spawnSync(cmd, argv, Object.assign({}, spawnOpts, { stdio: "ignore", timeout: left(deadlineAt), killSignal: "SIGKILL", windowsHide: true }));
    }
    const again = R.readCards(missing, { deadlineAt });
    if (again.ok) for (const ref of missing) { const c = again.results[refKey(ref.repo, ref.number)]; if (c && c.ok) cards.set(refKey(ref.repo, ref.number), c); }
    return { ok: true };
  }
  const resolveCard = (ref) => cards.get(refKey(ref.repo, ref.number)) || { ok: false, reason: "no-card" };
  return {
    prepare,
    write: (ref, value) => writePmField(ref, value, { timeoutMs: Math.min(WRITE_TIMEOUT_MS, left(start())), resolveCard }),
    read: (refs) => R.readPmFields(refs, { deadlineAt: start() }),
  };
}

module.exports = { writePmField, createPmField };
