# shellcheck shell=bash
# #2729 inTrailingLinkRun / shownInTurn of hooks/lib/plan-link-turn-check.js: the last text block
# closes on a run of plan-link lines (entryLine / renderModelContext shapes) that holds the stage's
# line; shownInTurn looks at every assistant text item of the current turn. The link argument is
# the plan-link result plus its stage. Sourced by ../feature-plan-url-stop-guard.sh.

IFS= read -r -d '' UNIT_RUN_JS <<'JS' || true
["inTrailingLinkRun", "shownInTurn"].forEach((f) => ok(f + " is exported", typeof tc[f] === "function", typeof tc[f]));
const PL = require(path.join(path.dirname(process.env.TC_LIB), "plan-link.js"));
const DIR = path.join(require("os").tmpdir(), "trailing-link-run");
const BLOB = "https://example.invalid/test-owner/test-repo/blob/main/";
const nat = (s) => path.join(DIR, "s-" + s + ".md");
const urlOf = (s) => BLOB + "s-" + s + ".md";
const local = (s) => ({ stage: s, path: nat(s), reason: PL.REASONS.PLAN_SYNC_OFF });
const pub = (s) => ({ stage: s, url: urlOf(s), kind: "blob", path: nat(s) });
const own = (link, form) => PL.entryLine({ stage: link.stage, url: link.url, path: form || link.path, reason: link.reason });
// rendered(entry) -> the line renderModelContext prints for one entry (its reason text appended).
const rendered = (e) => PL.renderModelContext([e], { when: "confirm" }).split("\n")[1];
const run = (text, link) => { try { return tc.inTrailingLinkRun(text, link); } catch (e) { return { threw: e.message }; } };
const QUESTION = "Shall I proceed with this plan?";

// The three cases the #2729 plan names (stage 2 step 4).
const I = pub("intent");
const O = pub("outline");
const twoLines = "Both plans are ready.\n" + own(I) + "\n" + own(O);
ok("two trailing link lines -> the first is in the run", run(twoLines, I) === true, show(run(twoLines, I)));
ok("two trailing link lines -> the second is in the run", run(twoLines, O) === true, show(run(twoLines, O)));
const linkThenQ = "Plan:\n" + own(I) + "\n" + QUESTION;
ok("link line followed by a question -> false", run(linkThenQ, I) === false, show(run(linkThenQ, I)));
const earlier = "Plans:\n" + own(I) + "\n" + QUESTION + "\n" + own(O);
ok("earlier link line followed by a question, then another link line -> the earlier is false", run(earlier, I) === false, show(run(earlier, I)));
ok("earlier link line followed by a question, then another link line -> the trailing one is true", run(earlier, O) === true, show(run(earlier, O)));

