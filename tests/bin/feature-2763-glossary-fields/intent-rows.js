"use strict";
// Test bodies for tests/bin/feature-2763-glossary-fields.js (#2763 S2-4, S2-6): checkIntentRows'
// redefine-no-change with the fields, and the intent-row digest carrying the fields. Holds no case
// markers; the entrypoint wraps each body in its own test() inside a case.

const assert = require("node:assert");
const crypto = require("node:crypto");
const path = require("node:path");
const X = require("./fixtures");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const load = (rel) => require(path.join(ROOT, rel));
const USER = "docs/glossary/user.md";
const INTERNAL = "docs/glossary/internal.md";
const PLAIN = X.entry("statusline", "A line.");
const WITH_ID = X.entry("statusline", "A line.", { identifiers: ["status-line"] });

function setsOf(userEntry) {
  const p = load("bin/lib/glossary-provenance.js");
  const files = { [USER]: X.file("user", [userEntry]), [INTERNAL]: X.file("internal", [X.entry("kilo", "K.")]) };
  return p.readTermSets((f) => files[f], [USER, INTERNAL]);
}
// A parsed intent row: V3 rows carry the field arrays, V1 / V2 rows leave them undefined.
const v3Row = (identifiers, homographs) => ({ term: "statusline", category: "user", operation: "redefine",
  definition: "A line.", identifiers, homographs });
const v2Row = () => ({ term: "statusline", category: "user", operation: "redefine", definition: "A line." });
const reasons = (sets, row) => load("bin/lib/glossary-provenance.js").checkIntentRows(sets, [row]).map((o) => o.reason);

// S2-4: a V3 row is a no-change only when the Definition and the fields both match; a V1 / V2 row
// cannot state the fields, so it is compared on the Definition alone.
function redefineNoChange() {
  assert.deepStrictEqual(reasons(setsOf(PLAIN), v3Row(["status-line"], [])), [],
    "V3 row, same Definition, new Identifier: a real change");
  assert.deepStrictEqual(reasons(setsOf(WITH_ID), v3Row([], [])), [],
    "V3 row, same Definition, Identifier cleared: a real change");
  assert.deepStrictEqual(reasons(setsOf(PLAIN), v3Row([], [])), ["redefine-no-change"],
    "V3 row, same Definition, same (empty) fields");
  assert.deepStrictEqual(reasons(setsOf(WITH_ID), v3Row(["status-line"], [])), ["redefine-no-change"],
    "V3 row, same Definition, same Identifier");
  assert.deepStrictEqual(reasons(setsOf(WITH_ID), v2Row()), ["redefine-no-change"],
    "V2 row, same Definition (the fields are not compared)");
}

// S2-6: the digest of the intent rows moves when a V3 row changes its fields; a V2 row keeps the
// pre-change formula (term, category, operation, Definition) so existing records stay valid.
function rowsDigestFields() {
  const { intentRowsOf } = load("hooks/workflow-state/glossary-check/scope/sources.js");
  const body = (ids) => X.v3([X.v3Row("statusline", "user", "redefine", "A line.", ids, [])]);
  const a = intentRowsOf(null, body(["status-line"]));
  const b = intentRowsOf(null, body(["status_line"]));
  // The fields must not leak into the Definition (a V1 fallback would move the digest by itself).
  assert.deepStrictEqual(a.rows.map((r) => [r.operation, r.definition, r.identifiers]),
    [["redefine", "A line.", ["status-line"]]], "the V3 row is parsed with its fields apart");
  assert.notStrictEqual(a.digest, b.digest, "rows differing only in Identifier have different digests");
  assert.strictEqual(intentRowsOf(null, body(["status-line"])).digest, a.digest, "the same body gives the same digest");
  const homo = (hs) => intentRowsOf(null, X.v3([X.v3Row("statusline", "user", "redefine", "A line.", ["status-line"], hs)])).digest;
  assert.notStrictEqual(homo(["statuses"]), homo(["stati"]), "rows differing only in Homographs have different digests");
  assert.notStrictEqual(homo(["statuses"]), a.digest, "a Homographs value moves the digest from the empty one");
  const v2 = intentRowsOf(null, X.v2([X.v2Row("statusline", "user", "redefine", "A line.")]));
  const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
  const old = sha(JSON.stringify([JSON.stringify(["statusline", "user", "redefine", "A line."])]));
  assert.strictEqual(v2.digest, old, "a V2 row digest equals the pre-change formula");
}

module.exports = { redefineNoChange, rowsDigestFields };
