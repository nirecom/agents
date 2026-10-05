#!/usr/bin/env bash
# Tests: hooks/lib/jev/pending.js, hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, orphan-sweep, corrupt-pending, parser-failure, unmappable, module-stub, sweep-claim-collision, scope:issue-specific, pwsh-not-required, breaker-parser-failure, enoent-retry, parser-exit-status, latency, secret-shape-load-failure, normalizer-failure, in-process-normalize

# No dispatch may disappear from the decision log: a pending hand-off that is not valid JSON
# still becomes one "llm missing" orphan record with safe defaults, and is kept for a retry
# while the log is unwritable. A parser failure on Jev's answer is logged as unmappable with
# the registry fallback, never as a usable Jev answer.

# TL3 gap (what this test does NOT catch): a real normalizer crash inside the host's hook
# process; the normalizer failure here is a stubbed normalize() export in a probe process.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

HPROBE="$(np "$LIBDIR/hardening-probe.js")"
# kp <cmd> [args...]: one hardening-probe process with JEV on, the sentinel key and the mock.
kp() {
  (
    cd "$FX/cwd" || exit 97
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE \
      -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS \
      JEV=on "TYPESAFE_API_KEY=$SENTINEL_KEY" "JEV_BASE_URL=$MOCK_URL" \
      bash "$RWT" 60 node "$HPROBE" "$REPO_N" "$@" 2>> "$ERR_ALL" < /dev/null
  )
}
pend_n() { find "$JEVDIR/$1/pending" -name "$2" 2>/dev/null | wc -l | tr -d ' '; }
SAFE='r && [r.llm.status, String(r.llm.answer), String(r.llm.latency_ms), r.llm.executor_model, r.jev.status, r.fallback_reason, String(r.step), r.stage, JSON.stringify(r.input)].join("|")'
SAFE_EXP='missing|null|null|unknown|not-run|not-run|null|unknown|{"bytes":0,"sha256":null,"truncated":false,"sources":[]}'

echo "=== an unparseable TTL-expired entry is still recorded as llm missing ==="
case_begin "k-corrupt-pending-orphan-recorded" "hooks/lib/jev/pending.js"
fx_new k-corrupt
SID="jev2460-k-corrupt"
mkdir -p "$JEVDIR/$SID/pending"
printf '{not json at all' > "$JEVDIR/$SID/pending/toolu_k_bad.json"
: > "$JEVDIR/$SID/pending/toolu_k_empty.json"
printf '\x00\xff garbage' > "$JEVDIR/$SID/pending/toolu_k_badclaim.claimed-123"
printf '[1,2' > "$JEVDIR/$SID/pending/toolu_k_badul.unlogged-123-456"
hq age "$(np "$JEVDIR/$SID/pending")" 3900000 --recursive
mock_mode '{}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_k_trigger
check "the triggering post exits 0 with no stderr" "0|" "$HOOK_RC|$(cat "$ERR")"
for _t in toolu_k_bad toolu_k_empty toolu_k_badclaim toolu_k_badul; do
  check "$_t: exactly one orphan record, llm missing with safe defaults" "1|$SAFE_EXP" \
    "$(rq "$_t" 'recs.length')|$(rq "$_t" "$SAFE")"
done
check "every corrupt entry was removed after its record was appended; the trigger paired" "0|1|ok" \
  "$(pending_count)|$(rq toolu_k_trigger 'recs.length')|$(rq toolu_k_trigger 'r && r.jev.status')"
check "no unparseable line was written to the log" "0" "$(hq broken "$(np "$LOG")")"
case_end

case_begin "k-corrupt-pending-kept-when-append-fails" "hooks/lib/jev/pending.js"
fx_new k-corrupt-keep
SID="jev2460-k-keep"
mkdir -p "$JEVDIR/$SID/pending"
printf '{not json' > "$JEVDIR/$SID/pending/toolu_k_keep.json"
hq age "$(np "$JEVDIR/$SID/pending")" 3900000 --recursive
mock_mode '{}'
mkdir -p "$LOG"
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_k_keep_t1
check "log unwritable: the corrupt entry is taken but kept as a -sweep claim for retry" "0|1|0" \
  "$HOOK_RC|$(pend_n "$SID" 'toolu_k_keep.claimed-*-sweep')|$(pend_n "$SID" 'toolu_k_keep.json')"
