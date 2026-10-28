"use strict";

// #2475 supervisor codex input: transcript + handoff + session-progress.md + plan artifacts + state
// rendered as seven delimited blocks. Every block body is defanged so embedded
// text can never forge a delimiter or open an HTML comment.

const fs = require("fs");
const path = require("path");
const { classify } = require("./rules");
const cursorLib = require("./cursor");
const { getHandoffPath, readDocumentFile, MAX_BYTES } = require("../handoff-artifact");
const { progressPathFor, isRegularFile, isValidSid } = require("../progress-file");
const { resolvePlanArtifactOwner } = require("../../workflow-state/plan-artifact-owner");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { getStatePath } = require("../supervisor-state-writer");
const { diagnoseControlMigration } = require("../../workflow-state/state-io/control-dir");

// A bracketed word run that reads as a fence once case, spacing, underscores and full-width forms
// are ignored: any "... START|BEGIN|END", plus the suffix-less fence this input itself uses.
const FENCE_VARIANT_RE = /[[\uFF3B]([^[\]\uFF3B\uFF3D\n]{1,120})[\]\uFF3D]/g;
const FENCE_WORDS_RE = /^(?:[A-Z]+ )*(?:START|BEGIN|END)$|^SUPERVISOR INPUT HEADER$/;

function fenceWords(inner) {
  return inner.normalize("NFKC").toUpperCase().replace(/[\s_]+/g, " ").trim();
}

// JS twin of bin/review-plan-codex neutralize_delimiters plus the embed_file comment rewrite,
// then the variant pass (the counterpart of bin/lib/concern-ledger/defang-fences.sh).
function defang(text) {
  return String(text)
    .replace(/<!--/g, "(!--")
    .replace(/-->/g, "--)")
    .replace(/\[([^\][]*(?:START|BEGIN|END)[^\][]*)\]/g, "($1)")
    .replace(FENCE_VARIANT_RE, (m, inner) => (FENCE_WORDS_RE.test(fenceWords(inner)) ? `(${inner})` : m));
}

function readOptional(p) {
  try { return fs.readFileSync(p, "utf8"); } catch (_) { return null; }
}

// Complete lines only: a trailing fragment without '\n' is still being written.
function readTranscript(transcriptPath) {
  const raw = fs.readFileSync(transcriptPath, "utf8");
  const cut = raw.lastIndexOf("\n");
  const lines = cut < 0 ? [] : raw.slice(0, cut).split("\n");
  let unparsable = 0;
  const entries = lines.map((l) => {
    if (l.trim() === "") return null;
    try { return JSON.parse(l); } catch (_) { unparsable++; return null; }
  });
  return { entries, unparsable };
}

function collect(entries, start) {
  const ctx = { toolUses: new Map() };
  const utterances = [];
  const actions = [];
  const humanBodies = new Set();
  const counts = { commands: 0, edits: 0, invocations: 0, sentinels: 0, hook_blocks: 0 };
  const countKey = { "A-bash": "commands", "A-edit": "edits", "A-invoke": "invocations", "A-sentinel": "sentinels", "A-stop-block": "hook_blocks", "A-hook-deny": "hook_blocks" };
  let userLines = 0;
  entries.forEach((entry, i) => {
    if (!entry) return;
    if (entry.type === "user") userLines++;
    const r = classify(entry, ctx);
    for (const rec of (Array.isArray(r) ? r : [r]).filter((x) => x && x.keep)) {
      if (rec.rule.startsWith("U-")) {
        if (rec.rule === "U-queued" && humanBodies.has(rec.text)) continue;
        if (rec.rule === "U-human") humanBodies.add(rec.text);
        utterances.push(`L${i + 1} ${entry.timestamp || "-"} | ${rec.text}`);
      } else if (i >= start) {
        actions.push(`L${i + 1} ${rec.text}`);
        if (countKey[rec.rule]) counts[countKey[rec.rule]]++;
      }
    }
  });
  return { utterances, actions, counts, userLines };
}

function block(name, bodyLines) {
  const body = bodyLines.length > 0 ? bodyLines.map(defang).join("\n") : "(none)";
  return `[${name} START]\n${body}\n[${name} END]`;
}

function handoffLines(transcriptPath, wsid) {
  const candidates = [path.basename(transcriptPath).replace(/\.jsonl$/i, "")];
  if (wsid && wsid !== "UNAVAILABLE" && !candidates.includes(wsid)) candidates.push(wsid);
  const out = [];
  for (const sid of candidates) {
    let p;
    try { p = getHandoffPath(sid); } catch (e) { diagnoseControlMigration(e, "supervisor-codex-input"); continue; }
    const text = readDocumentFile(p);
    if (text !== null) out.push(`--- ${path.basename(p)} ---`, text.replace(/\n$/, ""));
  }
  return out;
}

