#!/usr/bin/env bash
# tests/hooks/feature-plan-link.sh
# Tests: hooks/lib/plan-link.js
# Tags: plan-link, plan-sync, blob-url, additional-context, unit, TL1, scope:common, path-leak, project-host, gitlab
# hooks/lib/plan-link.js: the one place that turns a plan artifact into the model-facing
# link (blob URL + local path, or local path + reason) and renders the additionalContext text.
# Whether a URL may be shown follows the project-host record beside the plan.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
# psf_setup pins both dirs inside a function; the top-level re-export is the pin the
# isolation gate (bin/check-plans-dir-isolation.sh) sees before the first exec.
export WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
trap psf_cleanup EXIT
PL_LIB="$(psf_np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-link.js")"
PL_SID="0d2c5d7e-1111-4222-8333-444455556666"
PL_SID_MIS="1e3d6e8f-2222-4333-8444-555566667777"
PL_SID_NOREC="2f4e7f90-3333-4444-8555-666677778888"
PL_BLOB="https://github.com/test-owner/test-repo/blob/main"
PL_BLOB_GL="https://gitlab.com/test-group/test-project/-/blob/main"
PL_BLOB_GLS="https://gitlab.example.com/test-group/test-project/-/blob/main"
PL_ORIGIN_SSHGH="ssh://git@ssh.github.com:443/test-owner/test-repo.git"

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
for (const f of ["linkFromSyncResult", "resolvePlanLink", "renderModelContext", "entryLine"]) ok(f + " is exported", typeof pl[f] === "function", typeof pl[f]);
const R = pl.REASONS ? Object.values(pl.REASONS) : [];
for (const r of ["no-artifact", "plan-sync-off", "not-provisioned", "not-published", "unknown-forge", "host-mismatch", "no-project-host", "invalid-session"])
  ok("REASONS has " + r, R.includes(r), show(pl.REASONS));
ok("REASONS no longer names the forge by exclusion", !R.some((r) => /github/i.test(String(r))), show(pl.REASONS));
const S = Array.isArray(pl.STAGES) ? pl.STAGES : (pl.STAGES ? Object.values(pl.STAGES) : []);
ok("STAGES are intent, outline, detail", show([...S].sort()) === show(["detail", "intent", "outline"]), show(pl.STAGES));
const T = pl.REASON_TEXT || {};
ok("REASON_TEXT explains every reason", R.length > 0 && R.every((r) => typeof T[r] === "string" && T[r].length > 0), show(T));
const cmd = String(pl.PLAN_LINK_COMMAND || "");
ok("PLAN_LINK_COMMAND runs bin/plan-link with --stage", /bin\/plan-link/.test(cmd) && /--stage/.test(cmd), show(cmd));
ok("PLAN_LINK_COMMAND names the agents main root, not a checkout path", /AGENTS_MAIN_ROOT/.test(cmd) && !/[A-Za-z]:[\\/]/.test(cmd), show(cmd));
')"
case_end

case_begin "link-from-sync-result" "hooks/lib/plan-link.js"
pl_report "$(pl_node '
const url = "https://github.com/test-owner/test-repo/blob/main/s-intent.md";
const R = pl.REASONS ? Object.values(pl.REASONS) : [];
const f = pl.linkFromSyncResult;
const eq = (n, got, want) => ok(n, show(got) === show(want), "got=" + show(got) + " want=" + show(want));
const reasonOnly = (n, r, want) => { let got; try { got = f(r); } catch (e) { got = { threw: e.message }; }
  ok(n, got && !got.url && got.reason === want, show(got)); };
