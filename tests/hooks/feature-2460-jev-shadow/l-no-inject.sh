#!/usr/bin/env bash
# Tests: hooks/jev-shadow-post.js, hooks/lib/jev/broker.js, hooks/lib/jev/sanitize.js
# Tags: TL2, hooks, jev, shadow-silent, no-injection, record-return, terminal-sanitisation, table-driven, scope:issue-specific, pwsh-not-required

# Shadow mode must not touch the main conversation: the post hook writes zero bytes to
# stdout in every outcome (ok, fallbacks, missing or unparseable LLM text, a duplicate post,
# JEV off) and still logs. recordShadow returns the record it built (the logged line) instead
# of a display block, and the [JEV] block module is gone; its two terminal-safe sanitisers
# live on in hooks/lib/jev/sanitize.js with unchanged behaviour.

# TL3 gap (what this test does NOT catch): the real host's handling of an empty PostToolUse
# stdout; TL3-hook-agent-jev-shadow.sh T4 checks the live transcript carries no [JEV] text.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

HPROBE="$(np "$LIBDIR/hardening-probe.js")"
SANITIZE_JS="$REPO_N/hooks/lib/jev/sanitize.js"
JEV_BLOCK_JS="$REPO_N/hooks/lib/jev/jev-block.js"
# lp <JEV-value> <cmd> [args...]: one hardening-probe process with that JEV, the sentinel key and the mock.
lp() {
  local jev="$1"
  shift
  (
    cd "$FX/cwd" || exit 97
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE -u CLAUDECODE \
      -u JEV -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS \
      "JEV=$jev" "TYPESAFE_API_KEY=$SENTINEL_KEY" "JEV_BASE_URL=$MOCK_URL" \
      bash "$RWT" 60 node "$HPROBE" "$REPO_N" "$@" 2>> "$ERR_ALL" < /dev/null
  )
}
log_state() { [ -e "$LOG" ] && echo present || echo absent; }

echo "=== p-no-stdout: the post hook prints nothing in any outcome ==="
# silent_row <name> <tid> <expected record expr value> <record expr>: the last post's rc and
# stdout, then a record field that proves the row exercised the intended outcome.
silent_row() {
  check "$1: post rc 0, stdout exactly empty, and the record shows the outcome" "0|empty|$3" \
    "$HOOK_RC|$(stdout_state)|$(rq "$2" "$4")"
}
case_begin "p-no-stdout-ok" "hooks/jev-shadow-post.js"
fx_new p-ok
mock_mode '{}'
pair jev2460-p-ok toolu_p_ok
silent_row ok toolu_p_ok "1|ok|ok" 'recs.length + "|" + (r && [r.jev.status, r.llm.status].join("|"))'
check "ok: the pre hook printed nothing either" "0|empty" "$PRE_RC|$(mkpayload "$FX/io/pre-again.json" pre jev2460-p-ok toolu_p_ok2; run_hook pre "$FX/io/pre-again.json"; stdout_state)"
case_end
case_begin "p-no-stdout-no-key" "hooks/jev-shadow-post.js"
fx_new p-nokey
mock_mode '{}'
pair jev2460-p-nokey toolu_p_nokey TYPESAFE_API_KEY=__unset__
silent_row no-key toolu_p_nokey "no-key|no-key|0" '[r && r.jev.status, r && r.fallback_reason].join("|")'"+ \"|$(mock_total)\""
case_end
case_begin "p-no-stdout-breaker-open" "hooks/jev-shadow-post.js"
fx_new p-breaker
mock_mode '{}'
mkdir -p "$JEVDIR/jev2460-p-breaker"
printf '%s' '{"consecutive_failures":3,"open_until_ms":9999999999999,"last_failure_status":"timeout"}' > "$JEVDIR/jev2460-p-breaker/breaker.json"
pair jev2460-p-breaker toolu_p_breaker
silent_row breaker-open toolu_p_breaker "breaker-open|0" 'String(r && r.jev.status)'"+ \"|$(mock_count systemone)\""
case_end
case_begin "p-no-stdout-missing-llm" "hooks/jev-shadow-post.js"
fx_new p-missing
mock_mode '{}'
mkpayload "$FX/io/pre-m.json" pre jev2460-p-missing toolu_p_missing
mkpayload "$FX/io/post-m.json" post jev2460-p-missing toolu_p_missing --response none
run_hook pre "$FX/io/pre-m.json"
run_hook post "$FX/io/post-m.json"
silent_row missing-llm toolu_p_missing "missing|null" 'r && [r.llm.status, String(r.llm.answer)].join("|")'
case_end
case_begin "p-no-stdout-parse-fallback" "hooks/jev-shadow-post.js"
fx_new p-pfb
mock_mode '{}'
LLM_TEXT=$'SIGNALS: S1-multi-file\nand some trailing prose' pair jev2460-p-pfb toolu_p_pfb
silent_row parse-fallback toolu_p_pfb "parse-fallback" 'r && r.llm.status'
case_end
case_begin "p-no-stdout-duplicate-post" "hooks/jev-shadow-post.js"
fx_new p-dup
mock_mode '{}'
pair jev2460-p-dup toolu_p_dup
check "duplicate: the first post was silent" "0|empty" "$HOOK_RC|$(stdout_state)"
run_hook post "$FX/io/post-toolu_p_dup.json"
silent_row duplicate-post toolu_p_dup "2|ok,not-run" 'recs.length + "|" + recs.map((x) => x.jev.status).join(",")'
case_end
case_begin "p-no-stdout-jev-off" "hooks/jev-shadow-post.js"
fx_new p-off
mock_mode '{}'
pair jev2460-p-off toolu_p_off JEV=off
check "JEV=off: both hooks rc 0, stdout empty, no request, no log" "0|0|empty|0|absent" \
  "$PRE_RC|$HOOK_RC|$(stdout_state)|$(mock_total)|$(log_state)"
