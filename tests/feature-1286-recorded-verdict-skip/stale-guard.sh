#!/bin/bash
# shellcheck shell=bash
# tests/feature-1286-recorded-verdict-skip/stale-guard.sh
# Tests: hooks/lib/workflow-state/skip-signal-resolver.js
# Tags: L2, workflow, skip-signal, stale-guard, scope:issue-specific
#
# # L3 gap
# L2 tests inject WORKFLOW_PLANS_DIR to isolate plan artifacts. A real CC session
# (L3) would additionally verify that the guard fires on a live session where
# intent.md / outline.md are actually written by clarify-intent / make-outline-plan.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: skill-orchestration
#
# L3 gap: fs.statSync permission error (EACCES)
# Requires OS-level file permission manipulation that is not reliably cross-platform.
# Expected behavior per spec: fail-closed → false (same as ENOENT). Verified manually.
# Cannot monkeypatch fs.statSync without a mocking framework (Jest/sinon) — not present here.
#
# L3 gap: sids with single-quote, backtick, newline, or embedded whitespace/Unicode
# eval_hvsj interpolates sid/target directly into the node -e string, making these chars
# untestable via this helper. Production code does not validate sid format (SESSION_ID_VALID_RE
# is only used by isTrivial). Coverage is indirect via SG-8/SG-8b (no state file → false).
#
# #1310 stale-guard cases (SG-1..SG-4). Some are RED pre-implementation:
#   SG-2, SG-2b, SG-4 expected to FAIL until hasValidSkipJudgment gains the
#   mtime(artifact) > recorded_at guard and readSkipJudgment checks "recorded_at" in sj.
# Sourced-then-run via the dispatcher; relies on helpers.sh being sourced.

# Isolated plans dir so artifact mtime vs recorded_at is fully controlled.
PLANS_TEST_DIR="$TMPDIR_BASE/plans-test"
mkdir -p "$PLANS_TEST_DIR"
PLANS_TEST_DIR_N="$(cygpath -m "$PLANS_TEST_DIR" 2>/dev/null || echo "$PLANS_TEST_DIR")"

# Call hasValidSkipJudgment with WORKFLOW_PLANS_DIR set (resolver_eval does not).
eval_hvsj() {
  local sid="$1" target="$2"
  WORKFLOW_PLANS_DIR="$PLANS_TEST_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    if (typeof r.hasValidSkipJudgment !== 'function') { console.log('NOT_FUNCTION'); process.exit(0); }
    const result = r.hasValidSkipJudgment('$sid', '$target');
    console.log(result ? 'true' : 'false');
  " 2>&1 || echo "ERROR"
}

# Write a state fixture with a well-formed skip_judgment for the given target,
# stamped with the supplied recorded_at ISO string.
write_sg_state() {
  local sid="$1" target="$2" recorded_at="$3"
  local base cond
  if [ "$target" = "detail" ]; then
    base="$JSON_AT_DETAIL"
    cond='{"sd_c1":true,"sd_c2":true,"sd_c3":true}'
  else
    base="$JSON_AT_OUTLINE"
    cond='{"so_c1":true,"so_c2":true}'
  fi
  printf '%s' "$base" | run_with_timeout node -e "
    let data=''; process.stdin.on('data',d=>data+=d);
    process.stdin.on('end',()=>{
      const s=JSON.parse(data);
      s.steps['$target'].skip_judgment={
        recorded_at:'$recorded_at',
        judgment_source:'orchestrator',
        conditions:$cond,
        all_conditions_met:true
      };
      process.stdout.write(JSON.stringify(s));
    });
  " > "$WORKFLOW_DIR/${sid}.json"
}

# Same as write_sg_state but OMITS the recorded_at field entirely.
write_sg_state_no_recorded_at() {
  local sid="$1" target="$2"
  local base cond
  if [ "$target" = "detail" ]; then
    base="$JSON_AT_DETAIL"
    cond='{"sd_c1":true,"sd_c2":true,"sd_c3":true}'
  else
    base="$JSON_AT_OUTLINE"
    cond='{"so_c1":true,"so_c2":true}'
  fi
  printf '%s' "$base" | run_with_timeout node -e "
    let data=''; process.stdin.on('data',d=>data+=d);
    process.stdin.on('end',()=>{
      const s=JSON.parse(data);
      s.steps['$target'].skip_judgment={
        judgment_source:'orchestrator',
        conditions:$cond,
        all_conditions_met:true
      };
      process.stdout.write(JSON.stringify(s));
    });
  " > "$WORKFLOW_DIR/${sid}.json"
}

