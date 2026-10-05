#!/usr/bin/env node
"use strict";
// recordShadow's return value: `record` prints "record" for a plain-object return (else its
// typeof); `record-ret` prints the returned record as JSON, "null", or "TYPE:<typeof>".
// Library probe for f-breaker.sh and k-fallbacks.sh (#2460): drives breaker.tryAcquire with an
// injected clock, races it across processes, and runs queryShadow (one or a sequence) with the normalizer stubbed.
// Usage: node hardening-probe.js <repo> <cmd> [args...]; prints one line.
// Required as a module (the broker suite's probe), it only exports stubNormalizer.
const fs = require("fs");
const path = require("path");
const Module = require("module");

const [repo, cmd, ...args] = process.argv.slice(2);
const lib = (p) => require(path.join(repo, p));
const out = (s) => process.stdout.write(String(s));
const clock = (ms) => ({ now: () => Number(ms) });

// stubNormalizer(repoDir, mode): call before the broker loads. Replaces normalize() of the
// registered normalizer module: real | throw | nonstring (42) | null | undefined | object;
// missing makes loading that module throw MODULE_NOT_FOUND. Returns { calls } (normalize or load attempts).
function stubNormalizer(repoDir, mode) {
  const file = require(path.join(repoDir, "hooks/lib/jev/registry.js")).registryEntry("complexity-judge").normalizer;
  const counter = { calls: 0 };
  if (mode === "missing") {
    const realLoad = Module._load;
    Module._load = function (request, parent, isMain) {
      let resolved = null;
      try { resolved = Module._resolveFilename(request, parent, isMain); } catch (_e) { resolved = null; }
      if (resolved === path.resolve(file)) {
        counter.calls++;
        throw Object.assign(new Error("Cannot find module '" + request + "'"), { code: "MODULE_NOT_FOUND" });
      }
      return realLoad.apply(this, arguments);
    };
    return counter;
  }
  const mod = require(file);
  const real = mod.normalize;
  const returns = { nonstring: 42, null: null, undefined: undefined, object: { csv: "S1-multi-file" } };
  mod.normalize = function (raw) {
    counter.calls++;
    if (mode === "throw") throw new Error("normalizer stub");
    if (Object.prototype.hasOwnProperty.call(returns, mode)) return returns[mode];
    return real(raw);
  };
  return counter;
}

function stateOf(breaker, sid) {
  try { return fs.readFileSync(breaker.breakerPath(sid), "utf8"); } catch (_e) { return "absent"; }
}

