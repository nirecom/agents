# shellcheck shell=bash
# #2650 endsWithLinkLine of hooks/lib/plan-link-turn-check.js: the final block of a presentation
# turn holds the stage's plan-link line, and any other line in that block is real plan-link output
# (entryLine / renderModelContext shapes), never prose that merely starts with "<stage>: ".
# Sourced by ../feature-plan-url-stop-guard.sh inside its unit-turn-split case.

IFS= read -r -d '' UNIT_ENDS_JS <<'JS' || true
ok("endsWithLinkLine is exported", typeof tc.endsWithLinkLine === "function", typeof tc.endsWithLinkLine);
const PL = require(path.join(path.dirname(process.env.TC_LIB), "plan-link.js"));
const DIR = path.join(require("os").tmpdir(), "ends-with-link-line");
const BLOB = "https://example.invalid/test-owner/test-repo/blob/main/";
const nat = (s) => path.join(DIR, "s-" + s + ".md");
const urlOf = (s) => BLOB + "s-" + s + ".md";
const local = (s) => ({ path: nat(s), reason: PL.REASONS.PLAN_SYNC_OFF });
const pub = (s) => ({ url: urlOf(s), kind: "blob", path: nat(s) });
const own = (s, link, form) => PL.entryLine({ stage: s, url: link.url, path: form || link.path, reason: link.reason });
// rendered(entry) -> the line renderModelContext prints for one entry (its reason text appended).
const rendered = (e) => PL.renderModelContext([e], { when: "confirm" }).split("\n")[1];
const ends = (s, link, text) => { try { return tc.endsWithLinkLine(s, link, text); } catch (e) { return { threw: e.message }; } };

const probe = { stage: "outline", path: nat("outline"), reason: PL.REASONS.NOT_PUBLISHED };
ok("fixture: renderModelContext appends the reason text to a no-URL line",
  rendered(probe) === PL.entryLine(probe) + " — " + PL.REASON_TEXT[PL.REASONS.NOT_PUBLISHED], show(rendered(probe)));

for (const stage of PL.STAGES) {
  const [o1, o2] = PL.STAGES.filter((s) => s !== stage);
  const L = local(stage);
  const P = pub(stage);
  const urlLine = PL.entryLine({ stage: o1, url: urlOf(o1), path: nat(o1) });
  const urlBare = PL.entryLine({ stage: o1, url: urlOf(o1) });
  const pathEntry = { stage: o1, path: nat(o1), reason: PL.REASONS.NOT_PUBLISHED };
  const unavEntry = { stage: o2, reason: PL.REASONS.NO_ARTIFACT };
  const ownSuffixed = rendered({ stage, path: L.path, reason: L.reason });
  const ownWrongText = own(stage, L) + " — " + PL.REASON_TEXT[PL.REASONS.NOT_PUBLISHED];
  const cases = [
    { name: "A1 local-path line alone (native)", link: L, text: "Plan written.\n" + own(stage, L), want: true },
    { name: "A1b local-path line alone (forward-slash)", link: L, text: own(stage, L, fwdOf(L.path)), want: true },
    { name: "A2 URL line alone", link: P, text: "Plan written.\n" + own(stage, P), want: true },
    { name: "A3 then another stage's URL line", link: L, text: own(stage, L) + "\n" + urlLine, want: true },
    { name: "A3b then another stage's bare URL line", link: P, text: own(stage, P) + "\n" + urlBare, want: true },
    { name: "A4 then another stage's local-path line with reason text", link: L, text: own(stage, L) + "\n" + rendered(pathEntry), want: true },
    { name: "A4b then another stage's local-path line", link: L, text: own(stage, L) + "\n" + PL.entryLine(pathEntry), want: true },
    { name: "A5 then another stage's unavailable line", link: L, text: own(stage, L) + "\n" + PL.entryLine(unavEntry), want: true },
    { name: "A5b then another stage's unavailable line with reason text", link: P, text: own(stage, P) + "\n" + rendered(unavEntry), want: true },
    { name: "A6 another stage's line before it", link: L, text: "Plans:\n" + urlLine + "\n" + own(stage, L), want: true },
    { name: "A7 then other-stage prose", link: L, text: own(stage, L) + "\n" + o1 + ": some prose", want: false },
    { name: "A8 then other-stage verdict prose", link: P, text: own(stage, P) + "\n" + o2 + ": looks good", want: false },
    { name: "A9 then same-stage prose", link: L, text: own(stage, L) + "\n" + stage + ": see above", want: false },
    { name: "A10 then plain prose", link: L, text: own(stage, L) + "\nLet me know if you want changes.", want: false },
    { name: "A11 trailing whitespace and blank lines", link: L, text: own(stage, L) + "  \n\n   \n", want: true },
    { name: "A12 only inside a fenced code block", link: L, text: "Plan:\n```\n" + own(stage, L) + "\n```", want: false },
    { name: "A13 then a URL-shaped line running on into prose", link: L, text: own(stage, L) + "\n" + o1 + ": " + urlOf(o1) + " and more text", want: false },
    { name: "A14 then a local-path line with an unknown reason", link: L, text: own(stage, L) + "\n" + o1 + ": `" + nat(o1) + "` (no URL: bogus-reason)", want: false },
    { name: "A15 then a reason-text line running on into prose", link: L, text: own(stage, L) + "\n" + rendered(pathEntry) + " and more", want: false },
    { name: "A16 own local-path line with its reason text alone", link: L, text: "Plan written.\n" + ownSuffixed, want: true },
    { name: "A17 own line with its reason text, then another stage's line", link: L, text: ownSuffixed + "\n" + urlLine, want: true },
    { name: "A18 own line with another reason's text", link: L, text: ownWrongText, want: false },
    { name: "A18b own line with a free-text suffix", link: L, text: own(stage, L) + " — whatever", want: false },
  ];
  for (const c of cases) {
    const got = ends(stage, c.link, c.text);
    ok("endsWithLinkLine [" + stage + "] " + c.name + " -> " + c.want, got === c.want, "got=" + show(got) + " text=" + show(c.text));
  }
}
JS
tc_report "$(tc_node "$UNIT_ENDS_JS")"
