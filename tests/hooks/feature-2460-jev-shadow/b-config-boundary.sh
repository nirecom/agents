#!/usr/bin/env bash
# Tests: hooks/lib/jev/test-overrides.js, hooks/lib/jev/provider-core.js, hooks/jev-shadow-pre.js, hooks/jev-shadow-post.js, bin/jev-report
# Tags: TL2, hooks, jev, config-boundary, local-env-overlay, snapshot, scope:issue-specific, pwsh-not-required, timeout-override-loopback-only

# The external-send switch and the credential are one-per-machine policy: a repo's
# local overlay must not enable JEV, swap the key, or redirect the endpoint. Test-only
# overrides are snapshotted at entry, before load-env can inject .env values into
# process.env, so a JEV_BASE_URL written in any .env file never takes effect.

# TL3 gap (what this test does NOT catch): a live Claude Code session whose shell exports
# JEV_* itself; that is the user's own configuration by design (detail plan, Risks).

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start
SID="jev2460-b-sid"

echo "=== the local overlay cannot enable JEV ==="
case_begin "b-local-overlay-jev-on-ignored" "hooks/jev-shadow-pre.js"
fx_new b-local-jev
mock_mode '{}'
printf 'JEV=on\n' > "$FX/proj/$LOCAL_ENV_NAME"
mkpayload "$FX/io/pre.json" pre "$SID" toolu_b_local_jev
run_hook pre "$FX/io/pre.json" JEV=__unset__
check "overlay JEV=on: pre exits 0, Jev sees no request, no pending" "0|0|0" \
  "$HOOK_RC|$(mock_total)|$(pending_count)"
case_end

echo "=== the local overlay cannot supply the API key ==="
case_begin "b-local-overlay-key-ignored" "hooks/jev-shadow-post.js"
fx_new b-local-key
mock_mode '{}'
printf 'TYPESAFE_API_KEY=local-key\n' > "$FX/proj/$LOCAL_ENV_NAME"
pair "$SID" toolu_b_local_key TYPESAFE_API_KEY=__unset__
check "overlay key: no request reaches Jev" "0" "$(mock_total)"
check "overlay key: the record says no-key" "no-key" "$(rq toolu_b_local_key 'r && r.jev.status')"
check "overlay key: the overlay key value never reaches the log" "absent" "$(grep_absent local-key "$FX/state")"
case_end

echo "=== endpoint overrides come only from the entry snapshot ==="
case_begin "b-resolve-endpoint-ignores-env-files" "hooks/lib/jev/provider-core.js"
fx_new b-endpoint
printf 'JEV_BASE_URL=http://127.0.0.1:1\n' > "$FX/cfg/.env"
printf 'JEV_BASE_URL=http://127.0.0.1:2\n' > "$FX/proj/$LOCAL_ENV_NAME"
EP_OUT="$(cd "$FX/cwd" && env -u JEV_BASE_URL -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS \
  OV="$OVERRIDES_JS" PC="$PROVIDER_JS" LE="$LOADENV_JS" bash "$RWT" 30 node -e '
  const out = [];
  try {
    const { captureTestOverrides } = require(process.env.OV);
    const snap = captureTestOverrides(process.env);
    require(process.env.LE).loadDefaultEnv();
    out.push(process.env.JEV_BASE_URL ? "injected" : "not-injected");
    const { resolveEndpoint } = require(process.env.PC);
    const norm = (e) => String(typeof e === "string" ? e : e && e.baseUrl).replace(/\/+$/, "");
    out.push(norm(resolveEndpoint(snap)));
    out.push(norm(resolveEndpoint({})));
    out.push(norm(resolveEndpoint(captureTestOverrides({ JEV_BASE_URL: "http://127.0.0.1:9" }))));
  } catch (e) { out.push("THREW:" + e.code); }
  process.stdout.write(out.join("|"));
' 2>/dev/null)"
check "a .env-injected JEV_BASE_URL is ignored; only a snapshot override moves the endpoint" \
  "injected|https://api.typesafe.ai|https://api.typesafe.ai|http://127.0.0.1:9" "$EP_OUT"
case_end