eq("pushed + url -> {url}", f({ status: "pushed", url }), { url });
reasonOnly("pushed without a url -> unknown-forge", { status: "pushed" }, "unknown-forge");
reasonOnly("pushed, reason unknown-forge -> unknown-forge", { status: "pushed", reason: "unknown-forge" }, "unknown-forge");
reasonOnly("skipped host-mismatch -> host-mismatch", { status: "skipped", reason: "host-mismatch" }, "host-mismatch");
reasonOnly("skipped no-project-host -> no-project-host", { status: "skipped", reason: "no-project-host" }, "no-project-host");
eq("off -> plan-sync-off", f({ status: "off" }), { reason: "plan-sync-off" });
eq("not-provisioned -> not-provisioned", f({ status: "not-provisioned", reason: "no-repo" }), { reason: "not-provisioned" });
eq("failed -> not-published", f({ status: "failed", reason: "offline" }), { reason: "not-published" });
for (const r of [{ status: "skipped" }, { status: "skipped", reason: "not-regular-file" }, { status: "skipped", reason: "budget-exhausted" }, null, undefined, {}]) {
  let got; try { got = f(r); } catch (e) { got = { threw: e.message }; }
  ok("non-published " + show(r) + " -> a known reason, no url", got && !got.url && R.includes(got.reason), show(got));
}
')"
case_end

case_begin "entry-line" "hooks/lib/plan-link.js"
pl_report "$(pl_node '
const url = "https://github.com/test-owner/test-repo/blob/main/s-intent.md";
const p = "/home/someone/plans/s-intent.md";
const e = (x) => { try { return String(pl.entryLine(x)); } catch (err) { return "THREW:" + err.message; } };
const withUrl = e({ stage: "intent", url, path: p, absPath: p });
ok("url entry: one line starting with the stage", !withUrl.includes("\n") && withUrl.startsWith("intent: "), show(withUrl));
ok("url entry: holds the URL and the local path", withUrl.includes(url) && withUrl.includes(p), show(withUrl));
const noUrl = e({ stage: "outline", reason: "host-mismatch", path: p, absPath: p });
ok("reason entry: one line starting with the stage", !noUrl.includes("\n") && noUrl.startsWith("outline: "), show(noUrl));
ok("reason entry: holds the local path and the reason word, no URL", noUrl.includes(p) && noUrl.includes("host-mismatch") && !noUrl.includes("://"), show(noUrl));
const absent = e({ stage: "detail", reason: "no-artifact" });
ok("absent plan: \"<stage>: (unavailable: <reason>)\"", absent === "detail: (unavailable: no-artifact)", show(absent));
')"
case_end

# Fixture plans dirs. "published" = on main and origin/main with the content on disk.
#   PL_PUB (github.com): PL_SID intent published, outline published then edited locally, detail absent;
#     PL_SID_MIS intent published, outline local-only, detail published; PL_SID_NOREC intent
#     published, outline local-only.
#   PL_NG (unknown forge), PL_GL (gitlab.com), PL_GLS (self-hosted GitLab), PL_SG (ssh.github.com):
#     PL_SID intent published. PL_RAW: not provisioned.
PL_PUB="$(psf_np "$PSF_ROOT/pub-plans")"; PL_NG="$(psf_np "$PSF_ROOT/ng-plans")"; PL_RAW="$(psf_np "$PSF_ROOT/raw-plans")"
PL_GL="$(psf_np "$PSF_ROOT/gl-plans")"; PL_GLS="$(psf_np "$PSF_ROOT/gls-plans")"; PL_SG="$(psf_np "$PSF_ROOT/sg-plans")"
PL_FIX="ok"

# pl_publish <plansDir> <rel> <content>
pl_publish() {
  printf '%s\n' "$3" > "$1/$2" || return 1
  psf_commit_file "$1" "$2" refs/remotes/origin/main >/dev/null 2>&1
}