check "the kept file still holds the original bytes" "{not json" \
  "$(cat "$(find "$JEVDIR/$SID/pending" -name 'toolu_k_keep.claimed-*-sweep' | head -n 1)")"
rmdir "$LOG"
hq age "$(np "$JEVDIR/$SID/pending")" 3900000 --recursive
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_k_keep_t2
check "log writable again: the retry records it once with safe defaults and removes it" "1|$SAFE_EXP|0" \
  "$(rq toolu_k_keep 'recs.length')|$(rq toolu_k_keep "$SAFE")|$(pend_n "$SID" 'toolu_k_keep*')"
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_k_keep_t3
check "a further post records it no more" "1" "$(rq toolu_k_keep 'recs.length')"
case_end

case_begin "k-corrupt-pending-within-ttl-untouched" "hooks/lib/jev/pending.js"
fx_new k-corrupt-fresh
SID="jev2460-k-fresh"
mkdir -p "$JEVDIR/$SID/pending"
printf '{not json' > "$JEVDIR/$SID/pending/toolu_k_fresh.json"
mock_mode '{}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_k_fresh_t
check "a corrupt entry inside its TTL is neither recorded nor removed" "0|1" \
  "$(rq toolu_k_fresh 'recs.length')|$(pend_n "$SID" 'toolu_k_fresh.json')"
case_end

echo "=== a parser failure on Jev's answer is unmappable with the fallback answer ==="
case_begin "k-parser-failure-is-unmappable" "hooks/lib/jev/broker.js"
fx_new k-parser
SID="jev2460-k-parser"
mkdir -p "$JEVDIR/$SID"
printf '%s' '{"consecutive_failures":2,"open_until_ms":0,"last_failure_status":"timeout"}' > "$JEVDIR/$SID/breaker.json"
mock_mode '{}'
K_PF="$(kp query-parser-fail "$SID" toolu_k_parse)"
check "queryShadow: status unmappable, registry fallback answer, latency a finite number (the POST completed), probabilities kept, parser called once" \
  "unmappable|S0-undecidable|finite|true|1" \
  "$(IFS='|' read -r a b c d e <<< "$K_PF"; [[ "$c" =~ ^[0-9]+$ ]] && c=finite; echo "$a|$b|$c|$d|$e")"
check "the query was answered by the mock" "1" "$(mock_count systemone)"
check "a parser failure counts as a breaker failure: 2 -> 3, last status bad-response" "3|bad-response" \
  "$(hq json-expr "$(np "$JEVDIR/$SID/breaker.json")" 'o && [o.consecutive_failures, o.last_failure_status].join("|")')"
K_FIN='(x) => (Number.isFinite(x) && x >= 0 ? "finite" : String(x))'
check "the pending hand-off carries the same jev side" "unmappable|S0-undecidable|finite" \
  "$(hq json-expr "$(np "$JEVDIR/$SID/pending/toolu_k_parse.json")" 'o && [o.jev.status, o.jev.answer, ('"$K_FIN"')(o.jev.latency_ms)].join("|")')"
check "the paired record logs jev unmappable, fallback_reason unmappable, the fallback answer, a finite latency" \
  "record|1|unmappable|unmappable|S0-undecidable|finite" \
  "$(kp record "$SID" toolu_k_parse)|$(rq toolu_k_parse 'recs.length + "|" + (r && [r.jev.status, r.fallback_reason, r.jev.answer, ('"$K_FIN"')(r.jev.latency_ms)].join("|"))')"
case_end
case_begin "k-build-questions-failure-latency-null" "hooks/lib/jev/broker.js"
fx_new k-bq
SID="jev2460-k-bq"
mock_mode '{}'
check "buildQuestions throws: unmappable with the fallback answer, latency null (no POST was made)" \
  "unmappable|S0-undecidable|null" "$(kp query-bq-fail "$SID" toolu_k_bq)"
