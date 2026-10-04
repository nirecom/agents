#!/usr/bin/env bash
# Tests: hooks/lib/jev/pending.js, hooks/lib/jev/decision-record.js, hooks/jev-shadow-pre.js, hooks/jev-shadow-post.js, hooks/lib/jev/dispatch-gate.js, hooks/lib/jev/state-paths.js
# Tags: TL2, hooks, jev, pairing, agreement, pending, orphan-sweep, orphan-retry, scope:issue-specific, pwsh-not-required, tid-of, has-entries, min-claim-age, rewrite-claim, unlogged-record

# pre and post pair through tool_use_id into exactly one decision record. Agreement is
# compared only when both sides are ok, with the rubric's S1b => S1 implication applied
# to both sides (a side listing S1b without S1 disagrees); a missing post becomes "llm missing" after the TTL, a missing pre becomes
# "jev not-run" (so does a duplicate post), and hostile session/tool_use ids never touch
# the filesystem.

# TL3 gap (what this test does NOT catch): the real host's tool_use_id sharing between
# PreToolUse and PostToolUse; TL3-hook-agent-jev-shadow.sh T3 covers that.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

echo "=== one record per dispatch, with step and stage ==="
case_begin "e-pair-one-record-outline" "hooks/jev-shadow-post.js"
fx_new e-basic
SID="jev2460-e-basic"
check "fixture: the workflow state sits at outline" "outline" "$(hq seed-step "$SID" outline)"
mock_mode '{}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_e_basic
check "exactly one record for the tool_use_id" "1" "$(rq toolu_e_basic 'recs.length')"
check "v/point/mode/adopted/session/step/stage" "1|complexity-judge|shadow|llm|$SID|outline|outline" \
  "$(rq toolu_e_basic 'r && [r.v, r.point, r.mode, r.adopted, r.session_id, r.step, r.stage].join("|")')"
check "both sides ok and agree" "ok|ok|true" "$(rq toolu_e_basic 'r && [r.jev.status, r.llm.status, r.agreement].join("|")')"
check "the pending file is consumed" "0" "$(pending_count)"
case_end

echo "=== agreement table (jev answers from the mock, llm from the payload) ==="
fx_new e-agree
SID="jev2460-e-agree"
# agree_row <tid> <mode-json> <llm-text> <expected agreement|jev.status|llm.status>
agree_row() {
  mock_mode "$2"
  LLM_TEXT="$3" pair "$SID" "$1"
  check "$1: agreement|jev.status|llm.status" "$4" \
    "$(rq "$1" 'r && [String(r.agreement), r.jev.status, r.llm.status].join("|")')"
}
case_begin "e-agree-match" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_match '{"answers":{"S1-multi-file":0.97,"S2-architecture":0.95}}' \
  "SIGNALS: S1-multi-file, S2-architecture" "true|ok|ok"
check "match: every per-signal entry is true" "7|true" \
  "$(rq toolu_e_match 'r && r.agreement_by_signal && Object.keys(r.agreement_by_signal).length + "|" + Object.values(r.agreement_by_signal).every(v => v === true)')"
case_end
case_begin "e-agree-mismatch" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_mismatch '{"answers":{"S1-multi-file":0.02,"S2-architecture":0.95}}' \
  "SIGNALS: S3-security" "false|ok|ok"
check "mismatch: per-signal S1 true, S2 false, S3 false" "true|false|false" \
  "$(rq toolu_e_mismatch 'r && ["S1-multi-file","S2-architecture","S3-security"].map(k => r.agreement_by_signal[k]).join("|")')"
case_end
case_begin "e-agree-implication-jev-side" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_impl_jev '{"answers":{"S1-multi-file":0.02,"S1b-wide-change":0.95}}' \
  "SIGNALS: S1-multi-file, S1b-wide-change" "false|ok|ok"
check "jev S1b without S1 is a rubric violation: logged answer stays S1b alone; per-signal S1 false, S1b true" \
  "S1b-wide-change|false|true" \
  "$(rq toolu_e_impl_jev 'r && [r.jev.answer, r.agreement_by_signal["S1-multi-file"], r.agreement_by_signal["S1b-wide-change"]].join("|")')"
case_end
case_begin "e-agree-implication-llm-side" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_impl_llm '{"answers":{"S1-multi-file":0.97,"S1b-wide-change":0.95}}' \
  "SIGNALS: S1b-wide-change" "false|ok|ok"