psf_make_provisioned "$PL_PUB" "$PSF_ORIGIN_E2E" >/dev/null 2>&1 || PL_FIX="pub"
pl_publish "$PL_PUB" "$PL_SID-intent.md" "pub intent" || PL_FIX="pub-intent"
pl_publish "$PL_PUB" "$PL_SID-outline.md" "published outline" || PL_FIX="pub-outline"
printf 'outline edited after publishing\n' > "$PL_PUB/$PL_SID-outline.md"
pl_publish "$PL_PUB" "$PL_SID_MIS-intent.md" "mismatch intent" || PL_FIX="mis-intent"
printf 'mismatch outline\n' > "$PL_PUB/$PL_SID_MIS-outline.md"
pl_publish "$PL_PUB" "$PL_SID_MIS-detail.md" "no-host detail" || PL_FIX="mis-detail"
pl_publish "$PL_PUB" "$PL_SID_NOREC-intent.md" "norec intent" || PL_FIX="norec-intent"
printf 'norec outline\n' > "$PL_PUB/$PL_SID_NOREC-outline.md"
psf_record "$PL_PUB" "$PL_SID-intent.md" github.com
psf_record "$PL_PUB" "$PL_SID-outline.md" github.com
psf_record "$PL_PUB" "$PL_SID_MIS-intent.md" gitlab.com
psf_record "$PL_PUB" "$PL_SID_MIS-outline.md" gitlab.com
psf_record "$PL_PUB" "$PL_SID_MIS-detail.md" none

# pl_one_published <plansDir> <origin> <record-host>
pl_one_published() {
  psf_make_provisioned "$1" "$2" >/dev/null 2>&1 || return 1
  pl_publish "$1" "$PL_SID-intent.md" "intent for ${1##*/}" || return 1
  psf_record "$1" "$PL_SID-intent.md" "$3"
}
pl_one_published "$PL_NG" "$PSF_ORIGIN_PLAIN" "$PSF_HOST_PLAIN" || PL_FIX="ng"
pl_one_published "$PL_GL" "$PSF_ORIGIN_GL" gitlab.com || PL_FIX="gl"
pl_one_published "$PL_GLS" "$PSF_ORIGIN_GL_SELF" gitlab.example.com || PL_FIX="gls"
pl_one_published "$PL_SG" "$PL_ORIGIN_SSHGH" github.com || PL_FIX="sg"
mkdir -p "$PL_RAW"; printf 'raw\n' > "$PL_RAW/$PL_SID-intent.md"
psf_record "$PL_RAW" "$PL_SID-intent.md" github.com
if [ "$PL_FIX" = ok ]; then pass "fixture plans dirs built"; else fail "fixture plans dirs built" "step=$PL_FIX"; fi

PL_RESOLVE_PRE='
const [sid, pub, ng, raw, gl, gls, sg, sidMis, sidNoRec] = process.argv.slice(1);
const norm = (p) => String(p || "").replace(/\\/g, "/").toLowerCase();
const call = (s, stage, dir) => { try { return pl.resolvePlanLink(s, stage, { plansDir: dir }); } catch (e) { return { threw: e.message }; } };
const hasPath = (n, got, dir, s, stage) => ok(n + " — carries the local path",
  got && require("path").isAbsolute(String(got.path || "")) && norm(got.path) === norm(dir + "/" + s + "-" + stage + ".md"), show(got));
const expectUrl = (n, dir, s, stage, want) => { const got = call(s, stage, dir);
  ok(n + " -> url", got && got.url === want, show(got) + " want=" + want); hasPath(n, got, dir, s, stage); };
const expectReason = (n, dir, s, stage, reason) => { const got = call(s, stage, dir);
  ok(n + " -> " + reason + ", no url", got && !got.url && got.reason === reason, show(got)); hasPath(n, got, dir, s, stage); };
const expectNoPath = (n, got, reason) => ok(n + " -> " + reason + ", no url, no path", got && !got.url && !got.path && got.reason === reason, show(got));
'
# pl_resolve <name> <remote-url> <js-body> [GITLAB_HOSTNAME] — the assignments sit inside the
# substitution: a `VAR=x cmd "$(...)"` prefix never reaches the subshell.
pl_resolve() {
  pl_report "$(PLAN_SYNC_REMOTE_URL="$2" GITLAB_HOSTNAME="${4:-}" GITLAB_SSH_HOSTNAME="" pl_node "$PL_RESOLVE_PRE$3" \
    "$PL_SID" "$PL_PUB" "$PL_NG" "$PL_RAW" "$PL_GL" "$PL_GLS" "$PL_SG" "$PL_SID_MIS" "$PL_SID_NOREC")"
}