async function main() {
  if (cmd === "acquire") {
    // acquire <sid> <nowMs>: tryAcquire's verdict, then breaker.json as it is afterwards.
    const breaker = lib("hooks/lib/jev/breaker.js");
    out(breaker.tryAcquire(args[0], clock(args[1])) + "|" + stateOf(breaker, args[0]));
  } else if (cmd === "acquire-lockfail") {
    // The lock helper throws: tryAcquire must fall back to !isOpen instead of throwing.
    const log = lib("hooks/lib/jsonl-rotating-log.js");
    log.withLock = () => { throw new Error("lock unavailable"); };
    const breaker = lib("hooks/lib/jev/breaker.js");
    out(breaker.tryAcquire(args[0], clock(args[1])) + "|" + stateOf(breaker, args[0]));
  } else if (cmd === "fail") {
    const breaker = lib("hooks/lib/jev/breaker.js");
    breaker.recordFailure(args[0], args[1], clock(args[2]));
    out(stateOf(breaker, args[0]));
  } else if (cmd === "succeed") {
    // succeed <sid> [admittedAtMs]: without admittedAtMs, the no-opts call (unconditional reset).
    const breaker = lib("hooks/lib/jev/breaker.js");
    if (args[1] === undefined) breaker.recordSuccess(args[0]);
    else breaker.recordSuccess(args[0], { admittedAtMs: Number(args[1]) });
    out(stateOf(breaker, args[0]));
  } else if (cmd === "consts") {
    const breaker = lib("hooks/lib/jev/breaker.js");
    out([breaker.FAILURE_THRESHOLD, breaker.OPEN_MS, breaker.TRIAL_MS].join("|"));
  } else if (cmd === "race") {
    // race <sid> <startAtMs>: load first, then spin to a shared start so the calls overlap.
    const breaker = lib("hooks/lib/jev/breaker.js");
    const at = Number(args[1]);
    while (Date.now() < at) { /* barrier */ }
    out(breaker.tryAcquire(args[0]));
  } else if (cmd === "query-parser-fail") {
    // The normalizer throws, so normalizeViaParser returns null.
    const overrides = lib("hooks/lib/jev/test-overrides.js").captureTestOverrides(process.env);
    const stub = stubNormalizer(repo, "throw");
    const broker = lib("hooks/lib/jev/broker.js");
    const r = await broker.queryShadow({ point: "complexity-judge", sessionId: args[0], toolUseId: args[1],
      toolInput: { subagent_type: "complexity-judge", prompt: "probe" }, step: "outline", overrides });
    out(r === null ? "null" : [r.jev.status, r.jev.answer, JSON.stringify(r.jev.latency_ms),
      r.jev.probabilities !== null && typeof r.jev.probabilities === "object", stub.calls].join("|"));
  } else if (cmd === "query-bq-fail") {
    // The adapter's buildQuestions throws, so runJev returns before any probe or query POST.
    const overrides = lib("hooks/lib/jev/test-overrides.js").captureTestOverrides(process.env);
    lib("bin/workflow/lib/jev-complexity-adapter.js").buildQuestions = () => { throw new Error("probe"); };
    const broker = lib("hooks/lib/jev/broker.js");
    const r = await broker.queryShadow({ point: "complexity-judge", sessionId: args[0], toolUseId: args[1],
      toolInput: { subagent_type: "complexity-judge", prompt: "probe" }, step: "outline", overrides });
    out(r === null ? "null" : [r.jev.status, r.jev.answer, JSON.stringify(r.jev.latency_ms)].join("|"));
  } else if (cmd === "query-normalizer") {
    // query-normalizer <sid> <tid> <stubNormalizer mode>: one queryShadow with that normalizer. Prints
    // "<status>|<answer>|<latency is number>|<normalizer calls>".
    const overrides = lib("hooks/lib/jev/test-overrides.js").captureTestOverrides(process.env);
    const stub = stubNormalizer(repo, args[2]);
    const broker = lib("hooks/lib/jev/broker.js");
    const r = await broker.queryShadow({ point: "complexity-judge", sessionId: args[0], toolUseId: args[1],
      toolInput: { subagent_type: "complexity-judge", prompt: "probe" }, step: "outline", overrides });
    out(r === null ? "null" : [r.jev.status, r.jev.answer, typeof r.jev.latency_ms === "number", stub.calls].join("|"));
  } else if (cmd === "query-seq") {
    // query-seq <sid> <n> <parser-fail|real>: n queryShadow calls (parser-fail: the normalizer throws); prints
    // "<jev statuses>|<consecutive_failures>|<last_failure_status>|<open now>".
    const overrides = lib("hooks/lib/jev/test-overrides.js").captureTestOverrides(process.env);
    if (args[2] === "parser-fail") stubNormalizer(repo, "throw");
    const broker = lib("hooks/lib/jev/broker.js");
    const breaker = lib("hooks/lib/jev/breaker.js");
    const statuses = [];
    for (let i = 0; i < Number(args[1]); i++) {
      const r = await broker.queryShadow({ point: "complexity-judge", sessionId: args[0], toolUseId: "toolu_q_" + i,
        toolInput: { subagent_type: "complexity-judge", prompt: "probe" }, step: "outline", overrides });
      statuses.push(r === null ? "null" : r.jev.status);
    }
    const s = breaker.readBreaker(args[0]);
    out([statuses.join(","), s.consecutive_failures, s.last_failure_status, breaker.isOpen(args[0])].join("|"));
  } else if (cmd === "record") {
    const broker = lib("hooks/lib/jev/broker.js");
    const r = broker.recordShadow({ point: "complexity-judge", sessionId: args[0], toolUseId: args[1],
      llmText: "SIGNALS: S1-multi-file", toolInput: { subagent_type: "complexity-judge" }, step: "outline" });
    out(r === null ? "null" : typeof r === "object" && !Array.isArray(r) ? "record" : typeof r);
  } else if (cmd === "record-ret") {
    // record-ret <sid> <tid> [point-json]: recordShadow's return value as JSON ("null" for null,
    // "TYPE:<typeof>" for anything that is not a plain object).
    const broker = lib("hooks/lib/jev/broker.js");
    const point = args[2] === undefined ? "complexity-judge" : args[2] === "undefined" ? undefined : JSON.parse(args[2]);
    const r = broker.recordShadow({ point, sessionId: args[0], toolUseId: args[1],
      llmText: "SIGNALS: S1-multi-file", toolInput: { subagent_type: "complexity-judge" }, step: "outline" });
    out(r === null ? "null" : typeof r === "object" && !Array.isArray(r) ? JSON.stringify(r) : "TYPE:" + typeof r);
  } else {
    out("UNKNOWN-CMD:" + cmd);
  }
}
if (require.main === module) main().catch((e) => out("THROW:" + (e && e.message)));

module.exports = { stubNormalizer };