check "llm S1b without S1: per-signal S1 false" "false" "$(rq toolu_e_impl_llm 'r && String(r.agreement_by_signal["S1-multi-file"])')"
case_end
case_begin "e-agree-implication-valid-pair" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_impl_pair '{"answers":{"S1-multi-file":0.97,"S1b-wide-change":0.95}}' \
  "SIGNALS: S1-multi-file, S1b-wide-change" "true|ok|ok"
case_end
case_begin "e-llm-parse-fallback" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_pfb '{}' $'SIGNALS: S1-multi-file\nand some trailing prose' "null|ok|parse-fallback"
check "parse-fallback: agreement_by_signal is null" "null" "$(rq toolu_e_pfb 'r && String(r.agreement_by_signal)')"
case_end
case_begin "e-jev-low-confidence" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_lowc '{"answers":{"S2-architecture":0.6}}' "SIGNALS: S1-multi-file" "null|low-confidence|ok"
check "low-confidence: no per-signal agreement, reason recorded, probabilities kept" "null|low-confidence|0.6" \
  "$(rq toolu_e_lowc 'r && [String(r.agreement_by_signal), r.fallback_reason, r.jev.probabilities["S2-architecture"]].join("|")')"
case_end
case_begin "e-llm-undecidable-vs-jev-none-not-compared" "hooks/lib/jev/decision-record.js"
NONE_MODE='{"answers":{"S1-multi-file":0.02}}'
agree_row toolu_e_s0_none "$NONE_MODE" "SIGNALS: S0-undecidable" "null|ok|ok"
check "S0 vs none: answers recorded, no per-signal agreement, no fallback reason" "|S0-undecidable|null|null" \
  "$(rq toolu_e_s0_none 'r && [r.jev.answer, r.llm.answer, String(r.agreement_by_signal), String(r.fallback_reason)].join("|")')"
agree_row toolu_e_none_none "$NONE_MODE" "SIGNALS: none" "true|ok|ok"
case_end
case_begin "e-llm-undecidable-vs-jev-signals-not-compared" "hooks/lib/jev/decision-record.js"
agree_row toolu_e_s0_sig '{"answers":{"S1-multi-file":0.97,"S3-security":0.95}}' "SIGNALS: S0-undecidable" "null|ok|ok"
check "S0 vs signals: jev answer kept, agreement_by_signal null" "S1-multi-file,S3-security|null" \
  "$(rq toolu_e_s0_sig 'r && [r.jev.answer, String(r.agreement_by_signal)].join("|")')"
case_end
case_begin "e-llm-preamble-then-s0-line-ok" "hooks/jev-shadow-post.js"
agree_row toolu_e_s0_pre '{}' $'analysis...\nSIGNALS: S0-undecidable' "null|ok|ok"
check "preamble + exact S0 line: llm answer S0-undecidable, not parse-fallback" "S0-undecidable" "$(rq toolu_e_s0_pre 'r && r.llm.answer')"
case_end
case_begin "e-llm-empty-is-missing" "hooks/jev-shadow-post.js"
agree_row toolu_e_empty '{}' "" "null|ok|missing"
case_end

echo "=== closeImplications is symmetric and comparison-only ==="
case_begin "e-close-implications" "hooks/lib/jev/decision-record.js"
CI_JS="$TMPROOT/close-implications.js"
cat > "$CI_JS" <<'JS'
try {
  const { closeImplications } = require(process.argv[2]);
  const s = (x) => Array.from(x).sort().join(",");
  const input = new Set(["S1b-wide-change"]);
  const out = closeImplications(input);
  process.stdout.write([s(out), s(input), s(closeImplications(new Set(["S2-architecture"]))), s(closeImplications(new Set()))].join("|"));
} catch (e) { process.stdout.write("THREW:" + (e.code || e.message)); }
JS
CI_OUT="$(run_with_timeout 30 node "$(np "$CI_JS")" "$RECORD_JS" 2>/dev/null)"
check "S1b adds S1; input untouched; other sets unchanged" "S1-multi-file,S1b-wide-change|S1b-wide-change|S2-architecture|" "$CI_OUT"
case_end
case_begin "e-compare-undecidable-either-side" "hooks/lib/jev/decision-record.js"
CMP_JS="$TMPROOT/compare-undecidable.js"
cat > "$CMP_JS" <<'JS'
try {
  const { compare } = require(process.argv[2]);
  const ok = (answer) => ({ status: "ok", answer });
  const f = (c) => String(c.agreement) + "/" + String(c.agreement_by_signal);
  process.stdout.write([f(compare(ok("S0-undecidable"), ok(""))), f(compare(ok("S1-multi-file"), ok("S1-multi-file,S0-undecidable"))),
    String(compare(ok(""), ok("")).agreement)].join("|"));
} catch (e) { process.stdout.write("THREW:" + (e.code || e.message)); }
JS
CMP_OUT="$(run_with_timeout 30 node "$(np "$CMP_JS")" "$RECORD_JS" 2>/dev/null)"
check "S0 on the jev side or mixed into the llm side is not compared; none vs none still agrees" "null/null|null/null|true" "$CMP_OUT"
case_end

