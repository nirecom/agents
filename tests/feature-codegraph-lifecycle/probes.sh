# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle/index-health.js, bin/codegraph-lifecycle/process-identity.js
# Tags: codegraph, lifecycle, probes, sqlite, tokenizer, scope:issue-specific
# Oracles for tests/feature-codegraph-lifecycle.sh. They observe fixture and
# post-run state independently of the CLI under test, so a case can prove its
# own precondition held instead of passing vacuously. Sourced by harness.sh.

# dbprobe.js — reports what `<root>/.codegraph/codegraph.db` actually is, as
# `key=value` pairs. `open=fail openerr=not-a-database` is the branch L9c needs.
cat > "$TMP_BASE/dbprobe.js" <<'DBPROBE'
process.removeAllListeners("warning");
const fs = require("node:fs");
const path = require("node:path");
const MAGIC = Buffer.concat([Buffer.from("SQLite format 3", "latin1"), Buffer.from([0])]);
const db = path.join(process.argv[2], ".codegraph", "codegraph.db");
const out = { exists: "no", size: "-", header: "-", open: "-", openerr: "-", tables: "-", versions: "-", nodes: "-", state: "-" };
let st = null;
try { st = fs.statSync(db); } catch (_) {}
function readHead() {
  const head = Buffer.alloc(16);
  const fd = fs.openSync(db, "r");
  try { fs.readSync(fd, head, 0, 16, 0); } finally { fs.closeSync(fd); }
  return head;
}
if (st && st.isFile()) {
  out.exists = "yes";
  out.size = String(st.size);
  try { out.header = readHead().equals(MAGIC) ? "ok" : "bad"; }
  catch (e) { out.header = "unreadable"; out.openerr = String(e.code || "read-error"); }
  let DatabaseSync = null;
  try { ({ DatabaseSync } = require("node:sqlite")); } catch (_) { out.open = "unavailable"; }
  if (DatabaseSync && out.header !== "unreadable") {
    let d = null;
    try {
      d = new DatabaseSync(db, { readOnly: true });
      const t = d.prepare("select name from sqlite_master where type='table'").all().map((r) => r.name).sort();
      out.open = "ok";
      out.tables = t.length ? t.join(",") : "none";
      if (t.indexOf("schema_versions") >= 0) out.versions = String(d.prepare("select count(*) as c from schema_versions").get().c);
      if (t.indexOf("nodes") >= 0) out.nodes = String(d.prepare("select count(*) as c from nodes").get().c);
      if (t.indexOf("project_metadata") >= 0) {
        const r = d.prepare("select value as v from project_metadata where key='index_state'").get();
        out.state = r ? String(r.v) : "none";
      }
    } catch (e) {
      out.open = "fail";
      out.openerr = /file is not a database/i.test(String(e && e.message)) ? "not-a-database" : String(e && e.code);
    } finally { try { if (d) d.close(); } catch (_) {} }
  }
}
process.stdout.write(Object.keys(out).map((k) => k + "=" + out[k]).join(" "));
DBPROBE

# tokprobe.js — drives the tokenizer and the identity matcher directly. Every
# failure mode (missing module, missing export, throw) becomes an ERROR:* value
# so the assertion reports it rather than the row silently disappearing.
cat > "$TMP_BASE/tokprobe.js" <<'TOKPROBE'
process.removeAllListeners("warning");
const mode = process.argv[3];
let mod = null;
function emit(s) { process.stdout.write(s); process.exit(0); }
try { mod = require(process.argv[2]); } catch (e) { emit("ERROR:module-not-loadable:" + (e.code || "throw")); }
if (typeof mod.tokenizeCommandLine !== "function") emit("ERROR:tokenizeCommandLine-not-exported");
let toks;
try { toks = mod.tokenizeCommandLine(process.argv[4]); } catch (e) { emit("ERROR:tokenize-threw"); }
if (!Array.isArray(toks)) emit("ERROR:tokenize-not-an-array");
if (mode === "tokens") emit(toks.map((t) => "[" + String(t) + "]").join(""));
if (typeof mod.isDaemonForRoot !== "function") emit("ERROR:isDaemonForRoot-not-exported");
let verdict;
try { verdict = mod.isDaemonForRoot(toks, process.argv[5]); } catch (e) { emit("ERROR:match-threw"); }
emit(verdict === true ? "kill" : "no-kill");
TOKPROBE