echo ""
echo "=== SG-1..SG-8: stale-guard — artifact mtime vs recorded_at binding ==="
# Note: MECHANICAL_RE / BROAD_RE / NEW_API_RE regex constants are covered by module-api.sh;
# they are not in scope for this stale-guard sub-file.

# SG-1: outline, artifact present, recorded_at far future → mtime < recorded_at → NOT stale.
: > "$PLANS_TEST_DIR/sg1-intent.md"
write_sg_state "sg1" "outline" "2099-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "sg1" "outline")"
check "SG-1: outline artifact present, recorded_at=2099 → true" "true" "$OUT"

# SG-1b: detail, artifact present, recorded_at far future → NOT stale.
: > "$PLANS_TEST_DIR/sg1b-outline.md"
write_sg_state "sg1b" "detail" "2099-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "sg1b" "detail")"
check "SG-1b: detail artifact present, recorded_at=2099 → true" "true" "$OUT"

# SG-2: outline, artifact present, recorded_at far past → mtime > recorded_at → STALE. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg2-intent.md"
write_sg_state "sg2" "outline" "2020-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "sg2" "outline")"
check "SG-2: outline artifact edited after recorded_at (stale) → false" "false" "$OUT"

# SG-2b: detail, artifact present, recorded_at far past → STALE. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg2b-outline.md"
write_sg_state "sg2b" "detail" "2020-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "sg2b" "detail")"
check "SG-2b: detail artifact edited after recorded_at (stale) → false" "false" "$OUT"

# SG-3: outline, artifact ABSENT → stale (per intent spec: artifact 欠損 → stale 扱い → false). [RED pre-impl]
# Note: the implementation uses ENOENT→false; existing RV-* tests that omit WORKFLOW_PLANS_DIR
# will need artifact files added when write-code implements the guard.
rm -f "$PLANS_TEST_DIR/sg3-intent.md"
write_sg_state "sg3" "outline" "2020-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "sg3" "outline")"
check "SG-3: artifact absent (outline) → false (stale per spec)" "false" "$OUT"

# SG-3b: detail, artifact ABSENT → false. Symmetric of SG-3 for detail target. [RED pre-impl]
rm -f "$PLANS_TEST_DIR/sg3b-outline.md"
write_sg_state "sg3b" "detail" "2020-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "sg3b" "detail")"
check "SG-3b: artifact absent (detail) → false (stale per spec)" "false" "$OUT"

# SG-4: recorded_at field missing → readSkipJudgment returns null → false. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg4-intent.md"
write_sg_state_no_recorded_at "sg4" "outline"
OUT="$(eval_hvsj "sg4" "outline")"
check "SG-4: recorded_at field missing (outline) → false" "false" "$OUT"

# SG-4b: same as SG-4 for detail target. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg4b-outline.md"
write_sg_state_no_recorded_at "sg4b" "detail"
OUT="$(eval_hvsj "sg4b" "detail")"
check "SG-4b: recorded_at field missing (detail) → false" "false" "$OUT"

# Helper: write fixture with a JS expression for recorded_at (for null / non-date tests).
# ra_js is a literal JS expression embedded directly in the node script — no env var / pipe needed.
# Call: write_sg_state_raw_ra <sid> <target> <js-expr>
#   null → "null"   empty string → '""'   non-date → '"not-a-date"'
write_sg_state_raw_ra() {
  local sid="$1" target="$2" ra_js="$3"
  local base cond
  if [ "$target" = "detail" ]; then
    base="$JSON_AT_DETAIL"
    cond='{"sd_c1":true,"sd_c2":true,"sd_c3":true}'
  else
    base="$JSON_AT_OUTLINE"
    cond='{"so_c1":true,"so_c2":true}'
  fi
  printf '%s' "$base" | run_with_timeout node -e "
    let data=''; process.stdin.on('data',d=>data+=d);
    process.stdin.on('end',()=>{
      const s=JSON.parse(data);
      s.steps['$target'].skip_judgment={
        recorded_at:$ra_js,
        judgment_source:'orchestrator',
        conditions:$cond,
        all_conditions_met:true
      };
      process.stdout.write(JSON.stringify(s));
    });
  " > "$WORKFLOW_DIR/${sid}.json"
}

# SG-5: recorded_at is a non-date string → isNaN guard → false. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg5-intent.md"
write_sg_state_raw_ra "sg5" "outline" '"not-a-date"'
OUT="$(eval_hvsj "sg5" "outline")"
check "SG-5: recorded_at='not-a-date' (NaN, outline) → false" "false" "$OUT"