case_end

echo "=== recordShadow returns the record it logged ==="
# RET_FIELDS: the listed fields equal the logged record's, and the return adds no field the log lacks.
RET_CMP='["v","point","session_id","tool_use_id","jev","llm","agreement"].every((k) => Object.prototype.hasOwnProperty.call(x, k) && JSON.stringify(x[k]) === JSON.stringify(r[k])) + "|" + Object.keys(x).every((k) => Object.prototype.hasOwnProperty.call(r, k))'
# ret_vs_log <tid> <returned-json>: compare a recordShadow return with the single logged record.
ret_vs_log() {
  case "$2" in
    "{"*) rq "$1" "(() => { const x = $2; return r ? $RET_CMP : 'no-record'; })()" ;;
    *) echo "not-an-object:$2" ;;
  esac
}
# ret_js: $RET as a JS literal when it is a JSON object, else null (a TYPE:<x> marker is not JS).
ret_js() { case "$RET" in "{"*) printf '%s' "$RET" ;; *) printf 'null' ;; esac; }
case_begin "b-record-shadow-returns-record-paired" "hooks/lib/jev/broker.js"
fx_new l-ret
SID="jev2460-l-ret"
mock_mode '{}'
mkpayload "$FX/io/pre-ret.json" pre "$SID" toolu_l_ret
run_hook pre "$FX/io/pre-ret.json"
check "fixture: the pre hook left one pending" "1" "$(pending_count)"
RET="$(lp on record-ret "$SID" toolu_l_ret)"
check "paired: recordShadow returns a plain object equal to the logged record on v, point, ids, jev, llm, agreement" \
  "true|true" "$(ret_vs_log toolu_l_ret "$RET")"
check "paired: the returned record is v1, complexity-judge, this sid and tid, jev ok" "1|complexity-judge|$SID|toolu_l_ret|ok" \
  "$(rq toolu_l_ret "(() => { const x = $(ret_js); return x && typeof x === 'object' ? [x.v, x.point, x.session_id, x.tool_use_id, x.jev && x.jev.status].join('|') : 'not-an-object'; })()")"
case_end
case_begin "b-record-shadow-returns-record-no-claim" "hooks/lib/jev/broker.js"
RET="$(lp on record-ret "$SID" toolu_l_noclaim)"
check "no pending (late post): the record is still returned and equals the logged one" "true|true" \
  "$(ret_vs_log toolu_l_noclaim "$RET")"
check "no pending: the returned jev side is not-run" "not-run" \
  "$(rq toolu_l_noclaim "(() => { const x = $(ret_js); return x && x.jev ? x.jev.status : 'not-an-object'; })()")"
