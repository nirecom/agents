#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/state-ancestry.js
// Tags: TL2, workflow-state, progress-file, session-inherit, regression-2748, scope:issue-specific, pwsh-not-required
// #2748: resolveFirstSid(sid, state?) answers the first generation of a session chain from the state
// alone — first_session_id, then previous_session_ids[0], then a non-self sidecar pin — and walks
// upstream_session_id only for a legacy state. stateAncestors(state) is the I/O-free ancestor list.
// Legacy states are written raw (upstream_session_id only), never with a hand-made inherited_from.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("fs");
const path = require("path");

const restore = isolate();
process.on("exit", () => restore());

const F = require("./feature-2304-inheritance-state-copy/fixture");
const PF = F.mod("hooks/lib/progress-file");

// Guarded: the module is new in #2748, so each case fails on its own until it exists.
let SA = null;
let loadError = null;
try { SA = F.mod("hooks/workflow-state/state-ancestry"); } catch (e) { loadError = e; }
function sa(name) {
  if (!SA) throw new Error(`state-ancestry.js not loadable: ${loadError && String(loadError.message).split("\n")[0]}`);
  if (typeof SA[name] !== "function") throw new Error(`state-ancestry.js does not export ${name}`);
  return SA[name];
}
const first = (sid, st) => (st === undefined ? sa("resolveFirstSid")(sid) : sa("resolveFirstSid")(sid, st));

// check(name, fn) — one node:test test; fn fails it by throwing or by returning a message string.
function check(name, fn) {
  test(name, () => {
    const why = fn();
    if (typeof why === "string") assert.fail(why);
  });
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  assert.strictEqual(JSON.stringify(got), JSON.stringify(want), `${what || "value"}: want=${show(want)} got=${show(got)}`);
}

// state(sid, top) — a raw v5 state with the given top-level session chain keys and nothing else of note.
function state(sid, top) {
  const st = Object.assign(F.S().createInitialState(sid, F.UP_CTX), top || {});
  F.writeRaw(sid, st);
  return st;
}
const pin = (sid, rootSid) => {
  if (!PF.mergePressure(sid, { root_sid: rootSid })) throw new Error(`could not pin ${sid}`);
};

caseBegin("resolve-first-sid-priority", "hooks/workflow-state/state-ancestry.js");
{
  check("A1: first_session_id wins over a non-self pin and previous_session_ids", () => {
    state("a1f-me", { first_session_id: "a1f-field", previous_session_ids: ["a1f-prev"], upstream_session_id: "a1f-prev" });
    pin("a1f-me", "a1f-pin");
    eq(first("a1f-me"), "a1f-field", "resolveFirstSid");
  });
  check("A1: previous_session_ids[0] wins over a disagreeing non-self sidecar pin", () => {
    state("a1s-me", { previous_session_ids: ["a1s-prev"], upstream_session_id: "a1s-prev" });
    pin("a1s-me", "a1s-pin");
    eq(first("a1s-me"), "a1s-prev", "resolveFirstSid");
  });
  check("A1: a non-self pin wins on a legacy upstream-only state (no previous_session_ids)", () => {
    state("a1u-me", { upstream_session_id: "a1u-up" });
    pin("a1u-me", "a1u-pin");
    eq(first("a1u-me"), "a1u-pin", "resolveFirstSid");
  });
  check("A1: a non-self pin wins on a state with no ancestors", () => {
    state("a1z-me");
    pin("a1z-me", "a1z-pin");
    eq(first("a1z-me"), "a1z-pin", "resolveFirstSid");
  });
  check("A1: previous_session_ids[0] is the answer when nothing earlier decides", () => {
    state("a1p-me", { previous_session_ids: ["a1p-oldest", "a1p-mid"], upstream_session_id: "a1p-mid" });
    eq(first("a1p-me"), "a1p-oldest", "resolveFirstSid");
  });
  check("A1: a first generation with no sidecar resolves to itself", () => {
    state("a1o-me");
    eq(first("a1o-me"), "a1o-me", "resolveFirstSid");
  });
  check("A1: a sid with no state resolves to itself", () => eq(first("a1n-nostate"), "a1n-nostate", "resolveFirstSid"));
  check("A1: an invalid sid is returned unchanged and nothing throws", () => eq(first("../a1-bad"), "../a1-bad", "resolveFirstSid"));
  check("A1: an invalid first_session_id is ignored", () => {
    state("a1i-me", { first_session_id: "../a1i-bad", previous_session_ids: ["a1i-prev"], upstream_session_id: "a1i-prev" });
    eq(first("a1i-me"), "a1i-prev", "resolveFirstSid");
  });
  check("A1: an explicit state argument is used instead of the file", () => {
    const st = { previous_session_ids: ["a1x-given"], upstream_session_id: "a1x-given" };
    eq(first("a1x-nostate", st), "a1x-given", "resolveFirstSid(sid, state)");
  });
}
caseEnd();

