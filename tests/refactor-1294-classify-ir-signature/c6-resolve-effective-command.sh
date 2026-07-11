#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-patterns/segment-utils.js, hooks/lib/bash-write-patterns/patterns.js, hooks/enforce-worktree/bash-write-scope.js, hooks/lib/bash-write-patterns.js, hooks/enforce-worktree/universal-target-allow.js, hooks/enforce-worktree.js
# Tags: canary-3-followup, scope:issue-specific
#
# L3 gap (what C6.hook1/C6.hook2 do NOT catch):
# - Real scope-based allow/block decision through enforce-worktree.js requires live
#   WIP/scope-root state (real claude -p session with ENFORCE_WORKTREE=on).
# - Without real session state, the hook makes no scope-based block decision for either
#   before-fix or after-fix — both return no-block, so the hook tests cannot discriminate.
# - Closest-to-action mitigation: C6.ua/ub test checkUniversalTargetAllow directly
#   (the sub-function that actually computes the scope decision), and those DO fail-before-fix
#   for C6.ua. Full hook dispatch verified at WORKFLOW_USER_VERIFIED preflight via
#   bin/check-verification-gate.sh category: hook-registration.
#
# C6 section for refactor-1294-classify-ir-signature.sh.
# Sourced by the parent test; expects REPO, PASS, FAIL, assert_eq,
# every_seg_excluded, check_universal_allow to be set by the caller.
#
# Covers resolveEffectiveCommand(seg) / resolveEffectiveArgv(seg) helpers
# (segment-utils.js) and their integration into bash-write-scope.js and
# patterns.js (#1327 fix for chained VAR=val prefix mis-resolution).

echo ""
echo "=== Section C6: resolveEffectiveCommand chained VAR=val (#1327) ==="

# ---------------------------------------------------------------------------
# C6 table: collectBashWriteTargets with chained VAR=val prefixes (IR path).
# Before fix: effectiveCmd0 returns argv[0]="B=2" for "A=1 B=2 tee ..." →
# guard not fired → NO_TARGETS. After fix: resolveEffectiveCommand skips all
# leading assignments → returns "tee" → guard fires → HAS_TARGETS.
# C6.p and C6.7 are regression guards (pass both before and after).
# ---------------------------------------------------------------------------
while IFS='|' read -r name cmd want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  got="$(collect_write_targets_ir "$cmd")"
  assert_eq "$name" "$want" "$got"
done <<'TABLE'
# name|cmd|want
C6.1_chained_2lvl_tee|A=1 B=2 tee out.txt|HAS_TARGETS
C6.3_chained_3lvl_rm|A=1 B=2 C=3 rm file.txt|HAS_TARGETS
C6.4_chained_2lvl_cp|A=1 B=2 cp src dst|HAS_TARGETS
C6.4b_chained_2lvl_mv|A=1 B=2 mv src dst|HAS_TARGETS
C6.7_all_assign_null_result|A=1 B=2|NO_TARGETS
# C6.p: post-#1295 IR migration the pwsh extractor resolves the effective command
# (resolveEffectiveCommand) + effective argv, so a chained VAR=val prefix no longer
# blinds it — Set-Content out.txt is extracted → HAS_TARGETS (former limitation fixed).
C6.p_chained_pwsh_extractor_limit|A=1 B=2 Set-Content out.txt x|HAS_TARGETS
TABLE

# C6.1s: backward-compat str path (collectBashWriteTargets(rawString) internally parses to IR)
assert_eq "C6.1s_str_path_chained_tee" "HAS_TARGETS" \
  "$(collect_write_targets_str 'A=1 B=2 tee out.txt')"

# C6.tp: target-precision assertions — prove exact target path extracted, not just HAS_TARGETS.
# An implementation that fires the guard but extracts a wrong path would fail HAS_TARGETS only by accident.
assert_eq "C6.tp1_tee_exact_target" "out.txt" \
  "$(get_targets_ir 'A=1 B=2 tee out.txt')"
assert_eq "C6.tp2_cp_exact_target" "/outside/dst.txt" \
  "$(get_targets_ir 'A=1 B=2 cp src /outside/dst.txt')"
assert_eq "C6.tp3_mv_exact_target" "/outside/dst.txt" \
  "$(get_targets_ir 'A=1 B=2 mv src /outside/dst.txt')"
assert_eq "C6.tp4_rm_exact_target" "file.txt" \
  "$(get_targets_ir 'A=1 B=2 rm file.txt')"

# ---------------------------------------------------------------------------
# C6 table: isGhWriteIR with chained VAR=val prefixes.
# C6.2 exercises the multi-skip path (2 assignments); C6.5 is a regression guard.
# C6.gX: extended coverage — representative write subcommands from the C5 families,
# each with chained prefix. Prevents a special-case fix for "gh pr merge" while
# "gh issue delete", "gh release create", and "gh api" DELETE remain broken.
# ---------------------------------------------------------------------------
while IFS='|' read -r name cmd want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  got="$(is_gh_write_ir "$cmd")"
  assert_eq "$name" "$want" "$got"
