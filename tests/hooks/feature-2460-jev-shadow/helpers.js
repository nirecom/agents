#!/usr/bin/env node
"use strict";
// Node helpers for the feature-2460-jev-shadow fragments (#2460). Test-only.
// Subcommands (see the dispatch below): payload, seed-step, bind-worktree, state-bind, q, qa, broken, json-expr,
// json-get, json-set, age, now, mock-count <log> <systemone|models>, mock-q. `payload` reads the LLM text from $LLM_TEXT so
// shell quoting never touches it; `q` binds r = the single record for a tool_use_id.

const fs = require("fs");
const path = require("path");

const REPO = path.resolve(__dirname, "..", "..", "..");
const MOCK_ROUTES = { systemone: "/v1/systemone", models: "/v1/models" };
const [cmd, ...args] = process.argv.slice(2);

function readLines(p) {
  try { return fs.readFileSync(p, "utf8").split("\n").filter((l) => l.trim()); } catch (_e) { return []; }
}
function allRecords(log) {
  const recs = [];
  for (const f of [log + ".3", log + ".2", log + ".1", log]) {
    for (const l of readLines(f)) { try { recs.push(JSON.parse(l)); } catch (_e) { /* counted by broken */ } }
  }
  return recs;
}
function flag(name, dflt) {
  const i = args.indexOf(name);
  return i === -1 ? dflt : args[i + 1];
}
function evalExpr(expr, scope) {
  const names = Object.keys(scope);
  // eslint-disable-next-line no-new-func
  const fn = new Function(...names, "return (" + expr + ");");
  return fn(...names.map((n) => scope[n]));
}
function print(v) {
  process.stdout.write((typeof v === "string" ? v : JSON.stringify(v)) + "\n");
}
function ageTree(p, ms, recursive) {
  const t = (Date.now() - ms) / 1000;
  const st = fs.statSync(p);
  if (recursive && st.isDirectory()) {
    for (const e of fs.readdirSync(p)) ageTree(path.join(p, e), ms, true);
  }
  fs.utimesSync(p, t, t);
}

// payload <out> <pre|post> <sid> <tid> [--tool --subagent --agent-id --prompt --model --response --cwd]
function buildPayload() {
  const [out, kind, sid, tid] = args;
  const text = process.env.LLM_TEXT === undefined ? "SIGNALS: S1-multi-file" : process.env.LLM_TEXT;
  const toolInput = {
    subagent_type: flag("--subagent", "complexity-judge"),
    description: "judge complexity",
    prompt: flag("--prompt", "Judge the task complexity for this session."),
  };
  const model = flag("--model", undefined);
  if (model !== undefined) toolInput.model = model;
  const p = {
    session_id: sid,
    transcript_path: path.join(path.dirname(out), "transcript.jsonl"),
    cwd: flag("--cwd", process.cwd()),
    hook_event_name: kind === "pre" ? "PreToolUse" : "PostToolUse",
    tool_name: flag("--tool", "Agent"),
    tool_use_id: tid,
    tool_input: toolInput,
  };
  const agentId = flag("--agent-id", undefined);
  if (agentId !== undefined) p.agent_id = agentId;
  if (kind === "post") {
    const shape = flag("--response", "content");
    if (shape === "content") p.tool_response = { content: [{ type: "text", text }] };
    else if (shape === "string") p.tool_response = text;
    else if (shape === "output") p.tool_output = text;
    else if (shape === "output_text") p.tool_output_text = text;
  }
  fs.writeFileSync(out, JSON.stringify(p));
}

// seed-step <sid> <step>: mark every VALID_STEPS entry before <step> complete.
function seedStep() {
  const [sid, target] = args;
  const io = require(path.join(REPO, "hooks", "workflow-state", "state-io.js"));
  const { resolveCurrentEffectiveStep } = require(path.join(REPO, "hooks", "workflow-state", "current-step.js"));
  for (const s of io.VALID_STEPS) {
    if (s === target) break;
    io.markStep(sid, s, "complete");
  }
  print(String(resolveCurrentEffectiveStep(sid)));
}

