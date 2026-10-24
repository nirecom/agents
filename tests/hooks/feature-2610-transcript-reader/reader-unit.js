"use strict";
// Unit driver for ../feature-2610-transcript-reader.sh: exercises hooks/lib/transcript-reader.js
// (TR_LIB) on hand-built transcripts under TR_TDIR and prints one PASS|name / FAIL|name|detail
// line per assertion. A late flush is simulated by a worker thread that appends the final line
// while the reader blocks the main thread in Atomics.wait.

const fs = require("fs");
const path = require("path");
const { Worker } = require("worker_threads");

const out = [];
const ok = (n, c, d) => out.push(c ? "PASS|" + n : "FAIL|" + n + "|" + d);
const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };
const TDIR = process.env.TR_TDIR;
let seq = 0;
const tpath = () => path.join(TDIR, "t" + (++seq) + ".jsonl");

const U = (text) => ({ type: "user", message: { role: "user", content: text } });
const UMETA = (text) => ({ type: "user", isMeta: true, message: { role: "user", content: text } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const B = (command) => ({ type: "tool_use", id: "t1", name: "Bash", input: { command } });
const line = (e) => JSON.stringify(e);
const writeT = (p, entries) => fs.writeFileSync(p, entries.map((e) => (typeof e === "string" ? e : line(e))).join("\n") + "\n");

// appendLater(p, text, ms) — a worker appends `text` to p after ms; returns a "started" flag reader.
function appendLater(p, text, ms) {
  const sab = new SharedArrayBuffer(4);
  const flag = new Int32Array(sab);
  const w = new Worker(
    "const { workerData } = require('worker_threads'); const fs = require('fs');" +
    "const f = new Int32Array(workerData.sab); Atomics.store(f, 0, 1); Atomics.notify(f, 0);" +
    "setTimeout(() => { fs.appendFileSync(workerData.p, workerData.text); Atomics.store(f, 0, 2); }, workerData.ms);",
    { eval: true, workerData: { p, text, ms, sab } });
  w.unref();
  // Wait until the worker is running, so the delay is measured from a live timer.
  for (let i = 0; i < 100 && Atomics.load(flag, 0) === 0; i++) Atomics.wait(flag, 0, 0, 20);
  return () => Atomics.load(flag, 0);
}

let tr;
try {
  tr = require(process.env.TR_LIB);
} catch (e) {
  process.stdout.write("FAIL|require hooks/lib/transcript-reader.js|not implemented: " + (e.code || e.message) + "\n");
  process.exit(0);
}

const call = (fn, arg) => { try { return fn(arg); } catch (e) { return { threw: e.message }; } };
const tail = (input) => call(tr.readTurnTail, { input });
const prev = (transcriptPath) => call((p) => tr.splitTurns(tr.parseLines(tr.readTranscriptLines(p))), transcriptPath);
const textOf = (r) => (r && typeof r.lastTextBlock === "string" ? r.lastTextBlock : r && r.lastTextBlock);

try {
  ["readTranscriptLines", "readTurnTail", "parseLines", "splitTurns"].forEach((f) =>
    ok(f + " is exported", typeof tr[f] === "function", typeof tr[f]));
  ok("readPreviousTurn is not exported (removed in #2738)", !("readPreviousTurn" in tr), typeof tr.readPreviousTurn);

  // Late flush: the final text line arrives ~150ms after the read starts; last_assistant_message
  // names it, so the reader waits (50ms steps, 500ms cap) and returns the flushed block.
  {
    const p = tpath();
    writeT(p, [U("go"), A(T("EARLIER-TEXT"))]);
    const state = appendLater(p, line(A(T("FINAL-FLUSHED-TEXT"))) + "\n", 150);
    const t0 = Date.now();
    const r = tail({ transcript_path: p, last_assistant_message: "FINAL-FLUSHED-TEXT" });
    const ms = Date.now() - t0;
    ok("late flush — final line appended after the read began", state() === 2, "worker state=" + state());
    ok("late flush — lastTextBlock is the flushed final text", textOf(r) === "FINAL-FLUSHED-TEXT", show(r));
    ok("late flush — not undecidable", r && r.undecidable !== true, show(r));
    ok("late flush — waited for the line (>=100ms) within the cap (<1500ms)", ms >= 100 && ms < 1500, "ms=" + ms);
    const e = r && r.lastAssistantEntry;
    const items = e && e.message && Array.isArray(e.message.content) ? e.message.content : [];
    ok("late flush — lastAssistantEntry is the flushed entry", items.some((x) => x && x.text === "FINAL-FLUSHED-TEXT"), show(e));
  }

  // Never matches: the wait runs out (about 500ms) and the result is undecidable.
  {
    const p = tpath();
    writeT(p, [U("go"), A(T("SOMETHING-ELSE"))]);
    const t0 = Date.now();
    const r = tail({ transcript_path: p, last_assistant_message: "TEXT-THAT-NEVER-ARRIVES" });
    const ms = Date.now() - t0;
    ok("no match — undecidable:true", r && r.undecidable === true, show(r));
    ok("no match — waited about the 500ms cap (>=400ms, <3000ms)", ms >= 400 && ms < 3000, "ms=" + ms);
  }

  // Trimmed endsWith: trailing whitespace in either side still matches.
  {
    const p = tpath();
    writeT(p, [U("go"), A(T("Body line.\nPlan link here.  "))]);
    const r = tail({ transcript_path: p, last_assistant_message: "Plan link here.\n" });
    ok("trimmed endsWith match — decided at once", r && r.undecidable !== true && textOf(r) === "Body line.\nPlan link here.  ", show(r));
  }

  // No last_assistant_message: read once, no wait — a line appended 150ms later is not seen.
  {
    const p = tpath();
    writeT(p, [U("go"), A(T("ONLY-FLUSHED-TEXT"))]);
    appendLater(p, line(A(T("LATER-TEXT"))) + "\n", 150);
    const t0 = Date.now();
    const r = tail({ transcript_path: p });
    const ms = Date.now() - t0;
    ok("no field — lastTextBlock from the single read", textOf(r) === "ONLY-FLUSHED-TEXT", show(r));
    ok("no field — not undecidable", r && r.undecidable !== true, show(r));
    ok("no field — returned without waiting (<120ms)", ms < 120, "ms=" + ms);
  }

  // Two text blocks in the final message, the URL only in the first: last_assistant_message may
  // join both, but lastTextBlock is the second alone, so the plan-link check still blocks.
  {
    const p = tpath();
    const url = "https://example.invalid/owner/repo/blob/main/s-intent.md";
    writeT(p, [U("go"), A(T("Plan: " + url), T("Done."))]);
    const r = tail({ transcript_path: p, last_assistant_message: "Plan: " + url + "\n\nDone." });
    ok("two text blocks — lastTextBlock is the second block only", textOf(r) === "Done.", show(r));
    ok("two text blocks — decided (joined message ends with the last block)", r && r.undecidable !== true, show(r));
    let tc = null;
    try { tc = require(process.env.TC_LIB); } catch (e) { ok("plan-link-turn-check loads", false, e.message); }
    if (tc) {
      const v = tc.checkPlanUrlInTurn({ stages: ["intent"], turnText: textOf(r) || "",
        resolve: () => ({ url, kind: "blob", path: "/plans/s-intent.md" }) });
      ok("two text blocks — plan-link check on lastTextBlock blocks", !!v && (v.block === true || v.decision === "block"), show(v));
    }
  }

  // Empty and missing transcripts never throw.
  {
    const p = tpath();
    fs.writeFileSync(p, "");
    const lines = call(tr.readTranscriptLines, p);
    ok("empty transcript — readTranscriptLines gives no entries", Array.isArray(lines) && lines.filter((l) => l && String(l).trim()).length === 0, show(lines));
    const r = tail({ transcript_path: p });
    ok("empty transcript — readTurnTail does not throw, no text block", r && !r.threw && !textOf(r), show(r));
    const missing = path.join(TDIR, "does-not-exist.jsonl");
    const lm = call(tr.readTranscriptLines, missing);
    ok("missing transcript — readTranscriptLines does not throw", !(lm && lm.threw), show(lm));
    const rm = tail({ transcript_path: missing });
    ok("missing transcript — readTurnTail does not throw, no text block", rm && !rm.threw && !textOf(rm), show(rm));
    const rp = prev(missing);
    ok("missing transcript — splitTurns over the read does not throw, no prior prompt", rp && !rp.threw && rp.hasPriorPrompt === false && rp.currentTurnEntries.length === 0, show(rp));
  }

  // A malformed JSONL line is skipped, before or after the text that matters.
  {
    const p = tpath();
    writeT(p, [U("go"), "{not json", A(T("GOOD-TEXT")), "{\"type\":\"assistant\",\"message\":"]);
    const r = tail({ transcript_path: p });
    ok("malformed lines — lastTextBlock is the last parseable text", textOf(r) === "GOOD-TEXT", show(r));
    const r2 = tail({ transcript_path: p, last_assistant_message: "GOOD-TEXT" });
    ok("malformed lines — matches last_assistant_message without waiting out", r2 && r2.undecidable !== true && textOf(r2) === "GOOD-TEXT", show(r2));
  }

  // Parser table: each row's raw input goes through parseLines (and, for array rows, through a
  // written transcript and readTranscriptLines first); a malformed line or non-array input yields
  // no entry and never throws.
  {
    const PARSE_CASES = [
      { name: "valid", input: [line(U("go")), line(A(T("OK")))], expected: [U("go"), A(T("OK"))] },
      { name: "mixed", input: [line(U("go")), "{not json", line(A(T("GOOD-TEXT"))), "{\"type\":\"assistant\",\"message\":", "42", "null"], expected: [U("go"), A(T("GOOD-TEXT"))] },
      { name: "malformed", input: ["{not json", "{\"type\":\"user\","], expected: [] },
      { name: "non-array (null)", input: null, expected: [] },
      { name: "non-array (string)", input: line(U("go")), expected: [] },
      { name: "non-array (object)", input: { 0: line(U("go")), length: 1 }, expected: [] },
    ];
    for (const c of PARSE_CASES) {
      const got = call(tr.parseLines, c.input);
      ok("parseLines table — " + c.name, Array.isArray(got) && show(got) === show(c.expected), show(got));
      if (!Array.isArray(c.input)) continue;
      const p = tpath();
      fs.writeFileSync(p, c.input.join("\n") + "\n");
      const lines = call(tr.readTranscriptLines, p);
      ok("readTranscriptLines table — " + c.name + " returns every raw line", show(lines) === show(c.input), show(lines));
      const viaFile = call(tr.parseLines, lines);
      ok("read+parse table — " + c.name, Array.isArray(viaFile) && show(viaFile) === show(c.expected), show(viaFile));
    }
  }

  // splitTurns: the previous turn is the span between the last two real prompts.
  {
    const p = tpath();
    writeT(p, [U("first"), A(T("OLDEST")), U("second"), A(T("PREV-TURN-TEXT")), U("third"), A(B("echo x"))]);
    const r = prev(p);
    const has = (arr, s) => Array.isArray(arr) && JSON.stringify(arr).includes(s);
    const lacks = (arr, s) => Array.isArray(arr) && !JSON.stringify(arr).includes(s);
    ok("previous turn — hasPriorPrompt:true", r && r.hasPriorPrompt === true, show(r));
    ok("previous turn — prevTurnEntries holds the previous turn's text", has(r && r.prevTurnEntries, "PREV-TURN-TEXT"), show(r));
    ok("previous turn — prevTurnEntries excludes the turn before it", lacks(r && r.prevTurnEntries, "OLDEST"), show(r));
    ok("previous turn — currentTurnEntries holds this turn's tool_use", has(r && r.currentTurnEntries, "echo x"), show(r));
    ok("previous turn — currentTurnEntries excludes the previous turn", lacks(r && r.currentTurnEntries, "PREV-TURN-TEXT"), show(r));
  }
  // Entries that are not real prompts stay inside the turn they appear in; the exact turn contents
  // are compared so a splitTurns that drops or moves an entry fails.
  {
    const meta = UMETA("<local-command-caveat>meta</local-command-caveat>");
    const compact = { type: "user", isCompactSummary: true, message: { role: "user", content: "This session is being continued..." } };
    const toolResult = { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } };
    const SPLIT_CASES = [
      { name: "single prompt",
        entries: [U("only prompt"), A(T("PRESENTED")), A(B("echo x"))],
        expected: { hasPriorPrompt: false, prevTurnEntries: [], currentTurnEntries: [A(T("PRESENTED")), A(B("echo x"))] } },
      { name: "isMeta entry is not a real prompt",
        entries: [U("only prompt"), A(T("PRESENTED")), meta, A(B("echo x"))],
        expected: { hasPriorPrompt: false, prevTurnEntries: [], currentTurnEntries: [A(T("PRESENTED")), meta, A(B("echo x"))] } },
      { name: "compact summary is not a real prompt",
        entries: [U("only prompt"), A(T("PRESENTED")), compact, A(B("echo x"))],
        expected: { hasPriorPrompt: false, prevTurnEntries: [], currentTurnEntries: [A(T("PRESENTED")), compact, A(B("echo x"))] } },
      { name: "tool_result-only user entry does not open a turn",
        entries: [U("first"), A(T("PREV-TEXT")), toolResult, A(T("PREV-AFTER-RESULT")), U("second"), A(B("echo x")), toolResult, A(T("CUR-AFTER-RESULT"))],
        expected: { hasPriorPrompt: true,
          prevTurnEntries: [A(T("PREV-TEXT")), toolResult, A(T("PREV-AFTER-RESULT"))],
          currentTurnEntries: [A(B("echo x")), toolResult, A(T("CUR-AFTER-RESULT"))] } },
    ];
    for (const c of SPLIT_CASES) {
      const p = tpath();
      writeT(p, c.entries);
      const r = prev(p);
      ok(c.name + " — hasPriorPrompt:" + c.expected.hasPriorPrompt, r && r.hasPriorPrompt === c.expected.hasPriorPrompt, show(r));
      ok(c.name + " — prevTurnEntries exact", r && show(r.prevTurnEntries) === show(c.expected.prevTurnEntries), show(r && r.prevTurnEntries));
      ok(c.name + " — currentTurnEntries exact", r && show(r.currentTurnEntries) === show(c.expected.currentTurnEntries), show(r && r.currentTurnEntries));
    }
  }
} catch (e) {
  ok("driver does not throw", false, e && e.stack);
}
process.stdout.write(out.join("\n") + "\n");
process.exit(0);
