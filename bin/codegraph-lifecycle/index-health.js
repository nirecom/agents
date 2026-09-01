#!/usr/bin/env node
// index-health.js — decide what <root>/.codegraph/codegraph.db actually is.
//
// Sole owner of every "is this index usable" judgement (CPR-SSOT): the init and
// sync verbs of bin/codegraph-lifecycle.js ask here instead of re-deriving.
// Never launches the codegraph binary and never writes a byte — verdicts come
// from one file read plus read-only SQLite queries, so an unusable index can
// never become a reason to run CodeGraph against it.

// removeAllListeners must precede the node:sqlite require: Node 24 emits an
// ExperimentalWarning on first use, which would break the "off / no-op writes
// zero bytes to stderr" contract this whole feature rests on.
process.removeAllListeners("warning");

const fs = require("fs");
const path = require("path");

// The 16-byte SQLite file header: the ASCII text plus a terminating NUL.
const SQLITE_MAGIC = Buffer.concat([Buffer.from("SQLite format 3", "latin1"), Buffer.from([0])]);
const REQUIRED_TABLES = ["nodes", "edges", "files", "project_metadata", "schema_versions"];

function databasePath(root) {
  return path.join(root, ".codegraph", "codegraph.db");
}

// upstreamSeesInitialized reimplements upstream directory.js isInitialized()
// verbatim: a .codegraph directory holding a codegraph.db entry, size and
// contents unread. Its ONLY legitimate use is picking which verb to hand the
// codegraph binary (`init -y` builds, `index -q` rebuilds). Never use it as a
// health signal — it is true for a 0-byte file and for a corrupt one alike.
function upstreamSeesInitialized(root) {
  try {
    if (!fs.statSync(path.join(root, ".codegraph")).isDirectory()) return false;
    return fs.statSync(databasePath(root)).isFile();
  } catch (_) {
    return false;
  }
}

function readHeader(file) {
  const head = Buffer.alloc(SQLITE_MAGIC.length);
  const fd = fs.openSync(file, "r");
  try {
    fs.readSync(fd, head, 0, head.length, 0);
  } finally {
    fs.closeSync(fd);
  }
  return head;
}

function countRows(db, table) {
  const row = db.prepare("select count(*) as n from " + table).get();
  return Number(row && row.n);
}

// classifySchema runs only against a successfully opened database. Missing
// tables and an empty schema_versions mean "valid SQLite, but not a CodeGraph
// index" — the fake-DB case a magic-byte check alone cannot see.
function classifySchema(db) {
  const present = new Set(
    db.prepare("select name from sqlite_master where type='table'").all().map((r) => String(r.name))
  );
  if (REQUIRED_TABLES.some((t) => !present.has(t))) return "invalid";
  if (countRows(db, "schema_versions") < 1) return "invalid";

  const stateRow = db.prepare("select value from project_metadata where key='index_state'").get();
  const state = stateRow ? String(stateRow.value) : "";
  if (state === "indexing") return "indexing";
  if (state !== "complete") return "incomplete";
  return countRows(db, "nodes") < 1 ? "incomplete" : "valid";
}

// classifyIndex returns one of: absent | invalid | incomplete | indexing |
// valid | unverifiable. Idempotent and side-effect free. Short-circuits from
// cheapest to most expensive so a missing or obviously-bogus file never
// reaches SQLite. "unverifiable" is the fail-closed verdict: a lock, a
// permission wall, or a Node without node:sqlite must not be read as "fine".
function classifyIndex(root) {
  if (process.env.CG_LIFECYCLE_FORCE_UNVERIFIABLE === "1") return "unverifiable";

  const file = databasePath(root);
  let stat = null;
  try {
    stat = fs.statSync(file);
  } catch (_) {
    return "absent";
  }
  if (!stat.isFile()) return "invalid";
  if (stat.size === 0) return "invalid";

  try {
    if (!readHeader(file).equals(SQLITE_MAGIC)) return "invalid";
  } catch (_) {
    return "unverifiable";
  }

  let DatabaseSync = null;
  try {
    ({ DatabaseSync } = require("node:sqlite"));
  } catch (_) {
    return "unverifiable";
  }

  let db = null;
  try {
    db = new DatabaseSync(file, { readOnly: true });
  } catch (err) {
    return /file is not a database/i.test(String(err && err.message)) ? "invalid" : "unverifiable";
  }
  try {
    return classifySchema(db);
  } catch (_) {
    return "unverifiable";
  } finally {
    try {
      db.close();
    } catch (_) {
      /* best-effort: a close failure never changes the verdict */
    }
  }
}

module.exports = { upstreamSeesInitialized, classifyIndex, databasePath, REQUIRED_TABLES };
