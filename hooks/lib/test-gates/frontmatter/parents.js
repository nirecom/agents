"use strict";
// The parent baselines the --staged frontmatter check judges against (#2812; ports ctf_parents_load /
// _ctf_par_find of bin/check-test-frontmatter/self-impl.sh). parentsIo(rels, recordOf, readBlobs) ->
// parents(rel) -> { inParent, same, heads: [Buffer], base: Buffer | null }. recordOf(rel) gives the
// merge-parents record; readBlobs(oids) a Map oid -> Buffer (one batch; a throw retries per oid).
// A 3-way needs every baseline it names; short of one, head1 alone (or none: judged as new).

function readAll(oids, readBlobs) {
  if (oids.length === 0) return new Map();
  try {
    return readBlobs(oids);
  } catch {
    const map = new Map();
    for (const o of oids) {
      try {
        const one = readBlobs([o]);
        if (one.has(o)) map.set(o, one.get(o));
      } catch {
        // An unreadable baseline is left out; the caller narrows the judgment.
      }
    }
    return map;
  }
}

function slotsOf(r) {
  return r.same === 1 ? [] : [r.b1, r.b2, r.base].filter(Boolean);
}

function parentsIo(rels, recordOf, readBlobs) {
  const recs = new Map(rels.map((rel) => [rel, recordOf(rel)]));
  const blobs = readAll([...new Set([...recs.values()].flatMap(slotsOf))], readBlobs);
  return (rel) => {
    let r = recs.get(rel);
    if (!r) {
      r = recordOf(rel);
      recs.set(rel, r);
      for (const [o, b] of readAll(slotsOf(r).filter((o) => !blobs.has(o)), readBlobs)) blobs.set(o, b);
    }
    const res = { inParent: r.in_parent === 1, same: r.same === 1, heads: [], base: null };
    if (res.same) return res;
    const h1 = r.b1 ? blobs.get(r.b1) : null;
    const h2 = r.b2 ? blobs.get(r.b2) : null;
    const b = r.base ? blobs.get(r.base) : null;
    if (h1) res.heads.push(h1);
    if (h1 && h2 && (!r.base || b)) {
      res.heads.push(h2);
      res.base = b || null;
    }
    return res;
  };
}

module.exports = { parentsIo, readAll, slotsOf };
