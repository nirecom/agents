"use strict";
// One file's self-implemented harness verdict (#2507 D7; ports _csi_check / _csi_head_keys of
// bin/check-self-impl.sh). judge({ name, file, head | heads, base }) -> { lines: [{ err, text }], high,
// infra }: file / heads / base are paths or in-memory files (source.js); the parents' count of each
// (kind, detail) key is subtracted (headKeys). An err line belongs on stderr, the rest on stdout.

const R = require("./registry");
const S = require("./source");
const { report } = require("./self-impl");

// rows(out) — [{ line, kind, detail }] as `IFS=$'\t' read -r line kind detail` reads them.
function rows(out) {
  const s = String(out).replace(/\n+$/, "");
  if (!s) return [];
  return s.split("\n").map((l) => {
    const m = /^([^\t]*)(?:\t+([^\t]*)(?:\t+(.*))?)?$/s.exec(l.replace(/^\t+|\t+$/g, ""));
    return { line: m[1], kind: m[2] || "", detail: (m[3] || "").replace(/\r$/, "") };
  }).filter((r) => r.line);
}

// keysOf(copy, name) — the (kind, detail) key of each detection; null when the op cannot analyse it.
function keysOf(copy, name) {
  const r = report(copy, name);
  return r.rc === 0 ? rows(r.stdout).map((k) => `${k.kind}\t${k.detail}`) : null;
}

// headKeys(heads, base, name) — the existing detections: head1's, or with two heads (a merge, #2812)
// head1's + head2's minus one per base key (judge collapses identical base-less heads to one first).
// head1 unanalysable → none; head2 or base → head1 alone.
function headKeys(heads, base, name) {
  const h1 = keysOf(heads[0], name);
  if (!h1) return [];
  if (!heads[1]) return h1;
  const h2 = keysOf(heads[1], name);
  const b = base ? keysOf(base, name) : [];
  if (!h2 || !b) return h1;
  const keys = [...h1, ...h2];
  for (const k of b) {
    const i = keys.indexOf(k);
    if (i >= 0) keys.splice(i, 1);
  }
  return keys;
}

function runtimeOf(name) {
  try {
    const m = R.match(name);
    return (m && R.fieldValue(m.entry, "launch.requires")) || "its runtime";
  } catch {
    return "its runtime";
  }
}

function judge({ name, file, head, heads, base }) {
  const res = { lines: [], high: false, infra: false };
  const hs = (heads || [head]).filter(Boolean);
  const bytes = hs.length ? S.bytesOf(file) : null;
  if (hs.some((h) => S.bytesOf(h).equals(bytes))) return res;
  // R5: identical heads are one parent, so a base-less pair must not count each key twice.
  if (hs[1] && !base && S.bytesOf(hs[1]).equals(S.bytesOf(hs[0]))) hs.pop();
  const r = report(file, name);
  if (r.rc === 0) {
    const found = rows(r.stdout);
    const keys = hs.length && found.length ? headKeys(hs, hs[1] ? base : null, name) : [];
    for (const d of found) {
      const i = keys.indexOf(`${d.kind}\t${d.detail}`);
      if (i >= 0) {
        keys.splice(i, 1);
        continue;
      }
      res.lines.push({ err: false, text: `HIGH: ${name} line ${d.line}: self-implemented harness (${d.kind} ${d.detail}) code=SELF_IMPLEMENTED_HARNESS` });
      res.high = true;
    }
  } else if (r.rc === 3) {
    res.lines.push({ err: false, text: `WARN: ${name}: harness self-implementation not checked (no caseEmbedRules) code=SELF_IMPL_CHECK_UNSUPPORTED` });
  } else if (r.rc === 69) {
    res.lines.push({ err: false, text: `WARN: ${name}: harness self-implementation not checked (${runtimeOf(name)} is not installed) code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE` });
  } else {
    res.lines.push({ err: true, text: `check-self-impl.sh: self-impl op failed (rc=${r.rc}): ${name}` });
    res.infra = true;
  }
  return res;
}

module.exports = { judge, rows };