caseBegin("resolve-first-sid-self-pinned-sidecar-with-ancestors", "hooks/workflow-state/state-ancestry.js");
{
  check("A2: a self-pinned sidecar with ancestors is ignored -> previous_session_ids[0]", () => {
    state("a2-me", { previous_session_ids: ["a2-root", "a2-mid"], upstream_session_id: "a2-mid" });
    pin("a2-me", "a2-me");
    eq(first("a2-me"), "a2-root", "resolveFirstSid");
  });
  check("A3: a self pin on a first generation is not a trace -> the own sid", () => {
    state("a3-me");
    pin("a3-me", "a3-me");
    eq(first("a3-me"), "a3-me", "resolveFirstSid");
  });
}
caseEnd();

caseBegin("resolve-first-sid-legacy-walk", "hooks/workflow-state/state-ancestry.js");
{
  check("A4: legacy A <- B <- C resolves C to A, not to its direct upstream B", () => {
    state("a4-a");
    state("a4-b", { upstream_session_id: "a4-a" });
    state("a4-c", { upstream_session_id: "a4-b" });
    eq(first("a4-c"), "a4-a", "resolveFirstSid(C)");
  });
  check("A4: legacy A <- B <- C <- D resolves D to A", () => {
    state("a4d-a");
    state("a4d-b", { upstream_session_id: "a4d-a" });
    state("a4d-c", { upstream_session_id: "a4d-b" });
    state("a4d-d", { upstream_session_id: "a4d-c" });
    eq(first("a4d-d"), "a4d-a", "resolveFirstSid(D)");
  });
  check("A4b: a legacy C over a new-format B takes B's previous_session_ids[0]", () => {
    state("a4b-a1");
    state("a4b-b", { previous_session_ids: ["a4b-a0", "a4b-a1"], upstream_session_id: "a4b-a1" });
    state("a4b-c", { upstream_session_id: "a4b-b" });
    eq(first("a4b-c"), "a4b-a0", "resolveFirstSid(C)");
  });
  check("A4b: a new-format hop whose previous_session_ids has no valid element stops at that hop", () => {
    state("a4e-b", { previous_session_ids: ["../x", 7] });
    state("a4e-c", { upstream_session_id: "a4e-b" });
    eq(first("a4e-c"), "a4e-b", "resolveFirstSid(C)");
  });
  check("A4b: a hop carrying first_session_id answers the walk", () => {
    state("a4f-b", { first_session_id: "a4f-root", upstream_session_id: "a4f-x" });
    state("a4f-c", { upstream_session_id: "a4f-b" });
    eq(first("a4f-c"), "a4f-root", "resolveFirstSid(C)");
  });
  check("A4b: a hop pinned to another sid answers the walk", () => {
    state("a4g-b");
    pin("a4g-b", "a4g-root");
    state("a4g-c", { upstream_session_id: "a4g-b" });
    eq(first("a4g-c"), "a4g-root", "resolveFirstSid(C)");
  });
  check("A4c: C <- B with no state for B resolves C to B", () => {
    state("a4c-c", { upstream_session_id: "a4c-b" });
    eq(first("a4c-c"), "a4c-b", "resolveFirstSid(C)");
  });
}
caseEnd();

