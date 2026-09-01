# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js, bin/codegraph-lifecycle/process-identity.js
# Tags: codegraph, lifecycle, fixtures, sqlite, scope:issue-specific
# Fixture generators for tests/feature-codegraph-lifecycle.sh: the recording
# `codegraph` stub, the identity-query stub, the daemon stand-ins and the DB
# builder. Sourced by harness.sh once the temp tree exists.

mkdir -p "$TMP_BASE/helpers/sigterm" "$TMP_BASE/external"

# The `codegraph` stub is a hardlink of the node binary plus this NODE_OPTIONS
# preload, because on win32 spawnSync reaches neither a PATH-visible shell
# script nor a .cmd/.bat stub. The preload only acts inside that hardlink.
# CG_STUB_MAKEDB opts a case into a stub that actually produces an index: on a
# non-failing init/index it builds that DB kind at the root argv carried, which
# is what turns L7b / L9s / L11f into end-to-end success paths.
cat > "$TMP_BASE/recorder.js" <<'RECORDER'
const path = require("node:path");
const fs = require("node:fs");
const self = path.basename(process.execPath).toLowerCase().replace(/\.exe$/, "");
if (self === "codegraph" && process.env.CG_STUB_LOG) {
  const argv = process.argv.slice(1);
  const verb = argv.length ? path.basename(argv[0]) : "";
  let line = [verb].concat(argv.slice(1)).join(" ");
  if (process.env.CG_STUB_PROBE_PID) {
    let alive = "no";
    try { process.kill(Number(process.env.CG_STUB_PROBE_PID), 0); alive = "yes"; } catch (_) {}
    line += " probe_alive=" + alive;
  }
  fs.appendFileSync(process.env.CG_STUB_LOG, line + "\n");
  if (verb === "status" && process.env.CG_STUB_STATUS_JSON) {
    process.stdout.write(process.env.CG_STUB_STATUS_JSON);
  }
  if (process.env.CG_STUB_ENV_LOG) {
    const wanted = String(process.env.CG_STUB_ENV_VARS || "").split(",").filter(Boolean);
    const snap = wanted.map((k) => k + "=" + (process.env[k] === undefined ? "<unset>" : process.env[k])).join(" ");
    fs.appendFileSync(process.env.CG_STUB_ENV_LOG, snap + "\n");
  }
  const fails = String(process.env.CG_STUB_FAIL || "").split(",").map((s) => s.trim());
  const failed = fails.indexOf(verb) >= 0;
  const wantDb = process.env.CG_STUB_MAKEDB;
  if (!failed && wantDb && (verb === "init" || verb === "index")) {
    try { require(process.env.CG_MKDB).buildDb(argv[argv.length - 1], wantDb, "", true); }
    catch (e) { fs.appendFileSync(process.env.CG_STUB_LOG, "STUB-MAKEDB-FAILED " + e.message + "\n"); }
  }
  process.exit(failed ? 1 : 0);
}
RECORDER
ln -f "$NODE_REAL_SH" "$SH_BIN/codegraph$STUB_EXT" 2>/dev/null || cp "$NODE_REAL_SH" "$SH_BIN/codegraph$STUB_EXT"
chmod +x "$SH_BIN/codegraph$STUB_EXT" 2>/dev/null || true

# Identity-query stub (`ps` on POSIX, `powershell.exe` on win32): CG_QUERY_OUT
# feeds a canned command line, CG_QUERY_SLEEP forces a timeout, else it exits
# CG_QUERY_EXIT. Every invocation is appended to CG_QLOG.
write_query_stub() {
    cat > "$1" <<'QSTUB'
#!/usr/bin/env bash
[ -n "${CG_QLOG:-}" ] && printf '%s\n' "$*" >> "$CG_QLOG"
[ -n "${CG_QUERY_SLEEP:-}" ] && sleep "$CG_QUERY_SLEEP"
if [ -n "${CG_QUERY_OUT:-}" ] && [ -f "$CG_QUERY_OUT" ]; then cat "$CG_QUERY_OUT"; exit 0; fi
exit "${CG_QUERY_EXIT:-1}"
QSTUB
    chmod +x "$1"
}
write_query_stub "$SH_QUERY/ps"
write_query_stub "$SH_QUERY/powershell.exe"
write_query_stub "$SH_QUERY_NODE/ps"
# win32 non-zero-exit variant: node rejects PowerShell's own flags and exits 9,
# which is a genuine non-zero external-query failure.
ln -f "$NODE_REAL_SH" "$SH_QUERY_NODE/powershell.exe" 2>/dev/null || cp "$NODE_REAL_SH" "$SH_QUERY_NODE/powershell.exe"

cat > "$TMP_BASE/helpers/codegraph.js" <<'HELPER'
const fs = require("node:fs");
if (process.env.CG_HELPER_PIDFILE) fs.writeFileSync(process.env.CG_HELPER_PIDFILE, String(process.pid));
setInterval(() => {}, 3600000);
HELPER
cp "$TMP_BASE/helpers/codegraph.js" "$TMP_BASE/helpers/impostor.js"

# SIGTERM-deaf stand-in for the escalation case. It keeps the basename
# `codegraph` (identity condition 2) by living in its own subdirectory.
cat > "$TMP_BASE/helpers/sigterm/codegraph.js" <<'STUBBORN'
const fs = require("node:fs");
process.on("SIGTERM", () => {});
if (process.env.CG_HELPER_PIDFILE) fs.writeFileSync(process.env.CG_HELPER_PIDFILE, String(process.pid));
setInterval(() => {}, 3600000);
STUBBORN