check "neither the probe nor the query reached the mock" "0" "$(mock_total)"
check "the paired record logs jev unmappable with latency null" "record|1|unmappable|null" \
  "$(kp record "$SID" toolu_k_bq)|$(rq toolu_k_bq 'recs.length + "|" + (r && [r.jev.status, String(r.jev.latency_ms)].join("|"))')"
case_end
case_begin "k-parser-failures-open-breaker" "hooks/lib/jev/broker.js"
fx_new k-parser-open
mock_mode '{}'
check "three parser failures open the breaker; the 4th call is breaker-open (statuses|count|last|open)" \
  "unmappable,unmappable,unmappable,breaker-open|3|bad-response|true" "$(kp query-seq jev2460-k-popen 4 parser-fail)"
check "only the first three calls reached Jev's query route" "3" "$(mock_count systemone)"
case_end
case_begin "k-normal-success-resets-breaker" "hooks/lib/jev/broker.js"
fx_new k-parser-ok
SID="jev2460-k-pok"
mkdir -p "$JEVDIR/$SID"
printf '%s' '{"consecutive_failures":2,"open_until_ms":0,"last_failure_status":"timeout"}' > "$JEVDIR/$SID/breaker.json"
mock_mode '{}'
check "a parsed, mapped answer is a success: the count resets to 0, the breaker stays closed" \
  "ok|0|timeout|false" "$(kp query-seq "$SID" 1 real)"
case_end

echo "=== a session dir renamed away mid-write is recreated once ==="
# pw <pending|unlogged> <sid> <tid> <fails>: tests/hooks/feature-2460-jev-shadow/pending-probe.js.
pw() { run_with_timeout 30 node "$(np "$LIBDIR/pending-probe.js")" "$REPO_N/hooks/lib/jev/pending.js" "$@" 2>> "$ERR_ALL"; }
case_begin "k-pending-write-enoent-retry" "hooks/lib/jev/pending.js"
fx_new k-enoent
check "writePending: one vanish before the rename: retried, the entry lands in the live pending dir (result|entries|tmp|vanishes)" \
  "ok|toolu_k_wp.json|0|1" "$(pw pending jev2460-k-wp toolu_k_wp 1)"
check "writeUnlogged: one vanish before the rename: retried, the unlogged entry lands in the live pending dir" \
  "true|toolu_k_wu.unlogged-*|0|1" "$(pw unlogged jev2460-k-wu toolu_k_wu 1)"
case_end
case_begin "k-pending-write-enoent-twice-fails" "hooks/lib/jev/pending.js"
fx_new k-enoent2
check "writePending: two vanishes in a row still throws ENOENT, nothing in the live dir (result|entries|tmp|vanishes)" \
  "threw:ENOENT||0|2" "$(pw pending jev2460-k-wp2 toolu_k_wp2 2)"
check "writeUnlogged: two vanishes in a row still returns false, nothing in the live dir (result|entries|tmp|vanishes)" \
  "false||0|2" "$(pw unlogged jev2460-k-wu2 toolu_k_wu2 2)"
case_end