echo "=== one side missing ==="
case_begin "e-post-only-not-run" "hooks/jev-shadow-post.js"
fx_new e-postonly
SID="jev2460-e-postonly"
mock_mode '{}'
mkpayload "$FX/io/post.json" post "$SID" toolu_e_postonly
run_hook post "$FX/io/post.json"
check "post without pre: one record, jev not-run, llm ok, agreement null" "1|not-run|ok|null" \
  "$(rq toolu_e_postonly 'recs.length + "|" + (r && [r.jev.status, r.llm.status, String(r.agreement)].join("|"))')"
check "post without pre sends nothing to Jev" "0" "$(mock_count systemone)"
case_end

case_begin "e-pre-only-ttl-missing-once" "hooks/lib/jev/pending.js"
fx_new e-preonly
SID="jev2460-e-preonly"
mock_mode '{}'
mkpayload "$FX/io/pre.json" pre "$SID" toolu_e_orphan
run_hook pre "$FX/io/pre.json"
check "pre leaves exactly one pending file" "1" "$(pending_count)"
hq age "$(np "$JEVDIR/$SID/pending")" 3900000 --recursive
mkpayload "$FX/io/post2.json" post "$SID" toolu_e_trigger1
run_hook post "$FX/io/post2.json"
check "after the 60-min TTL: one llm-missing record with null agreement" "1|missing|ok|null" \
  "$(rq toolu_e_orphan 'recs.length + "|" + (r && [r.llm.status, r.jev.status, String(r.agreement)].join("|"))')"
mkpayload "$FX/io/post3.json" post "$SID" toolu_e_trigger2
run_hook post "$FX/io/post3.json"
check "a second sweep does not duplicate the orphan record" "1" "$(rq toolu_e_orphan 'recs.length')"
check "the orphan pending file is gone" "0" "$(pending_count)"
case_end

case_begin "e-pending-ttl-override" "hooks/lib/jev/pending.js"
fx_new e-ttl
SID="jev2460-e-ttl"
mkpayload "$FX/io/pre.json" pre "$SID" toolu_e_ttl
run_hook pre "$FX/io/pre.json"
hq age "$(np "$JEVDIR/$SID/pending")" 5000 --recursive
mkpayload "$FX/io/post.json" post "$SID" toolu_e_ttl_trigger
run_hook post "$FX/io/post.json" JEV_PENDING_TTL_MS=1000
check "JEV_PENDING_TTL_MS=1000 sweeps a 5-second-old pending as missing" "missing" "$(rq toolu_e_ttl 'r && r.llm.status')"
case_end

case_begin "e-claimed-orphan-swept" "hooks/lib/jev/pending.js"
fx_new e-claimed
SID="jev2460-e-claimed"
mkpayload "$FX/io/pre.json" pre "$SID" toolu_e_claimed
run_hook pre "$FX/io/pre.json"
PF="$JEVDIR/$SID/pending/toolu_e_claimed.json"
if [ -f "$PF" ]; then mv "$PF" "$JEVDIR/$SID/pending/toolu_e_claimed.claimed-99999" 2>/dev/null; fi
[ -d "$JEVDIR/$SID/pending" ] && hq age "$(np "$JEVDIR/$SID/pending")" 3900000 --recursive
mkpayload "$FX/io/post.json" post "$SID" toolu_e_claimed_trigger
run_hook post "$FX/io/post.json"
check "a stale .claimed-<pid> file becomes one llm-missing record and is removed" "1|missing|0" \
  "$(rq toolu_e_claimed 'recs.length + "|" + (r && r.llm.status)')|$(pending_count)"
