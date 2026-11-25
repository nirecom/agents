"use strict";
// Writes of the Projects v2 `pm` text field (#2942, #3152); budget contract: docs/architecture/cross-session-messaging.md.
//   writePmField(ref, value|null, {timeoutMs, resolveCard, spawnSync?}) -> {result: ok|failed|unknown, reason?}; a killed
//   gh edit is unknown (the caller re-reads it); null clears the field.
//   createPmField({budget?|deadlines?|deadlineAt|budgetMs, spawnSync?, minCallMs?, resolveBoard?}) ->
//   {prepare, seedCards, writeMany, write, read, readFieldsAndCards}. prepare reads the unseeded cards, then adds the missing ones inside
//   budget.ensureWindow (no window: budget-exhausted, no spawn) and re-reads once. writeMany([{ref, value}]) ->
//   [{ref, value, result, reason?}] in item order: one aliased mutation per ALIAS_CHUNK items inside the mutate deadline.

const path = require("path");
const childProcess = require("child_process");
const { buildGhSpawn, buildBashScriptSpawn } = require("../../workflow/lib/workflow-init/spawn-env");
const { refKey } = require("../forge-issue-links");
const { classifyGhSpawn, BUDGET_EXHAUSTED, SPAWN_FAILED } = require("../forge-failure");
const R = require("./read");
const RB = require("../project-board/resolve");

const DEFAULT_TIMEOUT_MS = 5000;
// One gh edit's share of the old 5 s write budget; the rest is the re-read of an unknown write.
const WRITE_TIMEOUT_MS = 3500;
const ALIAS_CHUNK = 20;
// readCards reasons that refuse the write with their own reason instead of "no-card".
const FAIL_CLOSED = new Set(["pm-field-ambiguous", "pm-field-truncated"]);
const ENSURE_CARD = path.join(__dirname, "..", "..", "github-issues", "ensure-board-card.sh");

const spawnOf = (o) => (o && typeof o.spawnSync === "function" ? o.spawnSync : childProcess.spawnSync);

function writePmField(ref, value, opts) {
  const o = opts || {};
  const timeoutMs = Number.isFinite(o.timeoutMs) ? o.timeoutMs : DEFAULT_TIMEOUT_MS;
  if (timeoutMs <= 0) return { result: "failed", reason: BUDGET_EXHAUSTED };
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
  const r = spawnOf(o)(cmd, argv, Object.assign({}, spawnOpts, { stdio: "ignore", timeout: timeoutMs, killSignal: "SIGKILL" }));
  const kind = classifyGhSpawn(r);
  if (kind === SPAWN_FAILED) return { result: "failed", reason: SPAWN_FAILED };
  if (kind) return { result: "unknown", reason: kind };
  return r.status === 0 ? { result: "ok" } : { result: "failed", reason: `gh project item-edit exited ${r.status}` };
}

const left = (deadlineAt) => Math.max(0, deadlineAt - Date.now());
const J = (s) => JSON.stringify(String(s));

function aliasOf(it, i) {
  const c = it.card;
  const base = `projectId:${J(c.projectId)},itemId:${J(c.itemId)},fieldId:${J(c.fieldId)}`;
  if (it.value === null || it.value === undefined) return `m${i}: clearProjectV2ItemFieldValue(input:{${base}}){projectV2Item{id}}`;
  return `m${i}: updateProjectV2ItemFieldValue(input:{${base},value:{text:${J(it.value)}}}){projectV2Item{id}}`;
}