echo "=== two expired entries of one tool_use_id each keep their own sweep claim ==="
# COL_JS seed <sid> <tid>: an expired-to-be <tid>.json (marker A) and <tid>.unlogged-1-2 (marker B).
# COL_JS sweep <sid> <tid> <nowMs> <ttl> <minAge> <ok|fail>: prints
#   "<swept>|<onOrphan tids>|<onOrphan markers>|<entries left for tid>|<markers left>".
COL_JS="$TMPROOT/sweep-collision.js"
cat > "$COL_JS" <<'JS'
"use strict";
const fs = require("fs");
const path = require("path");
const pending = require(process.argv[2]);
const [cmd, sid, tid, ...a] = process.argv.slice(3);
const dir = pending.pendingDir(sid);
const marker = (o) => (o && typeof o.marker === "string" ? o.marker : "?");
if (cmd === "seed") {
  pending.writePending(sid, tid, { point: "complexity-judge", marker: "A" });
  fs.writeFileSync(path.join(dir, `${tid}.unlogged-1-2`), JSON.stringify({ point: "complexity-judge", marker: "B" }));
  process.stdout.write(fs.readdirSync(dir).sort().join(","));
} else {
  const tids = [];
  const seen = [];
  const n = pending.sweepOrphans(sid, { now: () => Number(a[0]), ttlMs: Number(a[1]), minClaimAgeMs: Number(a[2]),
    onOrphan: (t, o) => { tids.push(t); seen.push(marker(o)); return a[3] === "ok" ? { ok: true } : { ok: false }; } });
  let names = [];
  try { names = fs.readdirSync(dir).filter((x) => x.startsWith(tid) && !x.endsWith(".tmp")); } catch (_e) { names = []; }
  const left = names.map((x) => { try { return marker(JSON.parse(fs.readFileSync(path.join(dir, x), "utf8"))); } catch (_e) { return "?"; } });
  process.stdout.write([n, tids.sort().join(","), seen.sort().join(","), names.length, left.sort().join(",")].join("|"));
}
JS
# col <args...>: one COL_JS process in the current fixture.
col() { run_with_timeout 30 node "$(np "$COL_JS")" "$REPO_N/hooks/lib/jev/pending.js" "$@" 2>> "$ERR_ALL"; }
# col_seed_expired <sid> <tid>: seed both entries; COL_NOW is a clock 65 minutes past their mtime.
col_seed_expired() {
  check "fixture: one .json and one .unlogged entry for one tid" "$2.json,$2.unlogged-1-2" "$(col seed "$1" "$2")"
  COL_NOW=$(( $(hq now) + 3900000 ))
}

case_begin "k-sweep-claim-unique-per-entry" "hooks/lib/jev/pending.js"
fx_new k-collide
SID="jev2460-k-collide"
col_seed_expired "$SID" toolu_k_col
check "a failing sweep hands both over and keeps both, each with its own payload" "2|toolu_k_col,toolu_k_col|A,B|2|A,B" \
  "$(col sweep "$SID" toolu_k_col "$COL_NOW" 1000 0 fail)"
check "a later succeeding sweep (ttl 0, minClaimAge 0) hands both distinct payloads over and empties the dir" "2|A,B|0" \
  "$(col sweep "$SID" toolu_k_col $((COL_NOW + 1)) 0 0 ok | cut -d'|' -f1,3,4)"
check "nothing is left in the pending dir" "0" "$(pending_count)"
case_end

case_begin "k-sweep-claim-names-parse-to-tid" "hooks/lib/jev/pending.js"
fx_new k-collide-tid
SID="jev2460-k-collide-tid"
col_seed_expired "$SID" toolu_k_colt
check "fixture: the failing sweep took both entries" "2" "$(col sweep "$SID" toolu_k_colt "$COL_NOW" 1000 0 fail | cut -d'|' -f1)"
check "every kept claim name parses back to the tid: the retry sweep recovers both payloads under it" \
  "2|toolu_k_colt,toolu_k_colt|A,B|0" "$(col sweep "$SID" toolu_k_colt $((COL_NOW + 1)) 0 0 ok | cut -d'|' -f1-4)"
case_end