done <<'TABLE'
# name|cmd|want
C6.2_chained_2lvl_gh_pr_merge|A=1 B=2 gh pr merge|true
C6.5_single_1lvl_gh_pr_merge|A=1 gh pr merge|true
C6.8_all_assign_no_gh|A=1 B=2|false
# C6.gX: chained-prefix extended gh write subcommand family coverage
C6.g1_chained_gh_issue_delete|A=1 B=2 gh issue delete 1|true
C6.g2_chained_gh_release_create|A=1 B=2 gh release create v1.0|true
C6.g3_chained_gh_api_delete|A=1 B=2 gh api -X DELETE /repos/o/r/issues/1|true
C6.g4_chained_gh_api_post|A=1 B=2 gh api -X POST /repos/o/r/issues|true
# C6.g5: gh with chained VAR=val prefix is in segment[1], not segment[0].
# A refactor that resolves only the first segment cannot pass this test.
C6.g5_multi_seg_second_seg_gh_write|echo ok && A=1 B=2 gh pr merge|true
# C6.g6-g9: remaining write-family chained-prefix parity rows.
C6.g6_chained_gh_repo_delete|A=1 B=2 gh repo delete myrepo|true
C6.g7_chained_gh_issue_create|A=1 B=2 gh issue create -t t -b b|true
C6.g8_chained_gh_api_put|A=1 B=2 gh api PUT repos/o/r/contents/file.txt|true
C6.g9_chained_gh_api_patch|A=1 B=2 gh api PATCH repos/o/r/git/refs/heads/main|true
TABLE