// readHead(file, cap) -> {buf, size} | null: at most cap bytes, never the whole file. Never throws.
// Null unless the opened fd is the single-link regular file lstat saw: a hard link or a swap
// between lstat and open would make the file an alias of content outside the plans dir.
function readHead(file, cap) {
  let fd = null;
  try {
    const before = fs.lstatSync(file);
    if (!before.isFile()) return null;
    fd = fs.openSync(file, "r");
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.nlink !== 1 || st.dev !== before.dev || st.ino !== before.ino) return null;
    const buf = Buffer.alloc(Math.min(cap, st.size));
    let got = 0;
    while (got < buf.length) {
      const n = fs.readSync(fd, buf, got, buf.length - got, got);
      if (n <= 0) break;
      got += n;
    }
    return { buf: buf.subarray(0, got), size: st.size };
  } catch (_) {
    return null;
  } finally {
    if (fd !== null) try { fs.closeSync(fd); } catch (_) { /* already closed */ }
  }
}

// session-progress.md of the first generation (#2594), cut at the HANDOFF cap. The model writes it,
// so the block heads it as the model's own record -- never as evidence.
function progressLines(transcriptPath, wsid) {
  const sid = wsid && wsid !== "UNAVAILABLE" ? wsid : path.basename(transcriptPath).replace(/\.jsonl$/i, "");
  const p = progressPathFor(sid);
  if (!p || !isRegularFile(p)) return [];
  const head = readHead(p, MAX_BYTES);
  if (!head) return [];
  const cut = head.size > MAX_BYTES;
  const text = head.buf.toString("utf8").replace(/\n$/, "");
  const out = [`--- ${path.basename(p)} (written by the model, not evidence) ---`, text];
  if (cut) out.push(`(truncated at ${MAX_BYTES} bytes)`);
  return out;
}

// The plans every generation of the session chain reads: <first_session_id>-<kind>.md (#2748).
function planLines(wsid, planScope, artifact) {
  if (!wsid || wsid === "UNAVAILABLE" || !isValidSid(wsid)) return [];
  const kinds = planScope === "intent" ? ["intent"] : ["intent", "outline", "detail"];
  const out = [];
  const taken = [];
  const plansDir = getWorkflowPlansDir();
  for (const k of kinds) {
    let p;
    try { p = resolvePlanArtifactOwner(wsid, k, undefined, { plansDir }).path; } catch (_) { continue; }
    const text = readOptional(p);
    if (text === null) continue;
    taken.push(p);
    out.push(`--- ${path.basename(p)} ---`, text.replace(/\n$/, ""));
  }
  if (artifact && !taken.some((p) => cursorLib.samePath(p, artifact))) {
    const text = readOptional(artifact);
    if (text !== null) out.push(`--- artifact: ${path.basename(artifact)} ---`, text.replace(/\n$/, ""));
  }
  return out;
}

function stateLines(sid, snapshot) {
  let text = snapshot ? readOptional(snapshot) : null;
  if (text === null) {
    try { text = readOptional(getStatePath(sid)); } catch (e) { diagnoseControlMigration(e, "supervisor-codex-input"); text = null; }
  }
  return text === null ? [] : [text.replace(/\n$/, "")];
}

function readCursor(sid, mode) {
  try {
    const st = JSON.parse(fs.readFileSync(getStatePath(sid), "utf8"));
    return (st && st[mode] && st[mode].transcript_cursor) || null;
  } catch (e) {
    diagnoseControlMigration(e, "supervisor-codex-input");
    return null;
  }
}

// opts: {mode, sid, wsid, transcript, artifact, stateSnapshot, planScope} (paths already toWindowsPath'd).
function assemble(opts) {
  const { entries, unparsable } = readTranscript(opts.transcript);
  const cur = cursorLib.evaluate(readCursor(opts.sid, opts.mode), opts.transcript, entries);
  const c = collect(entries, cur.start);
  const scope = !opts.wsid || opts.wsid === "UNAVAILABLE" ? "none" : opts.planScope || "all";
  const header = [
    `transcript: ${opts.transcript} (${entries.length} complete lines)`,
    `actions range: L${cur.start + 1}..L${entries.length}`,
    `cursor: ${cur.status}`,
    `plan-scope: ${scope}`,
    `counts: utterances=${c.utterances.length} commands=${c.counts.commands} edits=${c.counts.edits} ` +
      `invocations=${c.counts.invocations} sentinels=${c.counts.sentinels} hook_blocks=${c.counts.hook_blocks} skipped_unparsable=${unparsable}`,
  ];
  if (c.userLines > 0 && c.utterances.length === 0) header.push("warning: no human utterances matched \u2014 transcript schema drift?");
  const text = [
    ["[SUPERVISOR INPUT HEADER]", ...header.map(defang)].join("\n"),
    block("HANDOFF", handoffLines(opts.transcript, opts.wsid)),
    block("PROGRESS", progressLines(opts.transcript, opts.wsid)),
    block("USER UTTERANCES", c.utterances),
    block(`ACTIONS SINCE PREVIOUS ${opts.mode.toUpperCase()} RUN`, c.actions),
    block("PLAN ARTIFACTS", planLines(opts.wsid, opts.planScope, opts.artifact)),
    block("SUPERVISOR STATE", stateLines(opts.sid, opts.stateSnapshot)),
  ].join("\n\n") + "\n";
  return { text, status: cur.status, next: cursorLib.next(opts.transcript, entries) };
}

module.exports = { assemble, defang, readTranscript };