case_begin "resolve-match-record" "hooks/lib/plan-link.js"
pl_resolve match "$PSF_ORIGIN_E2E" "
expectUrl('match record, published identical', pub, sid, 'intent', '$PL_BLOB/' + sid + '-intent.md');
const viaAbs = (() => { try { return pl.resolvePlanLink(sid, 'intent', { plansDir: pub, absPath: pub + '/' + sid + '-intent.md' }); } catch (e) { return { threw: e.message }; } })();
ok('match record, absPath given -> url', viaAbs && viaAbs.url === '$PL_BLOB/' + sid + '-intent.md', show(viaAbs));
hasPath('match record, absPath given', viaAbs, pub, sid, 'intent');
expectReason('match record, content differs from the destination', pub, sid, 'outline', 'not-published');
"
case_end

case_begin "resolve-mismatch-record" "hooks/lib/plan-link.js"
pl_resolve mismatch "$PSF_ORIGIN_E2E" "
expectReason('other-host record, plan identical at the destination', pub, sidMis, 'intent', 'host-mismatch');
expectReason('other-host record, plan absent at the destination', pub, sidMis, 'outline', 'host-mismatch');
expectReason('no-host record, plan identical at the destination', pub, sidMis, 'detail', 'no-project-host');
"
case_end

case_begin "resolve-no-record" "hooks/lib/plan-link.js"
pl_resolve norecord "$PSF_ORIGIN_E2E" "
expectUrl('no record, plan identical at the destination', pub, sidNoRec, 'intent', '$PL_BLOB/' + sidNoRec + '-intent.md');
expectReason('no record, plan absent at the destination', pub, sidNoRec, 'outline', 'not-published');
"
case_end

case_begin "resolve-setup-reasons" "hooks/lib/plan-link.js"
pl_resolve sync-off "" "
expectReason('PLAN_SYNC_REMOTE_URL empty', pub, sid, 'intent', 'plan-sync-off');
"
pl_resolve unprovisioned "$PSF_ORIGIN_E2E" "
expectReason('unprovisioned plans dir', raw, sid, 'intent', 'not-provisioned');
expectNoPath('missing detail artifact', call(sid, 'detail', pub), 'no-artifact');
"
case_end

case_begin "resolve-forge-url-shapes" "hooks/lib/plan-link.js"
pl_resolve gitlab "$PSF_ORIGIN_GL" "
expectUrl('gitlab.com destination', gl, sid, 'intent', '$PL_BLOB_GL/' + sid + '-intent.md');
"
pl_resolve gitlab-self "$PSF_ORIGIN_GL_SELF" "
expectUrl('self-hosted GitLab destination', gls, sid, 'intent', '$PL_BLOB_GLS/' + sid + '-intent.md');
" gitlab.example.com
pl_resolve ssh-github "$PL_ORIGIN_SSHGH" "
expectUrl('ssh.github.com destination', sg, sid, 'intent', '$PL_BLOB/' + sid + '-intent.md');
"
pl_resolve unknown-forge "$PSF_ORIGIN_PLAIN" "
expectReason('unknown-forge destination, plan published', ng, sid, 'intent', 'unknown-forge');
"
case_end

case_begin "resolve-invalid-session" "hooks/lib/plan-link.js"
pl_resolve invalid "$PSF_ORIGIN_E2E" "
for (const bad of ['', '../escape', 'a/b', null]) {
  let got; try { got = pl.resolvePlanLink(bad, 'intent', { plansDir: pub }); } catch (e) { got = { threw: e.message }; }
  expectNoPath('sid ' + show(bad), got, 'invalid-session');
}
let st; try { st = pl.resolvePlanLink(sid, 'bogus', { plansDir: pub }); } catch (e) { st = { threw: e.message }; }
ok('unknown stage -> no url, no path', st && !st.url && !st.path, show(st));
"
case_end

case_begin "render-model-context" "hooks/lib/plan-link.js"
pl_report "$(pl_node '
const url = "https://github.com/test-owner/test-repo/blob/main/s-intent.md";
const pIntent = "/home/someone/plans/s-intent.md", pOutline = "/home/someone/plans/s-outline.md";
const entries = [{ stage: "intent", url, path: pIntent, absPath: pIntent },
  { stage: "outline", reason: "host-mismatch", path: pOutline, absPath: pOutline },
  { stage: "detail", reason: "no-artifact" }];
