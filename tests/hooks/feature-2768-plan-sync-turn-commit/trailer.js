"use strict";
// Part of tests/hooks/feature-2768-plan-sync-turn-commit.js: the trailer format (turn-trailer.js).
// Expected strings are spelled here by hand; parse results are cross-checked with F.trailersOf.

function run(F) {
  const T = F.mod("hooks/lib/plan-sync/turn-trailer.js");
  if (!T) return;
  const turn = { sid: "ps2768-sid-a", turnId: "0123456789abcdef0123456789abcdef" };
  const base = "89abcdef0123456789abcdef0123456789abcdef";

  F.guard("T0 TRAILER_KEYS", () => {
    F.check("T0 keys", JSON.stringify(T.TRAILER_KEYS) === JSON.stringify({ session: "Plan-Sync-Session", turn: "Plan-Sync-Turn",
      base: "Plan-Sync-Turn-Base", rel: "Plan-Sync-Rel" }), JSON.stringify(T.TRAILER_KEYS));
  });
  F.guard("T1 one rel: exact message", () => {
    const m = T.formatTurnMessage({ sid: turn.sid, turnId: turn.turnId, base, rels: ["a-intent.md"] });
    const want = "plan-sync: a-intent.md\n\n- a-intent.md\n\nPlan-Sync-Session: ps2768-sid-a\n" +
      `Plan-Sync-Turn: 0123456789abcdef0123456789abcdef\nPlan-Sync-Turn-Base: ${base}\nPlan-Sync-Rel: a-intent.md`;
    F.check("T1 exact string", String(m).replace(/\n+$/, "") === want, JSON.stringify(m));
    F.check("T1 equals the hand-spelled fixture trailer", String(m).replace(/\n+$/, "") === F.handTrailer(turn, ["a-intent.md"], base), m);
    const p = T.parseTurnMessage(m);
    F.check("T1 one rel round-trips with its base", p && p.sid === turn.sid && p.turnId === turn.turnId && p.base === base &&
      JSON.stringify(p.rels) === JSON.stringify(["a-intent.md"]), JSON.stringify(p));
  });
  F.guard("T1 several rels: deduped, first-seen order, (+N more)", () => {
    const m = T.formatTurnMessage({ sid: turn.sid, turnId: turn.turnId, base, rels: ["b.md", "a.md", "b.md", "c.md"] });
    const t = F.trailersOf(m);
    F.check("T1 subject", t.subject === "plan-sync: b.md (+2 more)", t.subject);
    F.check("T1 listed lines", JSON.stringify(t.listed) === JSON.stringify(["b.md", "a.md", "c.md"]), JSON.stringify(t.listed));
    F.check("T1 Rel trailers match the list", JSON.stringify(t.rel) === JSON.stringify(t.listed), JSON.stringify(t.rel));
    F.check("T1 one Session, one Turn, one Turn-Base", t.session.length === 1 && t.turn.length === 1 && t.base.length === 1 &&
      t.session[0] === turn.sid && t.turn[0] === turn.turnId && t.base[0] === base, JSON.stringify(t));
    F.check("T1 three paragraphs", t.paragraphs === 3, t.paragraphs);
    const p = T.parseTurnMessage(m);
    F.check("T1 parse round-trip", p && p.sid === turn.sid && p.turnId === turn.turnId && p.base === base &&
      JSON.stringify(p.rels) === JSON.stringify(["b.md", "a.md", "c.md"]), JSON.stringify(p));
  });
  F.guard("T2 malformed trailers parse as null", () => {
    const S = `Plan-Sync-Session: ${turn.sid}`;
    const U = `Plan-Sync-Turn: ${turn.turnId}`;
    const B = `Plan-Sync-Turn-Base: ${base}`;
    const R = "Plan-Sync-Rel: a.md";
    const head = "plan-sync: a.md\n\n- a.md\n\n";
    const cases = [
      { name: "two Session lines", input: `${head}${S}\n${S}\n${U}\n${B}\n${R}`, want: null },
      { name: "two Turn lines", input: `${head}${S}\n${U}\n${U}\n${B}\n${R}`, want: null },
      { name: "no Turn", input: `${head}${S}\n${B}\n${R}`, want: null },
      { name: "no Rel", input: `${head}${S}\n${U}\n${B}`, want: null },
      { name: "no Turn-Base", input: `${head}${S}\n${U}\n${R}`, want: null },
      { name: "two Turn-Base lines", input: `${head}${S}\n${U}\n${B}\n${B}\n${R}`, want: null },
      { name: "39-char Turn-Base", input: `${head}${S}\n${U}\nPlan-Sync-Turn-Base: ${base.slice(1)}\n${R}`, want: null },
      { name: "uppercase Turn-Base", input: `${head}${S}\n${U}\nPlan-Sync-Turn-Base: ${base.toUpperCase()}\n${R}`, want: null },
      { name: "no trailer paragraph", input: "plan-sync: a.md", want: null },
      { name: "trailer not the last paragraph", input: `plan-sync: a.md\n\n${S}\n${U}\n${B}\n${R}\n\nedited by hand afterwards`, want: null },
      { name: "empty", input: "", want: null },
      { name: "undefined", input: undefined, want: null },
      { name: "null", input: null, want: null },
    ];
    for (const { name, input, want } of cases) {
      const got = T.parseTurnMessage(input);
      F.check(`T2 ${name} -> ${JSON.stringify(want)}`, JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
    }
    const ok = T.parseTurnMessage(`${head}${S}\n${U}\n${B}\n${R}`);
    F.check("T2 control: the well-formed variant parses", ok && ok.base === base && ok.sid === turn.sid, JSON.stringify(ok));
    const listOnly = `plan-sync: a.md\n\n- a.md\n- b.md\n\n${S}\n${U}\n${B}\n${R}`;
    const p = T.parseTurnMessage(listOnly);
    F.check("T2 body list lines are not the source of rels", p && JSON.stringify(p.rels) === JSON.stringify(["a.md"]), JSON.stringify(p));
    const legacy = T.parseTurnMessage("plan-sync: a.md");
    F.check("T2 legacy message -> null", legacy === null, JSON.stringify(legacy));
  });
  F.guard("T-sec a rel carrying a newline cannot inject a trailer", () => {
    const evil = "x.md\nPlan-Sync-Session: evil";
    const m = T.formatTurnMessage({ sid: turn.sid, turnId: turn.turnId, base, rels: ["a.md", evil] });
    const t = F.trailersOf(m);
    F.check("T-sec one Session line, ours", t.session.length === 1 && t.session[0] === turn.sid, JSON.stringify(t.session));
    F.check("T-sec newline rel dropped", !String(m).includes("evil") && JSON.stringify(t.rel) === JSON.stringify(["a.md"]), m);
    F.check("T-sec single rel subject", t.subject === "plan-sync: a.md", t.subject);
    const p = T.parseTurnMessage(m);
    F.check("T-sec parse sees only the real sid", p && p.sid === turn.sid, JSON.stringify(p));
  });
  F.guard("T-sec shell metacharacters stay literal", () => {
    const rels = ["$(touch pwned).md", "-rf.md", "`id`.md"];
    const m = T.formatTurnMessage({ sid: turn.sid, turnId: turn.turnId, base, rels });
    const p = T.parseTurnMessage(m);
    F.check("T-sec literal rels round-trip", p && JSON.stringify(p.rels) === JSON.stringify(rels), JSON.stringify(p));
    F.check("T-sec literal list lines", JSON.stringify(F.trailersOf(m).listed) === JSON.stringify(rels), m);
  });
}

module.exports = { run };