// bind-worktree <sid> <path> [session_worktree|entered|cwd|entered-null-cwd|entered-missing-cwd|entered-fallback]:
// point an existing workflow state at <path> through top-level session_worktree (default), a worktree
// "entered" event (projected as state.cwd), or session_start_context.cwd only (projected as state.cwd but
// never a binding, #2460 C12). The entered-* modes set the start-context cwd to <path> and then append an
// entered event whose cwd is null, absent (hand-edited), or <path> with path_source fallback-process-cwd;
// none of them binds. Prints the field as readState(sid) projects it.
function enteredEvent(dir, source) {
  return { kind: "worktree", transition: "entered", git_branch: "feature/jev2460-helper", cwd: dir,
    worktree_path: dir, path_source: source, provenance: "observed", origin: "jev2460-test-helper" };
}
function bindWorktree() {
  const [sid, dir, via] = args;
  const io = require(path.join(REPO, "hooks", "workflow-state", "state-io.js"));
  if (!io.readState(sid)) throw new Error("bind-worktree: no workflow state for " + sid);
  if (via === "entered") {
    io.appendEvents(sid, [enteredEvent(dir, "tool_input")]);
    print(String(io.readState(sid).cwd));
  } else if (via === "entered-null-cwd" || via === "entered-missing-cwd" || via === "entered-fallback") {
    io.updateTopLevel(sid, (record) => {
      record.session_start_context = Object.assign({}, record.session_start_context, { cwd: dir });
    });
    if (via === "entered-fallback") io.appendEvents(sid, [enteredEvent(dir, "fallback-process-cwd")]);
    else io.appendEvents(sid, [enteredEvent(null, "migration-unknown")]);
    if (via === "entered-missing-cwd") {
      const f = io.getStatePath(sid);
      const raw = JSON.parse(fs.readFileSync(f, "utf8"));
      const entered = raw.events.filter((e) => e && e.kind === "worktree" && e.transition === "entered");
      delete entered[entered.length - 1].cwd;
      fs.writeFileSync(f, JSON.stringify(raw));
    }
    const s = io.readState(sid);
    print(String(s.cwd) + "|" + String(s.worktree_entered_at !== null));
  } else if (via === "cwd") {
    io.updateTopLevel(sid, (record) => {
      record.session_start_context = Object.assign({}, record.session_start_context, { cwd: dir });
    });
    print(String(io.readState(sid).cwd));
  } else {
    io.recordSessionWorktree(sid, dir);
    print(String(io.readState(sid).session_worktree));
  }
}

try {
  if (cmd === "payload") buildPayload();
  else if (cmd === "seed-step") seedStep();
  else if (cmd === "bind-worktree") bindWorktree();
  else if (cmd === "state-bind") {
    // state-bind <sid>: "<state.cwd>|<state.session_worktree>" as readState projects them ("none" without a state),
    // separators shown as "/" so the value compares with np (cygpath -m) output.
    const s = require(path.join(REPO, "hooks", "workflow-state", "state-io.js")).readState(args[0]);
    const fwd = (v) => String(v).replace(/\\/g, "/");
    print(s ? fwd(s.cwd) + "|" + fwd(s.session_worktree) : "none");
  }
  else if (cmd === "q") {
    const [log, tid, expr] = args;
    const recs = allRecords(log).filter((r) => r && r.tool_use_id === tid);
    print(String(evalExpr(expr, { recs, r: recs.length === 1 ? recs[0] : undefined })));
  } else if (cmd === "qa") {
    print(String(evalExpr(args[1], { recs: allRecords(args[0]) })));
  } else if (cmd === "broken") {
    let n = 0;
    for (const f of [args[0], args[0] + ".1", args[0] + ".2", args[0] + ".3"]) {
      for (const l of readLines(f)) { try { JSON.parse(l); } catch (_e) { n++; } }
    }
    print(String(n));
  } else if (cmd === "json-expr") {
    let o;
    try { o = JSON.parse(fs.readFileSync(args[0], "utf8")); } catch (_e) { o = undefined; }
    print(String(evalExpr(args[1], { o, now: Date.now() })));
  } else if (cmd === "json-get") {
    const o = JSON.parse(fs.readFileSync(args[0], "utf8"));
    print(JSON.stringify(o[args[1]]));
  } else if (cmd === "json-set") {
    const o = JSON.parse(fs.readFileSync(args[0], "utf8"));
    o[args[1]] = JSON.parse(args[2]);
    fs.writeFileSync(args[0], JSON.stringify(o));
  } else if (cmd === "age") {
    ageTree(args[0], Number(args[1]), args[2] === "--recursive");
  } else if (cmd === "now") {
    print(String(Date.now()));
  } else if (cmd === "mock-count") {
    // Slash-less route tokens: Git Bash (MSYS) rewrites a "/v1/..." argument into a Windows path.
    if (!Object.prototype.hasOwnProperty.call(MOCK_ROUTES, args[1])) {
      throw new Error("mock-count: unknown route token " + args[1] + " (use " + Object.keys(MOCK_ROUTES).join("|") + ")");
    }
    const reqs = readLines(args[0]).map((l) => JSON.parse(l));
    print(String(reqs.filter((r) => r.path === MOCK_ROUTES[args[1]]).length));
  } else if (cmd === "mock-q") {
    const reqs = readLines(args[0]).map((l) => JSON.parse(l));
    print(String(evalExpr(args[1], { reqs })));
  } else {
    process.stderr.write("helpers.js: unknown command " + cmd + "\n");
    process.exit(2);
  }
} catch (e) {
  print("HELPER-ERROR:" + e.message);
}