# SG-5b: empty-string recorded_at → NaN → false. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg5b-intent.md"
write_sg_state_raw_ra "sg5b" "outline" '""'
OUT="$(eval_hvsj "sg5b" "outline")"
check "SG-5b: recorded_at='' (empty string, NaN, outline) → false" "false" "$OUT"

# SG-5c: non-date recorded_at, detail target — symmetric of SG-5. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg5c-outline.md"
write_sg_state_raw_ra "sg5c" "detail" '"not-a-date"'
OUT="$(eval_hvsj "sg5c" "detail")"
check "SG-5c: recorded_at='not-a-date' (NaN, detail) → false" "false" "$OUT"

# SG-6: recorded_at is null (field present, value null) → epoch 0 → mtime > 0 → stale → false. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg6-intent.md"
write_sg_state_raw_ra "sg6" "outline" "null"
OUT="$(eval_hvsj "sg6" "outline")"
check "SG-6: recorded_at=null (epoch, outline) → false (stale)" "false" "$OUT"

# SG-6b: null recorded_at, detail target — symmetric of SG-6. [RED pre-impl]
: > "$PLANS_TEST_DIR/sg6b-outline.md"
write_sg_state_raw_ra "sg6b" "detail" "null"
OUT="$(eval_hvsj "sg6b" "detail")"
check "SG-6b: recorded_at=null (epoch, detail) → false (stale)" "false" "$OUT"

# SG-7: recorded_at 1ms AFTER artifact mtime → strict > means not stale → true.
# Inline path to avoid A=... placement issue (env-var-after-command is a positional arg, not env).
: > "$PLANS_TEST_DIR/sg7-intent.md"
SG7_MTIME_MS="$(run_with_timeout node -e "process.stdout.write(String(require('fs').statSync('$PLANS_TEST_DIR_N/sg7-intent.md').mtimeMs))" 2>/dev/null)"
SG7_JUST_AFTER="$(run_with_timeout node -e "process.stdout.write(new Date(Number('$SG7_MTIME_MS')+1).toISOString())" 2>/dev/null)"
write_sg_state "sg7" "outline" "$SG7_JUST_AFTER"
OUT="$(eval_hvsj "sg7" "outline")"
check "SG-7: recorded_at 1ms after mtime → not stale → true" "true" "$OUT"

# SG-7b: recorded_at exactly equals artifact mtime → strict > so equal is not stale → true.
: > "$PLANS_TEST_DIR/sg7b-intent.md"
SG7B_MTIME_MS="$(run_with_timeout node -e "process.stdout.write(String(require('fs').statSync('$PLANS_TEST_DIR_N/sg7b-intent.md').mtimeMs))" 2>/dev/null)"
SG7B_EXACT_ISO="$(run_with_timeout node -e "process.stdout.write(new Date(Number('$SG7B_MTIME_MS')).toISOString())" 2>/dev/null)"
write_sg_state "sg7b" "outline" "$SG7B_EXACT_ISO"
OUT="$(eval_hvsj "sg7b" "outline")"
check "SG-7b: recorded_at exactly equals mtime (strict >) → not stale → true" "true" "$OUT"

# SG-7c: detail target, recorded_at 1ms after mtime → not stale → true. Symmetric of SG-7.
: > "$PLANS_TEST_DIR/sg7c-outline.md"
SG7C_MTIME_MS="$(run_with_timeout node -e "process.stdout.write(String(require('fs').statSync('$PLANS_TEST_DIR_N/sg7c-outline.md').mtimeMs))" 2>/dev/null)"
SG7C_JUST_AFTER="$(run_with_timeout node -e "process.stdout.write(new Date(Number('$SG7C_MTIME_MS')+1).toISOString())" 2>/dev/null)"
write_sg_state "sg7c" "detail" "$SG7C_JUST_AFTER"
OUT="$(eval_hvsj "sg7c" "detail")"
check "SG-7c: detail recorded_at 1ms after mtime → not stale → true" "true" "$OUT"

# SG-8: adversarial sessionId with path traversal → no state file exists → false (fail-closed).
# Note: eval_hvsj uses shell interpolation ('$sid') so sids with single-quote chars cannot be
# tested here (test-helper limitation, not a gap in production coverage).
# SESSION_ID_VALID_RE is only used by isTrivial (line 62), not hasValidSkipJudgment.
OUT="$(eval_hvsj "../sg8-traversal" "outline")"
check "SG-8: adversarial sid '../sg8-traversal' → false (fail-closed)" "false" "$OUT"

# SG-8b: adversarial sid with no state file → false (fail-closed).
# Uses only shell-safe chars; single-quote/backtick/newline/space/Unicode exclusion
# is documented in the top-level L3 gap section.
OUT="$(eval_hvsj "sg8b-no-state" "outline")"
check "SG-8b: adversarial sid (no state file) → false (fail-closed)" "false" "$OUT"