// sendChunk(chunk, timeoutMs, spawn) -> [{result, reason?}] per chunk item, from one aliased mutation.
function sendChunk(chunk, timeoutMs, spawn) {
  const query = `mutation { ${chunk.map(aliasOf).join(" ")} }`;
  const [cmd, argv, spawnOpts] = buildGhSpawn(["api", "graphql", "--input", "-"]);
  let r;
  try {
    r = spawn(cmd, argv, Object.assign({}, spawnOpts, { input: JSON.stringify({ query }), encoding: "utf8", timeout: timeoutMs, killSignal: "SIGKILL" }));
  } catch (_) { r = null; }
  const kind = classifyGhSpawn(r);
  if (kind === SPAWN_FAILED) return chunk.map(() => ({ result: "failed", reason: SPAWN_FAILED }));
  if (kind) return chunk.map(() => ({ result: "unknown", reason: kind }));
  let body;
  try { body = JSON.parse(String(r.stdout || "")); } catch (_) { body = null; }
  const data = body && body.data && typeof body.data === "object" ? body.data : null;
  if (!data) return chunk.map(() => ({ result: "unknown", reason: `gh api graphql exited ${r.status}` }));
  const errors = Array.isArray(body.errors) ? body.errors : [];
  return chunk.map((_, i) => {
    const alias = `m${i}`;
    const err = errors.find((e) => e && Array.isArray(e.path) && e.path[0] === alias);
    if (err) return { result: "failed", reason: String(err.type || err.message || "mutation-error") };
    return data[alias] ? { result: "ok" } : { result: "unknown", reason: "no-answer" };
  });
}