case_end

echo "=== hostile tool_use_id ==="
case_begin "e-tool-use-id-traversal-rejected" "hooks/lib/jev/pending.js"
fx_new e-traversal
SID="jev2460-e-traversal"
mkpayload "$FX/io/pre.json" pre "$SID" "../../../escape-2460"
mkpayload "$FX/io/post.json" post "$SID" "../../../escape-2460"
run_hook pre "$FX/io/pre.json"; T_PRE=$HOOK_RC
run_hook post "$FX/io/post.json"; T_POST=$HOOK_RC
check "both hooks exit 0 on a traversal id" "0|0" "$T_PRE|$T_POST"
check "no file named after the traversal id exists anywhere in the fixture" "0" \
  "$(find "$FX" -name '*escape-2460*' 2>/dev/null | wc -l | tr -d ' ')"
check "no pending file was written" "0" "$(pending_count)"
case_end

# hostile_row <row> <sid> <tid>: pre+post with an id the path-segment guard must refuse.
# Nothing may reach Jev or the filesystem: a traversal would land under $FX (or $TMPROOT).
hostile_row() {
  local row="$1" sid="$2" tid="$3" pre_rc
  fx_new "e-hostile-$row"
  mock_mode '{}'
  mkpayload "$FX/io/pre.json" pre "$sid" "$tid"
  mkpayload "$FX/io/post.json" post "$sid" "$tid"
  run_hook pre "$FX/io/pre.json"; pre_rc=$HOOK_RC
  run_hook post "$FX/io/post.json"
  check "$row: pre|post exit, post stdout, Jev requests, files under state/, pending, log" \
    "0|0||0|0|0|nolog" \
    "$pre_rc|$HOOK_RC|$(cat "$OUT")|$(mock_total)|$(find "$FX/state" -type f 2>/dev/null | wc -l | tr -d ' ')|$(pending_count)|$([ -e "$LOG" ] && echo log || echo nolog)"
  check "$row: no escape-*-2460 entry anywhere under the test temp root" "0" \
    "$(find "$TMPROOT" -name '*escape-*-2460*' 2>/dev/null | wc -l | tr -d ' ')"
}
LONG_ID="$(printf 'a%.0s' $(seq 1 129))"

echo "=== hostile session_id ==="
case_begin "e-session-id-traversal-rejected" "hooks/lib/jev/dispatch-gate.js"
hostile_row sid-dotdot-escape "../../escape-sid-2460" toolu_e_hsid1
hostile_row sid-slash "a/escape-sid-2460" toolu_e_hsid2
hostile_row sid-dot "." toolu_e_hsid3
hostile_row sid-dotdot ".." toolu_e_hsid4
hostile_row sid-129-chars "$LONG_ID" toolu_e_hsid5
case_end

case_begin "e-tool-use-id-hostile-table" "hooks/lib/jev/dispatch-gate.js"
hostile_row tid-slash jev2460-e-htid "a/escape-tid-2460"
hostile_row tid-dotdot jev2460-e-htid ".."
hostile_row tid-129-chars jev2460-e-htid "$LONG_ID"
case_end

case_begin "e-id-128-chars-accepted-control" "hooks/lib/jev/state-paths.js"
fx_new e-id128
SID128="${LONG_ID:1}"
mock_mode '{}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID128" toolu_e_id128
check "control: a 128-char session_id pairs into one record after one Jev query" "1|1|$SID128" \
  "$(rq toolu_e_id128 'recs.length')|$(mock_count systemone)|$(rq toolu_e_id128 'r && r.session_id')"
case_end

echo "=== duplicate PostToolUse for one tool_use_id ==="
case_begin "e-duplicate-post-not-paired-twice" "hooks/lib/jev/pending.js"
fx_new e-dup
SID="jev2460-e-dup"
mock_mode '{}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_e_dup
check "fixture: the first post pairs with the pre (jev ok)" "0|1|ok" \
  "$HOOK_RC|$(rq toolu_e_dup 'recs.length')|$(rq toolu_e_dup 'r && r.jev.status')"
LLM_TEXT="SIGNALS: S1-multi-file" run_hook post "$FX/io/post-toolu_e_dup.json"
check "second post exits 0" "0" "$HOOK_RC"
check "second post appends one record that claims no Jev pairing" "2|ok|not-run|null" \
  "$(rq toolu_e_dup 'recs.length + "|" + recs.map(x => x.jev.status).join("|") + "|" + String(recs[1] && recs[1].agreement)')"
