#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, broker, shared-lib, scope:issue-specific, pwsh-not-required
# Shared scaffolding for the feature-2460-jev-broker fragments: the shadow suite's fixtures
# and mock Jev, plus the broker probe process (bp) and its listing helpers. Sourced once by
# the dispatcher (idempotent); holds no cases of its own.

if [ -n "${_FEAT2460_JEV_BROKER_LIB_SOURCED:-}" ]; then
  return 0
fi
_FEAT2460_JEV_BROKER_LIB_SOURCED=1

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"
. "$AGENTS_DIR/tests/hooks/feature-2460-jev-shadow/_lib.sh"
mock_start

PROBE="$TMPROOT/broker-probe.js"
cat > "$PROBE" <<'JS'
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const [repo, cmd, ...args] = process.argv.slice(2);
const lib = (p) => require(path.join(repo, p));
const overrides = lib("hooks/lib/jev/test-overrides.js").captureTestOverrides(process.env);
// Records where the parser's raw file sits and what it holds at the moment the parser starts.
const spawns = [];
const realSpawnSync = cp.spawnSync;
// Set by rt-parser-exit: the real parser runs, then its exit status is replaced by this one.
let forcedParserStatus = null;
cp.spawnSync = function (file, argv, opts) {
  const isParser = Array.isArray(argv) && argv.includes("--raw-file");
  if (isParser) {
    const raw = argv[argv.indexOf("--raw-file") + 1];
    let text = null;
    try { text = fs.readFileSync(raw, "utf8"); } catch (_e) { text = null; }
    spawns.push({ dir: path.dirname(raw), text, timeout: opts && opts.timeout });
  }
  const r = realSpawnSync.apply(this, arguments);
  return isParser && forcedParserStatus !== null ? Object.assign({}, r, { status: forcedParserStatus, signal: null }) : r;
};
const broker = lib("hooks/lib/jev/broker.js");
const registry = lib("hooks/lib/jev/registry.js");
const provider = lib("hooks/lib/jev/provider-core.js");
const val = (s) => (s === "undefined" ? undefined : JSON.parse(s));
const out = (s) => process.stdout.write(String(s));
const jevRoot = path.resolve(process.env.AGENTS_STATE_DIR, "jev");
const where = (d) => path.relative(jevRoot, d).split(path.sep).join("/").replace(/norm-[A-Za-z0-9]{6}$/, "norm-XXXXXX");
function normLine(result) {
  const s = spawns.length
    ? [spawns.map((x) => where(x.dir)).join(","), spawns.every((x) => x.timeout === broker.PARSER_TIMEOUT_MS),
      spawns.map((x) => JSON.stringify(x.text)).join(",")]
    : ["no-spawn", "-", "-"];
  return [JSON.stringify(result)].concat(s).join("|");
}
async function main() {
  if (cmd === "entry") {
    const R = registry.REGISTRY;
    out(args.map((a) => {
      const r = registry.registryEntry(val(a));
      return r === null ? "null" : r === R["complexity-judge"] ? "same-ref" : "other:" + typeof r;
    }).join("|"));
  } else if (cmd === "budget") {
    const s = JSON.parse(fs.readFileSync(args[0], "utf8"));
    const find = (ev, name) => (s.hooks[ev] || []).flatMap((g) => g.hooks || [])
      .filter((h) => typeof h.command === "string" && h.command.includes(name));
    const pre = find("PreToolUse", "jev-shadow-pre.js");
    const post = find("PostToolUse", "jev-shadow-post.js");
    const sum = provider.PROBE_TIMEOUT_MS + provider.QUERY_TIMEOUT_MS + broker.PARSER_TIMEOUT_MS;
    const inside = (h) => Number.isFinite(h.timeout) && h.timeout > 0 && sum < h.timeout * 1000;
    out([pre.length, post.length, provider.PROBE_TIMEOUT_MS, provider.QUERY_TIMEOUT_MS, broker.PARSER_TIMEOUT_MS,
      pre.every(inside), post.every(inside)].join("|"));
  } else if (cmd === "norm") {
    out(normLine(broker.normalizeViaParser(val(args[0]), val(args[1]), val(args[2]))));
  } else if (cmd === "norm2") {
    out(normLine(broker.normalizeViaParser(val(args[0]), val(args[1]))));
  } else if (cmd === "norm-twice") {
    const a = broker.normalizeViaParser(val(args[0]), val(args[1]), val(args[2]));
    const b = broker.normalizeViaParser(val(args[0]), val(args[1]), val(args[2]));
    out([JSON.stringify(a), JSON.stringify(b), spawns.length, new Set(spawns.map((x) => x.dir)).size].join("|"));
  } else if (cmd === "norm-no-os-tmp") {
    for (const k of ["TMPDIR", "TEMP", "TMP"]) process.env[k] = args[0];
    out(fs.existsSync(os.tmpdir()) + "|" + normLine(broker.normalizeViaParser(val(args[1]), val(args[2]), val(args[3]))));
  } else if (cmd === "query") {
    const r = await broker.queryShadow({ point: val(args[0]), sessionId: "sid-1", toolUseId: "toolu_b_query",
      toolInput: { subagent_type: "complexity-judge", prompt: "probe" }, step: "outline", overrides });
    out(r === null ? "null" : r.point + "|" + (r.jev && r.jev.status));
  } else if (cmd === "query-probe-stub") {
    const stub = JSON.parse(args[0]);
    provider.jevCoreProbe = async () => stub;
    const r = await broker.queryShadow({ point: "complexity-judge", sessionId: "sid-1", toolUseId: "toolu_b_probe",
      toolInput: { subagent_type: "complexity-judge", prompt: "probe" }, step: "outline", overrides });
    out(r === null ? "null" : [r.jev.status, String(r.jev.http_status), JSON.stringify(r.jev.latency_ms)].join("|"));
  } else if (cmd === "record") {
    const r = broker.recordShadow({ point: val(args[0]), sessionId: "sid-1", toolUseId: "toolu_b_record",
      llmText: "SIGNALS: S1-multi-file", toolInput: { subagent_type: "complexity-judge" }, step: "outline" });
    out(r === null ? "null" : typeof r === "object" && !Array.isArray(r) ? "record" : typeof r);
  } else if (cmd === "qt") {
    const r = await broker.queryShadow({ point: "complexity-judge", sessionId: "sid-1", toolUseId: args[0],
      toolInput: { subagent_type: "complexity-judge", prompt: "probe" }, step: "outline", overrides });
    const l = r && r.jev.latency_ms;
    out(r === null ? "null" : [r.jev.status, l === null ? "null" : Number.isFinite(l) && l >= 0 ? "finite" : "bad:" + l].join("|"));
  } else if (cmd === "rt") {
    const r = broker.recordShadow({ point: "complexity-judge", sessionId: "sid-1", toolUseId: args[0],
      llmText: "SIGNALS: S1-multi-file", toolInput: { subagent_type: "complexity-judge" }, step: "outline",
      endTs: args[1] === undefined ? undefined : val(args[1]) });
    out(r === null ? "null" : typeof r === "object" && !Array.isArray(r) ? "record" : typeof r);
  } else if (cmd === "rt-parser-exit") {
    // rt-parser-exit <toolUseId> <status>: recordShadow whose LLM-side parser exits <status>.
    forcedParserStatus = Number(args[1]);
    const r = broker.recordShadow({ point: "complexity-judge", sessionId: "sid-1", toolUseId: args[0],
      llmText: "SIGNALS: S1-multi-file", toolInput: { subagent_type: "complexity-judge" }, step: "outline" });
    out(r === null ? "null" : [r.llm.status, r.llm.answer, String(r.agreement), r.jev && r.jev.status, spawns.length].join("|"));
  } else if (cmd === "sweep") {
    out(broker.sweepSession("sid-1", { pendingTtlMs: Number(args[0]) || undefined }));
  } else if (cmd === "resolve-step") {
    // resolve-step <cwd> <notes-sid> <hook-sid> <settled|clarify|none>: <cwd>/WORKTREE_NOTES.md names
    // <notes-sid>, whose state (unless none) is bound to <cwd> via session_worktree and is either fully
    // settled or at clarify_intent. Prints notesSessionId|own step|resolveStep twice|stage.
    const [cwd, nsid, hsid, mode] = args;
    const io = lib("hooks/workflow-state/state-io.js");
    const { resolveCurrentEffectiveStep } = lib("hooks/workflow-state/current-step.js");
    const adapter = lib("bin/workflow/lib/jev-complexity-adapter.js");
    fs.writeFileSync(path.join(cwd, "WORKTREE_NOTES.md"), "# Worktree Notes\n\nSession-ID: " + nsid + "\n");
    if (mode !== "none") {
      for (const s of io.VALID_STEPS) {
        if (mode === "clarify" && s === "clarify_intent") break;
        // outline/detail completion needs a plan approval; skipped settles them just the same.
        io.markStep(nsid, s, s === "outline" || s === "detail" ? "skipped" : "complete");
      }
      io.recordSessionWorktree(nsid, cwd);
    }
    const a = broker.resolveStep("complexity-judge", hsid, cwd);
    const b = broker.resolveStep("complexity-judge", hsid, cwd);
    out([String(adapter.notesSessionId(cwd)), String(resolveCurrentEffectiveStep(hsid)), String(a), String(b),
      adapter.stageForStep(a)].join("|"));
  } else if (cmd === "drop-key") {
    const o = JSON.parse(fs.readFileSync(args[0], "utf8"));
    delete o[args[1]];
    fs.writeFileSync(args[0], JSON.stringify(o));
    out(Object.prototype.hasOwnProperty.call(o, args[1]));
  }
}
main().catch((e) => out("THROW:" + (e && e.name)));
JS
PROBE_N="$(np "$PROBE")"

# bp <cmd> [json-arg ...]: one probe process in the current fixture, away from the worktree.
# JEV is unset unless BP_JEV is set (even to ""), which becomes the probe's JEV value.
bp() {
  (
    cd "$FX/cwd" || exit 97
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE -u CLAUDECODE \
      -u JEV -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS ${BP_JEV+"JEV=$BP_JEV"} \
      "TYPESAFE_API_KEY=$SENTINEL_KEY" "JEV_BASE_URL=$MOCK_URL" \
      bash "$RWT" 60 node "$PROBE_N" "$REPO_N" "$@" 2>> "$ERR_ALL" < /dev/null
  )
}
# names <dir>: its entries, sorted and comma-joined (empty for an empty or missing dir).
names() { ls -A "$1" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//'; }
norm_left() { find "$FX" -name 'norm-*' 2>/dev/null | wc -l | tr -d ' '; }
RAW='"SIGNALS: S1-multi-file"'
POINT='"complexity-judge"'

log_state() { [ -e "$LOG" ] && echo present || echo absent; }
pend_n() { find "$JEVDIR/sid-1/pending" -name "$1" 2>/dev/null | wc -l | tr -d ' '; }
