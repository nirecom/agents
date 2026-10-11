# shellcheck shell=bash
# checkPlanUrlInTurn verdicts: the reply must hold the blob URL when one exists, otherwise the
# plan's local path in any accepted form; nothing is required when the plan cannot be resolved.
# Sourced by ../feature-plan-url-stop-guard.sh inside its unit-check-plan-url case.

IFS= read -r -d '' UNIT_CHECK_JS <<'JS' || true
const DIR = path.join(require("os").homedir(), ".workflow-plans");
const file = (stage) => "s-" + stage + ".md";
const nat = (stage) => path.join(DIR, file(stage));
const fwd = (stage) => fwdOf(nat(stage));
const tilde = (stage) => "~/.workflow-plans/" + file(stage);
const uri = (stage) => uriOf(nat(stage));
const BLOB = "https://github.com/test-owner/test-repo/blob/main/";
const URL_I = BLOB + file("intent");
const URL_O = BLOB + file("outline");
const pub = (stage) => ({
  intent: { url: URL_I, kind: "blob", path: nat("intent") },
  outline: { url: URL_O, kind: "blob", path: nat("outline") },
})[stage] || { reason: "no-artifact" };
const local = (reason) => (stage) => ({ path: nat(stage), reason });
const mixed = (stage) => (stage === "intent" ? pub(stage) : local("not-published")(stage));
const run = (stages, turnText, resolve) => {
  try { return tc.checkPlanUrlInTurn({ stages, turnText, resolve, plansDir: DIR }); } catch (e) { return { threw: e.message }; }
};
const allow = (n, r) => ok(n, !isBlock(r) && !(r && r.threw), show(r));
const block = (n, r) => {
  ok(n, isBlock(r), show(r));
  const reason = r && typeof r.reason === "string" ? r.reason : "";
  ok(n + " — reason has the plan-link prefix", reason.startsWith("[confirm-plan] plan-link:"), show(reason));
  ok(n + " — reason names no URL", !/https?:\/\//.test(reason), show(reason));
  ok(n + " — reason points at bin/plan-link", reason.includes("bin/plan-link"), show(reason));
  ok(n + " — reason carries none of the retired wording", reason !== "" && !/GitHub|Layer [0-9]|never a local path/.test(reason), show(reason));
};

allow("URL exists, URL and local path in the reply -> allow", run(["intent"], "Plan: " + URL_I + " (" + nat("intent") + ")", pub));
allow("URL exists, URL alone without the local path -> allow", run(["intent"], "Plan: " + URL_I, pub));
block("URL exists, local path alone -> block", run(["intent"], "Plan: " + nat("intent"), pub));
block("URL exists, neither in the reply -> block", run(["intent"], "Plan written.", pub));
block("one of two published stages missing -> block", run(["intent", "outline"], "Plan: " + URL_I, pub));
allow("both URLs present -> allow", run(["intent", "outline"], URL_I + " and " + URL_O, pub));
allow("no stages -> allow", run([], "nothing", pub));
block("another stage URL only (intent URL, outline checked) -> block", run(["outline"], "Plan: " + URL_I, pub));
block("another session URL -> block", run(["intent"], "Plan: " + BLOB + "other-intent.md", pub));
block("same file in another repo -> block", run(["intent"], "Plan: https://github.com/test-owner/other-repo/blob/main/s-intent.md", pub));
// The URL must not run on into more URL characters (detail: no URL character after the URL).
block("URL prefix of a longer URL -> block", run(["intent"], "Plan: " + URL_I + ".bak", pub));
allow("URL followed by whitespace -> allow", run(["intent"], "Plan: " + URL_I + "\nNext step.", pub));

for (const reason of ["host-mismatch", "no-project-host", "plan-sync-off", "not-published"]) {
  allow("no URL (" + reason + "), local path in the reply -> allow", run(["intent"], "Plan: " + nat("intent"), local(reason)));
  block("no URL (" + reason + "), neither in the reply -> block", run(["intent"], "Plan written.", local(reason)));
}
allow("no URL, forward-slash path form -> allow", run(["intent"], "Plan: " + fwd("intent"), local("not-published")));
allow("no URL, ~ path form -> allow", run(["intent"], "Plan: " + tilde("intent"), local("not-published")));
allow("no URL, file URI form -> allow", run(["intent"], "Plan: " + uri("intent"), local("not-published")));
block("no URL, a blob URL alone -> block", run(["intent"], "Plan: " + URL_I, local("host-mismatch")));
block("no URL, another stage's local path only -> block", run(["outline"], "Plan: " + nat("intent"), local("not-published")));

allow("URL stage shown by URL, no-URL stage shown by path -> allow", run(["intent", "outline"], URL_I + " and " + nat("outline"), mixed));
block("URL stage shown, no-URL stage missing -> block", run(["intent", "outline"], "Plan: " + URL_I, mixed));
block("no-URL stage shown, URL stage missing -> block", run(["intent", "outline"], "Plan: " + nat("outline"), mixed));

allow("plan file absent (reason only) -> allow", run(["intent"], "Plan written.", () => ({ reason: "no-artifact" })));
allow("resolve throws -> allow", run(["intent"], "Plan written.", () => { throw new Error("boom"); }));
allow("resolve returns nothing -> allow", run(["intent"], "Plan written.", () => null));
JS
tc_report "$(tc_node "$UNIT_CHECK_JS")"