const r = (when) => { try { return pl.renderModelContext(entries, { when }); } catch (e) { return "THREW:" + e.message; } };
const lineOf = (s, needle) => String(s).split("\n").filter((l) => l.includes(needle));
const a = r("after-write"), c = r("confirm");
for (const [n, s] of [["after-write", a], ["confirm", c]]) {
  ok(n + " is a string", typeof s === "string" && !s.startsWith("THREW:"), show(s));
  ok(n + " names every stage", ["intent", "outline", "detail"].every((st) => String(s).includes(st)), show(s));
  const li = lineOf(s, url), lo = lineOf(s, "host-mismatch"), ld = lineOf(s, "no-artifact");
  ok(n + " puts the URL and the local path on one line", li.some((l) => l.includes(pIntent)), show(s));
  ok(n + " puts the reason and the local path on one line", lo.some((l) => l.includes(pOutline)), show(s));
  ok(n + " absent plan: reason line without a path", ld.length > 0 && ld.every((l) => !l.includes("/home/someone")), show(s));
  ok(n + " no longer forbids a local path", !/never show a local|do not (show|print|write) (the )?local path/i.test(String(s)), show(s));
  ok(n + " names the plan-link command for later questions", String(s).includes("bin/plan-link"), show(s));
  ok(n + " steers away from SendUserFile", String(s).includes("SendUserFile"), show(s));
}
ok("after-write and confirm wording differ", a !== c, show([a, c]));
')"
case_end

# #2513 S4: the local path is inline code; the URL stays bare so the reply auto-links it.
case_begin "entry-line-inline-code" "hooks/lib/plan-link.js"
pl_report "$(pl_node '
const url = "https://example.invalid/test-owner/test-repo/blob/main/s-intent.md";
const p = "/tmp/plan-link-test/s-intent.md";
const e = (x) => { try { return String(pl.entryLine(x)); } catch (err) { return "THREW:" + err.message; } };
const bt = String.fromCharCode(96);
const eq = (n, got, want) => ok(n, got === want, "got=" + show(got) + " want=" + show(want));
eq("url entry: the path is backticked, the URL is not", e({ stage: "intent", url, path: p }), "intent: " + url + " (" + bt + p + bt + ")");
eq("reason entry: the path is backticked", e({ stage: "outline", reason: "plan-sync-off", path: p }), "outline: " + bt + p + bt + " (no URL: plan-sync-off)");
eq("url without a path: unchanged", e({ stage: "detail", url }), "detail: " + url);
eq("absent plan: unchanged", e({ stage: "detail", reason: "no-artifact" }), "detail: (unavailable: no-artifact)");
const ctx = (() => { try { return pl.renderModelContext([{ stage: "intent", url, path: p }], { when: "confirm" }); } catch (err) { return "THREW:" + err.message; } })();
ok("renderModelContext carries the backticked entry line", String(ctx).includes("intent: " + url + " (" + bt + p + bt + ")"), show(ctx));
ok("renderModelContext never backticks the URL", !String(ctx).includes(bt + url), show(ctx));
')"
PL_CLI_PLAN="$WORKFLOW_PLANS_DIR/$PL_SID-intent.md"
printf 'cli intent\n' > "$PL_CLI_PLAN"
PL_CLI_OUT="$(PLAN_SYNC_REMOTE_URL="" psf_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/plan-link" --session "$PL_SID" --stage intent 2>&1)"
PL_CLI_P="$(printf '%s' "$PL_CLI_OUT" | sed -n 's/^intent: `\(.*\)` (no URL: plan-sync-off)$/\1/p')"
if [ -n "$PL_CLI_P" ] && [ "${PL_CLI_P%"$PL_SID-intent.md"}" != "$PL_CLI_P" ]; then
  pass "bin/plan-link prints the backticked local path"
else
  fail "bin/plan-link prints the backticked local path" "out=$PL_CLI_OUT"
fi
rm -f "$PL_CLI_PLAN"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