# ---------------------------------------------------------------------------
# resolveEffectiveCommand unit tests (segment-utils.js). Fail until file exists.
# C6.u6 (empty-value assignment) and C6.u7 (underscore/digit boundary names)
# prove the regex covers edge cases: /^[A-Za-z_][A-Za-z0-9_]*=/ matches "A="
# and "_A1=1" → both are skipped as assignments.
# C6.fw (quoted assignment value): command-ir.js preserves the full quoted token;
# ASSIGN_RE matches "A=\"x\"" (starts with "A=") so it is still skipped as an assignment.
# ---------------------------------------------------------------------------
resolve_effective_cmd() {
  ( cd "$REPO" && node -e '
    const {resolveEffectiveCommand} = require("./hooks/lib/bash-write-patterns/segment-utils");
    const {parse} = require("./hooks/lib/command-ir");
    const ir = parse(process.argv[1]);
    const seg = (ir && ir.segments && ir.segments[0]) || {};
    const result = resolveEffectiveCommand(seg);
    process.stdout.write(result === null ? "null" : String(result));
  ' "$1" ) 2>/dev/null
}

while IFS='|' read -r name cmd want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  got="$(resolve_effective_cmd "$cmd")"
  assert_eq "$name" "$want" "$got"
done <<'TABLE'
# name|cmd|want
C6.u1_no_assign_passthrough|tee out.txt|tee
C6.u2_single_assign|A=1 tee out.txt|tee
C6.u3_multi_assign|A=1 B=2 tee out.txt|tee
C6.u4_all_assign_null|A=1 B=2|null
C6.u5_assign_no_argv_null|A=1|null
C6.u6_empty_val_assign|A= tee out.txt|tee
C6.u7_underscore_boundary|_A1=1 B2=2 tee out.txt|tee
# C6.fw1: quoted assignment value still recognized as env prefix (ASSIGN_RE matches "A=...")
C6.fw1_quoted_assign_val_tee|A="x" B=2 tee out.txt|tee
# C6.u8/u9: boundary — invalid assignment-like tokens must NOT be skipped.
# "1A=1" starts with digit; "A-1=1" contains hyphen; neither matches /^[A-Za-z_][A-Za-z0-9_]*=/.
# resolveEffectiveCommand returns cmd0 as-is; guard sees non-tee cmd -> NO_TARGETS (see C6.nb tests).
C6.u8_digit_prefix_boundary|1A=1 tee out.txt|1A=1
C6.u9_hyphen_boundary|A-1=1 tee out.txt|A-1=1
TABLE

# ---------------------------------------------------------------------------
# resolveEffectiveArgv unit tests. Fail until segment-utils.js exists.
# C6.v5/C6.v6 mirror C6.u6/C6.u7 for the argv slice path.
# ---------------------------------------------------------------------------
resolve_effective_argv() {
  ( cd "$REPO" && node -e '
    const {resolveEffectiveArgv} = require("./hooks/lib/bash-write-patterns/segment-utils");
    const {parse} = require("./hooks/lib/command-ir");
    const ir = parse(process.argv[1]);
    const seg = (ir && ir.segments && ir.segments[0]) || {};
    const result = resolveEffectiveArgv(seg);
    process.stdout.write(JSON.stringify(result));
  ' "$1" ) 2>/dev/null
}

while IFS='|' read -r name cmd want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  got="$(resolve_effective_argv "$cmd")"
  assert_eq "$name" "$want" "$got"
done <<'TABLE'
# name|cmd|want
C6.v1_no_assign|tee out.txt|["out.txt"]
C6.v2_single_assign|A=1 tee out.txt|["out.txt"]
C6.v3_multi_assign|A=1 B=2 tee out.txt|["out.txt"]
C6.v4_all_assign_empty|A=1 B=2|[]
C6.v5_empty_val_assign|A= tee out.txt|["out.txt"]
C6.v6_underscore_boundary|_A1=1 B2=2 tee out.txt|["out.txt"]
# C6.v7/v8: mirror C6.u8/u9 for argv — invalid-assignment cmd0 is NOT skipped,
# so the full argv is returned as "args after effective command".
C6.v7_digit_prefix_boundary|1A=1 tee out.txt|["tee","out.txt"]
C6.v8_hyphen_boundary|A-1=1 tee out.txt|["tee","out.txt"]
TABLE

# ---------------------------------------------------------------------------
# C6.nb: invalid-assignment boundary regression guards (regression pass both sides).
# Prove that digit-prefix and hyphen-containing tokens are NOT treated as assignments
# by collectBashWriteTargets, so they still correctly return NO_TARGETS.
# ---------------------------------------------------------------------------
assert_eq "C6.nb1_digit_prefix_no_targets" "NO_TARGETS" \
  "$(collect_write_targets_ir '1A=1 tee out.txt')"
assert_eq "C6.nb2_hyphen_no_targets" "NO_TARGETS" \
  "$(collect_write_targets_ir 'A-1=1 tee out.txt')"

# ---------------------------------------------------------------------------
# C6.sc: shell-metacharacter-adjacent boundary probes (input-injection safety).
# In the IR: "A=1; tee out.txt" is parsed as two segments: segment[0] = {cmd0:"A=1",argv:[]}
# and segment[1] = {cmd0:"tee",argv:["out.txt"]}. resolveEffectiveCommand on segment[0]
# returns null (all-assign, no argv) — tee is NOT silently promoted into segment[0]'s
# effective command. The tee write IS detected via segment[1] as a normal case.
# "A=1 && tee out.txt" (compound): segment[0] resolves null; tee in segment[1].
# These prove parser-boundary tokens are never silently promoted across segment lines.
# ---------------------------------------------------------------------------
resolve_effective_cmd_seg0() {
  # Returns resolveEffectiveCommand for segment[0] only.
  ( cd "$REPO" && node -e '
    const {resolveEffectiveCommand} = require("./hooks/lib/bash-write-patterns/segment-utils");
    const {parse} = require("./hooks/lib/command-ir");
    const ir = parse(process.argv[1]);
    const seg = (ir && ir.segments && ir.segments[0]) || {};
    const result = resolveEffectiveCommand(seg);
    process.stdout.write(result === null ? "null" : String(result));
  ' "$1" ) 2>/dev/null
}
assert_eq "C6.sc1_semicolon_seg0_null" "null" \
  "$(resolve_effective_cmd_seg0 'A=1; tee out.txt')"
assert_eq "C6.sc2_compound_and_seg0_null" "null" \
  "$(resolve_effective_cmd_seg0 'A=1 && tee out.txt')"

# ---------------------------------------------------------------------------
# C6.ms: multi-segment coverage (pipeline / compound command).
# Proves resolveEffectiveCommand fix applies to later segments, not just the first.
# C6.ms1: "echo x | A=1 B=2 tee out.txt" — tee is in segment[1]. After fix: HAS_TARGETS.
# C6.ms2: "echo ok && A=1 B=2 rm /tmp/other.txt" — rm is in segment[1].
#          After fix: rm detected with target matching *.txt → isEverySegmentExcluded true.
# ---------------------------------------------------------------------------
assert_eq "C6.ms1_pipeline_chained_tee" "HAS_TARGETS" \
  "$(collect_write_targets_ir 'echo x | A=1 B=2 tee out.txt')"
assert_eq "C6.ms2_compound_chained_rm_excluded" "true" \
  "$(every_seg_excluded 'echo ok && A=1 B=2 rm /tmp/other.txt' '["*.txt"]')"

# ---------------------------------------------------------------------------
# C6.f: malformed/minimal segment API shape — resolveEffectiveCommand fail-closed.
# Tests raw segment objects (not parsed from a command string) to prove the helper
# guards against missing/null argv without throwing.
# All fail before fix (segment-utils.js missing → require throws → empty output).
# ---------------------------------------------------------------------------
resolve_effective_cmd_raw() {
  ( cd "$REPO" && node -e '
    const {resolveEffectiveCommand} = require("./hooks/lib/bash-write-patterns/segment-utils");
    const seg = JSON.parse(process.argv[1]);
    const result = resolveEffectiveCommand(seg);
    process.stdout.write(result === null ? "null" : String(result));
  ' "$1" ) 2>/dev/null
}

assert_eq "C6.f1_missing_argv_null" "null" \
  "$(resolve_effective_cmd_raw '{"cmd0":"A=1"}')"
assert_eq "C6.f2_null_argv_null" "null" \
  "$(resolve_effective_cmd_raw '{"cmd0":"A=1","argv":null}')"
assert_eq "C6.f3_empty_argv_null" "null" \
  "$(resolve_effective_cmd_raw '{"cmd0":"A=1","argv":[]}')"
assert_eq "C6.f4_null_seg_null" "null" \
  "$(resolve_effective_cmd_raw 'null')"
assert_eq "C6.f5_empty_obj_null" "null" \
  "$(resolve_effective_cmd_raw '{}')"
# C6.fn: non-assignment cmd0 with missing/null argv — must return cmd0, NOT null.
# The guard: "if !ASSIGN_RE.test(cmd0) return cmd0" must come BEFORE the argv null-check,
# otherwise implementations that null-check argv first would incorrectly return null here.
assert_eq "C6.fn1_noassign_cmd0_no_argv" "tee" \
  "$(resolve_effective_cmd_raw '{"cmd0":"tee"}')"
assert_eq "C6.fn2_noassign_cmd0_null_argv" "tee" \
  "$(resolve_effective_cmd_raw '{"cmd0":"tee","argv":null}')"

# ---------------------------------------------------------------------------
# C6.fat: malformed argv type — argv is a non-array value (string or plain object).
# resolveEffectiveCommand must return null (fail-closed, no throw).
# resolveEffectiveArgv must return [] (fail-closed, no throw).
# Fail before fix: segment-utils.js absent.
# ---------------------------------------------------------------------------
assert_eq "C6.fat1_string_argv_resolveCmd_null" "null" \
  "$(resolve_effective_cmd_raw '{"cmd0":"A=1","argv":"tee"}')"
assert_eq "C6.fat2_object_argv_resolveCmd_null" "null" \
  "$(resolve_effective_cmd_raw '{"cmd0":"A=1","argv":{}}')"
# C6.fat3/fat4 use resolve_effective_argv_raw — defined below; assertions placed there.

# ---------------------------------------------------------------------------
# C6.mi: malformed IR shape at isGhWriteIR/collectBashWriteTargets integration boundary.
# Proves fail-closed (returns false/NO_TARGETS) without throwing on bad IR shapes.
# Regression guards (pass both before and after fix — current code already handles these).
# ---------------------------------------------------------------------------
is_gh_write_raw_ir() {
  ( cd "$REPO" && node -e '
    const {isGhWriteIR} = require("./hooks/lib/bash-write-patterns/patterns");
    const ir = JSON.parse(process.argv[1]);
    try { process.stdout.write(String(isGhWriteIR(ir))); }
    catch(e) { process.stdout.write("THREW:" + e.message.split("\n")[0]); }
  ' "$1" ) 2>/dev/null
}
assert_eq "C6.mi1_null_ir_no_throw" "false" "$(is_gh_write_raw_ir 'null')"
assert_eq "C6.mi2_empty_ir_no_throw" "false" "$(is_gh_write_raw_ir '{}')"
assert_eq "C6.mi3_null_segments_no_throw" "false" "$(is_gh_write_raw_ir '{"segments":null}')"
assert_eq "C6.mi4_empty_segments_no_throw" "false" "$(is_gh_write_raw_ir '{"segments":[]}')"

# resolveEffectiveArgv malformed segment API — same fail-closed contract.
resolve_effective_argv_raw() {
  ( cd "$REPO" && node -e '
    const {resolveEffectiveArgv} = require("./hooks/lib/bash-write-patterns/segment-utils");
    const seg = JSON.parse(process.argv[1]);
    const result = resolveEffectiveArgv(seg);
    process.stdout.write(JSON.stringify(result));
  ' "$1" ) 2>/dev/null
}

assert_eq "C6.fa1_argv_missing_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":"A=1"}')"
assert_eq "C6.fa2_argv_null_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":"A=1","argv":null}')"
assert_eq "C6.fa3_argv_empty_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":"A=1","argv":[]}')"
assert_eq "C6.fa4_null_seg_empty" "[]" \
  "$(resolve_effective_argv_raw 'null')"
assert_eq "C6.fa5_empty_obj_empty" "[]" \
  "$(resolve_effective_argv_raw '{}')"
# C6.fna: non-assignment cmd0 with missing/null argv → [] (no args available).
assert_eq "C6.fna1_noassign_no_argv_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":"tee"}')"
assert_eq "C6.fna2_noassign_null_argv_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":"tee","argv":null}')"

# C6.fat3/fat4: malformed argv type for resolveEffectiveArgv (defined above; placed here).
assert_eq "C6.fat3_string_argv_resolveArgv_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":"A=1","argv":"tee"}')"
assert_eq "C6.fat4_object_argv_resolveArgv_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":"A=1","argv":{}}')"