check "no second Jev query, no pending or .claimed leftovers" "1|0|0" \
  "$(mock_count systemone)|$(pending_count)|$(find "$JEVDIR" -name '*.claimed-*' 2>/dev/null | wc -l | tr -d ' ')"
case_end

echo "=== a pending file's own point is file content, never trusted ==="
# orphan_with_point <tag> <point-json>: a real pre-hook pending whose point is rewritten.
orphan_with_point() {
  mkpayload "$FX/io/pre-$1.json" pre "$SID" "toolu_e_pt_$1"
  run_hook pre "$FX/io/pre-$1.json"
  hq json-set "$(np "$JEVDIR/$SID/pending/toolu_e_pt_$1.json")" point "$2"
}
# pending_points: the point value of each rewritten pending, one per line.
pending_points() {
  local t
  for t in ctor proto unreg num; do hq json-get "$(np "$JEVDIR/$SID/pending/toolu_e_pt_$t.json")" point; done
}
case_begin "e-orphan-point-not-taken-from-file" "hooks/jev-shadow-post.js"
fx_new e-orphan-point
SID="jev2460-e-orphan-point"
mock_mode '{}'
orphan_with_point ctor '"constructor"'
orphan_with_point proto '"__proto__"'
orphan_with_point unreg '"no-such-point-2460"'
orphan_with_point num '5'
check "fixture: four pending files carrying the rewritten point values" '4|"constructor"|"__proto__"|"no-such-point-2460"|5' \
  "$(pending_count)|$(pending_points | paste -sd'|' -)"
hq age "$(np "$JEVDIR/$SID/pending")" 3900000 --recursive
mkpayload "$FX/io/post-trigger.json" post "$SID" toolu_e_pt_trigger
run_hook post "$FX/io/post-trigger.json"
check "the sweeping post hook exits 0, writes nothing to stdout and still logs its own record" "0|empty|1" \
  "$HOOK_RC|$(stdout_state)|$(rq toolu_e_pt_trigger 'recs.length')"
for t in ctor proto unreg num; do
  check "$t: one llm-missing orphan record, filed under the registered point, jev side kept" "1|complexity-judge|missing|ok" \
    "$(rq "toolu_e_pt_$t" 'recs.length + "|" + (r && [r.point, r.llm.status, r.jev.status].join("|"))')"
done
check "every record in the log names the registered point; all pending files are gone" "5|complexity-judge|0" \
  "$(hq qa "$(np "$LOG")" 'recs.length + "|" + Array.from(new Set(recs.map((x) => String(x.point)))).join(",")')|$(pending_count)"
case_end

echo "=== the parser's temp dir lives under the Jev state dir and is removed ==="
case_begin "e-pair-leaves-no-norm-dir" "hooks/jev-shadow-post.js"
fx_new e-norm
SID="jev2460-e-norm"
mock_mode '{}'
OSTMP_N="$(np "$FX/ostmp")"
mkdir -p "$FX/ostmp"
NORM_ENV=("TMPDIR=$OSTMP_N" "TEMP=$OSTMP_N" "TMP=$OSTMP_N")
check "fixture: a node child given these variables resolves os.tmpdir() to the fixture dir" "true" \
  "$(env "${NORM_ENV[@]}" bash "$RWT" 30 node -e 'const p = require("path"); process.stdout.write(String(p.resolve(require("os").tmpdir()).toLowerCase() === p.resolve(process.argv[1]).toLowerCase()))' "$OSTMP_N" 2>/dev/null)"
LLM_TEXT="SIGNALS: S1-multi-file, S3-security" pair "$SID" toolu_e_norm "${NORM_ENV[@]}"
check "both hooks exit 0; the parser ran on both sides (normalised answers recorded)" "0|0|S1-multi-file|S1-multi-file,S3-security" \
  "$PRE_RC|$HOOK_RC|$(rq toolu_e_norm 'r && [r.jev.answer, r.llm.answer].join("|")')"
check "the session state dir exists and no norm-* entry is left anywhere under the Jev state dir" "present|0" \
  "$([ -d "$JEVDIR/$SID" ] && echo present || echo absent)|$(find "$JEVDIR" -name 'norm-*' 2>/dev/null | wc -l | tr -d ' ')"
