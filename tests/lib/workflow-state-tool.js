"use strict";
// tests/lib/workflow-state-tool.js
// Fixture tool for the #2544 tests: seeds and reads a session's workflow
// state and control dir, and builds hook input. argv: <agents-dir> <mode> <args...>.
// Prints its answer on stdout; any failure prints one ERR:<reason> line, never a stack.
const [agents, mode, ...a] = process.argv.slice(2);
const out = (s) => process.stdout.write(String(s));
const show = (v) => (v === undefined || v === null ? "(absent)" : typeof v === "string" ? v : JSON.stringify(v));

try {
  const wf = require(agents + "/hooks/workflow-state");
  const state = (sid) => wf.readState(sid) || {};
  if (mode === "seed") {
    // seed <sid> <events-json>
    const { appendEvents } = require(agents + "/hooks/workflow-state/state-io/events");
    appendEvents(a[0], JSON.parse(a[1]).map((e) =>
      Object.assign({ provenance: "observed", origin: "run-tests-hook" }, e)));
  } else if (mode === "field") {
    // field <sid> <step> <field>
    const e = (state(a[0]).steps || {})[a[1]];
    out(show(e ? e[a[2]] : undefined));
  } else if (mode === "path") {
    // path <sid> <step> <field> <dotted.path> — a value inside an object annotation
    let v = ((state(a[0]).steps || {})[a[1]] || {})[a[2]];
    for (const k of a[3].split(".")) v = v === undefined || v === null ? undefined : v[k];
    out(show(v));
  } else if (mode === "count") {
    out((state(a[0]).events || []).length);
  } else if (mode === "eff") {
    // eff <sid> <step> <repo-dir>
    const eff = wf.reconcileEffectiveState(wf.readState(a[0]), a[0], { repoDir: a[2], resolveAll: true });
    out(show(eff.steps[a[1]] && eff.steps[a[1]].status));
  } else if (mode === "hookjson") {
    // hookjson <sid> <command> <cwd> [<tool-name>] [<agent-id>]
    const tool = a[3] || "Bash";
    const input = tool === "runCommands" ? { commands: [a[1]], cwd: a[2] } : { command: a[1], cwd: a[2] };
    const o = { tool_name: tool, session_id: a[0], tool_input: input, tool_response: { exit_code: 0, stdout: "" } };
    if (a[4]) o.agent_id = a[4];
    out(JSON.stringify(o));
  } else if (mode === "ctl") {
    // ctl <sid> <name> <content> — write one control-dir file
    const { controlPath } = require(agents + "/hooks/workflow-state/state-io/control-dir");
    require("fs").writeFileSync(controlPath(a[0], a[1], { forWrite: true }), a[2] || "");
    out("ok");
  } else if (mode === "ctlhas") {
    // ctlhas <sid> <name> → yes | no
    const { getSessionControlDir } = require(agents + "/hooks/workflow-state/state-io/control-dir");
    out(require("fs").existsSync(require("path").join(getSessionControlDir(a[0]), a[1])) ? "yes" : "no");
  } else if (mode === "ctlrm") {
    const { getSessionControlDir } = require(agents + "/hooks/workflow-state/state-io/control-dir");
    require("fs").unlinkSync(require("path").join(getSessionControlDir(a[0]), a[1]));
    out("ok");
  } else if (mode === "sha") {
    // sha <sid> <name> → sha256 hex of a control-dir file
    const { getSessionControlDir } = require(agents + "/hooks/workflow-state/state-io/control-dir");
    const bytes = require("fs").readFileSync(require("path").join(getSessionControlDir(a[0]), a[1]));
    out(require("crypto").createHash("sha256").update(bytes).digest("hex"));
  } else {
    out("ERR:unknown-mode " + mode);
  }
} catch (e) {
  out("ERR:" + String((e && e.message) || e).split("\n")[0]);
}
