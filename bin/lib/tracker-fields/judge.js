"use strict";
// The tracker board's forge judge (#3135): compares a board with EXPECTED_FIELDS.
//   judge({fields, holders, values}) -> {needed, missing:[name], diagnostics:[{kind, message, count?}]}
//     fields: {ok:true, nodes:[{name, dataType, options?}]} | {ok:false, reason}; holders: holders.js holdersOf;
//     values: readPmFields' answer for the held issues ({ok, values} | {ok:false, reason}).
//   Only a missing field is NEEDED (the board preparation creates it). type-mismatch, option-missing,
//   unbackfilled, backfill-conflict and undecidable (a forge failure) are diagnostics, never NEEDED.
//   judgeRepo(repo, {entries?, homeRepo?, timeoutMs?}) -> judge's answer for the repo's board, read from the forge.

const { spawnSync } = require("child_process");
const path = require("path");
const S = require(path.join(__dirname, "..", "..", "..", "hooks", "pm-session", "schema"));
const { buildGhSpawn } = require("../../workflow/lib/workflow-init/spawn-env");
const { EXPECTED_FIELDS, PM } = require("./expected");
const { holdersOf, refsOf } = require("./holders");
const { readPmFields } = require("../pm-field/read");

const FIX = "run /migrate-tracker in this repo to backfill it";
const optName = (o) => (typeof o === "string" ? o : o && o.name);

function fieldDiagnostics(nodes) {
  const missing = [];
  const diagnostics = [];
  for (const want of EXPECTED_FIELDS) {
    const got = nodes.find((f) => f && f.name === want.name);
    if (!got) { missing.push(want.name); continue; }
    if (got.dataType && got.dataType !== want.dataType) {
      diagnostics.push({ kind: "type-mismatch", field: want.name, message: `the board field '${want.name}' is ${got.dataType}, expected ${want.dataType}` });
      continue;
    }
    const have = (Array.isArray(got.options) ? got.options : []).map(optName);
    const lack = (want.options || []).filter((o) => !have.includes(o));
    if (lack.length > 0) diagnostics.push({ kind: "option-missing", field: want.name, message: `the board field '${want.name}' lacks the option(s) ${lack.join(", ")}` });
  }
  return { missing, diagnostics };
}

function valueDiagnostics(holders, values) {
  const keys = Object.keys(holders || {});
  if (keys.length === 0) return [];
  if (!values || !values.ok) return [{ kind: "undecidable", message: `the pm field values could not be read (${(values && values.reason) || "unknown"})` }];
  const out = [];
  let unbackfilled = 0;
  for (const key of keys) {
    const hs = holders[key];
    const v = values.values ? values.values[key] : null;
    if (v === null || v === undefined || v === "") {
      if (hs.length > 1) out.push({ kind: "backfill-conflict", issue: key, message: `${key}: the pm field is empty and local PMs ${hs.join(", ")} all hold it` });
      else unbackfilled++;
    } else if (!hs.some((t) => S.sameTag(t, v))) {
      out.push({ kind: "backfill-conflict", issue: key, message: `${key}: the pm field names ${v} but local PM ${hs.join(", ")} holds it` });
    }
  }
  if (unbackfilled > 0) out.unshift({ kind: "unbackfilled", count: unbackfilled, message: `${unbackfilled} issue(s) held by a local PM have an empty pm field; ${FIX}` });
  return out;
}

function judge(input) {
  const o = input || {};
  const f = o.fields;
  if (!f || !f.ok || !Array.isArray(f.nodes)) {
    return { needed: false, missing: [], diagnostics: [{ kind: "undecidable", message: `the board fields could not be read (${(f && f.reason) || "unknown"})` }] };
  }
  const { missing, diagnostics } = fieldDiagnostics(f.nodes);
  if (!missing.includes(PM.name)) diagnostics.push(...valueDiagnostics(o.holders, o.values));
  return { needed: missing.length > 0, missing, diagnostics };
}

const FIELDS_QUERY = "query($projectId: ID!, $after: String) { node(id: $projectId) { ... on ProjectV2 { fields(first: 50, after: $after) { nodes { __typename ... on ProjectV2FieldCommon { id name dataType } ... on ProjectV2SingleSelectField { options { id name } } } pageInfo { hasNextPage endCursor } } } } }";

// gh(args, timeoutMs) -> the parsed JSON stdout, or {error}.
function gh(args, timeoutMs) {
  const [cmd, argv, opts] = buildGhSpawn(args);
  const r = spawnSync(cmd, argv, Object.assign({}, opts, { timeout: timeoutMs, killSignal: "SIGKILL" }));
  if (r.error || r.status !== 0) return { error: r.error ? r.error.message : `gh ${args[0]} exited ${r.status}` };
  try { return JSON.parse(r.stdout); } catch { return { error: `gh ${args[0]}: unparsable output` }; }
}

// boardFields(repo, timeoutMs) -> {ok:true, nodes} | {ok:false, reason}. The board is the one the board
// preparation (ensure-project-ready.sh) reuses: the owner's project titled "<repo> — Issue Timeline".
function boardFields(repo, timeoutMs) {
  const list = gh(["project", "list", "--owner", repo.split("/")[0], "--format", "json"], timeoutMs);
  if (list.error) return { ok: false, reason: list.error };
  const title = `${repo} — Issue Timeline`;
  const board = (Array.isArray(list.projects) ? list.projects : []).find((p) => p && p.title === title);
  if (!board || !board.id) return { ok: false, reason: `no board titled '${title}'` };
  const nodes = [];
  let after = null;
  for (let page = 0; page < 20; page++) {
    const args = ["api", "graphql", "-F", `projectId=${board.id}`, "-f", `query=${FIELDS_QUERY}`];
    if (after) args.push("-f", `after=${after}`);
    const r = gh(args, timeoutMs);
    const f = r && r.data && r.data.node && r.data.node.fields;
    if (r.error || !f || !Array.isArray(f.nodes)) return { ok: false, reason: r.error || "field list unreadable" };
    nodes.push(...f.nodes);
    if (!f.pageInfo || !f.pageInfo.hasNextPage || !f.pageInfo.endCursor) break;
    after = f.pageInfo.endCursor;
  }
  return { ok: true, nodes };
}

function judgeRepo(repo, opts) {
  const o = opts || {};
  const timeoutMs = Number.isFinite(o.timeoutMs) ? o.timeoutMs : 15000;
  const fields = boardFields(repo, timeoutMs);
  const holders = holdersOf(repo, { entries: o.entries, homeRepo: o.homeRepo });
  const refs = refsOf(holders, repo);
  const hasPm = fields.ok && fields.nodes.some((f) => f && f.name === PM.name);
  const values = hasPm && refs.length > 0 ? readPmFields(refs, { timeoutMs }) : { ok: true, values: {} };
  return judge({ fields, holders, values });
}

module.exports = { judge, judgeRepo, boardFields };
