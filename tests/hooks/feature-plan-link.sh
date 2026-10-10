#!/usr/bin/env bash
# tests/hooks/feature-plan-link.sh
# Tests: hooks/lib/plan-link.js
# Tags: plan-link, plan-sync, blob-url, additional-context, unit, TL1, scope:common, path-leak
# hooks/lib/plan-link.js: the one place that turns a plan artifact into the model-facing
# link (blob URL) or a reason code, and renders the additionalContext text for hooks.
# Model-facing output never carries a local absolute path, the plans dir, or ~/.workflow-plans.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$AGENTS_DIR/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
trap psf_cleanup EXIT
PL_LIB="$(psf_np "$AGENTS_DIR/hooks/lib/plan-link.js")"
PL_SID="0d2c5d7e-1111-4222-8333-444455556666"
PL_BLOB="https://github.com/test-owner/test-repo/blob/main"

# pl_node <js> [args...] — runs <js> with `pl` = hooks/lib/plan-link.js and `ok(name, cond, detail)`
# collecting "PASS|name" / "FAIL|name|detail" lines; a missing module is one FAIL line.
pl_node() {
  local js="$1"
  shift
  PL_LIB="$PL_LIB" psf_timeout 60 node -e "
const out = [];
const ok = (n, c, d) => out.push(c ? 'PASS|' + n : 'FAIL|' + n + '|' + d);
const show = (x) => JSON.stringify(x);
let pl;
try { pl = require(process.env.PL_LIB); }
catch (e) { process.stdout.write('FAIL|require hooks/lib/plan-link.js|not implemented: ' + (e.code || e.message) + '\n'); process.exit(0); }
try {
$js
} catch (e) { ok('driver does not throw', false, e && e.stack); }
process.stdout.write(out.join('\n') + '\n');" "$@" 2>&1 || printf 'FAIL|node driver|exit=%s\n' "$?"
}

# pl_report <lines> — maps PASS|/FAIL| lines onto the harness.
pl_report() {
  local line rest name
  [ -z "$1" ] && { fail "driver produced no assertions"; return; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rest="${line#*|}"; name="${rest%%|*}"
    case "$line" in
      PASS\|*) pass "$name" ;;
      FAIL\|*) fail "$name" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$1"
}

case_begin "exports-and-reasons" "hooks/lib/plan-link.js"
pl_report "$(pl_node '
for (const f of ["linkFromSyncResult", "resolvePlanLink", "renderModelContext"]) ok(f + " is exported", typeof pl[f] === "function", typeof pl[f]);
const R = pl.REASONS ? Object.values(pl.REASONS) : [];
for (const r of ["no-artifact", "plan-sync-off", "not-provisioned", "not-published", "non-github", "invalid-session"])
  ok("REASONS has " + r, R.includes(r), show(pl.REASONS));
')"
case_end

case_begin "link-from-sync-result" "hooks/lib/plan-link.js"
pl_report "$(pl_node '
const url = "https://github.com/test-owner/test-repo/blob/main/s-intent.md";
const R = pl.REASONS ? Object.values(pl.REASONS) : [];
const f = pl.linkFromSyncResult;
const eq = (n, got, want) => ok(n, show(got) === show(want), "got=" + show(got) + " want=" + show(want));
eq("pushed + url -> {url}", f({ status: "pushed", url }), { url });
eq("pushed non-github -> non-github", f({ status: "pushed", reason: "non-github" }), { reason: "non-github" });
eq("off -> plan-sync-off", f({ status: "off" }), { reason: "plan-sync-off" });
eq("not-provisioned -> not-provisioned", f({ status: "not-provisioned", reason: "no-repo" }), { reason: "not-provisioned" });
eq("failed -> not-published", f({ status: "failed", reason: "offline" }), { reason: "not-published" });
for (const r of [{ status: "skipped", reason: "not-regular-file" }, { status: "skipped", reason: "budget-exhausted" }, null, undefined, {}]) {
  let got; try { got = f(r); } catch (e) { got = { threw: e.message }; }
  ok("non-published " + show(r) + " -> a known reason, no url", got && !got.url && R.includes(got.reason), show(got));
}
')"
case_end

# Fixture plans dirs: published (GitHub origin, file on main and origin/main), local-only
# (committed nowhere), unprovisioned, and published on a non-GitHub origin.
PL_PUB="$(psf_np "$PSF_ROOT/pub-plans")"; PL_NG="$(psf_np "$PSF_ROOT/ng-plans")"; PL_RAW="$(psf_np "$PSF_ROOT/raw-plans")"
PL_FIX="ok"
psf_make_provisioned "$PL_PUB" "$PSF_ORIGIN_E2E" >/dev/null 2>&1 || PL_FIX="pub"
printf 'pub intent\n' > "$PL_PUB/$PL_SID-intent.md"
psf_commit_file "$PL_PUB" "$PL_SID-intent.md" refs/remotes/origin/main >/dev/null 2>&1 || PL_FIX="pub-commit"
printf 'local outline\n' > "$PL_PUB/$PL_SID-outline.md"
psf_make_provisioned "$PL_NG" "$PSF_ORIGIN_DEAD" >/dev/null 2>&1 || PL_FIX="ng"
printf 'ng intent\n' > "$PL_NG/$PL_SID-intent.md"
psf_commit_file "$PL_NG" "$PL_SID-intent.md" refs/remotes/origin/main >/dev/null 2>&1 || PL_FIX="ng-commit"
mkdir -p "$PL_RAW"; printf 'raw\n' > "$PL_RAW/$PL_SID-intent.md"
if [ "$PL_FIX" = ok ]; then pass "fixture plans dirs built"; else fail "fixture plans dirs built" "step=$PL_FIX"; fi