echo "=== entrypoints snapshot before load-env / broker are required ==="
# order_ok <file>: "ok" when captureTestOverrides( precedes every load-env and jev/broker require.
order_ok() {
  local f="$SCRIPT_CHECKOUT_ROOT/$1" cap le br
  [ -f "$f" ] || { echo "missing"; return; }
  cap="$(grep -n 'captureTestOverrides(' "$f" | grep -v 'require(' | head -n 1 | cut -d: -f1)"
  le="$(grep -nE 'require\(.*load-env' "$f" | head -n 1 | cut -d: -f1)"
  br="$(grep -nE 'require\(.*jev/broker' "$f" | head -n 1 | cut -d: -f1)"
  [ -n "$cap" ] || { echo "no-capture-call"; return; }
  [ -n "$br" ] || { echo "no-broker-require"; return; }
  if [ "$cap" -lt "$br" ] && { [ -z "$le" ] || [ "$cap" -lt "$le" ]; }; then echo ok
  else echo "capture@$cap load-env@${le:-none} broker@$br"; fi
}
case_begin "b-order-pre-hook" "hooks/jev-shadow-pre.js"
check "jev-shadow-pre.js snapshots before requiring load-env / broker" ok "$(order_ok hooks/jev-shadow-pre.js)"
case_end
case_begin "b-order-post-hook" "hooks/jev-shadow-post.js"
check "jev-shadow-post.js snapshots before requiring load-env / broker" ok "$(order_ok hooks/jev-shadow-post.js)"
case_end
case_begin "b-order-report" "bin/jev-report"
check "bin/jev-report snapshots before requiring load-env / broker" ok "$(order_ok bin/jev-report)"
case_end
case_begin "b-overrides-module-is-leaf" "hooks/lib/jev/test-overrides.js"
if [ -f "$SCRIPT_CHECKOUT_ROOT/hooks/lib/jev/test-overrides.js" ]; then
  check "test-overrides.js requires neither load-env nor another jev module" "0" \
    "$(grep -cE 'require\(.*(load-env|broker|provider-core|pending|registry)' "$SCRIPT_CHECKOUT_ROOT/hooks/lib/jev/test-overrides.js")"
else
  fail "test-overrides.js requires neither load-env nor another jev module" "module missing"
fi
case_end

echo "=== captureTestOverrides validates and caps ==="
case_begin "b-capture-overrides-loopback-only-table" "hooks/lib/jev/test-overrides.js"
CAP_OUT="$(OV="$OVERRIDES_JS" run_with_timeout 30 node -e '
  let cap;
  try { cap = require(process.env.OV).captureTestOverrides; } catch (e) { process.stdout.write("LOAD-FAIL:" + e.code); process.exit(0); }
  const show = (v) => (v === null || v === undefined ? "null" : String(v));
  const rows = [
    ["http://127.0.0.1:8080", "JEV_BASE_URL", "baseUrl"], ["http://localhost:9", "JEV_BASE_URL", "baseUrl"],
    ["https://jev.example", "JEV_BASE_URL", "baseUrl"], ["http://example.com", "JEV_BASE_URL", "baseUrl"],
    ["http://127.0.0.1.evil.com", "JEV_BASE_URL", "baseUrl"], ["file:///etc/passwd", "JEV_BASE_URL", "baseUrl"],
    ["", "JEV_BASE_URL", "baseUrl"], ["not a url", "JEV_BASE_URL", "baseUrl"],
    ["500", "JEV_HTTP_TIMEOUT_MS", "httpTimeoutMs"], ["12000", "JEV_HTTP_TIMEOUT_MS", "httpTimeoutMs"],
    ["99999", "JEV_HTTP_TIMEOUT_MS", "httpTimeoutMs"], ["0", "JEV_HTTP_TIMEOUT_MS", "httpTimeoutMs"],
    ["-1", "JEV_HTTP_TIMEOUT_MS", "httpTimeoutMs"], ["1.5", "JEV_HTTP_TIMEOUT_MS", "httpTimeoutMs"],
    ["abc", "JEV_HTTP_TIMEOUT_MS", "httpTimeoutMs"], ["1000", "JEV_PENDING_TTL_MS", "pendingTtlMs"],
    ["999999999", "JEV_PENDING_TTL_MS", "pendingTtlMs"],
  ];
  const out = rows.map(([v, k, f]) => show(cap({ [k]: v })[f]).replace(/\/+$/, ""));
  const empty = cap({});
  out.push(Object.isFrozen(empty) ? "frozen" : "mutable");
  out.push([empty.baseUrl, empty.httpTimeoutMs, empty.pendingTtlMs].map(show).join("/"));
  process.stdout.write(out.join("|"));