// A budgetMs (instead of deadlineAt) starts the deadline at the first call. A limited o.budget (hooks/pm-session/
// budget.js) or fixed o.deadlines {mutate, reread} take precedence for the windows they own.
function createPmField(opts) {
  const o = opts || {};
  const budget = o.budget && o.budget.limited ? o.budget : null;
  const spawn = spawnOf(o);
  const minCallMs = Number.isFinite(o.minCallMs) ? o.minCallMs : 0;
  const readOpts = (deadlineAt) => ({ deadlineAt, spawnSync: spawn, minCallMs });
  let deadlineAt = Number.isFinite(o.deadlineAt) ? o.deadlineAt : null;
  const start = () => {
    if (deadlineAt === null) deadlineAt = Date.now() + (Number.isFinite(o.budgetMs) ? o.budgetMs : DEFAULT_TIMEOUT_MS);
    return deadlineAt;
  };
  const cards = new Map();
  const cardFailure = new Map();
  let lastWindow = null;
  const keep = (key, c) => { if (c && (c.ok || FAIL_CLOSED.has(c.reason))) { cards.set(key, c); return true; } return false; };
  const resolveBoard = (repo, ro) => (typeof o.resolveBoard === "function" ? o.resolveBoard : RB.resolveBoard)(repo, ro);
  const failAll = (list, reason) => { for (const ref of list) cardFailure.set(refKey(ref.repo, ref.number), reason); };
  // addCards(missing, spawnMs) — the spawn timeouts share spawnMs, so their sum never passes the ensure window.
  function addCards(missing, spawnMs) {
    const byRepo = new Map();
    for (const ref of missing) byRepo.set(ref.repo, (byRepo.get(ref.repo) || []).concat([ref]));
    let pool = spawnMs;
    const endAt = Number.isFinite(spawnMs) ? Date.now() + spawnMs : Infinity;
    let count = byRepo.size + missing.length;
    const share = () => {
      const t = Number.isFinite(pool) ? Math.floor(pool / count) : DEFAULT_TIMEOUT_MS;
      pool -= Number.isFinite(pool) ? t : 0;
      count -= 1;
      return t;
    };
    for (const [repo, list] of byRepo) {
      const bt = share();
      if (bt <= 0) { count -= list.length; failAll(list, BUDGET_EXHAUSTED); continue; }
      const board = resolveBoard(repo, { timeoutMs: bt, spawnSync: spawn });
      const status = (board && board.status) || "fetch-failed";
      // A failed lookup may be transient: ensure-board-card then resolves the board itself, per card.
      if (status !== "resolved" && status !== "fetch-failed") { count -= list.length; failAll(list, `board-${status}`); continue; }
      for (const [i, ref] of list.entries()) {
        // The clock caps the pool share: time a slow earlier spawn really used is not spent twice.
        const t = Math.min(share(), endAt - Date.now());
        if (t <= 0) { count -= list.length - i - 1; failAll(list.slice(i), BUDGET_EXHAUSTED); break; }
        const [cmd, argv, spawnOpts] = buildBashScriptSpawn(ENSURE_CARD, ["--repo", ref.repo, String(ref.number)]);
        const env = Object.assign({}, spawnOpts.env || process.env, status === "resolved" ? RB.toInternalEnv(board) : {});
        spawn(cmd, argv, Object.assign({}, spawnOpts, { env, stdio: "ignore", timeout: t, killSignal: "SIGKILL" }));
      }
    }
  }
  function prepare(refs) {
    const checkAt = budget ? budget.checkDeadline() : start();
    const unseeded = refs.filter((ref) => !cards.has(refKey(ref.repo, ref.number)));
    if (unseeded.length === 0) return { ok: true };
    const r = R.readCards(unseeded, readOpts(checkAt));
    if (!r.ok) return r;
    const missing = [];
    for (const ref of unseeded) {
      const key = refKey(ref.repo, ref.number);
      const c = r.results[key];
      // A fail-closed read (ambiguous / truncated) is kept so its reason reaches the refuse message.
      if (!keep(key, c) && c && c.reason === "no-card") missing.push(ref);
    }
    if (missing.length === 0) return { ok: true };
    const win = budget ? budget.ensureWindow() : { spawnMs: left(start()), rereadDeadlineAt: start() };
    if (!win) { failAll(missing, BUDGET_EXHAUSTED); return { ok: true }; }
    addCards(missing, win.spawnMs);
    const again = R.readCards(missing, readOpts(win.rereadDeadlineAt));
    if (again.ok) for (const ref of missing) keep(refKey(ref.repo, ref.number), again.results[refKey(ref.repo, ref.number)]);
    return { ok: true };
  }
  function seedCards(map) {
    for (const [k, c] of Object.entries(map || {})) {
      const at = k.lastIndexOf("#");
      if (at > 0) keep(refKey(k.slice(0, at), Number(k.slice(at + 1))), c);
    }
  }
  const resolveCard = (ref) => cards.get(refKey(ref.repo, ref.number))
    || { ok: false, reason: cardFailure.get(refKey(ref.repo, ref.number)) || "no-card" };
  function windowOf() {
    if (budget) return budget.writeWindow();
    if (o.deadlines && Number.isFinite(o.deadlines.mutate)) return { mutate: o.deadlines.mutate, reread: Number.isFinite(o.deadlines.reread) ? o.deadlines.reread : o.deadlines.mutate };
    const end = start();
    return { mutate: Math.min(Date.now() + WRITE_TIMEOUT_MS, end), reread: end };
  }
  function writeMany(list) {
    const items = Array.isArray(list) ? list : [];
    const out = items.map((it) => ({ ref: it.ref, value: it.value }));
    if (items.length === 0) return out;
    lastWindow = windowOf();
    const send = [];
    items.forEach((it, i) => {
      const c = resolveCard(it.ref);
      if (!c.ok || typeof c.itemId !== "string") Object.assign(out[i], { result: "failed", reason: c.reason || "no-card" });
      else if (!c.projectId || !c.fieldId) Object.assign(out[i], { result: "failed", reason: "no-card" });
      else send.push({ i, card: c, value: it.value });
    });
    let spent = false;
    for (let s = 0; s < send.length; s += ALIAS_CHUNK) {
      const chunk = send.slice(s, s + ALIAS_CHUNK);
      const timeoutMs = Math.floor(lastWindow.mutate - Date.now());
      if (spent || !(timeoutMs > 0) || timeoutMs < minCallMs) {
        spent = true;
        for (const it of chunk) Object.assign(out[it.i], { result: "failed", reason: BUDGET_EXHAUSTED });
        continue;
      }
      sendChunk(chunk, timeoutMs, spawn).forEach((r, j) => Object.assign(out[chunk[j].i], r));
    }
    return out;
  }
  return {
    prepare,
    seedCards,
    writeMany,
    write: (ref, value) => writePmField(ref, value, { timeoutMs: Math.min(WRITE_TIMEOUT_MS, left(start())), resolveCard, spawnSync: spawn }),
    read: (refs) => R.readPmFields(refs, readOpts(lastWindow ? lastWindow.reread : (budget ? budget.writeWindow().reread : start()))),
    readFieldsAndCards: (refs) => {
      const r = R.readPmFieldsAndCards(refs, readOpts(budget ? budget.checkDeadline() : start()));
      if (r && r.ok) seedCards(r.cards);
      return r;
    },
  };
}

module.exports = { writePmField, createPmField, ALIAS_CHUNK };
