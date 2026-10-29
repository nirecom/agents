"use strict";
// One file's self-implemented harness verdict (#2507 D7; ports _csi_check / _csi_head_keys of
// bin/check-self-impl.sh). judge({ name, file, head }) -> { lines: [{ err, text }], high, infra }:
// file / head are paths or in-memory files (source.js); head is the HEAD version, whose count of
// each (kind, detail) key is subtracted. An err line belongs on stderr, the rest on stdout.

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

function headKeys(head, name) {
  const r = report(head, name);
  return r.rc === 0 ? rows(r.stdout).map((k) => `${k.kind}\t${k.detail}`) : [];
}

function runtimeOf(name) {
  try {
    const m = R.match(name);
    return (m && R.fieldValue(m.entry, "launch.requires")) || "its runtime";
  } catch {
    return "its runtime";
  }
}

function judge({ name, file, head }) {
  const res = { lines: [], high: false, infra: false };
  if (head && S.bytesOf(head).equals(S.bytesOf(file))) return res;
  const r = report(file, name);
  if (r.rc === 0) {
    const found = rows(r.stdout);
    const keys = head && found.length ? headKeys(head, name) : [];
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
