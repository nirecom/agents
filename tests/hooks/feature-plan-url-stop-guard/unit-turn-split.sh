# shellcheck shell=bash
# #2513 turn-split helpers of hooks/lib/plan-link-turn-check.js: the last text block, the previous
# turn, a plan rewrite in this turn, CONFIRM-free stage selection, caller-supplied reasons and the
# inline-code rule. Sourced by ../feature-plan-url-stop-guard.sh inside its unit-turn-split case.

IFS= read -r -d '' UNIT_SPLIT_JS <<'JS' || true
const eq = (n, got, want) => ok(n, show(got) === show(want), "got=" + show(got) + " want=" + show(want));
const has = (n, f) => ok(n + " is exported", typeof tc[f] === "function", typeof tc[f]);
["lastTextBlockOf", "previousTurnEntriesFromLines", "currentTurnWritesStage"].forEach((f) => has(f, f));

const BLOB = "https://example.invalid/test-owner/test-repo/blob/main/";
const DIR = path.join(require("os").tmpdir(), "turn-split-plans");
const nat = (stage) => path.join(DIR, "s-" + stage + ".md");
const pub = () => ({ url: BLOB + "s-intent.md", kind: "blob", path: nat("intent") });
const local = () => ({ path: nat("intent"), reason: "plan-sync-off" });
const run = (o) => { try { return tc.checkPlanUrlInTurn(o); } catch (e) { return { threw: e.message }; } };
const call = (f, ...a) => { try { return tc[f](...a); } catch (e) { return { threw: e.message }; } };

eq("lastTextBlockOf — last text item of the turn, across entries",
  call("lastTextBlockOf", [U("go"), A(T("first"), T("second")), R(), A(T("LAST"), B("ls"))]), "LAST");
eq("lastTextBlockOf — two blocks in the final entry -> the second", call("lastTextBlockOf", [U("go"), A(T("Plan: " + BLOB), T("Done."))]), "Done.");

const lines = [U("first"), A(T("OLDEST")), U("second"), A(T("PREV-TEXT")), R(), U("third"), A(B("echo x"))].map((e) => JSON.stringify(e));
const prev = call("previousTurnEntriesFromLines", lines);
ok("previousTurnEntriesFromLines — holds the previous turn", JSON.stringify(prev).includes("PREV-TEXT"), show(prev));
ok("previousTurnEntriesFromLines — excludes the turn before it", Array.isArray(prev) && !JSON.stringify(prev).includes("OLDEST"), show(prev));
ok("previousTurnEntriesFromLines — excludes the current turn", Array.isArray(prev) && !JSON.stringify(prev).includes("echo x"), show(prev));
const metaLines = [U("first"), A(T("PRESENTED")), UMETA("caveat"), UCOMPACT("summary"), A(B("echo x"))].map((e) => JSON.stringify(e));
const metaPrev = call("previousTurnEntriesFromLines", metaLines);
ok("previousTurnEntriesFromLines — isMeta / compact summary open no turn (no previous turn)",
  (metaPrev == null || Array.isArray(metaPrev)) && !JSON.stringify(metaPrev || []).includes("PRESENTED"), show(metaPrev));
const turnText = call("collectTurnAssistantText", [U("first"), A(T("BEFORE-META")), UMETA("caveat"), A(T("AFTER-META"))]);
ok("isRealUserPrompt — an isMeta entry does not cut the turn", String(turnText).includes("BEFORE-META"), show(turnText));

const P = nat("intent");
for (const name of ["Write", "Edit", "MultiEdit"]) {
  eq("currentTurnWritesStage — " + name + " on the plan -> true", call("currentTurnWritesStage", [U("ok"), A(W(P, name))], P), true);
}
eq("currentTurnWritesStage — Write on another file -> false", call("currentTurnWritesStage", [U("ok"), A(W(nat("outline")))], P), false);
eq("currentTurnWritesStage — Read of the plan -> false",
  call("currentTurnWritesStage", [U("ok"), A({ type: "tool_use", id: "t4", name: "Read", input: { file_path: P } })], P), false);

const st = (markers, turnEntries, includeConfirm) => {
  const r = call("stagesToCheck", { markers, turnEntries, includeConfirm });
  return Array.isArray(r) ? [...r].sort() : r;
};
eq("stagesToCheck includeConfirm:false — CONFIRM_OUTLINE only -> []", st([], [A(C("outline"), S("make-detail-plan"))], false), []);
eq("stagesToCheck includeConfirm:false — marker intent + CONFIRM_OUTLINE -> [intent]", st([{ suffix: "intent" }], [A(C("outline"))], false), ["intent"]);
eq("stagesToCheck includeConfirm omitted — CONFIRM_OUTLINE still counts", st([], [A(C("outline"))], undefined), ["outline"]);

