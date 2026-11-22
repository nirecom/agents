"use strict";
// Reads of the Projects v2 `pm` text field (#2942), one batched GitHub GraphQL call per 50 issues.
//   readPmFields(refs, {timeoutMs?, deadlineAt?}) -> {ok:true, values: {"<repo as given>#N": tag|null}} | {ok:false, reason}
//   readPmChains(refs, opts) -> {ok:true, results: {[refKey]: {ok:true, chain:[{repo, number, pm}]} | {ok:false, reason}}}
//     chain[0] is the issue itself, then its ancestors nearest first (the owner lookup and the writer's checks).
//   readCards(refs, opts) -> {ok:true, results: {[refKey]: {ok:true, itemId, projectId, fieldId} | {ok:false, reason}}}
// A forge failure is {ok:false}; it never reads as "unset".

const { batchedGraphql, refKey, MAX_ANCESTOR_DEPTH } = require("../forge-issue-links");

const PM_FIELD_NAME = "pm";
const ITEMS = `projectItems(first:20){nodes{id pm: fieldValueByName(name:"${PM_FIELD_NAME}"){... on ProjectV2ItemFieldTextValue{text}} project{id field(name:"${PM_FIELD_NAME}"){... on ProjectV2FieldCommon{id}}}}}`;

const itemNodes = (node) => (node && node.projectItems && Array.isArray(node.projectItems.nodes) ? node.projectItems.nodes.filter(Boolean) : []);
const textOf = (v) => (v && typeof v.text === "string" && v.text !== "" ? v.text : null);

// pmReadOf(node) -> {ok:true, pm: tag|null} | {ok:false, reason:"pm-field-ambiguous"}: the issue's pm value over
// all its cards; cards of several Projects that name different PMs cannot be told apart (the target Project is
// not identified), so that is a failed read, never a pick of the first.
function pmReadOf(node) {
  const vals = [];
  for (const i of itemNodes(node)) {
    const t = textOf(i.pm || i.fieldValueByName);
    if (t !== null && !vals.some((v) => v.toLowerCase() === t.toLowerCase())) vals.push(t);
  }
  return vals.length > 1 ? { ok: false, reason: "pm-field-ambiguous" } : { ok: true, pm: vals.length === 1 ? vals[0] : null };
}

const pmOf = (node) => { const r = pmReadOf(node); return r.ok ? r.pm : null; };

// cardOf(node) -> {ok, itemId, projectId, fieldId}: the one card on a board with a pm field, else the first card;
// several boards with a pm field are {ok:false, reason:"pm-field-ambiguous"} (a write would pick a Project blindly).
function cardOf(node) {
  const items = itemNodes(node);
  const boards = items.filter((i) => i.project && i.project.field && i.project.field.id);
  if (boards.length > 1) return { ok: false, reason: "pm-field-ambiguous" };
  const it = boards[0] || items[0];
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
    chain.push({ repo, number: cur.number, pm: p.pm });
    cur = cur.parent;
  }
  return { ok: true, chain };
}

// The values of readPmFields are keyed by the repo as the caller gave it (the writer compares by it).
const givenKey = (repo, n) => `${repo}#${n}`;

function readPmFields(refs, opts) {
  const r = batchedGraphql(refs, { fields: `number ${ITEMS}`, readNode: pmReadOf, keyOf: givenKey }, opts);
  if (!r.ok) return r;
  const values = {};
  for (const [key, v] of Object.entries(r.results)) {
    if (!v.ok) return { ok: false, reason: v.reason };
    values[key] = v.pm;
  }
  return { ok: true, values };
}

// readPmChains and readCards key their results by refKey (lower-case repo).
const readPmChains = (refs, opts) => batchedGraphql(refs, { fields: chainFields(0), readNode: chainOf }, opts);
const readCards = (refs, opts) => batchedGraphql(refs, { fields: `number ${ITEMS}`, readNode: (node) => cardOf(node) }, opts);

module.exports = { readPmFields, readPmChains, readCards, pmOf, pmReadOf, PM_FIELD_NAME, ITEMS };