check "nothing named *norm-* was created under the OS temp dir the hooks were given" "0" \
  "$(find "$FX/ostmp" -name '*norm-*' 2>/dev/null | wc -l | tr -d ' ')"
case_end

echo "=== an orphan whose hand-off failed is kept for the next sweep ==="
case_begin "e-sweep-keeps-orphan-until-logged" "hooks/lib/jev/pending.js"
fx_new e-sweep-retry
SWEEP_JS="$FX/io/sweep.js"
cat > "$SWEEP_JS" <<'JS'
"use strict";
const pending = require(process.argv[2]);
const sid = "jev2460-e-retry";
const mode = process.argv[3];
// argv[4]: the clock offset in ms this sweep runs at (now() = T0 + offset), so a sweep can
// run past the TTL a previous sweep restarted.
const t0 = Number(process.argv[5]);
const now = () => t0 + Number(process.argv[4] || 0);
if (mode === "seed") {
  for (const t of ["toolu_e_rt_throw", "toolu_e_rt_false", "toolu_e_rt_undef"]) pending.writePending(sid, t, { point: "complexity-judge" });
  process.stdout.write("seeded");
} else if (mode === "concurrent") {
  // A second sweeper at the same now() runs while the first is still handing its orphan over.
  pending.writePending(sid, "toolu_e_rt_conc", { point: "complexity-judge" });
  const seen = [];
  let inner = -1;
  const outer = pending.sweepOrphans(sid, { now, ttlMs: 1000, onOrphan: (tid) => {
    seen.push(tid);
    inner = pending.sweepOrphans(sid, { now, ttlMs: 1000, onOrphan: (t2) => { seen.push(t2); return { ok: true }; } });
    return { ok: true };
  } });
  process.stdout.write([outer, inner, seen.join(",")].join("|"));
} else {
  const seen = [];
  const n = pending.sweepOrphans(sid, { now, ttlMs: 1000, onOrphan: (tid) => {
    seen.push(tid);
    if (mode === "ok") return { ok: true };
    if (tid.endsWith("throw")) throw new Error("append failed");
    return tid.endsWith("false") ? { ok: false } : undefined;
  } });
  process.stdout.write(n + "|" + seen.sort().join(","));
}
JS
T0="$(hq now)"
# sweep_js <mode> [offset-ms]: one sweep process at T0 + offset.
sweep_js() { run_with_timeout 30 node "$(np "$SWEEP_JS")" "$REPO_N/hooks/lib/jev/pending.js" "$1" "${2:-0}" "$T0" 2>> "$ERR_ALL"; }
left() { ls -A "$JEVDIR/jev2460-e-retry/pending" 2>/dev/null | sed 's/\.claimed-[0-9]*-sweep$/:sweep/' | sort | paste -sd, -; }
check "fixture: three pendings" "seeded|3" "$(sweep_js seed)|$(pending_count)"
hq age "$(np "$JEVDIR/jev2460-e-retry/pending")" 3900000 --recursive
check "first sweep hands all three over (throw, {ok:false}, undefined)" "3|toolu_e_rt_false,toolu_e_rt_throw,toolu_e_rt_undef" "$(sweep_js fail)"
check "the throw and {ok:false} orphans stay as -sweep files; the undefined one is removed" \
  "toolu_e_rt_false:sweep,toolu_e_rt_throw:sweep" "$(left)"
check "the failed sweep restarted the TTL: a sweep at the same now() claims nothing" "0||2" "$(sweep_js fail)|$(pending_count)"
check "past the restarted TTL, a sweep that still fails retries both and keeps both" "2|toolu_e_rt_false,toolu_e_rt_throw|2" \
  "$(sweep_js fail 5000)|$(pending_count)"
check "past the next TTL, a sweep that succeeds hands each over once more and removes them" "2|toolu_e_rt_false,toolu_e_rt_throw|0" \
  "$(sweep_js ok 10000)|$(pending_count)"
check "a further sweep finds nothing" "0|" "$(sweep_js ok 20000)"
case_end