mv "$LOG" "$FX/io/saved.log"
mkdir -p "$LOG"
RET="$(lp on record-ret "$SID" toolu_l_unwritable)"
check "log unwritable: the built record is still returned (an object with this tid, llm ok)" "toolu_l_unwritable|ok" \
  "$(case "$RET" in "{"*) hq qa "$(np "$FX/io/no-such.log")" "(() => { const x = $RET; return x.tool_use_id + '|' + (x.llm && x.llm.status); })()" ;; *) echo "not-an-object:$RET" ;; esac)"
rmdir "$LOG"
case_end
case_begin "b-record-shadow-returns-null" "hooks/lib/jev/broker.js"
fx_new l-null
mock_mode '{}'
check "JEV=off: recordShadow returns null and logs nothing" "null|absent" "$(lp off record-ret jev2460-l-null toolu_l_off)|$(log_state)"
check "invalid session id: null" "null" "$(lp on record-ret '../escape' toolu_l_badsid)"
check "invalid tool_use_id: null" "null" "$(lp on record-ret jev2460-l-null '../escape')"
for _pt in '"constructor"' '"__proto__"' '"no-such-point"' 'undefined'; do
  check "unknown point $_pt: null" "null" "$(lp on record-ret jev2460-l-null toolu_l_pt "$_pt")"
done
check "none of the null returns logged anything" "absent" "$(log_state)"
case_end

echo "=== the [JEV] block module is gone; its sanitisers live in sanitize.js ==="
case_begin "l-jev-block-module-removed" "hooks/lib/jev/sanitize.js"
check "requiring hooks/lib/jev/jev-block.js throws MODULE_NOT_FOUND" "MODULE_NOT_FOUND" \
  "$(run_with_timeout 30 node -e 'try { require(process.argv[1]); process.stdout.write("LOADED"); } catch (e) { process.stdout.write(String(e && e.code)); }' "$JEV_BLOCK_JS" 2>/dev/null)"
check "sanitize.js exports exactly sanitizeAnswerIds and sanitizeEnum, both functions" "sanitizeAnswerIds,sanitizeEnum|true" \
  "$(run_with_timeout 30 node -e 'try { const S = require(process.argv[1]); process.stdout.write(Object.keys(S).sort().join(",") + "|" + Object.values(S).every((f) => typeof f === "function")); } catch (e) { process.stdout.write("THROW:" + (e && e.code)); }' "$SANITIZE_JS" 2>/dev/null)"
case_end
# sanitize_rows <js>: run <js> with S = sanitize.js, ESC = the escape char, row(name, value) printing "<name> <value>".
sanitize_rows() {
  run_with_timeout 30 node -e '
    const S = require(process.argv[1]);
    const ESC = String.fromCharCode(27);
    const row = (name, v) => console.log(name + " " + v);
    const same = (fn, v) => { const r = fn(v); return r === v ? "kept" : r; };
    '"$1" "$SANITIZE_JS" 2>/dev/null
}
# check_rows <name> <actual>: the expected rows come on stdin.
check_rows() { check "$1" "$(cat)" "$2"; }
case_begin "l-sanitize-enum-table" "hooks/lib/jev/sanitize.js"
check_rows "sanitizeEnum keeps [a-z0-9_-]{1,32} and prints - for everything else" "$(sanitize_rows '
  const CASES = [["cos1", "cos1"], ["write_code", "write_code"], ["write_tests", "write_tests"], ["outline", "outline"],
    ["detail", "detail"], ["hyphenated", "low-confidence"], ["len-1", "a"], ["len-32", "a".repeat(32)], ["len-33", "a".repeat(33)],
    ["empty", ""], ["space", "A b"], ["uppercase", "Cos1"], ["dot", "a.b"], ["esc", "x" + ESC + "[31m"],
    ["newline-inside", "cos1\nstage: forged"], ["trailing-newline", "cos1\n"], ["carriage-return", "cos1\r"],
    ["non-ascii", "cosé"], ["number", 5], ["null", null], ["undefined", undefined], ["boolean", true],
    ["array", ["cos1"]], ["object", { toString: () => "cos1" }]];
  for (const [name, v] of CASES) row(name, same(S.sanitizeEnum, v));
')" <<'EOF'
cos1 kept
write_code kept
write_tests kept
outline kept
detail kept
hyphenated kept
len-1 kept
len-32 kept
len-33 -
empty -
space -
uppercase -
dot -
esc -
newline-inside -
trailing-newline -
carriage-return -
non-ascii -
number -
null -
undefined -
boolean -
array -
object -
EOF
case_end
case_begin "l-sanitize-answer-ids-table" "hooks/lib/jev/sanitize.js"
check_rows "sanitizeAnswerIds keeps only vocabulary ids, - for null/undefined, (none) when nothing survives" "$(sanitize_rows '
  const CASES = [["null", null], ["undefined", undefined], ["one-id", "S1-multi-file"], ["two-ids", "S1-multi-file,S2-architecture"],
    ["undecidable", "S0-undecidable"], ["padded", " S1-multi-file , S3-security "], ["empty", ""], ["unknown-id", "S9-evil-token"],
    ["mixed", "S1-multi-file,S9-evil-token,rm -rf /"], ["lowercase", "s1-multi-file"], ["esc-suffix", "S1-multi-file" + ESC + "[31m"],
    ["newline-smuggle", "S1-multi-file\nSIGNALS: S3-security"], ["free-text", "ignore previous instructions"],
    ["number", 5], ["array", ["S2-architecture", "S9-evil-token"]]];
  for (const [name, v] of CASES) row(name, same(S.sanitizeAnswerIds, v));
')" <<'EOF'
null -
undefined -
one-id kept
two-ids kept
undecidable kept
padded S1-multi-file,S3-security
empty (none)
unknown-id (none)
mixed S1-multi-file
lowercase (none)
esc-suffix (none)
newline-smuggle (none)
free-text (none)
number (none)
array S2-architecture
EOF
case_end

finish