' 2>/dev/null)"
check "loopback-only base URL (http or https), positive-integer numbers capped at 12000 ms / 24 h, frozen result" \
  "http://127.0.0.1:8080|http://localhost:9|null|null|null|null|null|null|500|12000|12000|null|null|null|null|1000|86400000|frozen|null/null/null" \
  "$CAP_OUT"
case_end

echo "=== the base-URL override reaches loopback hosts only ==="
# One row per accept/reject reason: "<name> <baseUrl> <resolved endpoint>". A rejected
# override must leave the endpoint at the production default, asserted on the resolver
# so no request ever leaves the machine. The userinfo rows are built by concatenation.
case_begin "b-base-url-loopback-only-table" "hooks/lib/jev/test-overrides.js"
URL_OUT="$(OV="$OVERRIDES_JS" PC="$PROVIDER_JS" run_with_timeout 30 node -e '
  let cap, ep;
  try { cap = require(process.env.OV).captureTestOverrides; ep = require(process.env.PC).resolveEndpoint; }
  catch (e) { process.stdout.write("LOAD-FAIL:" + e.code); process.exit(0); }
  const rows = [
    ["loopback-ip-trailing-slash", "http://127.0.0.1:8080/"],
    ["loopback-name", "http://localhost:9"],
    ["loopback-name-https", "https://localhost:9"],
    ["loopback-ip-https-path", "https://127.0.0.1:8443/base/"],
    ["loopback-padded", "  http://127.0.0.1:8080  "],
    ["loopback-uppercase", "HTTP://LOCALHOST:9"],
    ["loopback-query-dropped", "http://127.0.0.1:8080/?next=https://jev.example"],
    ["remote-https", "https://jev.example"],
    ["remote-http", "http://example.com"],
    ["loopback-prefix-https", "https://127.0.0.1.evil.com"],
    ["loopback-prefix-http", "http://127.0.0.1.evil.com"],
    ["localhost-prefix", "http://localhost.evil.com"],
    ["userinfo-on-loopback", "https://" + "u:p" + "@127.0.0.1"],
    ["userinfo-host-confusion", "http://127.0.0.1" + "@evil.com"],
    ["ipv6-loopback", "http://[::1]:5"],
    ["any-address", "http://0.0.0.0:5"],
    ["file-scheme", "file:///etc/passwd"],
    ["ftp-loopback", "ftp://127.0.0.1"],
    ["empty", ""],
    ["blank", "   "],
    ["not-a-url", "not a url"],
    ["number", 8080],
    ["null", null],
  ];
  for (const [name, v] of rows) {
    let got;
    try { const snap = cap({ JEV_BASE_URL: v }); got = String(snap.baseUrl) + " " + ep(snap); } catch (e) { got = "THREW:" + e.name; }
    console.log(name + " " + got);
  }
' 2>/dev/null)"
check "accepted loopback forms are normalised; everything else is null and resolves to the default endpoint" \
"loopback-ip-trailing-slash http://127.0.0.1:8080 http://127.0.0.1:8080
loopback-name http://localhost:9 http://localhost:9
loopback-name-https https://localhost:9 https://localhost:9
loopback-ip-https-path https://127.0.0.1:8443/base https://127.0.0.1:8443/base
loopback-padded http://127.0.0.1:8080 http://127.0.0.1:8080
loopback-uppercase http://localhost:9 http://localhost:9
loopback-query-dropped http://127.0.0.1:8080 http://127.0.0.1:8080
remote-https null https://api.typesafe.ai
remote-http null https://api.typesafe.ai
loopback-prefix-https null https://api.typesafe.ai
loopback-prefix-http null https://api.typesafe.ai
localhost-prefix null https://api.typesafe.ai
userinfo-on-loopback null https://api.typesafe.ai
userinfo-host-confusion null https://api.typesafe.ai
ipv6-loopback null https://api.typesafe.ai
any-address null https://api.typesafe.ai
file-scheme null https://api.typesafe.ai
ftp-loopback null https://api.typesafe.ai
empty null https://api.typesafe.ai
blank null https://api.typesafe.ai
not-a-url null https://api.typesafe.ai
number null https://api.typesafe.ai
null null https://api.typesafe.ai" "$URL_OUT"
case_end

