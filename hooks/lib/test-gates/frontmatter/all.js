"use strict";
// --all of the frontmatter check (#2507 D7): the supported tests directly in each test dir of the
// repo's .agents.json tests section (#2473; uninitialized: the legacy categories), listed per
// registry entry as tlr_list_dir_into lists them.

const fs = require("fs");
const path = require("path");
const R = require("../registry");
const RS = require("../../repo-settings");
const { readHeaders } = require("../headers");
const { checkContent } = require("./content");
const { toWindowsPath } = require("../../branch-diff");

const patternRe = (p) => new RegExp(`^${p.split("*").map((s) => s.replace(/[.-]/g, "\\$&")).join("[\\s\\S]+")}$`);

// listSupported(dir) — the files of dir a supported entry's patterns match, entry by entry.
function listSupported(dir) {
  let names;
  try {
    names = fs.readdirSync(toWindowsPath(dir)).sort();
  } catch {
    return [];
  }
  const seen = new Set();
  const out = [];
  for (const e of R.reg().entries.filter((x) => x.status === "supported")) {
    const res = e.patterns.map(patternRe);
    for (const n of names) {
      if (seen.has(n) || !res.some((re) => re.test(n))) continue;
      const abs = path.join(toWindowsPath(dir), n);
      try {
        if (!fs.statSync(abs).isFile()) continue;
      } catch {
        continue;
      }
      seen.add(n);
      out.push(n);
    }
  }
  return out;
}

// allCheck(root) -> { rc, lines }: every listed file's header diagnostics, named root-relative.
function allCheck(root) {
  const lines = [];
  for (const testDir of RS.testDirsIn(R.layoutFor(root))) {
    const dir = `${root}/${testDir}`;
    for (const n of listSupported(dir)) {
      const rel = `${testDir}/${n}`;
      let text = "";
      try {
        text = fs.readFileSync(path.join(toWindowsPath(dir), n), "utf8");
      } catch {
        text = "";
      }
      const h = readHeaders(text, n);
      lines.push(...checkContent(rel, h.tests, h.tags));
    }
  }
  return { rc: lines.length ? 1 : 0, lines };
}

module.exports = { allCheck, listSupported };