# pl_resolve <name> <remote-url> <js-body> — js sees dir args via process.argv and helpers.
PL_RESOLVE_PRE='
const [sid, pub, ng, raw] = process.argv.slice(1);
const R = pl.REASONS ? Object.values(pl.REASONS) : [];
const leakFree = (n, v, dirs) => { const s = show(v);
  ok(n + " — no local path", !dirs.some((d) => s.includes(d) || s.includes(d.replace(/\//g, "\\"))) && !s.includes("workflow-plans"), s); };
const call = (stage, opts) => { try { return pl.resolvePlanLink(sid, stage, opts); } catch (e) { return { threw: e.message }; } };
const expectReason = (n, got, reason, dirs) => { ok(n, got && !got.url && got.reason === reason, show(got)); leakFree(n, got, dirs); };
'
# The assignment sits inside the substitution: a `VAR=x cmd "$(...)"` prefix never reaches the subshell.
pl_resolve() {
  pl_report "$(PLAN_SYNC_REMOTE_URL="$2" pl_node "$PL_RESOLVE_PRE$3" "$PL_SID" "$PL_PUB" "$PL_NG" "$PL_RAW")"
}

case_begin "resolve-published-url" "hooks/lib/plan-link.js"
pl_resolve published "$PSF_ORIGIN_E2E" "
const want = '$PL_BLOB/' + sid + '-intent.md';
for (const [n, opts] of [['absPath given', { plansDir: pub, absPath: pub + '/' + sid + '-intent.md' }], ['plansDir only', { plansDir: pub }]]) {
  const got = call('intent', opts);
  ok('published (' + n + ') -> url', got && got.url === want, show(got));
  ok('published (' + n + ') -> kind is a non-empty string', got && typeof got.kind === 'string' && got.kind.length > 0, show(got));
  leakFree('published (' + n + ')', got, [pub]);
}
"
case_end

case_begin "resolve-not-published-reasons" "hooks/lib/plan-link.js"
pl_resolve unpublished "$PSF_ORIGIN_E2E" "
expectReason('local-only outline -> not-published', call('outline', { plansDir: pub }), 'not-published', [pub]);
expectReason('missing detail artifact -> no-artifact', call('detail', { plansDir: pub }), 'no-artifact', [pub]);
expectReason('unprovisioned plans dir -> not-provisioned', call('intent', { plansDir: raw }), 'not-provisioned', [raw]);
"
pl_resolve sync-off "" "
expectReason('PLAN_SYNC_REMOTE_URL empty -> plan-sync-off', call('intent', { plansDir: pub }), 'plan-sync-off', [pub]);
"
pl_resolve non-github "$PSF_ORIGIN_DEAD" "
expectReason('non-GitHub origin, file published -> non-github', call('intent', { plansDir: ng }), 'non-github', [ng]);
"
case_end

case_begin "resolve-invalid-session" "hooks/lib/plan-link.js"
pl_resolve invalid "$PSF_ORIGIN_E2E" "
for (const bad of ['', '../escape', 'a/b', null]) {
  let got; try { got = pl.resolvePlanLink(bad, 'intent', { plansDir: pub }); } catch (e) { got = { threw: e.message }; }
  expectReason('sid ' + show(bad) + ' -> invalid-session', got, 'invalid-session', [pub]);
}
"
case_end

case_begin "render-model-context" "hooks/lib/plan-link.js"
pl_report "$(pl_node '
const url = "https://github.com/test-owner/test-repo/blob/main/s-intent.md";
const secret = "/home/someone/.workflow-plans/s-outline.md";
const entries = [{ stage: "intent", url, absPath: "/home/someone/.workflow-plans/s-intent.md" },
  { stage: "outline", reason: "not-published", absPath: secret }];
const r = (when) => { try { return pl.renderModelContext(entries, { when }); } catch (e) { return "THREW:" + e.message; } };
const a = r("after-write"), c = r("confirm");
for (const [n, s] of [["after-write", a], ["confirm", c]]) {
  ok(n + " is a string", typeof s === "string" && !s.startsWith("THREW:"), show(s));
  ok(n + " carries the blob URL", String(s).includes(url), show(s));
  ok(n + " carries the reason for the unpublished stage", String(s).includes("not-published"), show(s));
  ok(n + " names both stages", String(s).includes("intent") && String(s).includes("outline"), show(s));
  ok(n + " never renders an entry absPath", !String(s).includes("/home/someone") && !String(s).includes("workflow-plans"), show(s));
}
ok("after-write and confirm wording differ", a !== c, show([a, c]));
')"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