cat > "$TMP_BASE/samepath.js" <<'SAMEPATH'
const fs = require("node:fs");
const path = require("node:path");
function norm(p) {
  let r;
  try { r = fs.realpathSync.native(p); } catch (_) { r = path.resolve(p); }
  if (process.platform === "win32") r = r.replace(/\\/g, "/").toLowerCase();
  if (r.length > 3 && /[/\\]$/.test(r)) r = r.slice(0, -1);
  return r;
}
process.stdout.write(norm(process.argv[2]) === norm(process.argv[3]) ? "yes" : "no");
SAMEPATH

# mkdb.js — SSOT for every DB fixture in this suite, used both as a CLI (make_db)
# and as a module (the recording stub's CG_STUB_MAKEDB path). Kinds: absent |
# empty-dir | zero | corrupt | fake-schema | healthy | state-partial |
# state-failed | state-indexing | state-missing | no-nodes | no-schema-versions |
# no-table-<nodes|edges|files|project_metadata|schema_versions>
cat > "$TMP_BASE/mkdb.js" <<'MKDB'
process.removeAllListeners("warning");
const fs = require("node:fs");
const path = require("node:path");
const MAGIC = Buffer.concat([Buffer.from("SQLite format 3", "latin1"), Buffer.from([0])]);
const REQUIRED = ["nodes", "edges", "files", "project_metadata", "schema_versions"];
const DDL = {
  nodes: "create table nodes(id integer primary key, name text)",
  edges: "create table edges(id integer primary key, src integer, dst integer)",
  files: "create table files(id integer primary key, path text)",
  project_metadata: "create table project_metadata(key text primary key, value text, updated_at integer)",
  schema_versions: "create table schema_versions(version integer primary key, applied_at integer)",
};
const STATE = {
  healthy: "complete", "no-nodes": "complete", "no-schema-versions": "complete",
  "state-partial": "partial", "state-failed": "failed", "state-indexing": "indexing",
};
function buildDb(root, kind, payload, keepDir) {
  const dir = path.join(root, ".codegraph");
  const db = path.join(dir, "codegraph.db");
  if (keepDir) {
    ["codegraph.db", "codegraph.db-wal", "codegraph.db-shm"].forEach((f) => {
      fs.rmSync(path.join(dir, f), { force: true });
    });
  } else {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  if (kind === "absent") return;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, ".gitignore"), "*\n");
  if (kind === "empty-dir") return;
  if (kind === "zero") { fs.writeFileSync(db, ""); return; }
  if (kind === "corrupt") {
    const tail = payload || "garbage-that-is-not-a-real-database";
    fs.writeFileSync(db, Buffer.concat([MAGIC, Buffer.from(tail, "latin1")]));
    return;
  }
  let DatabaseSync;
  try { ({ DatabaseSync } = require("node:sqlite")); }
  catch (e) {
    const err = new Error("node:sqlite unavailable: " + e.message);
    err.cgSqliteUnavailable = true;
    throw err;
  }
  const omit = kind.indexOf("no-table-") === 0 ? kind.slice("no-table-".length) : "";
  if (omit && REQUIRED.indexOf(omit) < 0) throw new Error("unknown table to omit: " + omit);
  const d = new DatabaseSync(db);
  try {
    if (kind === "fake-schema") { d.exec("create table foo(a)"); return; }
    REQUIRED.forEach((t) => { if (t !== omit) d.exec(DDL[t]); });
    if (kind !== "no-schema-versions" && omit !== "schema_versions") {
      d.exec("insert into schema_versions values (1,0),(9,0)");
    }
    if (kind !== "no-nodes" && omit !== "nodes") d.exec("insert into nodes values (1,'sym')");
    if (omit === "project_metadata" || kind === "state-missing") return;
    const v = omit ? "complete" : STATE[kind];
    if (!v) throw new Error("unknown fixture kind: " + kind);
    d.exec("insert into project_metadata values ('index_state','" + v + "',0)");
  } finally { d.close(); }
}
module.exports = { buildDb };
if (require.main === module) {
  try { buildDb(process.argv[2], process.argv[3], process.argv[4]); }
  catch (e) { console.error(e.message); process.exit(e.cgSqliteUnavailable ? 3 : 2); }
  process.exit(0);
}
MKDB

# make_db <root-native> <kind> [payload] — payload is the byte tail of `corrupt`.
make_db() {
    local out rc
    out="$("$NODE_EXE" "$MKDB_N" "$1" "$2" "${3:-}" 2>&1)"; rc=$?
    if [ "$rc" -eq 3 ]; then
        fail "DB fixture '$2' — node:sqlite unavailable on $("$NODE_EXE" --version); required, not skippable: $out"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then fail "DB fixture '$2' could not be built: $out"; return 1; fi
    return 0
}

mkroot() {
    local d="$TMP_BASE/roots/$1"
    rm -rf "$d"; mkdir -p "$d"
    printf '%s' "$(to_native "$d")"
}
root_sh() { printf '%s' "$TMP_BASE/roots/$1"; }

# write_env <value|__none__> [extra-line] — the extra line carries the C16
# secret sentinels and the malformed-.env shapes.
write_env() {
    if [ "$1" = "__none__" ]; then rm -f "$TMP_BASE/config/.env"; return 0; fi
    printf 'CODEGRAPH=%s\n' "$1" > "$TMP_BASE/config/.env"
    [ -n "${2:-}" ] && printf '%s\n' "$2" >> "$TMP_BASE/config/.env"
    return 0
}

write_pidfile() {
    mkdir -p "$1/.codegraph"
    printf '%s' "$2" > "$1/.codegraph/daemon.pid"
}