echo "=== a normalizer that throws, returns a non-string or cannot load is a failure ==="
# Jev's answer goes through the same in-process normalize() as the LLM side; any failure there is unmappable.
K_CSV="S1-multi-file"
# k_norm_case <mode> <sid> <tid>: seed breaker 2 failures, run query-normalizer, then pair the record.
k_norm_case() {
  mkdir -p "$JEVDIR/$2"
  printf '%s' '{"consecutive_failures":2,"open_until_ms":0,"last_failure_status":"timeout"}' > "$JEVDIR/$2/breaker.json"
  mock_mode '{}'
  K_OUT="$(kp query-normalizer "$2" "$3" "$1")"
  K_BRK="$(hq json-expr "$(np "$JEVDIR/$2/breaker.json")" 'o && [o.consecutive_failures, o.last_failure_status].join("|")')"
  K_REC="$(kp record "$2" "$3")|$(rq "$3" 'recs.length + "|" + (r && [r.jev.status, r.fallback_reason, r.jev.answer, r.llm.status, r.llm.answer].join("|"))')"
}
# k_norm_fail_checks <mode>: fixture + run + the three unmappable assertions for one normalizer failure.
k_norm_fail_checks() {
  fx_new "k-pnorm-$1"
  k_norm_case "$1" "jev2460-k-pnorm-$1" "toolu_k_pnorm_$1"
  check "$1: status unmappable with the fallback answer; the POST completed, so latency is a number; the normalizer was reached once (status|answer|latency number|calls)" \
    "unmappable|S0-undecidable|true|1" "$K_OUT"
  check "$1: counts as a breaker failure: 2 -> 3, last status bad-response" "3|bad-response" "$K_BRK"
  check "$1: the record logs jev unmappable with the fallback; the LLM answer is adopted" \
    "record|1|unmappable|unmappable|S0-undecidable|ok|S1-multi-file" "$K_REC"
}
case_begin "k-normalizer-throw-is-unmappable" "hooks/lib/jev/broker.js"
k_norm_fail_checks throw
case_end
case_begin "k-normalizer-nonstring-is-unmappable" "hooks/lib/jev/broker.js"
k_norm_fail_checks nonstring
k_norm_fail_checks object
case_end
case_begin "k-normalizer-missing-is-unmappable" "hooks/lib/jev/broker.js"
k_norm_fail_checks missing
case_end
case_begin "k-normalizer-real-is-mapped" "hooks/lib/jev/broker.js"
fx_new k-pnorm-real
k_norm_case real jev2460-k-pnorm-real toolu_k_pnorm_real
check "real normalizer: the mapped answer is recorded as ok (status|answer|latency number|calls)" \
  "ok|$K_CSV|true|1" "$K_OUT"
check "real normalizer: a success resets the breaker count" "0|timeout" "$K_BRK"
check "real normalizer: the record compares both ok sides" "record|1|ok||$K_CSV|ok|$K_CSV" "$K_REC"
case_end

echo "=== secret-shape cannot load its hard-secret patterns: no Jev query is sent ==="
# The stub pre-seeds require.cache so the real secret-shape.js resolves to exports that throw,
# exactly as they do when bin/scan-outbound.sh's pattern block is missing or unreadable.
case_begin "k-secret-shape-load-failure-sends-no-query" "hooks/lib/jev/broker.js"
fx_new k-ss-fail
SS_STUB="$TMPROOT/secret-shape-throws.js"
printf '%s\n' 'const p = require.resolve(process.env.JEV2460_SECRET_SHAPE);' \
  'const boom = () => { throw new Error("jev2460 stub: hard-secret patterns unavailable"); };' \
  'require.cache[p] = { id: p, filename: p, loaded: true, children: [], paths: [],' \
  '  exports: { isSecretShaped: boom, redactSecretShaped: boom, REDACTED_PLACEHOLDER: "[REDACTED]" } };' > "$SS_STUB"
SS_ENV=("JEV2460_SECRET_SHAPE=$REPO_N/hooks/workflow-state/complexity-routing/secret-shape.js" "NODE_OPTIONS=--require=$(np "$SS_STUB")")
mock_mode '{}'
LLM_TEXT="SIGNALS: S1-multi-file" pair jev2460-k-ss-fail toolu_k_ss_fail "${SS_ENV[@]}"
check "both hooks exit 0 and Jev received no query" "0|0|0" "$PRE_RC|$HOOK_RC|$(mock_count systemone)"
check "the record keeps the LLM answer and logs jev not-run" "1|not-run|ok|S1-multi-file" \
  "$(rq toolu_k_ss_fail 'recs.length + "|" + (r && [r.jev.status, r.llm.status, r.llm.answer].join("|"))')"
LLM_TEXT="SIGNALS: S1-multi-file" pair jev2460-k-ss-fail toolu_k_ss_ok
check "control: the same dispatch without the stub reaches Jev once" "1|ok" \
  "$(mock_count systemone)|$(rq toolu_k_ss_ok 'r && r.jev.status')"
case_end

finish