# C6.ec: empty and null cmd0 edge cases — pins boundary behavior.
# C6.ec1: resolve_effective_cmd_raw uses String(result) which would produce empty output for "".
#   Use inline JSON.stringify to distinguish "" from null/empty-output before fix.
# C6.ec2: null cmd0 → seg.cmd0==null → return null → String(null)→ "null".
# C6.ec3: empty cmd0 → resolveEffectiveArgv: ASSIGN_RE.test("") false → no argv → return [].
# C6.ec4: null cmd0 → resolveEffectiveArgv: null guard (cmd0==null) → return [] fail-closed.
assert_eq "C6.ec1_empty_cmd0_resolveCmd" '""' \
  "$(cd "$REPO" && node -e 'const {resolveEffectiveCommand}=require("./hooks/lib/bash-write-patterns/segment-utils");process.stdout.write(JSON.stringify(resolveEffectiveCommand(JSON.parse(process.argv[1]))));' '{"cmd0":""}' 2>/dev/null)"
assert_eq "C6.ec2_null_cmd0_resolveCmd_null" "null" \
  "$(resolve_effective_cmd_raw '{"cmd0":null,"argv":["tee"]}')"
assert_eq "C6.ec3_empty_cmd0_resolveArgv_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":""}')"
assert_eq "C6.ec4_null_cmd0_resolveArgv_empty" "[]" \
  "$(resolve_effective_argv_raw '{"cmd0":null,"argv":["tee"]}')"

