"use strict";
// Private case body of tests/hooks/feature-2936-receipt-recovery.js (consume-turn-markers-before):
// consumeTurnMarkersBefore unlinks only the markers created before the iso, never throws, and leaves
// markers whose created_at is missing or broken. The caller pins the isolation before requiring it.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const R = require("../feature-2729-presentation-receipt/fixture");
const P = require("./fixture");

function consumeBefore() {
  const TM = P.TM();
  assert.equal(typeof TM.consumeTurnMarkersBefore, "function", "consumeTurnMarkersBefore is exported");
  const sid = R.uuidSid(9599);
  const t = Date.now() - 30000;
  const iso = (ms) => new Date(t + ms).toISOString();
  const mk = (created) => TM.writeTurnMarker(sid, { session_id: sid, absPath: "x", suffix: "outline", ts: t, created_at: created });
  mk(iso(-1000));
  mk(iso(0));
  mk(iso(1000));
  const noTime = mk(iso(-5000));
  fs.writeFileSync(noTime, JSON.stringify({ session_id: sid, absPath: "x", suffix: "outline", ts: t }));
  const badTime = mk(iso(-5000));
  fs.writeFileSync(badTime, JSON.stringify({ session_id: sid, absPath: "x", suffix: "outline", ts: t, created_at: "not-a-time" }));
  TM.consumeTurnMarkersBefore(sid, iso(0));
  const left = TM.peekTurnMarkers(sid).map((m) => String(m.created_at)).sort();
  assert.deepEqual(left, [iso(0), iso(1000), "not-a-time", "undefined"].sort());
  const real = fs.unlinkSync;
  fs.unlinkSync = () => { throw Object.assign(new Error("EPERM"), { code: "EPERM" }); };
  try {
    assert.doesNotThrow(() => TM.consumeTurnMarkersBefore(sid, iso(5000)));
  } finally {
    fs.unlinkSync = real;
  }
  assert.equal(TM.peekTurnMarkers(sid).length, 4, "an unlink failure leaves the marker");
  for (const bad of ["../evil", "", 42, null]) assert.doesNotThrow(() => TM.consumeTurnMarkersBefore(bad, iso(5000)));
  assert.equal(TM.peekTurnMarkers(sid).length, 4, "an invalid sid touches nothing");
}

module.exports = { consumeBefore };
