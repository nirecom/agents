"use strict";
// Reads of the Projects v2 `pm` text field (#2942), one batched GitHub GraphQL call per 50 issues.
//   readPmFields(refs, {timeoutMs?, deadlineAt?}) -> {ok:true, values: {"<repo as given>#N": tag|null}} | {ok:false, reason}
//   readPmChains(refs, opts) -> {ok:true, results: {[refKey]: {ok:true, chain:[{repo, number, pm}]} | {ok:false, reason}}}
//     chain[0] is the issue itself, then its ancestors nearest first (the owner lookup and the writer's checks).
//   readCards(refs, opts) -> {ok:true, results: {[refKey]: {ok:true, itemId, projectId, fieldId} | {ok:false, reason}}}
// A forge failure is {ok:false}; it never reads as "unset". A card page with more cards than one read
// holds is {ok:false, reason:"pm-field-truncated"} (a hidden card could name another PM).

const { batchedGraphql, refKey, MAX_ANCESTOR_DEPTH } = require("../forge-issue-links");

const PM_FIELD_NAME = require("../tracker-fields/expected").PM.name;
// itemsOf(pageSize) -> the one projectItems selection (cards, their pm value, the board's pm field) every reader uses.
const itemsOf = (pageSize) => `projectItems(first:${pageSize}){nodes{id pm: fieldValueByName(name:"${PM_FIELD_NAME}"){... on ProjectV2ItemFieldTextValue{text}} project{id field(name:"${PM_FIELD_NAME}"){... on ProjectV2FieldCommon{id}}}} pageInfo{hasNextPage}}`;
const ITEMS = itemsOf(20);

// pmFieldAbsentError(e) -> true for GitHub's answer to field(name:"pm") on a board without that field (#3135):
// NOT_FOUND at <...>.projectItems.nodes[i].project.field. Readers pass it as batchedGraphql's tolerate.
const FIELD_TAIL = ["projectItems", "nodes", null, "project", "field"];
function pmFieldAbsentError(e) {
  if (!e || e.type !== "NOT_FOUND" || !Array.isArray(e.path) || e.path.length < FIELD_TAIL.length) return false;
  const tail = e.path.slice(-FIELD_TAIL.length);
  return FIELD_TAIL.every((k, i) => (k === null ? Number.isInteger(tail[i]) : tail[i] === k));
}

// A card page cut off by `first:` may hide a card that names another PM.
const truncated = (node) => Boolean(node && node.projectItems && node.projectItems.pageInfo && node.projectItems.pageInfo.hasNextPage === true);
const TRUNCATED = Object.freeze({ ok: false, reason: "pm-field-truncated" });

const itemNodes = (node) => (node && node.projectItems && Array.isArray(node.projectItems.nodes) ? node.projectItems.nodes.filter(Boolean) : []);
const textOf = (v) => (v && typeof v.text === "string" && v.text !== "" ? v.text : null);

// pmReadOf(node) -> {ok:true, pm: tag|null, fieldAbsent?:true} | {ok:false, reason:"pm-field-truncated"|"pm-field-ambiguous"}:
// the issue's pm value over all its cards; cards of several Projects that name different PMs cannot be told apart
// (the target Project is not identified), so that is a failed read, never a pick of the first. fieldAbsent marks an
// issue whose every card sits on a board without the pm field (#3135): its null is not a trusted "unset".
function pmReadOf(node) {
  if (truncated(node)) return { ...TRUNCATED };
  const vals = [];
  const cards = itemNodes(node);
  for (const i of cards) {
    const t = textOf(i.pm || i.fieldValueByName);
    if (t !== null && !vals.some((v) => v.toLowerCase() === t.toLowerCase())) vals.push(t);
  }
  if (vals.length > 1) return { ok: false, reason: "pm-field-ambiguous" };
  if (vals.length === 1) return { ok: true, pm: vals[0] };
  const absent = cards.length > 0 && cards.every((i) => i.project && !i.project.field);
  return absent ? { ok: true, pm: null, fieldAbsent: true } : { ok: true, pm: null };
}

// cardOf(node) -> {ok, itemId, projectId, fieldId}: the one card on a board with a PM field; no such card is
// {ok:false, reason:"no-card"} (the writer then ensures one), several are {ok:false, reason:"pm-field-ambiguous"}
// (a write would pick a Project blindly).
function cardOf(node) {
  if (truncated(node)) return { ...TRUNCATED };
  const boards = itemNodes(node).filter((i) => i.project && i.project.field && i.project.field.id);
  if (boards.length > 1) return { ok: false, reason: "pm-field-ambiguous" };
  const it = boards[0];
  if (!it || typeof it.id !== "string") return { ok: false, reason: "no-card" };
  const project = it.project || {};
  return { ok: true, itemId: it.id, projectId: project.id || null, fieldId: project.field && project.field.id ? project.field.id : null };
}

function chainFields(depth) {
  const own = `number repository{nameWithOwner} ${ITEMS}`;
  return depth < MAX_ANCESTOR_DEPTH ? `${own} parent{${chainFields(depth + 1)}}` : `${own} parent{number}`;
}

function chainOf(node, key) {
  const chain = [];
  const seen = new Set();
  let cur = node;
  let repo = key.split("#")[0];
  for (let depth = 0; cur; depth++) {
    if (!Number.isInteger(cur.number)) return { ok: false, reason: "parse_failed" };
    if (depth > MAX_ANCESTOR_DEPTH) return { ok: false, reason: "depth-cap" };
    if (cur.repository && typeof cur.repository.nameWithOwner === "string") repo = cur.repository.nameWithOwner;
    else if (depth > 0) return { ok: false, reason: "parse_failed" };
    const k = refKey(repo, cur.number);
    if (seen.has(k)) return { ok: false, reason: "cycle" };
    seen.add(k);
    const p = pmReadOf(cur);
    if (!p.ok) return p;
    chain.push(p.fieldAbsent ? { repo, number: cur.number, pm: p.pm, fieldAbsent: true } : { repo, number: cur.number, pm: p.pm });
    cur = cur.parent;
  }
  return { ok: true, chain };
}

// The values of readPmFields are keyed by the repo as the caller gave it (the writer compares by it).
const givenKey = (repo, n) => `${repo}#${n}`;

// readPmFields adds fieldAbsent: {key: true} only when some issue carries the mark.
function readPmFields(refs, opts) {
  const r = batchedGraphql(refs, { fields: `number ${ITEMS}`, readNode: pmReadOf, keyOf: givenKey, tolerate: pmFieldAbsentError }, opts);
  if (!r.ok) return r;
  const values = {};
  const fieldAbsent = {};
  for (const [key, v] of Object.entries(r.results)) {
    if (!v.ok) return { ok: false, reason: v.reason };
    values[key] = v.pm;
    if (v.fieldAbsent) fieldAbsent[key] = true;
  }
  return Object.keys(fieldAbsent).length > 0 ? { ok: true, values, fieldAbsent } : { ok: true, values };
}

// readPmChains and readCards key their results by refKey (lower-case repo). A card only on a board without the
// pm field is no-card for readCards (cardOf keeps boards with the field).
const readPmChains = (refs, opts) => batchedGraphql(refs, { fields: chainFields(0), readNode: chainOf, tolerate: pmFieldAbsentError }, opts);
const readCards = (refs, opts) => batchedGraphql(refs, { fields: `number ${ITEMS}`, readNode: (node) => cardOf(node), tolerate: pmFieldAbsentError }, opts);

module.exports = { readPmFields, readPmChains, readCards, pmReadOf, pmFieldAbsentError, itemsOf, PM_FIELD_NAME, ITEMS };