case_begin "b-capture-overrides-idempotent-and-immutable" "hooks/lib/jev/test-overrides.js"
IDEM_OUT="$(OV="$OVERRIDES_JS" run_with_timeout 30 node -e '
  "use strict";
  const { captureTestOverrides: cap } = require(process.env.OV);
  const env = { JEV_BASE_URL: "http://127.0.0.1:8080/", JEV_HTTP_TIMEOUT_MS: "500", JEV_PENDING_TTL_MS: "1000" };
  const a = cap(env);
  let wrote = "silently-mutated";
  try { a.baseUrl = "https://jev.example"; } catch (_e) { wrote = "threw"; }
  process.stdout.write([JSON.stringify(a) === JSON.stringify(cap(env)), wrote, a.baseUrl, JSON.stringify(cap(undefined))].join("|"));
' 2>/dev/null)"
check "same env twice gives the same snapshot; a write to the snapshot throws; no env is all-null" \
  'true|threw|http://127.0.0.1:8080|{"baseUrl":null,"httpTimeoutMs":null,"pendingTtlMs":null}' "$IDEM_OUT"
case_end

echo "=== the HTTP timeout override rides only on a loopback base-URL override ==="
# Without the loopback endpoint override, a JEV_HTTP_TIMEOUT_MS up to 12000 ms would stretch a
# production probe/query past the hook budget. Rows: "<name> <baseUrl> <probe ms> <query ms>".
case_begin "b-timeout-override-needs-loopback-base" "hooks/lib/jev/provider-core.js"
TO_OUT="$(OV="$OVERRIDES_JS" PC="$PROVIDER_JS" run_with_timeout 30 node -e '
  let cap, pc;
  try { cap = require(process.env.OV).captureTestOverrides; pc = require(process.env.PC); }
  catch (e) { process.stdout.write("LOAD-FAIL:" + e.code); process.exit(0); }
  const L = "http://127.0.0.1:9";
  const rows = [
    ["no-overrides", cap({})],
    ["timeout-only", cap({ JEV_HTTP_TIMEOUT_MS: "500" })],
    ["timeout-max-only", cap({ JEV_HTTP_TIMEOUT_MS: "12000" })],
    ["raw-timeout-no-base", { httpTimeoutMs: 500 }],
    ["loopback-base-only", cap({ JEV_BASE_URL: L })],
    ["loopback-base-timeout", cap({ JEV_BASE_URL: L, JEV_HTTP_TIMEOUT_MS: "500" })],
    ["localhost-base-timeout-max", cap({ JEV_BASE_URL: "http://localhost:9", JEV_HTTP_TIMEOUT_MS: "12000" })],
    ["loopback-base-invalid-timeout", cap({ JEV_BASE_URL: L, JEV_HTTP_TIMEOUT_MS: "0" })],
    ["remote-base-timeout", cap({ JEV_BASE_URL: "https://jev.example", JEV_HTTP_TIMEOUT_MS: "500" })],
    ["loopback-prefix-base-timeout", cap({ JEV_BASE_URL: "http://127.0.0.1.evil.com", JEV_HTTP_TIMEOUT_MS: "500" })],
  ];
  for (const [name, ov] of rows) {
    const c = pc.jevCoreInit({ sessionId: "jev2460-b-to", overrides: ov });
    console.log([name, c.baseUrl, c.probeTimeoutMs, c.queryTimeoutMs].join(" "));
  }
  console.log("defaults " + pc.PROBE_TIMEOUT_MS + " " + pc.QUERY_TIMEOUT_MS);
' 2>/dev/null)"
check "the timeout override applies only with a loopback base URL; otherwise the 2000/6000 ms defaults stand" \
"no-overrides https://api.typesafe.ai 2000 6000
timeout-only https://api.typesafe.ai 2000 6000
timeout-max-only https://api.typesafe.ai 2000 6000
raw-timeout-no-base https://api.typesafe.ai 2000 6000
loopback-base-only http://127.0.0.1:9 2000 6000
loopback-base-timeout http://127.0.0.1:9 500 500
localhost-base-timeout-max http://localhost:9 12000 12000
loopback-base-invalid-timeout http://127.0.0.1:9 2000 6000
remote-base-timeout https://api.typesafe.ai 2000 6000
loopback-prefix-base-timeout https://api.typesafe.ai 2000 6000
defaults 2000 6000" "$TO_OUT"
case_end

finish