caseBegin("resolve-first-sid-legacy-walk-cap", "hooks/workflow-state/state-ancestry.js");
{
  check("A5: a 200-hop legacy chain stops after about 64 state reads", () => {
    const sid = (i) => `a5-g${String(i).padStart(3, "0")}`;
    state(sid(0));
    for (let i = 1; i < 200; i++) state(sid(i), { upstream_session_id: sid(i - 1) });
    const dir = path.resolve(process.env.WORKFLOW_STATE_DIR).toLowerCase();
    const reads = new Set();
    const orig = fs.readFileSync;
    fs.readFileSync = function (p, ...rest) {
      if (typeof p === "string" && p.endsWith(".json") && path.resolve(path.dirname(p)).toLowerCase() === dir) reads.add(path.basename(p));
      return orig.call(fs, p, ...rest);
    };
    let got;
    try { got = first(sid(199)); } finally { fs.readFileSync = orig; }
    eq(typeof got === "string" && /^a5-g\d{3}$/.test(got), true, "a chain member is returned: " + show(got));
    eq(got === sid(0), false, "the 200-hop walk was capped, yet it reached the root");
    eq(reads.size >= 60 && reads.size <= 70, true, `distinct state files read=${reads.size}`);
  });
}
caseEnd();

caseBegin("resolve-first-sid-legacy-cycle", "hooks/workflow-state/state-ancestry.js");
{
  check("A6: a 2-member legacy cycle resolves to its smallest sid from either member", () => {
    state("a6-y", { upstream_session_id: "a6-x" });
    state("a6-x", { upstream_session_id: "a6-y" });
    eq([first("a6-x"), first("a6-y")], ["a6-x", "a6-x"], "resolveFirstSid of each member");
  });
  check("A6: a 3-member legacy cycle resolves to its smallest sid from every member", () => {
    state("a6c-m", { upstream_session_id: "a6c-k" });
    state("a6c-k", { upstream_session_id: "a6c-z" });
    state("a6c-z", { upstream_session_id: "a6c-m" });
    eq([first("a6c-m"), first("a6c-k"), first("a6c-z")], ["a6c-k", "a6c-k", "a6c-k"], "resolveFirstSid of each member");
  });
  check("A6: a tail into a cycle resolves to the cycle's smallest sid", () => {
    state("a6t-tail", { upstream_session_id: "a6c-z" });
    eq(first("a6t-tail"), "a6c-k", "resolveFirstSid(tail)");
  });
  check("A6: a cycle past MAX_LEGACY_WALK (64) hops is never reached; the walk stops on the chain", () => {
    const sid = (i) => `a6w-g${String(i).padStart(3, "0")}`;
    state("a6w-cyc-b", { upstream_session_id: "a6w-cyc-a" });
    state("a6w-cyc-a", { upstream_session_id: "a6w-cyc-b" });
    state(sid(0), { upstream_session_id: "a6w-cyc-b" });
    for (let i = 1; i < 100; i++) state(sid(i), { upstream_session_id: sid(i - 1) });
    const got = first(sid(99));
    eq(typeof got === "string" && /^a6w-g\d{3}$/.test(got) && got !== sid(0), true, "a capped chain member is returned: " + show(got));
  });
}
caseEnd();

caseBegin("state-ancestors-and-dedup", "hooks/workflow-state/state-ancestry.js");
{
  const anc = (st) => sa("stateAncestors")(st);
  check("A1: stateAncestors returns the valid previous_session_ids, oldest first", () => {
    eq(anc({ previous_session_ids: ["sa-a", "../x", 7, "a.b", "sa-b"], upstream_session_id: "sa-b" }), ["sa-a", "sa-b"], "ancestors");
  });
  check("A1: stateAncestors falls back to a valid upstream_session_id", () => {
    eq(anc({ upstream_session_id: "sa-up" }), ["sa-up"], "ancestors");
    eq(anc({ previous_session_ids: "not-an-array", upstream_session_id: "sa-up" }), ["sa-up"], "non-array chain");
  });
  check("A1: stateAncestors is empty for a first generation, an invalid upstream, or no state", () => {
    eq(anc({}), [], "no session chain keys");
    eq(anc({ upstream_session_id: "../sa-escape" }), [], "invalid upstream");
    eq(anc(null), [], "null state");
  });
  check("A1: an empty previous_session_ids array is authoritative (no upstream fallback)", () => {
    eq(anc({ previous_session_ids: [], upstream_session_id: "sa-up" }), [], "ancestors");
  });
  check("A1: dedupKeepFirst keeps the first occurrence of each element", () => {
    eq(sa("dedupKeepFirst")(["d-a", "d-b", "d-a", "d-c", "d-b"]), ["d-a", "d-b", "d-c"], "dedupKeepFirst");
  });
}
caseEnd();
