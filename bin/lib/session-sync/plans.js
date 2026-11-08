"use strict";
// Plan files between the workflow plans dir and <projects>/plans/ (#2658); only *.md travels.

const fs = require("node:fs");
const path = require("node:path");
const { writeAtomic, pathBlocked } = require("./apply");
const { blobIdOf } = require("./git");

function mdFiles(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isFile() && d.name.endsWith(".md")).map((d) => d.name);
  } catch (_) {
    return [];
  }
}

function readOrNull(file) {
  try {
    return fs.readFileSync(file);
  } catch (_) {
    return null;
  }
}

// toProjects(plansDir, projects) — copies changed plans into the working tree before the diff.
function toProjects(plansDir, projects) {
  if (!plansDir) return 0;
  let n = 0;
  for (const name of mdFiles(plansDir)) {
    if (pathBlocked(projects, `plans/${name}`)) continue;
    const src = fs.readFileSync(path.join(plansDir, name));
    const dest = path.join(projects, "plans", name);
    const cur = readOrNull(dest);
    if (cur !== null && cur.equals(src)) continue;
    writeAtomic(dest, src);
    n += 1;
  }
  return n;
}

// fromProjects(plansDir, projects, lMap) — a local plan is replaced only while it still equals
// what the last integration (L) held, so an edit made since then is never overwritten.
function fromProjects(plansDir, projects, lMap) {
  if (!plansDir) return 0;
  let n = 0;
  for (const name of mdFiles(path.join(projects, "plans"))) {
    if (pathBlocked(plansDir, name)) continue;
    const src = fs.readFileSync(path.join(projects, "plans", name));
    const dest = path.join(plansDir, name);
    const cur = readOrNull(dest);
    if (cur !== null && cur.equals(src)) continue;
    const base = lMap.get(`plans/${name}`);
    if (cur !== null && !(base && blobIdOf(cur) === base.blob)) continue;
    writeAtomic(dest, src);
    n += 1;
  }
  return n;
}

module.exports = { toProjects, fromProjects };