let seen = null;
const custom = run({ stages: ["intent"], turnText: "nothing", resolve: pub, reasonFor: (m) => { seen = m; return "CUSTOM-REASON"; } });
ok("reasonFor — its text is the block reason", isBlock(custom) && custom.reason === "CUSTOM-REASON", show(custom));
ok("reasonFor — receives the missing stages", JSON.stringify(seen) === JSON.stringify(["intent"]), show(seen));
const dflt = run({ stages: ["intent"], turnText: "nothing", resolve: pub });
ok("reasonFor omitted — the Stop reason is kept", isBlock(dflt) && String(dflt.reason).startsWith("[confirm-plan] plan-link:"), show(dflt));

ok("backtick before the URL -> not shown (block)", isBlock(run({ stages: ["intent"], turnText: "Plan: `" + BLOB + "s-intent.md`", resolve: pub })), "allowed");
ok("bare URL followed by a backticked path -> shown (allow)",
  !isBlock(run({ stages: ["intent"], turnText: "intent: " + BLOB + "s-intent.md (`" + P + "`)", resolve: pub })), "blocked");
ok("backticked local path, no URL -> shown (allow)",
  !isBlock(run({ stages: ["intent"], turnText: "intent: `" + P + "` (no URL: plan-sync-off)", resolve: local })), "blocked");
ok("backticked forward-slash path, no URL -> shown (allow)",
  !isBlock(run({ stages: ["intent"], turnText: "intent: `" + fwdOf(P) + "`", resolve: local })), "blocked");

for (const stage of ["intent", "outline", "detail"]) {
  const SP = nat(stage);
  const url = BLOB + "s-" + stage + ".md";
  const res = () => ({ url, kind: "blob", path: SP });
  const blocks = (n, text, resolve) => ok(stage + " " + n + " -> block", isBlock(run({ stages: [stage], turnText: text, resolve: resolve || res })), "allowed");
  const allows = (n, text, resolve) => ok(stage + " " + n + " -> allow", !isBlock(run({ stages: [stage], turnText: text, resolve: resolve || res })), "blocked");
  const fl = (stage2) => ({ path: nat(stage2), reason: "plan-sync-off" });
  blocks("C3 URL only inside a ``` fence", "Plan:\n```\n" + url + "\n```");
  blocks("C3 URL only inside a ~~~ fence", "Plan:\n~~~\n" + url + "\n~~~");
  blocks("C3 URL inside an unclosed fence", "Plan:\n```\n" + url);
  blocks("C3 local path only inside a ``` fence", "Plan:\n```\n" + SP + "\n```", () => fl(stage));
  blocks("C3 local path only inside a ~~~ fence", "Plan:\n~~~\n" + SP + "\n~~~", () => fl(stage));
  blocks("C3 local path inside an unclosed fence", "Plan:\n```\n" + SP, () => fl(stage));
  allows("C3 URL outside a fence plus a fenced copy", url + "\n```\n" + url + "\n```");
  allows("C3 inline-code local path (regression guard)", "Plan: `" + SP + "`", () => fl(stage));
  blocks("C3 URL right after a backtick (regression guard)", "Plan: `" + url + "`");

  // CommonMark inline code spans: a URL inside a span opened earlier on the line is not shown.
  const spanCases = [
    { name: "span URL inside a single-backtick span opened earlier", text: "Plan: `See " + url + "`", want: "block" },
    { name: "span URL inside a double-backtick span", text: "Plan: ``" + url + " x``", want: "block" },
    { name: "span opened before other text, URL, closed later", text: "`open " + url + " close`", want: "block" },
    { name: "span URL after a closed span on the same line", text: "`a` " + url, want: "allow" },
    { name: "span unmatched lone backtick earlier is literal", text: "it`s " + url, want: "allow" },
    { name: "span bare URL with a separate code span after it", text: url + " `code`", want: "allow" },
  ];
  for (const c of spanCases) (c.want === "block" ? blocks : allows)(c.name, c.text);

  const BASH = (command) => ({ type: "tool_use", id: "t5", name: "Bash", input: { command } });
  const writes = (n, item, want) => eq(stage + " C1 " + n, call("currentTurnWritesStage", [U("ok"), A(item)], SP), want);
  const base = "s-" + stage + ".md";
  const other = stage === "intent" ? "outline" : "intent";
  writes("Bash writing the basename -> true", BASH("printf x > " + DIR + "/" + base), true);
  writes("mixed-case basename -> true", BASH("printf x > " + DIR + "/" + base.toUpperCase()), true);
  writes("Windows backslash path -> true", BASH("copy nul " + DIR.replace(/\//g, "\\") + "\\" + base), true);
  writes("Read on the artifact -> false", { type: "tool_use", id: "t6", name: "Read", input: { file_path: SP } }, false);
  writes("Grep naming the artifact -> false", { type: "tool_use", id: "t7", name: "Grep", input: { pattern: base } }, false);
  writes("Bash touching a different stage -> false", BASH("printf x > " + DIR + "/s-" + other + ".md"), false);
  writes("CONFIRM echo itself -> false", C(stage), false);
  writes("CONFIRM echo mentioning the basename -> false", BASH('echo "<<WORKFLOW_CONFIRM_' + stage.toUpperCase() + ': approve ' + base + '>>"'), false);
}
JS
tc_report "$(tc_node "$UNIT_SPLIT_JS")"