echo "=== a concurrent sweeper at the same now() cannot re-claim a -sweep file ==="
case_begin "e-sweep-concurrent-same-now-once" "hooks/lib/jev/pending.js"
fx_new e-sweep-conc
SWEEP_JS_SRC="$SWEEP_JS"
SWEEP_JS="$FX/io/sweep.js"
cp "$SWEEP_JS_SRC" "$SWEEP_JS"
T0="$(( $(hq now) + 3900000 ))"
check "two sweepers at one now(): the first takes the orphan, the second claims nothing; handed over once, nothing left" \
  "1|0|toolu_e_rt_conc|0" "$(sweep_js concurrent)|$(pending_count)"
case_end

# PEND_JS <cmd>: drives pending.js directly in the fixture's state dir (AGENTS_STATE_DIR).
#   seed <age-ms> <name>..: files under jev2460-e-pj's pending dir, mtime now - age.
#   sweep <ttl> [minClaimAgeMs]: one sweep at now; prints "<n>|<onOrphan tids>|<names left>".
#   has <sid>               : hasEntries(sid).
#   rewrite <sid-json> <tid-json>: rewriteClaim's return value, or THREW.
PEND_JS="$TMPROOT/pending-drive.js"
cat > "$PEND_JS" <<'JS'
"use strict";
const fs = require("fs");
const path = require("path");
const pending = require(process.argv[2]);
const [cmd, ...a] = process.argv.slice(3);
const SID = "jev2460-e-pj";
const dir = () => pending.pendingDir(SID);
const left = () => { try { return fs.readdirSync(dir()).sort().join(","); } catch (_e) { return ""; } };
const out = (s) => process.stdout.write(String(s));
if (cmd === "seed") {
  fs.mkdirSync(dir(), { recursive: true });
  const t = (Date.now() - Number(a[0])) / 1000;
  for (const n of a.slice(1)) { fs.writeFileSync(path.join(dir(), n), JSON.stringify({ point: "complexity-judge" })); fs.utimesSync(path.join(dir(), n), t, t); }
  out(left());
} else if (cmd === "sweep") {
  const tids = [];
  const opts = { ttlMs: Number(a[0]), onOrphan: (tid) => { tids.push(tid); return { ok: true }; } };
  if (a[1] !== undefined) opts.minClaimAgeMs = Number(a[1]);
  const n = pending.sweepOrphans(SID, opts);
  out([n, tids.sort().join(","), left()].join("|"));
} else if (cmd === "has") {
  out(pending.hasEntries(a[0]));
} else if (cmd === "rewrite") {
  try { out(pending.rewriteClaim(JSON.parse(a[0]), JSON.parse(a[1]), { llm_observed: null })); } catch (e) { out("THREW:" + e.message); }
}
JS
pj() { run_with_timeout 30 node "$(np "$PEND_JS")" "$REPO_N/hooks/lib/jev/pending.js" "$@" 2>> "$ERR_ALL"; }

echo "=== tidOf: the rightmost mark with a well-formed suffix ==="
case_begin "e-tid-of-rightmost-mark" "hooks/lib/jev/pending.js"
fx_new e-tidof
pj seed 3900000 toolu_a.claimed-x.claimed-12 toolu_b.unlogged-1-2.claimed-5-sweep toolu_c.claimed-3.unlogged-7-8 \
  toolu_m1.claimed-abc toolu_m2.unlogged-123 toolu_m3.claimed-12-sweepX toolu_m4.claimed- toolu_m5.unlogged-1-2-3 > /dev/null
check "a tid that contains a mark is attributed to its rightmost mark; malformed suffixes are not marks and stay" \
  "3|toolu_a.claimed-x,toolu_b.unlogged-1-2,toolu_c.claimed-3|toolu_m1.claimed-abc,toolu_m2.unlogged-123,toolu_m3.claimed-12-sweepX,toolu_m4.claimed-,toolu_m5.unlogged-1-2-3" \
  "$(pj sweep 1000)"
check "a dir holding only malformed names has no entries" "false" "$(pj has jev2460-e-pj)"
case_end