for (const stage of PL.STAGES) {
  const [o1, o2] = PL.STAGES.filter((s) => s !== stage);
  const L = local(stage);
  const P = pub(stage);
  const urlLine = PL.entryLine({ stage: o1, url: urlOf(o1), path: nat(o1) });
  const urlBare = PL.entryLine({ stage: o1, url: urlOf(o1) });
  const pathEntry = { stage: o1, path: nat(o1), reason: PL.REASONS.NOT_PUBLISHED };
  const unavEntry = { stage: o2, reason: PL.REASONS.NO_ARTIFACT };
  const ownSuffixed = rendered({ stage, path: L.path, reason: L.reason });
  const ownWrongText = own(L) + " — " + PL.REASON_TEXT[PL.REASONS.NOT_PUBLISHED];
  const cases = [
    { name: "A1 local-path line alone (native)", link: L, text: "Plan written.\n" + own(L), want: true },
    { name: "A1b local-path line alone (forward-slash)", link: L, text: own(L, fwdOf(L.path)), want: true },
    { name: "A2 URL line alone", link: P, text: "Plan written.\n" + own(P), want: true },
    { name: "A3 then another stage's URL line", link: L, text: own(L) + "\n" + urlLine, want: true },
    { name: "A3b then another stage's bare URL line", link: P, text: own(P) + "\n" + urlBare, want: true },
    { name: "A4 then another stage's local-path line with reason text", link: L, text: own(L) + "\n" + rendered(pathEntry), want: true },
    { name: "A4b then another stage's local-path line", link: L, text: own(L) + "\n" + PL.entryLine(pathEntry), want: true },
    { name: "A5 then another stage's unavailable line", link: L, text: own(L) + "\n" + PL.entryLine(unavEntry), want: true },
    { name: "A5b then another stage's unavailable line with reason text", link: P, text: own(P) + "\n" + rendered(unavEntry), want: true },
    { name: "A6 another stage's line before it", link: L, text: "Plans:\n" + urlLine + "\n" + own(L), want: true },
    { name: "A6b blank lines between the link lines", link: L, text: own(L) + "\n\n" + urlLine, want: true },
    { name: "A7 then other-stage prose", link: L, text: own(L) + "\n" + o1 + ": some prose", want: false },
    { name: "A8 then other-stage verdict prose", link: P, text: own(P) + "\n" + o2 + ": looks good", want: false },
    { name: "A9 then same-stage prose", link: L, text: own(L) + "\n" + stage + ": see above", want: false },
    { name: "A10 then plain prose", link: L, text: own(L) + "\nLet me know if you want changes.", want: false },
    { name: "A11 trailing whitespace and blank lines", link: L, text: own(L) + "  \n\n   \n", want: true },
    { name: "A12 only inside a fenced code block", link: L, text: "Plan:\n```\n" + own(L) + "\n```", want: false },
    { name: "A13 then a URL-shaped line running on into prose", link: L, text: own(L) + "\n" + o1 + ": " + urlOf(o1) + " and more text", want: false },
    { name: "A14 then a local-path line with an unknown reason", link: L, text: own(L) + "\n" + o1 + ": `" + nat(o1) + "` (no URL: bogus-reason)", want: false },
    { name: "A15 then a reason-text line running on into prose", link: L, text: own(L) + "\n" + rendered(pathEntry) + " and more", want: false },
    { name: "A16 own local-path line with its reason text alone", link: L, text: "Plan written.\n" + ownSuffixed, want: true },
    { name: "A17 own line with its reason text, then another stage's line", link: L, text: ownSuffixed + "\n" + urlLine, want: true },
    { name: "A18 own line with another reason's text", link: L, text: ownWrongText, want: false },
    { name: "A18b own line with a free-text suffix", link: L, text: own(L) + " — whatever", want: false },
    { name: "A19 only another stage's line in the run", link: L, text: own(L) + "\n" + QUESTION + "\n" + urlLine, want: false },
  ];
  for (const c of cases) {
    const got = run(c.text, c.link);
    ok("inTrailingLinkRun [" + stage + "] " + c.name + " -> " + c.want, got === c.want, "got=" + show(got) + " text=" + show(c.text));
  }
}

// shownInTurn(link, entries): every assistant text item of the current turn, outside tool I/O.
const S1 = pub("outline");
const sit = (entries, ...link) => { try { return tc.shownInTurn(link.length ? link[0] : S1, entries); } catch (e) { return { threw: e.message }; } };
ok("shownInTurn — link in an earlier entry of the turn -> true",
  sit([U("go"), A(T("Summary: " + S1.url + " covers it."), B("ls")), R(), A(T("Next step."))]) === true, "not true");
ok("shownInTurn — link in the last text block mid-text -> true", sit([U("go"), A(T("See " + S1.url + " then more prose."))]) === true, "not true");
ok("shownInTurn — link only in the previous turn -> false",
  sit([U("first"), A(T("Plan: " + S1.url)), U("second"), A(T("Updated."))]) === false, "not false");
ok("shownInTurn — link only in tool input and tool_result -> false",
  sit([U("go"), A(T("Running."), B("echo " + S1.url)), RT(S1.url), A(T("Done."))]) === false, "not false");
ok("shownInTurn — link nowhere -> false", sit([U("go"), A(T("The outline plan is written."))]) === false, "not false");
const lp = local("detail");
ok("shownInTurn — no-URL plan, local path earlier in the turn -> true",
  sit([U("go"), A(T("Detail at `" + lp.path + "` is done."), B("ls")), R(), A(T("Moving on."))], lp) === true, "not true");
ok("shownInTurn — null link -> null (nothing to show)", sit([U("go"), A(T("x"))], null) === null, show(sit([U("go"), A(T("x"))], null)));
JS
tc_report "$(tc_node "$UNIT_RUN_JS")"