# C6.nc: no cmd0 field at all (undefined), argv present — adversarial shape.
# Fail before fix: segment-utils.js missing → require throws → empty output.
# After fix: resolveEffectiveCommand: cmd0==null (undefined==null) → null.
#            resolveEffectiveArgv: null guard for cmd0 → [] fail-closed.
assert_eq "C6.nc1_no_cmd0_with_argv_resolveCmd" "null" \
  "$(resolve_effective_cmd_raw '{"argv":["tee","out.txt"]}')"
assert_eq "C6.nc2_no_cmd0_with_argv_resolveArgv" "[]" \
  "$(resolve_effective_argv_raw '{"argv":["tee","out.txt"]}')"

# ---------------------------------------------------------------------------
# C6.ip: idempotency and mutation-safety probe.
# Proves: (a) calling helpers twice on the same seg yields identical results,
# (b) seg.argv is not mutated by the call, (c) returned argv slice is not aliased.
# Fail before fix: segment-utils.js missing → require throws → empty → FAIL.
# After fix: all checks pass → "OK".
# ---------------------------------------------------------------------------
check_idempotency_and_no_mutation() {
  ( cd "$REPO" && node -e '
    const {resolveEffectiveCommand, resolveEffectiveArgv} =
      require("./hooks/lib/bash-write-patterns/segment-utils");
    const seg = {cmd0: "A=1", argv: ["B=2", "tee", "out.txt"]};
    const r1 = resolveEffectiveCommand(seg);
    const r2 = resolveEffectiveCommand(seg);
    if (r1 !== r2) { process.stdout.write("CMD_NOT_IDEMPOTENT"); process.exit(0); }
    const a1 = resolveEffectiveArgv(seg);
    const a2 = resolveEffectiveArgv(seg);
    if (JSON.stringify(a1) !== JSON.stringify(a2)) { process.stdout.write("ARGV_NOT_IDEMPOTENT"); process.exit(0); }
    if (seg.argv.join(",") !== "B=2,tee,out.txt") { process.stdout.write("SEG_MUTATED"); process.exit(0); }
    a1.push("INJECTED");
    const a3 = resolveEffectiveArgv(seg);
    if (JSON.stringify(a3).includes("INJECTED")) { process.stdout.write("ARGV_ALIASED"); process.exit(0); }
    process.stdout.write("OK");
  ' ) 2>/dev/null
}
assert_eq "C6.ip1_idempotent_no_mutation_no_alias" "OK" \
  "$(check_idempotency_and_no_mutation)"

# C6.ip2: non-assignment branch alias-safety.
# Proves resolveEffectiveArgv returns a COPY (not seg.argv alias) for non-assignment cmd0.
# Requires: implementation uses `return seg.argv.slice()` not `return seg.argv`.
# Before fix: segment-utils.js missing → require throws → empty → "" ≠ "OK" → FAIL.
# After fix without alias fix: push mutates seg.argv → "ALIASED_OR_NOT_IDEMPOTENT" → FAIL.
# After fix with alias fix: returned copy is independent → "OK" → PASS.
check_noassign_argv_not_aliased() {
  ( cd "$REPO" && node -e '
    const {resolveEffectiveArgv} = require("./hooks/lib/bash-write-patterns/segment-utils");
    const seg = {cmd0: "tee", argv: ["out.txt"]};
    const result1 = resolveEffectiveArgv(seg);
    result1.push("MUTATED");
    const segUnchanged = seg.argv.length === 1;
    const result2 = resolveEffectiveArgv(seg);
    const idempotent = JSON.stringify(result2) === JSON.stringify(["out.txt"]);
    process.stdout.write(segUnchanged && idempotent ? "OK" : "ALIASED_OR_NOT_IDEMPOTENT");
  ' ) 2>/dev/null
}
assert_eq "C6.ip2_noassign_argv_not_aliased" "OK" \
  "$(check_noassign_argv_not_aliased)"

# C6.mp1: ASSIGN_RE mutation killed by the test suite.
# bin/mutation-probe.sh mutates ASSIGN_RE to /(?!)/ and verifies that an inline test fails.
# Before fix: segment-utils.js missing → probe exits non-zero (file not found) → FAIL.
# After fix: regex mutation detected → probe exits 0 (100% kill rate) → PASS.
check_assign_regex_mutation_killed() {
  local cmd="node -e 'const {resolveEffectiveCommand}=require(\"./hooks/lib/bash-write-patterns/segment-utils\");const r=resolveEffectiveCommand({cmd0:\"A=1\",argv:[\"B=2\",\"tee\"]});process.exit(r===\"tee\"?0:1);'"
  ( cd "$REPO" && bash bin/mutation-probe.sh \
    hooks/lib/bash-write-patterns/segment-utils.js \
    --test-cmd "$cmd" ) > /dev/null 2>&1
  echo $?
}
assert_eq "C6.mp1_assign_regex_mutation_killed" "0" \
  "$(check_assign_regex_mutation_killed)"

# ---------------------------------------------------------------------------
# C6.ws: behavioral stub wiring test — proves patterns.js CALLS resolveEffectiveCommand
# from segment-utils (not just imports it or uses dead-code). Injects a stub that always
# returns "STUB_CMD" (never "gh") into require.cache BEFORE requiring patterns.js, then
# asserts isGhWriteIR returns false for a chained-prefix "gh" command.
#   Before fix: patterns.js uses inline firstNonAssign → "gh" found → true → FAIL (expected false).
#               OR segment-utils.js missing → patterns.js load fails → empty → FAIL.
#   After fix:  patterns.js calls stub → resolveEffectiveCommand="STUB_CMD" → false → PASS.
# ---------------------------------------------------------------------------
check_patterns_uses_segment_utils_stub() {
  ( cd "$REPO" && node -e '
    const nodePath = require("path");
    const segPath = nodePath.resolve("hooks/lib/bash-write-patterns/segment-utils.js");
    require.cache[segPath] = {
      id: segPath, filename: segPath, loaded: true,
      exports: { resolveEffectiveCommand: () => "STUB_CMD", resolveEffectiveArgv: () => [] }
    };
    const {isGhWriteIR} = require("./hooks/lib/bash-write-patterns/patterns");
    const {parse} = require("./hooks/lib/command-ir");
    const ir = parse("A=1 B=2 gh pr merge");
    process.stdout.write(String(isGhWriteIR(ir)));
  ' ) 2>/dev/null
}
assert_eq "C6.ws1_patterns_uses_segment_utils_stub" "false" \
  "$(check_patterns_uses_segment_utils_stub)"

# C6.ws2: prove resolveEffectiveArgv is also called (not just resolveEffectiveCommand).
# Stub makes resolveEffectiveCommand="gh", resolveEffectiveArgv=["pr","merge","123"].
# Input: "A=1 B=2 echo ghfoo" — real effective command is "echo" (not gh).
#   Before fix: inline firstNonAssign finds "echo" → isGhWriteIR=false → FAIL (expected true).
#   After fix:  stub resolveEffectiveCommand="gh", resolveEffectiveArgv=["pr","merge","123"]
#               → gh pr merge detected as write → isGhWriteIR=true → PASS.
check_patterns_uses_resolveEffectiveArgv_stub() {
  ( cd "$REPO" && node -e '
    const nodePath = require("path");
    const segPath = nodePath.resolve("hooks/lib/bash-write-patterns/segment-utils.js");
    require.cache[segPath] = {
      id: segPath, filename: segPath, loaded: true,
      exports: {
        resolveEffectiveCommand: () => "gh",
        resolveEffectiveArgv: () => ["pr","merge","123"]
      }
    };
    const {isGhWriteIR} = require("./hooks/lib/bash-write-patterns/patterns");
    const {parse} = require("./hooks/lib/command-ir");
    const ir = parse("A=1 B=2 echo ghfoo");
    process.stdout.write(String(isGhWriteIR(ir)));
  ' ) 2>/dev/null
}
assert_eq "C6.ws2_patterns_uses_resolveEffectiveArgv_stub" "true" \
  "$(check_patterns_uses_resolveEffectiveArgv_stub)"

# ---------------------------------------------------------------------------
# C6.cw: require.cache wiring proof — proves modules actually LOAD segment-utils,
# not just contain the string in a comment or dead code.
# After fix: segment-utils.js exists → in cache after require. Before fix: absent → 0.
# ---------------------------------------------------------------------------
check_segment_utils_in_cache() {
  ( cd "$REPO" && node -e '
    const segPath = require.resolve("./hooks/lib/bash-write-patterns/segment-utils");
    require(process.argv[1]);
    process.stdout.write(require.cache[segPath] ? "1" : "0");
  ' "$1" ) 2>/dev/null
}
assert_eq "C6.cw1_patterns_loads_segment_utils" "1" \
  "$(check_segment_utils_in_cache './hooks/lib/bash-write-patterns/patterns')"
assert_eq "C6.cw2_scope_loads_segment_utils" "1" \
  "$(check_segment_utils_in_cache './hooks/enforce-worktree/bash-write-scope')"

# ---------------------------------------------------------------------------
# C6.rx: assignment-regex mutation probe.
# Runs resolveEffectiveCommand against a battery of boundary inputs in a single call.
# Sensitivity: if regex is never-match → A=1 case returns "A=1" (not "tee") → FAIL.
#              if regex is over-broad → 1A=1 case returns "tee" (not "1A=1") → FAIL.
# Five cases: valid(A=1), digit-prefix(1A=1), hyphen(A-1=1), empty-val(A=), underscore(_A=1).
# ---------------------------------------------------------------------------
check_assignment_re() {
  ( cd "$REPO" && node -e '
    const {resolveEffectiveCommand} = require("./hooks/lib/bash-write-patterns/segment-utils");
    const {parse} = require("./hooks/lib/command-ir");
    const cmds = ["A=1 tee out.txt","1A=1 tee out.txt","A-1=1 tee out.txt","A= tee out.txt","_A=1 tee out.txt"];
    const results = cmds.map(cmd => {
      const ir = parse(cmd);
      const seg = (ir && ir.segments && ir.segments[0]) || {};
      return resolveEffectiveCommand(seg);
    }).join(",");
    process.stdout.write(results);
  ' ) 2>/dev/null
}
assert_eq "C6.rx_regex_boundary" "tee,1A=1,A-1=1,tee,tee" "$(check_assignment_re)"

# Re-exports via bash-write-patterns.js dispatch file. Fail before fix.
assert_eq "C6.re resolveEffectiveCommand re-export" "function" \
  "$(cd "$REPO" && node -e 'process.stdout.write(typeof require("./hooks/lib/bash-write-patterns").resolveEffectiveCommand)' 2>/dev/null)"
assert_eq "C6.rv resolveEffectiveArgv re-export" "function" \
  "$(cd "$REPO" && node -e 'process.stdout.write(typeof require("./hooks/lib/bash-write-patterns").resolveEffectiveArgv)' 2>/dev/null)"

# ---------------------------------------------------------------------------
# Static assertions: patterns.js must import and CALL segment-utils helpers.
# C6.x1: require present (not just imported-and-ignored).
# C6.x2: inline firstNonAssign variable removed.
# C6.x3: resolveEffectiveArgv( is called (not merely imported) — catches rename/inline
#          bypass where require exists but the real helper is unused.
# ---------------------------------------------------------------------------
assert_eq "C6.x1_patterns_imports_segment_utils" "1" \
  "$(grep -q 'require.*segment-utils' "$REPO/hooks/lib/bash-write-patterns/patterns.js" 2>/dev/null && echo 1 || echo 0)"
assert_eq "C6.x2_patterns_no_inline_firstNonAssign" "0" \
  "$(grep -q 'firstNonAssign' "$REPO/hooks/lib/bash-write-patterns/patterns.js" 2>/dev/null && echo 1 || echo 0)"
assert_eq "C6.x3_patterns_calls_resolveEffectiveArgv" "1" \
  "$(grep -q 'resolveEffectiveArgv(' "$REPO/hooks/lib/bash-write-patterns/patterns.js" 2>/dev/null && echo 1 || echo 0)"

# Static assertions: post-#1295 the per-segment verb routing (with its
# resolveEffectiveCommand dependency) lives in the bash-write-targets barrel's
# collectWriteTargetsFromSegments; bash-write-scope.js delegates to it and no
# longer imports segment-utils directly. It must still not reference effectiveCmd0.
assert_eq "C6.bss1_scope_imports_segment_utils" "0" \
  "$(grep -q 'require.*segment-utils' "$REPO/hooks/enforce-worktree/bash-write-scope.js" 2>/dev/null && echo 1 || echo 0)"
assert_eq "C6.bss2_scope_no_effectiveCmd0" "0" \
  "$(grep -q 'effectiveCmd0' "$REPO/hooks/enforce-worktree/bash-write-scope.js" 2>/dev/null && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# C6.p2: post-#1295 the pwsh guard fires (resolveEffectiveCommand="Set-Content")
# AND the extractor resolves the effective argv, so out.txt is extracted cleanly —
# no fail-closed parseFailure. Before the IR migration the positional-tokens[0]
# limitation forced a null → PARSE_FAILURE; the fix eliminates it.
# ---------------------------------------------------------------------------
get_parse_failure_ir() {
  ( cd "$REPO" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const {collectBashWriteTargets} = require("./hooks/enforce-worktree/bash-write-scope");
    const ir = parse(process.argv[1]);
    const result = collectBashWriteTargets(ir);
    process.stdout.write(result && result.parseFailure ? "PARSE_FAILURE" : "NO_PARSE_FAILURE");
  ' "$1" ) 2>/dev/null
}
assert_eq "C6.p2_pwsh_guard_reached_parsefailure" "NO_PARSE_FAILURE" \
  "$(get_parse_failure_ir 'A=1 B=2 Set-Content out.txt x')"

# ---------------------------------------------------------------------------
# C6.c3: isEverySegmentExcluded transitive fix.
# Before fix: effectiveCmd0="B=2" → rm guard skipped → targets=null → fail-closed → false.
# After fix: resolveEffectiveCommand="rm" → guard fires → target matched → true.
# ---------------------------------------------------------------------------
assert_eq "C6.c3_every_seg_excl_chained_rm_match" "true" \
  "$(every_seg_excluded 'A=1 B=2 rm /tmp/other.txt' '["*.txt"]')"
assert_eq "C6.c3b_every_seg_excl_chained_rm_no_match" "false" \
  "$(every_seg_excluded 'A=1 B=2 rm /tmp/other.sh' '["*.txt"]')"

# ---------------------------------------------------------------------------
# C6.ua/C6.ub: checkUniversalTargetAllow with chained prefix.
# C6.ua: outside-scope target → "allow" after fix (Guard 5 taken).
# C6.ub: in-scope target → "abstain" both before and after (regression guard).
#   Before fix: targets=null → Guard 4 → abstain.
#   After fix: targets in scope → Guard 5 not taken → default abstain.
# ---------------------------------------------------------------------------
assert_eq "C6.ua_chained_cp_outside_scope_ir" "allow" \
  "$(check_universal_allow 'Bash' 'A=1 B=2 cp src /outside/dst.txt' '/tmp/scope' '/tmp/scope' 'ir')"

check_in_scope_abstain() {
  ( cd "$REPO" && node -e '
    const nodePath = require("path");
    const {checkUniversalTargetAllow} = require("./hooks/enforce-worktree/universal-target-allow");
    const {findRepoRoot, normalizeForCompare} = require("./hooks/enforce-worktree/git-repo-detection");
    const {parse} = require("./hooks/lib/command-ir");
    const rawRoot = findRepoRoot(nodePath.join(process.cwd(), "dummy-ref.txt"));
    if (!rawRoot) { process.stdout.write("SKIP_NO_REPO"); process.exit(0); }
    const repoRoot = normalizeForCompare(rawRoot) || rawRoot;
    const sessionRoots = new Set([repoRoot]);
    const targetPath = nodePath.join(rawRoot, "out.txt");
    const cmd = "A=1 B=2 cp src " + targetPath;
    const ir = parse(cmd);
    const result = checkUniversalTargetAllow("Bash", {command: cmd}, sessionRoots, rawRoot, ir);
    process.stdout.write(result.verdict);
  ' ) 2>/dev/null
}
assert_eq "C6.ub_chained_cp_in_scope_abstain" "abstain" "$(check_in_scope_abstain)"

# ---------------------------------------------------------------------------
# C6.hook: enforce-worktree.js subprocess dispatch with chained-prefix payload.
# Asserts no-crash AND no unexpected block decision. Without a real session (no
# WIP/scope-roots configured), the hook cannot make a scope-based block decision,
# so both before and after fix the result is no-block. Full allow/block assertion
# requires a live claude -p session (L3 gap — gated on RUN_E2E).
# ---------------------------------------------------------------------------
hook_decision() {
  local output
  output="$( ( cd "$REPO" && node hooks/enforce-worktree.js <<< "$1" 2>/dev/null ) )"
  echo "$output" | node -e '
    let d="";
    process.stdin.on("data", c => d+=c);
    process.stdin.on("end", () => {
      try { const j=JSON.parse(d); process.stdout.write(j.decision||"(none)"); }
      catch(e) { process.stdout.write("INVALID_JSON"); }
    });
  ' 2>/dev/null
}

# Scope-enforcement integration test (C6.4 in the classify_scope TABLE above) proves
# that "A=1 B=2 cp src /outside/dst.txt" reaches bash-write-scope.js and returns
# HAS_TARGETS before/after the fix — that IS the controlled effective-command path test.
# C6.hook1/hook2 below verify the hook produces valid JSON and does not panic.
_hook_cp_result="$(hook_decision '{"tool_name":"Bash","tool_input":{"command":"A=1 B=2 cp src /outside/dst.txt"},"session_id":"test-c6"}')"
assert_eq "C6.hook1_chained_cp_hook_no_crash_no_block" "no_block" \
  "$([ "$_hook_cp_result" != "block" ] && [ "$_hook_cp_result" != "INVALID_JSON" ] && echo no_block || echo block_or_error)"

_hook_inscp_result="$(hook_decision '{"tool_name":"Bash","tool_input":{"command":"A=1 B=2 tee /tmp/out.txt"},"session_id":"test-c6"}')"
assert_eq "C6.hook2_chained_tee_hook_no_crash" "no_crash" \
  "$([ "$_hook_inscp_result" != "INVALID_JSON" ] && echo no_crash || echo invalid_json)"