# readprobe.js — "can this process read the file at all", the positive control
# for the permission-denied case (chmod is a no-op for root and on win32).
cat > "$TMP_BASE/readprobe.js" <<'READPROBE'
const fs = require("node:fs");
try { fs.readFileSync(process.argv[2]); process.stdout.write("readable"); }
catch (e) { process.stdout.write("denied:" + String(e.code)); }
READPROBE

# killprobe.js — reports the errno process.kill(pid, 0) raises, so the EPERM
# case can prove the kernel really produced EPERM before asserting on it.
cat > "$TMP_BASE/killprobe.js" <<'KILLPROBE'
try { process.kill(Number(process.argv[2]), 0); process.stdout.write("ok"); }
catch (e) { process.stdout.write(String(e.code)); }
KILLPROBE

DBPROBE_N="$BASE/dbprobe.js"; TOKPROBE_N="$BASE/tokprobe.js"
READPROBE_N="$BASE/readprobe.js"; KILLPROBE_N="$BASE/killprobe.js"

# node_probe <script-native> [args...] — the one argv transport every probe below
# uses. On Git Bash / MSYS2 the runtime rewrites POSIX-looking argv entries before
# the native node.exe sees them: `--path=/r` arrives as `--path=R:/`, and a
# `/opt/...` token arrives prefixed with the Git installation root — so a probe
# asserting on the tokens it passed in can never match. These two variables switch
# that rewriting off for the child. The hazard belongs to the transport, not to any
# one probe, so the guard sits here; both variables are inert on Linux and macOS,
# which keeps the transport identical on every platform (CPR-UNV).
node_probe() { MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$NODE_EXE" "$@"; }

db_probe() { node_probe "$DBPROBE_N" "$1"; }
db_field() { db_probe "$1" | tr ' ' '\n' | grep -m1 "^$2=" | cut -d= -f2-; }
file_read_state() { node_probe "$READPROBE_N" "$1"; }
kill_probe() { node_probe "$KILLPROBE_N" "$1"; }
tok_tokens() { node_probe "$TOKPROBE_N" "$IDENTITY_N" tokens "$1"; }
tok_verdict() { node_probe "$TOKPROBE_N" "$IDENTITY_N" verdict "$1" "$2"; }

# assert_stub_db_built <name> — the recording stub's DB builder did not error
# out. Without it, a success-path case could assert on a DB the stub silently
# failed to write and read the resulting `invalid` verdict as the CLI's fault.
assert_stub_db_built() {
    assert_eq "$1 — the stub's DB build reported no failure" "0" "$(stub_db_failures)"
}

# assert_db_valid <name> <root-native> — the whole healthy definition, so a
# success-path case fails when the stub produced only a partial index.
assert_db_valid() {
    local name="$1" p; p="$(db_probe "$2")"
    assert_eq "$name — DB header is the 16-byte SQLite magic" "header=ok" "$(printf '%s' "$p" | tr ' ' '\n' | grep -m1 '^header=')"
    assert_eq "$name — DB opens read-only" "open=ok" "$(printf '%s' "$p" | tr ' ' '\n' | grep -m1 '^open=')"
    assert_eq "$name — every required table is present" "edges,files,nodes,project_metadata,schema_versions" "$(db_field "$2" tables)"
    assert_eq "$name — schema_versions carries migrations" "2" "$(db_field "$2" versions)"
    assert_eq "$name — nodes is non-empty" "1" "$(db_field "$2" nodes)"
    assert_eq "$name — index_state is complete" "complete" "$(db_field "$2" state)"
}
