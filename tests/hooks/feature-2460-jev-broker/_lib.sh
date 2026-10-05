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
// Counts every child_process launch from here on: normalizeViaParser must start none.
let childCalls = 0;
for (const k of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) {
  const real = cp[k];
  cp[k] = function () { childCalls++; return real.apply(this, arguments); };
}
// norm-stub <mode> and rt-normalizer <tid> <mode> swap the normalizer before the broker loads.
const { stubNormalizer } = lib("tests/hooks/feature-2460-jev-shadow/hardening-probe.js");
const stubMode = cmd === "norm-stub" ? args[0] : cmd === "rt-normalizer" ? args[1] : null;
const stub = stubMode === null ? null : stubNormalizer(repo, stubMode);
const broker = lib("hooks/lib/jev/broker.js");
const registry = lib("hooks/lib/jev/registry.js");
const provider = lib("hooks/lib/jev/provider-core.js");
const val = (s) => (s === "undefined" ? undefined : JSON.parse(s));
const out = (s) => process.stdout.write(String(s));
// "<result as JSON>|<child processes started>".
const normLine = (result) => JSON.stringify(result) + "|" + childCalls;
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
    const sum = provider.PROBE_TIMEOUT_MS + provider.QUERY_TIMEOUT_MS;
    const inside = (h) => Number.isFinite(h.timeout) && h.timeout > 0 && sum < h.timeout * 1000;
    out([pre.length, post.length, provider.PROBE_TIMEOUT_MS, provider.QUERY_TIMEOUT_MS,
      "PARSER_TIMEOUT_MS" in broker, "NORM_DIR_PREFIX" in broker, pre.every(inside), post.every(inside)].join("|"));
  } else if (cmd === "norm") {
    // norm <point> <raw> [extra]: an extra argument (the retired session id) must change nothing.
    const r = args.length > 2 ? broker.normalizeViaParser(val(args[0]), val(args[1]), val(args[2]))
      : broker.normalizeViaParser(val(args[0]), val(args[1]));
    out(normLine(r));
  } else if (cmd === "norm-stub") {
    // norm-stub <stubNormalizer mode> <point> <raw>: "<result>|<child processes>|<normalizer reached>".
    out(normLine(broker.normalizeViaParser(val(args[1]), val(args[2]))) + "|" + (stub.calls > 0));
  } else if (cmd === "norm-ostmp") {
    // norm-ostmp <os tmp dir> <point> <raw> [extra]: os.tmpdir() points at <os tmp dir> first.
    for (const k of ["TMPDIR", "TEMP", "TMP"]) process.env[k] = args[0];
    const r = args.length > 3 ? broker.normalizeViaParser(val(args[1]), val(args[2]), val(args[3]))
      : broker.normalizeViaParser(val(args[1]), val(args[2]));
    out(path.resolve(os.tmpdir()) === path.resolve(args[0]) ? normLine(r) : "TMPDIR-NOT-REDIRECTED:" + os.tmpdir());
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
  } else if (cmd === "rt-normalizer") {
    // rt-normalizer <toolUseId> <stubNormalizer mode>: recordShadow with that LLM-side normalizer.
    const r = broker.recordShadow({ point: "complexity-judge", sessionId: "sid-1", toolUseId: args[0],
      llmText: "SIGNALS: S1-multi-file", toolInput: { subagent_type: "complexity-judge" }, step: "outline" });
    out(r === null ? "null" : [r.llm.status, r.llm.answer, String(r.agreement), r.jev && r.jev.status, childCalls].join("|"));
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
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE \
      -u JEV -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS ${BP_JEV+"JEV=$BP_JEV"} \
      "TYPESAFE_API_KEY=$SENTINEL_KEY" "JEV_BASE_URL=$MOCK_URL" \
      bash "$RWT" 60 node "$PROBE_N" "$REPO_N" "$@" 2>> "$ERR_ALL" < /dev/null
  )
}
# names <dir>: its entries, sorted and comma-joined (empty for an empty or missing dir).
names() { ls -A "$1" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//'; }
# stray_files: entries a file-writing normalizer would leave (norm-* temp dirs, *-signals.txt,
# *.control dirs) anywhere in the fixture; 0 is the in-process contract.
stray_files() { find "$FX" \( -name 'norm-*' -o -name '*-signals.txt' -o -name '*.control' \) 2>/dev/null | wc -l | tr -d ' '; }
# fx_tree: every path in the fixture except the probe's stderr sink, sorted (a before/after snapshot).
fx_tree() { find "$FX" -mindepth 1 ! -path "$FX/io/*" 2>/dev/null | sort; }
RAW='"SIGNALS: S1-multi-file"'
POINT='"complexity-judge"'

log_state() { [ -e "$LOG" ] && echo present || echo absent; }
pend_n() { find "$JEVDIR/sid-1/pending" -name "$1" 2>/dev/null | wc -l | tr -d ' '; }