echo "=== hasEntries: only a missing dir is empty ==="
case_begin "e-has-entries-error-classes" "hooks/lib/jev/pending.js"
fx_new e-has
check "missing session dir: false" "false" "$(pj has jev2460-e-has-missing)"
mkdir -p "$JEVDIR/jev2460-e-has-empty/pending"
check "empty pending dir: false" "false" "$(pj has jev2460-e-has-empty)"
: > "$JEVDIR/jev2460-e-has-empty/pending/toolu_x.json"
check "a .json pending: true" "true" "$(pj has jev2460-e-has-empty)"
mkdir -p "$JEVDIR/jev2460-e-has-file"
printf 'x' > "$JEVDIR/jev2460-e-has-file/pending"
check "pending path is a regular file (readdir fails, not ENOENT): true" "true" "$(pj has jev2460-e-has-file)"
mkdir -p "$JEVDIR/jev2460-e-has-tmp/pending"
: > "$JEVDIR/jev2460-e-has-tmp/pending/toolu_x.123.tmp"
check "only a .tmp file: false" "false" "$(pj has jev2460-e-has-tmp)"
: > "$JEVDIR/jev2460-e-has-tmp/pending/toolu_x.unlogged-1-2"
check "an unlogged entry: true" "true" "$(pj has jev2460-e-has-tmp)"
case_end

echo "=== sweepOrphans: a claim younger than minClaimAgeMs is someone else's ==="
case_begin "e-sweep-min-claim-age" "hooks/lib/jev/pending.js"
fx_new e-minage
pj seed 30000 toolu_f1.claimed-11 toolu_f2.claimed-12-sweep toolu_fj.json toolu_fu.unlogged-1-2 > /dev/null
pj seed 120000 toolu_o1.claimed-13 toolu_o2.claimed-14-sweep > /dev/null
check "minClaimAgeMs=60000: fresh claim and -sweep skipped; older claims, .json and unlogged taken" \
  "4|toolu_fj,toolu_fu,toolu_o1,toolu_o2|toolu_f1.claimed-11,toolu_f2.claimed-12-sweep" "$(pj sweep 0 60000)"
check "control: without minClaimAgeMs the same fresh claims are taken" "2|toolu_f1,toolu_f2|" "$(pj sweep 0)"
case_end

echo "=== rewriteClaim never throws on a hostile id ==="
case_begin "e-rewrite-claim-invalid-ids" "hooks/lib/jev/pending.js"
fx_new e-rewrite
# Each row: sid JSON | tid JSON.
while IFS='|' read -r _s _t; do
  [[ -z "$_s" ]] && continue
  check "rewriteClaim($_s, $_t): false, no throw" "false" "$(pj rewrite "$_s" "$_t")"
done <<'TABLE'
"../escape-rw-2460"|"toolu_x"
"."|"toolu_x"
null|"toolu_x"
5|"toolu_x"
"jev2460-e-rw"|"../escape-rw-2460"
"jev2460-e-rw"|".."
"jev2460-e-rw"|null
TABLE
check "nothing was written for a hostile id" "0|0" \
  "$(find "$TMPROOT" -name '*escape-rw-2460*' 2>/dev/null | wc -l | tr -d ' ')|$(find "$FX/state" -type f 2>/dev/null | wc -l | tr -d ' ')"
mkdir -p "$JEVDIR/jev2460-e-rw/pending"
check "control: valid ids with a pending dir rewrite the claim" "true" "$(pj rewrite '"jev2460-e-rw"' '"toolu_x"')"
case_end

echo "=== a post with no pre and an unwritable log leaves an unlogged record, exit 0 ==="
case_begin "e-post-only-append-failure-unlogged" "hooks/jev-shadow-post.js"
fx_new e-unlogged
SID="jev2460-e-unlogged"
mock_mode '{}'
printf 'not a directory\n' > "$FX/state/logs"
LLM_TEXT="SIGNALS: S1-multi-file" mkpayload "$FX/io/post.json" post "$SID" toolu_e_ul
run_hook post "$FX/io/post.json"
check "post exits 0 and writes nothing to stdout" "0|empty" "$HOOK_RC|$(stdout_state)"
check "exactly one .unlogged-<pid>-<ts> file, no .json or claim" "1|1|0" \
  "$(find "$JEVDIR/$SID/pending" -name 'toolu_e_ul.unlogged-*' 2>/dev/null | grep -cE '\.unlogged-[0-9]+-[0-9]+$')|$(pending_count)|$(find "$JEVDIR" -name '*.claimed-*' 2>/dev/null | wc -l | tr -d ' ')"
UL="$(find "$JEVDIR/$SID/pending" -name 'toolu_e_ul.unlogged-*' 2>/dev/null | head -n 1)"
check "it carries the observed llm side and jev not-run" "ok|S1-multi-file|not-run" \
  "$(hq json-expr "$(np "$UL")" 'o && [o.llm_observed.status, o.llm_observed.answer, o.jev.status].join("|")')"
case_end

finish