# SG-9: idempotency — two consecutive calls on the same fixture/artifact → identical results.
: > "$PLANS_TEST_DIR/sg9-intent.md"
write_sg_state "sg9" "outline" "2099-01-01T00:00:00.000Z"
OUT1="$(eval_hvsj "sg9" "outline")"
OUT2="$(eval_hvsj "sg9" "outline")"
check "SG-9a: idempotency first call → true" "true" "$OUT1"
check "SG-9b: idempotency second call same result → true" "true" "$OUT2"

# SG-10: invalid targetStep ("review" is not a skip target) → no skip_judgment entry → false.
write_sg_state "sg10" "outline" "2099-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "sg10" "review")"
check "SG-10: invalid targetStep 'review' → false" "false" "$OUT"

# SG-11: UUID-format session ID with hyphens → artifact mapping works correctly.
: > "$PLANS_TEST_DIR/a73ad75f-test-intent.md"
write_sg_state "a73ad75f-test" "outline" "2099-01-01T00:00:00.000Z"
OUT="$(eval_hvsj "a73ad75f-test" "outline")"
check "SG-11: UUID-format session ID (hyphens) → artifact maps → true" "true" "$OUT"

# SG-12: boolean recorded_at=false → Date(false)=Date(0)=epoch → mtime > 0 → stale → false. [RED pre-impl]
# Covers non-string types that Date() may parse numerically.
: > "$PLANS_TEST_DIR/sg12-intent.md"
write_sg_state_raw_ra "sg12" "outline" "false"
OUT="$(eval_hvsj "sg12" "outline")"
check "SG-12: recorded_at=false (boolean → epoch → stale) → false" "false" "$OUT"

# SG-14: mutation test — record when fresh, touch artifact after, verify flips. [RED pre-impl]
# End-to-end flow: fresh file → not stale → mutate file → stale.
: > "$PLANS_TEST_DIR/sg14-intent.md"
SG14_MTIME_MS="$(run_with_timeout node -e "process.stdout.write(String(require('fs').statSync('$PLANS_TEST_DIR_N/sg14-intent.md').mtimeMs))" 2>/dev/null)"
SG14_JUST_AFTER="$(run_with_timeout node -e "process.stdout.write(new Date(Number('$SG14_MTIME_MS')+1).toISOString())" 2>/dev/null)"
write_sg_state "sg14" "outline" "$SG14_JUST_AFTER"
OUT1="$(eval_hvsj "sg14" "outline")"
check "SG-14a: artifact not mutated yet → not stale → true" "true" "$OUT1"
: > "$PLANS_TEST_DIR/sg14-intent.md"
OUT2="$(eval_hvsj "sg14" "outline")"
check "SG-14b: artifact mutated after recorded_at → stale → false" "false" "$OUT2"

# SG-15: malformed state JSON + present artifact → readSkipJudgment returns null → false.
# readState fails (JSON parse error) → readSkipJudgment null → hasValidSkipJudgment false.
# This is GREEN pre-impl (readSkipJudgment already handles exceptions by returning null).
: > "$PLANS_TEST_DIR/sg15-intent.md"
printf '%s' '{invalid-json' > "$WORKFLOW_DIR/sg15.json"
OUT="$(eval_hvsj "sg15" "outline")"
check "SG-15: malformed state JSON → fail-closed → false" "false" "$OUT"

# SG-13: fs.statSync throws EACCES → fail-closed → false. [RED pre-impl]
# Monkeypatching works without a mocking framework because Node's module cache shares
# a single 'fs' instance — patching after require() affects the resolver's fs reference.
# readState (state-io) uses readFileSync, so patching statSync only affects the new guard.
: > "$PLANS_TEST_DIR/sg13-intent.md"
write_sg_state "sg13" "outline" "2099-01-01T00:00:00.000Z"
OUT="$(WORKFLOW_PLANS_DIR="$PLANS_TEST_DIR_N" run_with_timeout node -e "
  const fs = require('fs');
  const r = require('$RESOLVER_N');
  const origStat = fs.statSync;
  fs.statSync = function() { const e = new Error('EACCES: permission denied'); e.code = 'EACCES'; throw e; };
  let result;
  try { result = r.hasValidSkipJudgment('sg13', 'outline'); } finally { fs.statSync = origStat; }
  console.log(result ? 'true' : 'false');
" 2>&1 || echo "ERROR")"
check "SG-13: statSync EACCES → fail-closed → false" "false" "$OUT"

